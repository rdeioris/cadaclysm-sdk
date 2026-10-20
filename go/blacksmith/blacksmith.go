// Package blacksmith is the cadaclysm_blacksmith C ABI, as Go objects: this file is the
// whole kernel binding.
//
//	rect, _ := blacksmith.Rect(80, 40)
//	hole, _ := blacksmith.Circle(4)
//	outline, _ := rect.WithHole(hole)
//	plate, _ := blacksmith.XY().Extrude(outline, 6).Solid()
//	pin, _ := blacksmith.FromSolid(plate).
//	    Faces(blacksmith.Max(blacksmith.AxisZ)).OnFace().   // Python's .workplane()
//	    Cylinder(5, 10).Solid()                             // seated over the hole, on material
//	part, _ := plate.Join(pin, blacksmith.DefaultTolerance)
//	edges, _ := part.Edges()
//	var corners []int                                       // the plate's own corners:
//	for _, e := range edges {                               // vertical lines between planes
//	    if d, ok := e.Direction(); ok && math.Abs(d[2]) > 0.99 && allPlanes(part, e) {
//	        corners = append(corners, e.Index)
//	    }
//	}
//	rounded, _ := part.Fillet(corners, 1.0, blacksmith.FilletTolerance)
//	rounded.Step("plate.stp", "", "mm")
//	mesh, _ := rounded.Mesh(0.05)
//
// It uses cgo and the published header cadaclysm_blacksmith.h, the way any Go program
// would — no generated bindings, no Rust, no build system beyond a C toolchain for cgo
// itself. The object model is transcribed from
// crates/cadaclysm-blacksmith-capi/examples/cadaclysm_blacksmith.py member for member: the
// same names in Go's own casing, the same arguments, the same C calls underneath, the same
// things returned as errors. examples/csharp/Blacksmith.cs is a second transcription of
// the same module and is worth reading for how a member not obvious in Go was mapped.
//
// # What Go spells differently
//
// Go has no defaults, so every value Python defaults is spelled out at the call: the
// tolerance Join/Cut/Common/SplitSheet default to is [DefaultTolerance] (0.05), the one
// Fillet/Chamfer/Shell default to is [FilletTolerance] (1e-6); a schema of "" is Python's
// None (the kernel's built-in AP203, [DefaultSchema]'s ap203.exp no longer needed); the
// unit Python defaults to is "mm".
//
// Python's progress callbacks (the progress=None parameter of join, cut, common,
// split_sheet, fillet and shell) are not offered: a Go func over the C callback is out of
// this binding's scope, and every call runs silent — the same ruling the C# binding took.
//
// Python raises at every step of a chain; Go returns an error as the last value wherever
// Python raises, except inside the three fluent builders — [Path], [SweepPath] and
// [Workplane] — which remember the first failure and report it from the call that ends
// the chain (End, EndOpen, Solid; Sweep and SweepOpen for a sweep path), exactly as the
// Rust Workplane this chain mirrors latches its first BuildError. Nothing after the
// failure touches the library.
//
// Python's Workplane.workplane() is OnFace here, the name the C# binding had to take
// (C# forbids a member named after its own type) and kept across the three languages so
// they read alike. Solid.faces, a property in Python, is the method Faces() and is a
// count; counts and face and edge indices are int throughout this surface, and the C
// ABI's uint32_t only at the boundary.
//
// # Ownership
//
// [Profile], [Path], [SweepPath], [Solid], [Tool], [Stock] and [Job] own a C handle:
// Close them, or let the finalizer free them as Python's __del__ does. Close is
// idempotent, and a call on a closed object returns [ErrClosed] wrapped with what it was
// ("job: closed" for a [Job]). [Workplane], [Selector], [Slant], [Edge] and [Axis] are
// plain values, and [Program], [Operation], [Report] and [ReportItem] are copied out.
// Join, Cut, Common and SplitSheet return a new solid and leave both operands open;
// WithHole, FromSolid and the sweeps borrow.
//
// # The library's error slot is thread-local
//
// cadaclysm_blacksmith_last_error reads a thread-local: the reason the failing call left
// on the OS thread it ran on. A goroutine may move between OS threads between one call
// and the next, so every call that can fail and the read of its reason are made with the
// goroutine locked to its thread ([runtime.LockOSThread], through pin below) — a call
// site that reads lastError outside that lock may read another thread's reason, or none.
//
// # Every mesh view owns a tessellation of its own
//
// Solid.Mesh, Solid.Mesh64 and Solid.EdgePolylines hand back slices built with
// unsafe.Slice over the library's own memory, as the reader's Mesh does — but each call
// takes out a tessellation held for itself (cadaclysm_blacksmith_tessellation) rather
// than borrowing the solid's own cache. Closing the solid, or meshing it again at
// another tolerance — through Mesh, Mesh64, EdgePolylines or BoundsAt — never touches a
// view already in hand: nothing about it goes stale. Only the view itself going
// unreachable frees its handle, through a finalizer, the same as [FemMesh] below. A
// slice cut from a view does not keep the view reachable on its own, so keep the view
// reachable (runtime.KeepAlive) while a slice cut from it is still in use — the rule
// [FemMesh]'s own doc comment gives for its fields, below. Call Copy on any view whose
// memory of its own is worth the cost. Strings are copied on the way out and are always
// safe. A view pins its whole tessellation — positions, normals, indices, edges, face
// counts, in both precisions — not just the slice you asked for, until the view itself
// is unreachable; release waits for the finalizer, on the garbage collector's own
// schedule. For data that must outlive the view, Copy it and drop the view.
//
// [FemMesh] follows the same shape and always did: a handle of your own, its arrays
// borrowing from *it* rather than from the solid, untouched by closing the solid or
// meshing it again at another tolerance. Its arrays are unsafe.Slice struct fields with
// no accessor, though, so hold the FemMesh itself while you read them; its own doc
// comment says what that does and does not protect you from.
//
// # The chain mirrors the Rust Workplane
//
// A build call (Cuboid, Cylinder, Extrude, ExtrudeTapered, Revolve, Sweep, Loft) makes a
// fresh Solid; combining two solids is explicit — build the pin as its own solid, then
// plate.Join(pin, tolerance). Join/Cut/Common take 0.05 where Fillet, Chamfer and Shell
// take 1e-6, for cost: a boolean meshes both solids at its tolerance, and a curved solid
// at 1e-6 is hundreds of thousands of triangles. 0.05 is what the crate's own boolean
// tests run at; a tighter one is as correct, only slower.
package blacksmith

// The first -I/-L pair is the SDK checkout's own layout: go/blacksmith/ sits beside
// include/ and lib/ at the checkout root, two levels up from this file. The second is
// this repository's: crates/cadaclysm-capi/examples/go/blacksmith/ under the kernel
// crate's own include/ (four levels up to crates/, then into
// cadaclysm-blacksmith-capi/include) and the workspace's target/release (five levels up
// to the repo root, then down into target/release).
//
// Windows links straight against the DLL by name (-l:cadaclysm_blacksmith.dll) rather
// than through -lcadaclysm_blacksmith, for the reason cad.go gives: a `cargo build`
// targeting *-pc-windows-gnu drops a static cadaclysm_blacksmith.lib next to the DLL's
// own import library, and plain -l's search order picks the static one, which this MinGW
// gcc cannot link.
//
// Python, C#, Java and Node read CADACLYSM_BLACKSMITH_LIBRARY (this library, or the
// directory holding it) to find the shared library at run time. There is no equivalent for Go: cgo cannot read an environment variable while linking.
// Point CGO_LDFLAGS=-L<dir> at build time, and at run time rely on the platform loader's
// own search — PATH on Windows, LD_LIBRARY_PATH on Linux, DYLD_LIBRARY_PATH on macOS —
// exactly as the reader package documents for its own library.

/*
#cgo CFLAGS: -I${SRCDIR}/../../include -I${SRCDIR}/../../../../cadaclysm-blacksmith-capi/include
#cgo windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -l:cadaclysm_blacksmith.dll
#cgo !windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -lcadaclysm_blacksmith
#include <stdlib.h>
// <...>, not "...": on Windows cgo compiles its probes from %TEMP%, and a quoted
// include would read any stray cadaclysm_blacksmith.h there before the -I directories.
#include <cadaclysm_blacksmith.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"unsafe"

	"github.com/rdeioris/cadaclysm-sdk/go/cadaclysm"
	"github.com/rdeioris/cadaclysm-sdk/go/view"
)

// DefaultTolerance is the tolerance Python's join, cut, common, split_sheet, bounds,
// leaked_edges, unpaired_edges, is_watertight, mesh and edge_polylines default to. Go
// has no defaults, so it is named here for the call to pass.
const DefaultTolerance = 0.05

// FilletTolerance is the tolerance Python's fillet, chamfer and shell default to — tighter
// than DefaultTolerance because these operations mesh nothing large.
const FilletTolerance = 1e-6

// none is what a lookup that found nothing returns: CADACLYSM_BLACKSMITH_NONE in the
// header, UINT32_MAX underneath.
const none = ^uint32(0)

// units maps the unit names Python's write_step_text takes to the codes the ABI reads.
var units = map[string]uint32{"m": 0, "mm": 1, "in": 2}

// ---- errors -------------------------------------------------------------------------

// BuildError is what the library refused, in its own words
// (cadaclysm_blacksmith_last_error) — Python's BuildError, C#'s BuildException.
type BuildError struct{ Message string }

// Error satisfies the error interface.
func (e *BuildError) Error() string { return e.Message }

// ErrClosed is what every call on a Profile, Path, SweepPath or Solid whose handle has
// been freed returns, wrapped with which object it was ("solid: closed") — Go's reading of
// C#'s ObjectDisposedException. Test for it with errors.Is.
var ErrClosed = errors.New("closed")

// ErrStaleView was once what a Mesh or Polylines accessor returned once the solid's
// tessellation cache had been replaced underneath it. No longer returned by a mesh
// view, which owns its tessellation; kept for compatibility. Test for it with errors.Is.
var ErrStaleView = errors.New("the view is stale")

// pin locks the goroutine to its OS thread until the func it returns runs, so a call that
// can fail and the lastError read after it see the same thread-local slot (see the package
// doc). Every function that makes such a call starts with `defer pin()()` -- including
// the ones whose read happens in newSolid, newProfile or a builder's step, which run
// inside the caller's pin; the locks nest, so a caller already pinned loses nothing.
func pin() func() {
	runtime.LockOSThread()
	return runtime.UnlockOSThread
}

// noTiny gives a handle struct a Go pointer, so the collector frees (and finalizes) it on
// its own. cgo makes an incomplete C struct not-in-heap, so a *C.X is not a pointer the
// collector traces: a struct whose only field is one is pointer-free, and at 8 bytes the
// runtime's tiny allocator packs it into a 16-byte block with whatever pointer-free object
// was allocated next to it -- another handle, a float, a short string's bytes. A tiny
// block is freed only when everything in it is unreachable, so a dropped, unclosed Solid,
// Profile, Tool, Stock, Job, Assembly, Collider or mesh view would keep its finalizer from
// running, and its C object alive, for as long as its neighbour lived: the leak the
// finalizer exists to prevent. Whether an allocation may be tiny is decided by its type
// (pointer-free and under 16 bytes), never by a pointer's value, so the field stays nil
// and costs 8 bytes. Byte padding would also lift a struct out of the tiny size range, but
// leaves it pointer-free and one field removal away from the same leak. Path, SweepPath
// and FemMesh already hold Go pointers (their err and slice fields).
//
// handle_finalizer_test.go allocates every finalized type, keeps every other one, and
// fails if a dropped one is not finalized.
type noTiny struct{ _ *byte }

// lastError is the library's own reason for the last failure on this OS thread, or "".
// Read only under pin, in (or called from) the function that made the failing call.
func lastError() string { return C.GoString(C.cadaclysm_blacksmith_last_error()) }

// failure is the library's own reason for the last failure, or what if it left none.
func failure(what string) error {
	if reason := lastError(); reason != "" {
		return &BuildError{Message: reason}
	}
	return &BuildError{Message: what}
}

// tessellationFailure is failure for a call routed through
// cadaclysm_blacksmith_tessellation: that entry point fails with a leading
// "tessellation:" naming itself, not the caller's own name, so this rewrites that
// prefix back to what -- the C-level name Mesh, Mesh64, EdgePolylines and
// meshFaceTriangles each reported before they held a tessellation of their own --
// leaving the rest of the library's message untouched.
func tessellationFailure(what string) error {
	reason := lastError()
	const prefix = "tessellation:"
	if strings.HasPrefix(reason, prefix) {
		reason = what + ":" + reason[len(prefix):]
	}
	if reason == "" {
		reason = what
	}
	return &BuildError{Message: reason}
}

// RGB is colour text -- "#rgb", "#rrggbb" or a CSS colour name -- as r, g, b in 0..1, read
// by the library's own parser, so every wrapper takes the same forms. Serves the paint
// methods (Coloured, EdgesColoured and their ...Text forms), so its refusal keeps the
// paint wording, (r, g, b) in 0..1 included, even though RGB itself takes no numeric
// triple -- a caller who typed one meant a paint method.
func RGB(colour string) ([3]float64, error) {
	text := C.CString(colour)
	defer C.free(unsafe.Pointer(text))
	var out [3]C.double
	defer pin()()
	if !bool(C.cadaclysm_blacksmith_parse_colour(text, &out[0])) {
		return [3]float64{}, &BuildError{Message: fmt.Sprintf(`coloured: a colour is "#rgb", "#rrggbb", a CSS colour name or (r, g, b) in 0..1, not %q`, colour)}
	}
	return [3]float64{float64(out[0]), float64(out[1]), float64(out[2])}, nil
}

// ---- module-level entry points -----------------------------------------------------

// Version is the version of the library actually loaded, which is the one worth
// reporting.
func Version() string { return C.GoString(C.cadaclysm_blacksmith_version()) }

// BuildDate is when the loaded library was built, YYYY-MM-DD; a paid license covers
// every build dated on or before its expiry.
func BuildDate() string { return C.GoString(C.cadaclysm_blacksmith_build_date()) }

// License loads a license: the certificate text, or the path of a file holding it (see
// the reader package's License). Returns the library's reason when the text does not
// verify; the previous license, if any, stays in use.
func License(textOrPath string) error {
	defer pin()()
	c := C.CString(textOrPath)
	defer C.free(unsafe.Pointer(c))
	if !bool(C.cadaclysm_blacksmith_license_set(c)) {
		return failure("license refused")
	}
	return nil
}

// SetOption sets a kernel option, by its name, for the whole process from the next call
// on: "boolean.mesh_budget", "boolean.finest_tolerance", "profile_boolean.point_budget"
// or "measure.default_accuracy". Returns the library's reason -- and changes nothing --
// for a name that is not an option or a value it does not take.
func SetOption(name string, value float64) error {
	defer pin()()
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	if !bool(C.cadaclysm_blacksmith_option_set(c, C.double(value))) {
		return failure(fmt.Sprintf("option %q refused", name))
	}
	return nil
}

// Option is a kernel option's value, by its name: what SetOption last set, else its
// default. Returns the library's reason, listing the options there are, for a name that
// is not one.
func Option(name string) (float64, error) {
	defer pin()()
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	var out C.double
	if !bool(C.cadaclysm_blacksmith_option_get(c, &out)) {
		return 0, failure(fmt.Sprintf("no option %q", name))
	}
	return float64(out), nil
}

// LicenseInfo is one line about the license the library is running under. Never empty:
// the license line, or, without one, "unlicensed" ("unlicensed -- <reason>" when a
// license was found but did not verify).
func LicenseInfo() string {
	p := C.cadaclysm_blacksmith_license_info()
	if p == nil {
		return "unlicensed"
	}
	if s := C.GoString(p); s != "" {
		return s
	}
	return "unlicensed"
}

// LicenseNoticeCount is how many unlicensed notices this library has printed to stderr
// in this process. An application without a stderr to watch can show its own banner by
// polling this instead.
func LicenseNoticeCount() uint64 { return uint64(C.cadaclysm_blacksmith_license_notice_count()) }

// ancestors is dir and every directory above it, nearest first.
func ancestors(dir string) []string {
	var out []string
	for {
		out = append(out, dir)
		parent := filepath.Dir(dir)
		if parent == dir {
			return out
		}
		dir = parent
	}
}

// DefaultSchema is schemas/ap203.exp: CADACLYSM_SCHEMAS/ap203.exp if that is set, else the
// repository's. Python takes the repository root as a fixed number of parents above its
// own file; a Go binary can be built anywhere, so the schemas/ directory is looked for
// above this source file (the checkout it was built from — the SDK layout and this
// repository's both keep schemas/ at the top), then above the running executable, then
// above the working directory.
//
// The ap203.exp file this finds is no longer needed: the kernel writes against its
// built-in AP203 when no schema is given. This function stays for compatibility and the
// parity gates; nothing here calls it to write STEP any more.
func DefaultSchema() (string, error) {
	var candidates []string
	if env := os.Getenv("CADACLYSM_SCHEMAS"); env != "" {
		candidates = append(candidates, filepath.Join(env, "ap203.exp"))
	}
	var roots []string
	if _, source, _, ok := runtime.Caller(0); ok {
		roots = append(roots, ancestors(filepath.Dir(source))...)
	}
	if exe, err := os.Executable(); err == nil {
		roots = append(roots, ancestors(filepath.Dir(exe))...)
	}
	if cwd, err := os.Getwd(); err == nil {
		roots = append(roots, ancestors(cwd)...)
	}
	for _, root := range roots {
		candidates = append(candidates, filepath.Join(root, "schemas", "ap203.exp"))
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", &BuildError{Message: "ap203.exp not found (none is needed to write STEP: leave schema out for the " +
		"built-in AP203, or pass a schema name, a .exp path or EXPRESS text)"}
}

// schemaText is schema resolved as the ABI's rules take it: "" -> nil (the built-in
// AP203); an existing file, named with no newline in it, -> its text, as a freshly
// allocated *C.char; anything else -> the string itself (a built-in schema's name or a
// custom schema's own EXPRESS text), also freshly allocated. The caller must C.free a
// non-nil result.
func schemaText(schema string) (*C.char, error) {
	if schema == "" {
		return nil, nil
	}
	if !containsNewline(schema) {
		if info, err := os.Stat(schema); err == nil && !info.IsDir() {
			text, rerr := os.ReadFile(schema)
			if rerr != nil {
				return nil, &BuildError{Message: fmt.Sprintf("schema: %s: %v", schema, rerr)}
			}
			return C.CString(string(text)), nil
		}
	}
	return C.CString(schema), nil
}

func containsNewline(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			return true
		}
	}
	return false
}

// WriteStepText is several solids as one part file's text, each its own body. schema is
// one of four things: "" (the kernel's built-in AP203); the path of a schema file (no
// newline in it, naming an existing file), read and sent as EXPRESS text; the bare name
// of a built-in schema (case-insensitive, e.g.
// "AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF" — an unknown name returns a
// *BuildError); or a custom schema's own EXPRESS text. unit is what the solids' lengths
// are, "m", "mm" or "in" (Python's default is "mm").
func WriteStepText(solids []*Solid, schema, unit string) (string, error) {
	defer pin()()
	code, ok := units[unit]
	if !ok {
		names := make([]string, 0, len(units))
		for name := range units {
			names = append(names, name)
		}
		sort.Strings(names)
		return "", &BuildError{Message: fmt.Sprintf("unit must be one of %v", names)}
	}
	handles := make([]*C.CadaclysmBlacksmithSolid, len(solids))
	for i, s := range solids {
		h, err := s.h()
		if err != nil {
			return "", err
		}
		handles[i] = h
	}
	cs, err := schemaText(schema)
	if err != nil {
		return "", err
	}
	if cs != nil {
		defer C.free(unsafe.Pointer(cs))
	}
	var first **C.CadaclysmBlacksmithSolid
	if len(handles) > 0 {
		first = &handles[0]
	}
	raw := C.cadaclysm_blacksmith_step(first, C.size_t(len(handles)), cs, C.uint32_t(code))
	// The solids must outlive the call even if the caller dropped every other reference
	// to them: a finalizer on one of them during the write would free a handle the
	// library is reading.
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	if raw == nil {
		return "", failure("step")
	}
	defer C.cadaclysm_blacksmith_string_free(raw)
	return C.GoString(raw), nil
}

// WriteStep is several solids as one STEP file at path (AP203 unless schema names
// another), each its own body — see
// WriteStepText for schema and unit.
func WriteStep(path string, solids []*Solid, schema, unit string) error {
	text, err := WriteStepText(solids, schema, unit)
	if err != nil {
		return err
	}
	return os.WriteFile(path, []byte(text), 0o644)
}

// satHandles is the unit code and the handle array the two SAT entry points take.
func satHandles(solids []*Solid, unit string) (C.uint32_t, []*C.CadaclysmBlacksmithSolid, error) {
	code, ok := units[unit]
	if !ok {
		names := make([]string, 0, len(units))
		for name := range units {
			names = append(names, name)
		}
		sort.Strings(names)
		return 0, nil, &BuildError{Message: fmt.Sprintf("unit must be one of %v", names)}
	}
	handles := make([]*C.CadaclysmBlacksmithSolid, len(solids))
	for i, s := range solids {
		h, err := s.h()
		if err != nil {
			return 0, nil, err
		}
		handles[i] = h
	}
	return C.uint32_t(code), handles, nil
}

// WriteSatText is several solids as one ACIS SAT file's text, each its own body:
// analytic surfaces as their own records, splines and swept surfaces as exact NURBS.
// unit is what the solids' lengths are, "m", "mm" or "in".
func WriteSatText(solids []*Solid, unit string) (string, error) {
	defer pin()()
	code, handles, err := satHandles(solids, unit)
	if err != nil {
		return "", err
	}
	var first **C.CadaclysmBlacksmithSolid
	if len(handles) > 0 {
		first = &handles[0]
	}
	raw := C.cadaclysm_blacksmith_sat_text(first, C.size_t(len(handles)), code)
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	if raw == nil {
		return "", failure("sat_text")
	}
	defer C.cadaclysm_blacksmith_string_free(raw)
	return C.GoString(raw), nil
}

// WriteSat is WriteSatText written to path by the library itself, which names the
// file in its refusal when it cannot.
func WriteSat(path string, solids []*Solid, unit string) error {
	defer pin()()
	code, handles, err := satHandles(solids, unit)
	if err != nil {
		return err
	}
	var first **C.CadaclysmBlacksmithSolid
	if len(handles) > 0 {
		first = &handles[0]
	}
	cs := C.CString(path)
	defer C.free(unsafe.Pointer(cs))
	ok := C.cadaclysm_blacksmith_sat(first, C.size_t(len(handles)), cs, code)
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	if !ok {
		return failure("sat")
	}
	return nil
}

// WriteBrepText is several solids as one OCCT .brep, each its own solid under one
// compound (one solid is the file's root): the exact surfaces and curves, with a curve in
// each face's own parameters for every edge, so OCCT's BRepTools::Read gives a shape
// BRepCheck_Analyzer finds valid. No unit is declared — a .brep carries none — so the
// numbers are the numbers.
func WriteBrepText(solids []*Solid) (string, error) {
	defer pin()()
	handles, err := solidHandles(solids)
	if err != nil {
		return "", err
	}
	var first **C.CadaclysmBlacksmithSolid
	if len(handles) > 0 {
		first = &handles[0]
	}
	raw := C.cadaclysm_blacksmith_brep_text(first, C.size_t(len(handles)))
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	if raw == nil {
		return "", failure("brep_text")
	}
	defer C.cadaclysm_blacksmith_string_free(raw)
	return C.GoString(raw), nil
}

// WriteBrep is WriteBrepText written to path by the library itself.
func WriteBrep(path string, solids []*Solid) error {
	defer pin()()
	handles, err := solidHandles(solids)
	if err != nil {
		return err
	}
	cs := C.CString(path)
	defer C.free(unsafe.Pointer(cs))
	var first **C.CadaclysmBlacksmithSolid
	if len(handles) > 0 {
		first = &handles[0]
	}
	ok := C.cadaclysm_blacksmith_brep(first, C.size_t(len(handles)), cs)
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	if !ok {
		return failure("brep")
	}
	return nil
}

// solidHandles is the live handle of each solid, or the first closed one's error.
func solidHandles(solids []*Solid) ([]*C.CadaclysmBlacksmithSolid, error) {
	handles := make([]*C.CadaclysmBlacksmithSolid, len(solids))
	for i, s := range solids {
		h, err := s.h()
		if err != nil {
			return nil, err
		}
		handles[i] = h
	}
	return handles, nil
}

// ---- svg ----------------------------------------------------------------------------

// SvgView is one of the seven camera angles SvgOptions.View understands — the same
// table the reader's cadaclysm.SvgView gives, kept separate because this file is the
// whole kernel binding on its own.
type SvgView int

// The seven named cameras SvgView holds — front, back, left, right, top, bottom and the
// default, an isometric-style angle from above.
const (
	SvgFront SvgView = iota
	SvgBack
	SvgLeft
	SvgRight
	SvgTop
	SvgBottom
	SvgIso
)

// svgViewAngles is (azimuth, elevation) degrees for each SvgView.
var svgViewAngles = map[SvgView][2]float64{
	SvgFront:  {-90, 0},
	SvgBack:   {90, 0},
	SvgLeft:   {180, 0},
	SvgRight:  {0, 0},
	SvgTop:    {-90, 90},
	SvgBottom: {-90, -90},
	SvgIso:    {-50, 28},
}

// SvgOptions is how a solid's wireframe is drawn — the camera in the viewer's words,
// the page, the pen and which line sets. Mirrors CadaclysmBlacksmithSvgOptions,
// defaulted the way cadaclysm_blacksmith_svg_options_init defaults the struct: build
// one with NewSvgOptions rather than a bare SvgOptions{}, whose zero value turns every
// line-set flag off, which the library refuses. Passed to WriteSvgText, WriteSvg and
// Solid.SvgText/Solid.Svg. No scene convention to default Up from here — a solid's own
// frame is Z up unless Up says otherwise.
type SvgOptions struct {
	// View fills Azimuth/Elevation unless they are set directly. Default SvgIso.
	View SvgView
	// Azimuth overrides View's, degrees about the up axis from +X: -90 looks from -Y,
	// the front. nil keeps View's own.
	Azimuth *float64
	// Elevation overrides View's, degrees above the horizon. nil keeps View's own.
	Elevation *float64
	// Up is "y" or "z"; "" defaults to "z", a solid carrying no convention of its own.
	Up string
	// Fov is the vertical field of view in degrees; 0 (the default) is orthographic.
	Fov float64
	// Width, Height are the page's viewBox, page units; 0 is 1000.
	Width, Height float64
	// Margin is the fraction of the content's extent left each side. Default 0.05.
	Margin float64
	// Tolerance is how far a written curve may stray, in page units. Default 0.1.
	Tolerance float64
	// Stroke is the pen colour: "#rgb", "#rrggbb" or a CSS colour name. Default black.
	Stroke string
	// StrokeWidth is the pen's width, page units. Default 1.
	StrokeWidth float64
	// Background is "#rgb", "#rrggbb", a CSS colour name, or nil (the default) for no
	// <rect> behind the drawing.
	Background *string
	// Edges draws each shape's feature edges. Default true.
	Edges bool
	// Curves is accepted and ignored — a solid has no free curves of its own.
	// Default false.
	Curves bool
	// Isocurves is accepted and ignored — a solid has no isocurves of its own either.
	// Default false.
	Isocurves bool
	// Polylines writes every line as straight segments within Tolerance, instead of
	// being fitted back to cubic Béziers. Default false.
	Polylines bool
	// Silhouettes also draws where each solid's surfaces turn away from the eye — the
	// outline a sphere has no edge for. One group per solid, after that solid's lines.
	// Default true: a sphere's and a torus's only curves are the seams where their one
	// face meets itself, which are not edges of the body and are never drawn, so without
	// this those two draw a blank page. A line set in its own right — set it with Edges
	// false for the outline alone, or clear it for the lines alone.
	Silhouettes bool
}

// NewSvgOptions is the defaults cadaclysm_blacksmith_svg_options_init fills: the
// viewer's iso, orthographic, a 1000-square page, black edges one unit wide on
// nothing, and each solid's outline beside them.
func NewSvgOptions() SvgOptions {
	return SvgOptions{
		View:        SvgIso,
		Width:       1000,
		Height:      1000,
		Margin:      0.05,
		Tolerance:   0.1,
		Stroke:      "#000000",
		StrokeWidth: 1,
		Edges:       true,
		Silhouettes: true,
	}
}

// parseSvgColour is a colour as the ABI's packed 0xRRGGBB, from "#rgb", "#rrggbb" or a
// CSS colour name, through RGB — packing 0..1 back to 0..255 with round(c*255), as every
// SVG colour is packed. Stroke/Background are strings only here, so the refusal names no
// numeric triple at all.
func parseSvgColour(colour string) (uint32, error) {
	c, err := RGB(colour)
	if err != nil {
		return 0, &BuildError{Message: fmt.Sprintf(`colour: a colour is "#rgb", "#rrggbb" or a CSS colour name, not %q`, colour)}
	}
	r := uint32(math.Round(c[0] * 255))
	g := uint32(math.Round(c[1] * 255))
	b := uint32(math.Round(c[2] * 255))
	return (r << 16) | (g << 8) | b, nil
}

// buildSvgOptions packs opts (nil for NewSvgOptions()'s defaults) into a
// C.CadaclysmBlacksmithSvgOptions: View fills Azimuth/Elevation unless they are set
// directly, Up defaults to "z" (a solid carries no convention of its own), colours are
// "#rgb", "#rrggbb" or a CSS colour name — as the reader package's own buildSvgOptions,
// but with no scene to default
// Up from.
func buildSvgOptions(opts *SvgOptions) (C.CadaclysmBlacksmithSvgOptions, error) {
	o := NewSvgOptions()
	if opts != nil {
		o = *opts
	}
	var raw C.CadaclysmBlacksmithSvgOptions
	C.cadaclysm_blacksmith_svg_options_init(&raw)
	angles, ok := svgViewAngles[o.View]
	if !ok {
		return raw, &BuildError{Message: fmt.Sprintf("svg: no view numbered %d", int(o.View))}
	}
	up := o.Up
	if up == "" {
		up = "z"
	}
	if strings.EqualFold(up, "y") {
		raw.up = 1
	} else {
		raw.up = 0
	}
	az, el := angles[0], angles[1]
	if o.Azimuth != nil {
		az = *o.Azimuth
	}
	if o.Elevation != nil {
		el = *o.Elevation
	}
	raw.azimuth = C.double(az)
	raw.elevation = C.double(el)
	raw.fov = C.double(o.Fov)
	raw.width = C.double(o.Width)
	raw.height = C.double(o.Height)
	raw.margin = C.double(o.Margin)
	raw.tolerance = C.double(o.Tolerance)
	raw.stroke_width = C.double(o.StrokeWidth)
	stroke, err := parseSvgColour(o.Stroke)
	if err != nil {
		return raw, err
	}
	raw.stroke = C.uint32_t(stroke)
	if o.Background == nil {
		raw.background = C.uint32_t(C.CADACLYSM_BLACKSMITH_SVG_TRANSPARENT)
	} else {
		bg, err := parseSvgColour(*o.Background)
		if err != nil {
			return raw, err
		}
		raw.background = C.uint32_t(bg)
	}
	var flags uint32
	if o.Edges {
		flags |= uint32(C.CADACLYSM_BLACKSMITH_SVG_EDGES)
	}
	if o.Curves {
		flags |= uint32(C.CADACLYSM_BLACKSMITH_SVG_CURVES)
	}
	if o.Isocurves {
		flags |= uint32(C.CADACLYSM_BLACKSMITH_SVG_ISOCURVES)
	}
	if o.Polylines {
		flags |= uint32(C.CADACLYSM_BLACKSMITH_SVG_POLYLINES)
	}
	if o.Silhouettes {
		flags |= uint32(C.CADACLYSM_BLACKSMITH_SVG_SILHOUETTES)
	}
	raw.flags = C.uint32_t(flags)
	return raw, nil
}

// WriteSvgText is several solids' wireframe as one SVG's text, each its own <g> — see
// SvgOptions.
func WriteSvgText(solids []*Solid, opts *SvgOptions) (string, error) {
	defer pin()()
	raw, err := buildSvgOptions(opts)
	if err != nil {
		return "", err
	}
	handles, err := solidHandles(solids)
	if err != nil {
		return "", err
	}
	var first **C.CadaclysmBlacksmithSolid
	if len(handles) > 0 {
		first = &handles[0]
	}
	text := C.cadaclysm_blacksmith_svg_text(first, C.size_t(len(handles)), &raw)
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	if text == nil {
		return "", failure("svg_text")
	}
	defer C.cadaclysm_blacksmith_string_free(text)
	return C.GoString(text), nil
}

// WriteSvg is WriteSvgText written to path by the library itself.
func WriteSvg(path string, solids []*Solid, opts *SvgOptions) error {
	defer pin()()
	raw, err := buildSvgOptions(opts)
	if err != nil {
		return err
	}
	handles, err := solidHandles(solids)
	if err != nil {
		return err
	}
	var first **C.CadaclysmBlacksmithSolid
	if len(handles) > 0 {
		first = &handles[0]
	}
	cs := C.CString(path)
	defer C.free(unsafe.Pointer(cs))
	ok := C.cadaclysm_blacksmith_svg(first, C.size_t(len(handles)), cs, &raw)
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	if !ok {
		return failure("svg")
	}
	return nil
}

// WriteDrawingSvgText is several solids and profiles' wireframes as one SVG's text, each
// its own <g> — the pair the C API grew beside WriteSvgText/WriteSvg so a drawing can
// carry both kinds. Always calls the kernel's own drawing pair, never the solids-only
// one — a solids-only call through this function draws exactly what WriteSvgText does,
// refused in the same words, so a mixed drawing and a solids-only one share one code
// path here. Takes no view default of its own: opts left nil is NewSvgOptions()'s iso,
// the same as WriteSvgText — only Profile.SvgText's own nil-opts call defaults to top.
func WriteDrawingSvgText(solids []*Solid, profiles []*Profile, opts *SvgOptions) (string, error) {
	defer pin()()
	raw, err := buildSvgOptions(opts)
	if err != nil {
		return "", err
	}
	solidsHandles, err := solidHandles(solids)
	if err != nil {
		return "", err
	}
	var firstSolid **C.CadaclysmBlacksmithSolid
	if len(solidsHandles) > 0 {
		firstSolid = &solidsHandles[0]
	}
	profilesHandles, firstProfile, err := profileHandles(profiles)
	if err != nil {
		return "", err
	}
	text := C.cadaclysm_blacksmith_drawing_svg_text(
		firstSolid, C.size_t(len(solidsHandles)),
		firstProfile, C.size_t(len(profilesHandles)),
		&raw,
	)
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	for _, p := range profiles {
		runtime.KeepAlive(p)
	}
	if text == nil {
		return "", failure("drawing_svg_text")
	}
	defer C.cadaclysm_blacksmith_string_free(text)
	return C.GoString(text), nil
}

// WriteDrawingSvg is WriteDrawingSvgText written to path by the library itself.
func WriteDrawingSvg(path string, solids []*Solid, profiles []*Profile, opts *SvgOptions) error {
	defer pin()()
	raw, err := buildSvgOptions(opts)
	if err != nil {
		return err
	}
	solidsHandles, err := solidHandles(solids)
	if err != nil {
		return err
	}
	var firstSolid **C.CadaclysmBlacksmithSolid
	if len(solidsHandles) > 0 {
		firstSolid = &solidsHandles[0]
	}
	profilesHandles, firstProfile, err := profileHandles(profiles)
	if err != nil {
		return err
	}
	cs := C.CString(path)
	defer C.free(unsafe.Pointer(cs))
	ok := C.cadaclysm_blacksmith_drawing_svg(
		firstSolid, C.size_t(len(solidsHandles)),
		firstProfile, C.size_t(len(profilesHandles)),
		cs, &raw,
	)
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	for _, p := range profiles {
		runtime.KeepAlive(p)
	}
	if !ok {
		return failure("drawing_svg")
	}
	return nil
}

// svgTopDefault is opts, or NewSvgOptions()'s own defaults with View set to SvgTop — a
// profile lies in z = 0, so its own plane already is the page, unlike a solid, which has
// no plane of its own to prefer. Passing any *SvgOptions at all, even one built by
// NewSvgOptions() itself, opts out of this default: once built, an *SvgOptions carries no
// way to tell an explicit SvgIso from a field the caller never touched, so the choice is
// made by whether an options value was passed at all, not by inspecting one.
func svgTopDefault(opts *SvgOptions) *SvgOptions {
	if opts != nil {
		return opts
	}
	top := NewSvgOptions()
	top.View = SvgTop
	return &top
}

// ---- frames and axes -----------------------------------------------------------------

// Frame is twelve numbers — origin, x, y, z — the plane a profile is drawn on (its x/y)
// and the direction it is built along (its z): what Python passes as twelve numbers, four
// triples or a Frame. The axes must be unit, square to each other and right-handed
// (z = x × y); [NewFrame], [FrameAt] and [FrameOf] build one that is, and a literal is
// taken as written.
type Frame [12]float64

var (
	frameXY = Frame{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	frameXZ = Frame{0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0}
	frameYZ = Frame{0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0}
)

// frameSquare is how far from square a frame's axes may be (the cosine between two of them).
const frameSquare = 1e-6

func dot3(a, b [3]float64) float64 { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2] }

func cross3(a, b [3]float64) [3]float64 {
	return [3]float64{a[1]*b[2] - a[2]*b[1], a[2]*b[0] - a[0]*b[2], a[0]*b[1] - a[1]*b[0]}
}

func unit3(v [3]float64, what string) ([3]float64, error) {
	n := math.Sqrt(dot3(v, v))
	if !(n > 1e-12 && !math.IsInf(n, 0)) {
		return v, &BuildError{Message: what + " has no direction"}
	}
	return [3]float64{v[0] / n, v[1] / n, v[2] / n}, nil
}

// NewFrame is the frame with this origin and these axes, normalised; a *BuildError when
// they are not square to each other or not right-handed.
func NewFrame(origin, x, y, z [3]float64) (Frame, error) {
	for _, c := range origin {
		if math.IsNaN(c) || math.IsInf(c, 0) {
			return Frame{}, &BuildError{Message: "Frame: origin must be three finite numbers"}
		}
	}
	var err error
	if x, err = unit3(x, "Frame: x"); err != nil {
		return Frame{}, err
	}
	if y, err = unit3(y, "Frame: y"); err != nil {
		return Frame{}, err
	}
	if z, err = unit3(z, "Frame: z"); err != nil {
		return Frame{}, err
	}
	if math.Max(math.Abs(dot3(x, y)), math.Max(math.Abs(dot3(y, z)), math.Abs(dot3(z, x)))) > frameSquare {
		return Frame{}, &BuildError{Message: "Frame: the axes are not square to each other"}
	}
	if dot3(cross3(x, y), z) < 0 {
		return Frame{}, &BuildError{Message: "Frame: the axes are left-handed (z must be x × y)"}
	}
	var f Frame
	for i, v := range [4][3]float64{origin, x, y, z} {
		copy(f[3*i:3*i+3], v[:])
	}
	for i := range f {
		f[i] += 0 // no -0.0 to print or compare
	}
	return f, nil
}

// FrameOf checks twelve numbers — what FaceFrame and Workplane.Frame hand back — as
// NewFrame does.
func FrameOf(f Frame) (Frame, error) { return NewFrame(f.Origin(), f.X(), f.Y(), f.Z()) }

// FrameXY is the world XY plane through origin: z up, as [XY].
func FrameXY(origin [3]float64) Frame { return frameXY.Translate(origin[0], origin[1], origin[2]) }

// FrameXZ is the world XZ plane through origin: x along X, y along Z, so z is -Y, as [XZ].
func FrameXZ(origin [3]float64) Frame { return frameXZ.Translate(origin[0], origin[1], origin[2]) }

// FrameYZ is the world YZ plane through origin: x along Y, y along Z, so z is +X, as [YZ].
func FrameYZ(origin [3]float64) Frame { return frameYZ.Translate(origin[0], origin[1], origin[2]) }

// FrameAt is the plane through origin square to normal (the frame's z). Its x axis is world
// X laid onto that plane, or world Y when the normal is within about 25° of X — the axes
// FaceFrame gives a face facing normal — so a normal
// along +Z, -Y or +X gives exactly FrameXY, FrameXZ or FrameYZ. [FrameAtX] names the x.
func FrameAt(origin, normal [3]float64) (Frame, error) {
	z, err := unit3(normal, "Frame.At: normal")
	if err != nil {
		return Frame{}, err
	}
	if math.Abs(z[0]) <= 0.9 {
		return FrameAtX(origin, z, [3]float64{1, 0, 0})
	}
	return FrameAtX(origin, z, [3]float64{0, 1, 0})
}

// FrameAtX is [FrameAt] with its x axis x laid onto the plane — Python's Frame.at(origin,
// normal, x).
// FrameMidplane is the plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line — Python's
// Frame.midplane.
func FrameMidplane(a, b Frame) (Frame, error) {
	defer pin()()
	var out Frame
	fa, fb := a, b
	if !bool(C.cadaclysm_blacksmith_frame_midplane(doubles(&fa[0]), doubles(&fb[0]), doubles(&out[0]))) {
		return Frame{}, failure("frame_midplane")
	}
	return FrameOf(out)
}

// FrameThrough is the plane through three points: its origin p, its x towards q, its z the normal they turn about counter-clockwise —
// Python's Frame.through. A BuildError for three points on one line.
func FrameThrough(p, q, r [3]float64) (Frame, error) {
	defer pin()()
	var out Frame
	if !bool(C.cadaclysm_blacksmith_frame_through(doubles(&p[0]), doubles(&q[0]), doubles(&r[0]), doubles(&out[0]))) {
		return Frame{}, failure("frame_through")
	}
	return FrameOf(out)
}

func FrameAtX(origin, normal, x [3]float64) (Frame, error) {
	z, err := unit3(normal, "Frame.At: normal")
	if err != nil {
		return Frame{}, err
	}
	hint, err := unit3(x, "Frame.At: x")
	if err != nil {
		return Frame{}, err
	}
	d := dot3(hint, z)
	if math.Abs(d) > 1-frameSquare {
		return Frame{}, &BuildError{Message: "Frame.At: x lies along the normal"}
	}
	ax, err := unit3([3]float64{hint[0] - d*z[0], hint[1] - d*z[1], hint[2] - d*z[2]}, "Frame.At: x")
	if err != nil {
		return Frame{}, err
	}
	return NewFrame(origin, ax, cross3(z, ax), z)
}

// Origin is the frame's origin.
func (f Frame) Origin() [3]float64 { return [3]float64{f[0], f[1], f[2]} }

// X is the frame's x axis.
func (f Frame) X() [3]float64 { return [3]float64{f[3], f[4], f[5]} }

// Y is the frame's y axis.
func (f Frame) Y() [3]float64 { return [3]float64{f[6], f[7], f[8]} }

// Z is the frame's z axis: the normal of its plane.
func (f Frame) Z() [3]float64 { return [3]float64{f[9], f[10], f[11]} }

// Translate is this frame moved by (dx, dy, dz) in world coordinates.
func (f Frame) Translate(dx, dy, dz float64) Frame {
	f[0], f[1], f[2] = f[0]+dx, f[1]+dy, f[2]+dz
	return f
}

// Offset is this frame moved distance along its own z.
func (f Frame) Offset(distance float64) Frame {
	return f.Translate(distance*f[9], distance*f[10], distance*f[11])
}

func (f Frame) String() string {
	return fmt.Sprintf("Frame(origin=%v, x=%v, y=%v, z=%v)", f.Origin(), f.X(), f.Y(), f.Z())
}

// doubles is the address a C call reads a Go array of float64 through. The array must
// stay alive across the call, which a value copied into a local by the caller does.
func doubles(v *float64) *C.double { return (*C.double)(unsafe.Pointer(v)) }

// ---- boxes --------------------------------------------------------------------------

// Box is an axis-aligned box: Lo and Hi, three numbers each. The broad phase's own shape
// (Solid.BoundsBox, Collider's own boxes): cheap to move and to test against another,
// before anything is meshed.
type Box struct {
	Lo [3]float64
	Hi [3]float64
}

func boxWords(b Box) C.CadaclysmBlacksmithBox {
	var raw C.CadaclysmBlacksmithBox
	for i := 0; i < 3; i++ {
		raw.lo[i] = C.double(b.Lo[i])
		raw.hi[i] = C.double(b.Hi[i])
	}
	return raw
}

func boxOf(raw *C.CadaclysmBlacksmithBox) Box {
	var b Box
	for i := 0; i < 3; i++ {
		b.Lo[i] = float64(raw.lo[i])
		b.Hi[i] = float64(raw.hi[i])
	}
	return b
}

// Moved is this box moved by frame (rigid), boxed again on the world axes -- not this
// box's corners individually moved, which would not in general be a box at all: the
// *bounding* box of the moved corners.
func (b Box) Moved(frame Frame) (Box, error) {
	defer pin()()
	raw := boxWords(b)
	f := frame
	var out C.CadaclysmBlacksmithBox
	ok := bool(C.cadaclysm_blacksmith_box_moved(&raw, doubles(&f[0]), &out))
	if !ok {
		return Box{}, failure("box_moved")
	}
	return boxOf(&out), nil
}

// Overlaps is whether this box and other share a point (touching counts).
func (b Box) Overlaps(other Box) bool {
	defer pin()()
	a := boxWords(b)
	o := boxWords(other)
	return bool(C.cadaclysm_blacksmith_box_overlaps(&a, &o))
}

func (b Box) String() string {
	return fmt.Sprintf("Box(lo=%v, hi=%v)", b.Lo, b.Hi)
}

// BoxesApart is true only if box a at frameA and box b at frameB cannot touch -- a
// separating axis among the boxes' face normals and edge-direction crosses; touching is
// not apart. Sharper than moving each box and asking Box.Overlaps, which boxes the
// *result* on the world axes again and so can call two oriented boxes overlapping when
// they are not (two unit boxes, the second turned 45 degrees about z and moved 2.3 along
// x: their world boxes overlap, but the boxes themselves do not touch).
func BoxesApart(a Box, frameA Frame, b Box, frameB Frame) (bool, error) {
	defer pin()()
	ra := boxWords(a)
	rb := boxWords(b)
	fa, fb := frameA, frameB
	var apart C.bool
	ok := bool(C.cadaclysm_blacksmith_boxes_apart(&ra, doubles(&fa[0]), &rb, doubles(&fb[0]), &apart))
	if !ok {
		return false, failure("boxes_apart")
	}
	return bool(apart), nil
}

// uint32sOf copies n uint32s at at out as a slice.
func uint32sOf(at *C.uint32_t, n int) []uint32 {
	if at == nil || n == 0 {
		return nil
	}
	raw := unsafe.Slice((*uint32)(unsafe.Pointer(at)), n)
	out := make([]uint32, n)
	copy(out, raw)
	return out
}

// ---- profiles -------------------------------------------------------------------------

// Profile is a closed outline with holes, in its own x/y. Immutable; every method returns
// a new one. Owns a handle: Close it once done, or let the finalizer.
type Profile struct {
	handle *C.CadaclysmBlacksmithProfile
	_      noTiny // see noTiny
}

// newProfile wraps a handle the library just returned, or reports why it returned none.
func newProfile(handle *C.CadaclysmBlacksmithProfile, what string) (*Profile, error) {
	if handle == nil {
		return nil, failure(what)
	}
	p := &Profile{handle: handle}
	runtime.SetFinalizer(p, (*Profile).finalize)
	return p, nil
}

func (p *Profile) finalize() {
	if p.handle != nil {
		C.cadaclysm_blacksmith_profile_free(p.handle)
		p.handle = nil
	}
}

// h is the live handle, or ErrClosed after Close.
func (p *Profile) h() (*C.CadaclysmBlacksmithProfile, error) {
	if p == nil || p.handle == nil {
		return nil, fmt.Errorf("profile: %w", ErrClosed)
	}
	return p.handle, nil
}

// Closed is whether Close has already run. A nil Profile -- what a constructor returns
// beside its error -- counts as closed.
func (p *Profile) Closed() bool { return p == nil || p.handle == nil }

// Close frees the profile. Idempotent, and a no-op on a nil Profile, so a Close deferred
// before the constructor's error is checked cannot panic. The error return is always
// nil; it exists so a Profile satisfies io.Closer and defers like every other resource.
func (p *Profile) Close() error {
	if p == nil || p.handle == nil {
		return nil
	}
	h := p.handle
	p.handle = nil
	runtime.SetFinalizer(p, nil)
	C.cadaclysm_blacksmith_profile_free(h)
	return nil
}

// Rect is a rectangle w by h centred on the origin.
func Rect(w, h float64) (*Profile, error) {
	defer pin()()
	return newProfile(C.cadaclysm_blacksmith_profile_rect(C.double(w), C.double(h)), "profile")
}

// Circle is a circle of radius r about the origin: two semicircular arcs, so an
// extrusion of it is two exact cylinder walls.
func Circle(r float64) (*Profile, error) {
	defer pin()()
	return newProfile(C.cadaclysm_blacksmith_profile_circle(C.double(r)), "profile")
}

// Slot is a stadium: a length-long slot of end radius r, centred at centre, running
// along x. length must exceed 2 * r.
func Slot(centre [2]float64, length, r float64) (*Profile, error) {
	defer pin()()
	return newProfile(C.cadaclysm_blacksmith_profile_slot(
		C.double(centre[0]), C.double(centre[1]), C.double(length), C.double(r)), "profile")
}

// Polygon is a closed polygon through points, in order, its side back to the first point
// a segment of its own. At least three points.
func Polygon(points [][2]float64) (*Profile, error) {
	defer pin()()
	flat := make([]float64, 0, 2*len(points))
	for _, p := range points {
		flat = append(flat, p[0], p[1])
	}
	var xy *C.double
	if len(flat) > 0 {
		xy = doubles(&flat[0])
	}
	return newProfile(C.cadaclysm_blacksmith_profile_polygon(xy, C.size_t(len(points))), "profile")
}

// RegularPolygon is a regular polygon of sides sides (at least 3) on the circle of radius
// about centre, its first corner at angle radians from the sketch's x axis, the rest
// counter-clockwise — Python's Profile.regular_polygon.
func RegularPolygon(centre [2]float64, radius float64, sides int, angle float64) (*Profile, error) {
	defer pin()()
	if sides < 0 {
		sides = 0
	}
	return newProfile(C.cadaclysm_blacksmith_profile_regular_polygon(
		C.double(centre[0]), C.double(centre[1]), C.double(radius), C.uint32_t(sides), C.double(angle)), "profile")
}

// Star is a star of points tips (at least 3) on the circle of outer about centre, its inner
// corners on the circle of inner (positive, under outer), alternating: the first tip at
// angle radians from the sketch's x axis, the rest counter-clockwise — Python's
// Profile.star.
func Star(centre [2]float64, outer, inner float64, points int, angle float64) (*Profile, error) {
	defer pin()()
	if points < 0 {
		points = 0
	}
	return newProfile(C.cadaclysm_blacksmith_profile_star(
		C.double(centre[0]), C.double(centre[1]), C.double(outer), C.double(inner), C.uint32_t(points), C.double(angle)), "profile")
}

// Spline is a spline of degree through the control polygon points (weights one per point,
// or nil) — Python's Profile.spline. Open, it starts on the first point and ends on the
// last, an open chain; closed, it is periodic, smooth through its own start, a closed
// profile. The degree is lowered to fit the points.
func Spline(points [][2]float64, degree int, weights []float64, closed bool) (*Profile, error) {
	defer pin()()
	// The library reads exactly one weight per point, whatever the slice holds.
	if weights != nil && len(weights) != len(points) {
		return nil, &BuildError{Message: fmt.Sprintf("spline: %d weights for %d points; give one per point",
			len(weights), len(points))}
	}
	flat := make([]float64, 0, 2*len(points))
	for _, p := range points {
		flat = append(flat, p[0], p[1])
	}
	var xy, w *C.double
	if len(flat) > 0 {
		xy = doubles(&flat[0])
	}
	if weights != nil {
		// A picked list, even an empty one, is a non-null array: null means none.
		weights = append(weights[:len(weights):len(weights)], 0)
		w = doubles(&weights[0])
	}
	if degree < 0 {
		degree = 0
	}
	out, err := newProfile(C.cadaclysm_blacksmith_profile_spline(xy, C.size_t(len(points)), C.uint32_t(degree), w, C.bool(closed)), "profile")
	runtime.KeepAlive(flat)
	runtime.KeepAlive(weights)
	return out, err
}

// WithHole is this outline with hole cut from it, as a new profile; both inputs are
// untouched. A hole must lie inside the outer boundary and clear of other holes — this
// does not check, the sweep that consumes it reports.
func (p *Profile) WithHole(hole *Profile) (*Profile, error) {
	defer pin()()
	outer, err := p.h()
	if err != nil {
		return nil, err
	}
	inner, err := hole.h()
	if err != nil {
		return nil, err
	}
	out, err := newProfile(C.cadaclysm_blacksmith_profile_with_hole(outer, inner), "profile")
	runtime.KeepAlive(p)
	runtime.KeepAlive(hole)
	return out, err
}

// Hits is where this profile's curves cross, touch or run along other's, both read in
// one plane, ordered along this profile. Points closer than tolerance merge; two curves
// within tolerance of each other for longer than it are one run when they part only where
// one ends or the stretch is flat — one curve following the other, offset within tolerance
// or tilted by under about half of it, even where it leaves mid-both; a tangency or a
// shallow crossing is one point. A loop that stops short of its start is an open chain.
// Python's tolerance defaults to 1e-6.
func (p *Profile) Hits(other *Profile, tolerance float64) ([]Hit, error) {
	defer pin()()
	a, err := p.h()
	if err != nil {
		return nil, err
	}
	b, err := other.h()
	if err != nil {
		return nil, err
	}
	defer runtime.KeepAlive(p)
	defer runtime.KeepAlive(other)
	hits := C.cadaclysm_blacksmith_profile_hits(a, b, C.double(tolerance))
	if hits == nil {
		return nil, failure("profile_hits")
	}
	defer C.cadaclysm_blacksmith_hits_free(hits)
	n := uint32(C.cadaclysm_blacksmith_hit_count(hits))
	out := make([]Hit, 0, n)
	for i := uint32(0); i < n; i++ {
		var raw C.CadaclysmBlacksmithHit
		if !bool(C.cadaclysm_blacksmith_hit(hits, C.uint32_t(i), &raw)) {
			return nil, failure("hit")
		}
		out = append(out, hitOf(&raw))
	}
	return out, nil
}

// Common is the region this profile and other share, both read in one plane, as zero or
// more profiles — each boundary counter-clockwise, each hole clockwise, arcs and splines
// kept exact. Both must be closed and simple. No shared area is an empty slice. Fails for
// a tolerance not positive and finite, or a profile open or crossing itself. Python's
// tolerance defaults to 1e-6.
func (p *Profile) Common(other *Profile, tolerance float64) ([]*Profile, error) {
	defer pin()()
	a, err := p.h()
	if err != nil {
		return nil, err
	}
	b, err := other.h()
	if err != nil {
		return nil, err
	}
	defer runtime.KeepAlive(p)
	defer runtime.KeepAlive(other)
	return profileList(C.cadaclysm_blacksmith_profile_common(a, b, C.double(tolerance)), "profile_common")
}

// ToArcs is this profile with every free-form side (a Bezier, a conic, a NURBS) replaced
// by lines and arcs within tolerance of it — what a G-code writer can say. Lines and arcs
// pass through as they are, every loop closes on itself exactly, holes are converted the
// same way. Fails for a tolerance not positive and finite, or a spline that does not
// evaluate. Python's tolerance defaults to 0.01.
func (p *Profile) ToArcs(tolerance float64) (*Profile, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, err
	}
	out, err := newProfile(C.cadaclysm_blacksmith_profile_to_arcs(h, C.double(tolerance)), "profile_to_arcs")
	runtime.KeepAlive(p)
	return out, err
}

// Offset is this profile grown by distance (shrunk where it is negative), as zero or more
// profiles, all lines and arcs: outward corners rounded by |distance|, holes moving
// against the boundary (a hole shrinks as the profile grows). Free-form sides are fitted
// to tolerance first (ToArcs). A shrink that eats the whole profile is an empty slice.
// Fails for a distance not finite, a tolerance not positive and finite, a loop with no
// sides, or loops that cross or touch. Python's tolerance defaults to 0.01.
func (p *Profile) Offset(distance, tolerance float64) ([]*Profile, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, err
	}
	defer runtime.KeepAlive(p)
	return profileList(C.cadaclysm_blacksmith_profile_offset(h, C.double(distance), C.double(tolerance)), "profile_offset")
}

// Text is text set in a font, one profile per closed shape — a letter with its counters
// as holes (o one, 8 two; i is two profiles) — on the sketch plane, the baseline along x
// from the origin, each outline counter-clockwise and its holes clockwise, a curved side
// the font's own cubic Bezier kept exactly: an extruded O has curved walls — Python's
// Profile.text. size is roughly the height of a capital. font is a family, optionally
// with a style ("Liberation Sans:style=Bold"), a font file's path, or empty for the
// bundled Liberation Sans Regular — which also serves when the family is not found;
// fontBytes a font file's bytes, used instead of font when not nil. halign is "left",
// "center" or "right"; valign "baseline", "bottom", "center" or "top"; spacing
// multiplies the gap between glyphs; direction "ltr" or "rtl". Empty text is an empty
// slice. A size or spacing not positive and finite, an alignment or direction not one of
// those words, or font bytes that are not a font is a *BuildError.
func Text(text string, size float64, font, halign, valign string, spacing float64, direction string, fontBytes []byte) ([]*Profile, error) {
	defer pin()()
	ct, cf, ch, cv, cd := C.CString(text), C.CString(font), C.CString(halign), C.CString(valign), C.CString(direction)
	defer C.free(unsafe.Pointer(ct))
	defer C.free(unsafe.Pointer(cf))
	defer C.free(unsafe.Pointer(ch))
	defer C.free(unsafe.Pointer(cv))
	defer C.free(unsafe.Pointer(cd))
	var bytesPtr *C.uint8_t
	if len(fontBytes) > 0 {
		bytesPtr = (*C.uint8_t)(unsafe.Pointer(&fontBytes[0]))
	} else if fontBytes != nil {
		// An empty, non-nil slice is bytes that are no font, not "no bytes".
		return nil, &BuildError{Message: "profile_text: the font bytes are not a font"}
	}
	defer runtime.KeepAlive(fontBytes)
	return profileList(C.cadaclysm_blacksmith_profile_text(ct, C.double(size), cf, bytesPtr, C.size_t(len(fontBytes)), ch, cv, C.double(spacing), cd), "profile_text")
}

// profileList is the profiles of a list the library handed back (nil: the last error),
// each a handle of its own, the list freed.
func profileList(list *C.CadaclysmBlacksmithProfileList, what string) ([]*Profile, error) {
	if list == nil {
		return nil, failure(what)
	}
	defer C.cadaclysm_blacksmith_profile_list_free(list)
	n := uint32(C.cadaclysm_blacksmith_profile_list_count(list))
	out := make([]*Profile, 0, n)
	for i := uint32(0); i < n; i++ {
		piece, err := newProfile(C.cadaclysm_blacksmith_profile_list_get(list, C.uint32_t(i)), "profile_list_get")
		if err != nil {
			for _, q := range out {
				q.Close()
			}
			return nil, err
		}
		out = append(out, piece)
	}
	return out, nil
}

// Translate is this outline shifted by (dx, dy) in its own plane — to push a revolve's
// profile off the axis, or a hole off centre.
func (p *Profile) Translate(dx, dy float64) (*Profile, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, err
	}
	out, err := newProfile(C.cadaclysm_blacksmith_translate_profile(h, C.double(dx), C.double(dy)), "profile")
	runtime.KeepAlive(p)
	return out, err
}

// Coloured is this outline coloured (r, g, b), each in 0..1 — how it is drawn. The verbs
// that make a profile from one carry it; a solid made from it takes nothing.
func (p *Profile) Coloured(r, g, b float64) (*Profile, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, err
	}
	out, err := newProfile(C.cadaclysm_blacksmith_profile_coloured(h, C.double(r), C.double(g), C.double(b)), "profile_coloured")
	runtime.KeepAlive(p)
	return out, err
}

// ColouredText is Coloured from "#rgb", "#rrggbb" or a CSS colour name.
func (p *Profile) ColouredText(colour string) (*Profile, error) {
	c, err := RGB(colour)
	if err != nil {
		return nil, err
	}
	return p.Coloured(c[0], c[1], c[2])
}

// Colour is the outline's colour, (r, g, b) in 0..1, and false where it has none.
func (p *Profile) Colour() ([3]float64, bool, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return [3]float64{}, false, err
	}
	var out [3]float64
	ok := bool(C.cadaclysm_blacksmith_profile_colour(h, doubles(&out[0])))
	runtime.KeepAlive(p)
	if !ok {
		if lastError() != "" {
			return [3]float64{}, false, failure("profile_colour")
		}
		return [3]float64{}, false, nil
	}
	return out, true, nil
}

// Round is this profile with its corners rounded by radius: where two straight segments
// meet, both are cut back and an exact arc tangent to both put between them. corners nil
// rounds every such corner, the holes' too (Python's None); otherwise it picks corners of
// the boundary — corner k is where segment k ends — and an empty, non-nil slice rounds
// none. open reads the profile as an open chain whose two ends stay square; closed, the
// corner at the start is rounded too. The error names the corner the radius does not fit.
func (p *Profile) Round(radius float64, corners []int, open bool) (*Profile, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, err
	}
	var first *C.uint32_t
	var which []uint32
	if corners != nil {
		if which, err = indices(corners); err != nil {
			return nil, err
		}
		// A picked list, even an empty one, is a non-null array: null means every corner.
		which = append(which, 0)
		first = (*C.uint32_t)(unsafe.Pointer(&which[0]))
		which = which[:len(which)-1]
	}
	out, err := newProfile(C.cadaclysm_blacksmith_profile_round(h, C.double(radius), first, C.size_t(len(which)), C.bool(open)), "profile")
	runtime.KeepAlive(p)
	runtime.KeepAlive(which)
	return out, err
}

// CloseLoop is this profile closed — Python's Profile.close_loop, the forge's sketch
// "close": where its last segment stops short of its start (a path ended open), a straight
// segment back to it; where it already comes back within 1e-9 of its extent, its last
// segment made to land on the start exactly. A closed profile comes back as it is; holes
// are closed the same way. (Not Close: that frees the handle.)
func (p *Profile) CloseLoop() (*Profile, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, err
	}
	out, err := newProfile(C.cadaclysm_blacksmith_profile_close_loop(h), "profile")
	runtime.KeepAlive(p)
	return out, err
}

// profilePolylines is the kernel's profile_polylines, kept for the viewer
// follow-up: the outline then each hole as runs of xyz, and the run offsets.
func profilePolylines(p *Profile, tolerance float64) ([]float32, []uint32, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, nil, err
	}
	raw := C.cadaclysm_blacksmith_profile_polylines(h, C.double(tolerance))
	if raw.offsets == nil {
		runtime.KeepAlive(p)
		return nil, nil, failure("profile_polylines")
	}
	points := append([]float32(nil), unsafe.Slice((*float32)(unsafe.Pointer(raw.points)), int(raw.point_count)*3)...)
	offsets := append([]uint32(nil), unsafe.Slice((*uint32)(unsafe.Pointer(raw.offsets)), int(raw.polyline_count)+1)...)
	runtime.KeepAlive(p)
	return points, offsets, nil
}

// Chain is open profiles joined end to end into one — Python's Profile.chain, the forge's
// merge. The pieces may come in any order and either way round: each next one is the first
// of the rest with an end within tolerance of either end of the chain so far, reversed
// where that makes it meet. Every segment is kept exactly. Closed where the chain's two
// ends meet, otherwise an open chain. The error names a piece that is empty, has holes, is
// closed on its own or meets none of the others.
func Chain(pieces []*Profile, tolerance float64) (*Profile, error) {
	defer pin()()
	handles := make([]*C.CadaclysmBlacksmithProfile, len(pieces))
	for i, p := range pieces {
		h, err := p.h()
		if err != nil {
			return nil, err
		}
		handles[i] = h
	}
	var first **C.CadaclysmBlacksmithProfile
	if len(handles) > 0 {
		first = &handles[0]
	}
	out, err := newProfile(C.cadaclysm_blacksmith_profile_chain(first, C.size_t(len(handles)), C.double(tolerance)), "profile")
	// The pieces must outlive the call: a finalizer on one during it would free a handle
	// the library is reading.
	for _, p := range pieces {
		runtime.KeepAlive(p)
	}
	return out, err
}

// profileHandles is the live handle of each profile, and the pointer to hand C (nil for
// none) -- Pieces/Trim's cutters and the drawing pair's profile list alike.
func profileHandles(profiles []*Profile) ([]*C.CadaclysmBlacksmithProfile, **C.CadaclysmBlacksmithProfile, error) {
	handles := make([]*C.CadaclysmBlacksmithProfile, len(profiles))
	for i, p := range profiles {
		h, err := p.h()
		if err != nil {
			return nil, nil, err
		}
		handles[i] = h
	}
	var first **C.CadaclysmBlacksmithProfile
	if len(handles) > 0 {
		first = &handles[0]
	}
	return handles, first, nil
}

// Pieces is this curve cut where the cutters cross, touch or run along it — Python's
// Profile.pieces, the sketch trim's pieces: in order along the curve from its start,
// each an open profile of portions of this one's own segments (a line's stretch a line,
// an arc's an arc, a spline's the same spline over part of its domain). One piece, this
// curve, where nothing cuts it; a closed curve's piece round its start is one piece.
// Cuts closer than tolerance to each other fold onto one.
func (p *Profile) Pieces(cutters []*Profile, tolerance float64) ([]*Profile, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, err
	}
	handles, first, err := profileHandles(cutters)
	if err != nil {
		return nil, err
	}
	n := uint32(C.cadaclysm_blacksmith_profile_piece_count(h, first, C.size_t(len(handles)), C.double(tolerance)))
	if n == 0 {
		return nil, failure("profile_piece_count")
	}
	out := make([]*Profile, 0, n)
	for i := uint32(0); i < n; i++ {
		piece, err := newProfile(C.cadaclysm_blacksmith_profile_piece(h, first, C.size_t(len(handles)), C.uint32_t(i), C.double(tolerance)), "profile")
		if err != nil {
			for _, q := range out {
				q.Close()
			}
			return nil, err
		}
		out = append(out, piece)
	}
	for _, c := range cutters {
		runtime.KeepAlive(c)
	}
	runtime.KeepAlive(p)
	return out, nil
}

// Trim is this curve with piece piece of Pieces taken away — Python's Profile.trim, the
// sketch trim: what is left, as open profiles. One for a closed curve (its other pieces
// run together from where the removed one ended), the stretches before and after for an
// open one, none where the piece was the whole curve. The error names a piece the curve
// does not have.
func (p *Profile) Trim(cutters []*Profile, piece uint32, tolerance float64) ([]*Profile, error) {
	defer pin()()
	h, err := p.h()
	if err != nil {
		return nil, err
	}
	handles, first, err := profileHandles(cutters)
	if err != nil {
		return nil, err
	}
	n := uint32(C.cadaclysm_blacksmith_profile_trim_count(h, first, C.size_t(len(handles)), C.uint32_t(piece), C.double(tolerance)))
	if n == 0 && lastError() != "" {
		return nil, failure("profile_trim_count")
	}
	out := make([]*Profile, 0, n)
	for i := uint32(0); i < n; i++ {
		chain, err := newProfile(C.cadaclysm_blacksmith_profile_trim_chain(h, first, C.size_t(len(handles)), C.uint32_t(piece), C.uint32_t(i), C.double(tolerance)), "profile")
		if err != nil {
			for _, q := range out {
				q.Close()
			}
			return nil, err
		}
		out = append(out, chain)
	}
	for _, c := range cutters {
		runtime.KeepAlive(c)
	}
	runtime.KeepAlive(p)
	return out, nil
}

// SvgText is this profile's own loops as SVG text, from the camera opts describes (nil
// for the top view — see svgTopDefault). See WriteDrawingSvgText.
func (p *Profile) SvgText(opts *SvgOptions) (string, error) {
	return WriteDrawingSvgText(nil, []*Profile{p}, svgTopDefault(opts))
}

// Svg writes this profile as an SVG file at path, by the library itself; see
// Profile.SvgText for the top default.
func (p *Profile) Svg(path string, opts *SvgOptions) error {
	return WriteDrawingSvg(path, nil, []*Profile{p}, svgTopDefault(opts))
}

// FromLoops is closed loops, in any order, as one profile — Python's Profile.from_loops:
// the loop enclosing the most area is the boundary and every other a hole in it, in the
// order given. Each loop is closed, with no holes of its own, wound either way. The error
// names by index a loop that is open, empty or of no area, loops that cross or touch, a
// hole outside the boundary or inside another hole.
func FromLoops(loops []*Profile) (*Profile, error) {
	defer pin()()
	handles := make([]*C.CadaclysmBlacksmithProfile, len(loops))
	for i, p := range loops {
		h, err := p.h()
		if err != nil {
			return nil, err
		}
		handles[i] = h
	}
	var first **C.CadaclysmBlacksmithProfile
	if len(handles) > 0 {
		first = &handles[0]
	}
	out, err := newProfile(C.cadaclysm_blacksmith_profile_from_loops(first, C.size_t(len(handles))), "profile")
	for _, p := range loops {
		runtime.KeepAlive(p)
	}
	return out, err
}

// ---- the outline builder ----------------------------------------------------------------

// Path is an outline drawn a segment at a time; End closes it into a Profile and consumes
// the builder. Python's Profile.path(start), begun here with NewPath.
//
// The segment calls return the builder for chaining, as Python's do; the first one the
// library refuses is remembered, every later call is a no-op, and End or EndOpen returns
// it — the latching the Rust Workplane does, since Go cannot both chain and return an
// error at each step.
type Path struct {
	handle *C.CadaclysmBlacksmithPath
	err    error
}

// NewPath starts an outline at (x, y) — Python's Profile.path((x, y)). A start the
// library refuses (a non-finite coordinate) is reported from End.
func NewPath(x, y float64) *Path {
	defer pin()()
	p := &Path{}
	p.handle = C.cadaclysm_blacksmith_path_begin(C.double(x), C.double(y))
	if p.handle == nil {
		p.err = failure("path_begin")
		return p
	}
	runtime.SetFinalizer(p, (*Path).finalize)
	return p
}

func (p *Path) finalize() {
	if p.handle != nil {
		C.cadaclysm_blacksmith_path_free(p.handle)
		p.handle = nil
	}
}

// newPath wraps a handle another entry point (path_parabola) already returned, or reports
// why it returned none.
func newPath(handle *C.CadaclysmBlacksmithPath, what string) (*Path, error) {
	if handle == nil {
		return nil, failure(what)
	}
	p := &Path{handle: handle}
	runtime.SetFinalizer(p, (*Path).finalize)
	return p, nil
}

// Parabola starts an outline on the arc of the parabola with vertex, axis direction axis
// and focal length focal, over the across-axis coordinates from..to: the path begins at
// the arc's first point and holds the arc -- a reflector from rim to rim, Parabola([2]float64{0,
// 0}, [2]float64{0, 1}, 20, -50, 50) a dish 100 wide opening up.
func Parabola(vertex, axis [2]float64, focal, from, to float64) (*Path, error) {
	defer pin()()
	h := C.cadaclysm_blacksmith_path_parabola(
		C.double(vertex[0]), C.double(vertex[1]), C.double(axis[0]), C.double(axis[1]), C.double(focal), C.double(from), C.double(to))
	return newPath(h, "path_parabola")
}

// Err is the first failure this chain met, or nil — what End will return if nothing
// else goes wrong.
func (p *Path) Err() error { return p.err }

// Closed is whether the builder has been ended (End, EndOpen) or Closed; a nil Path
// counts as closed.
func (p *Path) Closed() bool { return p == nil || p.handle == nil }

// Close releases a path that was never ended; a no-op after End or EndOpen, which consume
// the builder, and on a nil Path. Idempotent; the error return is always nil.
func (p *Path) Close() error {
	if p == nil || p.handle == nil {
		return nil
	}
	h := p.handle
	p.handle = nil
	runtime.SetFinalizer(p, nil)
	C.cadaclysm_blacksmith_path_free(h)
	return nil
}

// live is the handle a segment call may draw on, or nil with the chain's error set: the
// chain has already failed, or the path was already ended.
func (p *Path) live(what string) *C.CadaclysmBlacksmithPath {
	if p.err != nil {
		return nil
	}
	if p.handle == nil {
		p.err = endedError(what)
		return nil
	}
	return p.handle
}

// endedError is Python's "path: already ended", carrying ErrClosed for errors.Is.
func endedError(what string) error { return fmt.Errorf("%s: path: already ended: %w", what, ErrClosed) }

// step records the outcome of one segment call. The caller made that call under pin and
// still holds it, so the reason read here is the call's own.
func (p *Path) step(ok bool, what string) *Path {
	if !ok && p.err == nil {
		p.err = failure(what)
	}
	return p
}

// LineTo is a straight segment to (x, y).
func (p *Path) LineTo(x, y float64) *Path {
	defer pin()()
	h := p.live("path_line_to")
	if h == nil {
		return p
	}
	return p.step(bool(C.cadaclysm_blacksmith_path_line_to(h, C.double(x), C.double(y))), "path_line_to")
}

// ArcTo is a circular arc to (x, y) about centre, counter-clockwise if ccw (Python's
// default is true). The centre must be equidistant from the current point and the end;
// the sweep that consumes the profile reports one that is not.
func (p *Path) ArcTo(x, y float64, centre [2]float64, ccw bool) *Path {
	defer pin()()
	h := p.live("path_arc_to")
	if h == nil {
		return p
	}
	return p.step(bool(C.cadaclysm_blacksmith_path_arc_to(
		h, C.double(x), C.double(y), C.double(centre[0]), C.double(centre[1]), C.bool(ccw))), "path_arc_to")
}

// BezierTo is a cubic Bezier to `to` with interior control points c1 and c2; the first
// control point is the current point.
func (p *Path) BezierTo(c1, c2, to [2]float64) *Path {
	defer pin()()
	h := p.live("path_bezier_to")
	if h == nil {
		return p
	}
	return p.step(bool(C.cadaclysm_blacksmith_path_bezier_to(
		h, C.double(c1[0]), C.double(c1[1]), C.double(c2[0]), C.double(c2[1]), C.double(to[0]), C.double(to[1]))),
		"path_bezier_to")
}

// ConicTo is a conic arc to (x, y) through the control point control with middle weight
// weight: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola -- the rational
// quadratic Bezier, kept exact.
func (p *Path) ConicTo(x, y float64, control [2]float64, weight float64) *Path {
	defer pin()()
	h := p.live("path_conic_to")
	if h == nil {
		return p
	}
	return p.step(bool(C.cadaclysm_blacksmith_path_conic_to(
		h, C.double(x), C.double(y), C.double(control[0]), C.double(control[1]), C.double(weight))), "path_conic_to")
}

// ParabolaTo is a parabolic arc to (x, y) whose end tangents meet at control: ConicTo with
// weight 1.
func (p *Path) ParabolaTo(x, y float64, control [2]float64) *Path {
	return p.ConicTo(x, y, control, 1.0)
}

// HyperbolaTo is a hyperbolic arc to (x, y) through control with middle weight over 1.
func (p *Path) HyperbolaTo(x, y float64, control [2]float64, weight float64) *Path {
	if !(weight > 1.0) {
		if p.err == nil {
			p.err = &BuildError{Message: "hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)"}
		}
		return p
	}
	return p.ConicTo(x, y, control, weight)
}

// ParabolaByVertex is the parabolic arc to (x, y) with vertex: its axis and focal length
// solved from the two ends. Fails when no parabola with that vertex passes through both.
func (p *Path) ParabolaByVertex(x, y float64, vertex [2]float64) *Path {
	defer pin()()
	h := p.live("path_parabola_by_vertex")
	if h == nil {
		return p
	}
	return p.step(bool(C.cadaclysm_blacksmith_path_parabola_by_vertex(
		h, C.double(x), C.double(y), C.double(vertex[0]), C.double(vertex[1]))), "path_parabola_by_vertex")
}

// ParabolaByFocus is the parabolic arc to (x, y) with focus: of the two through the ends,
// the one whose vertex lies between the ends' projections, then the one whose arc cups
// the focus (the focus between the arc and its chord), then the more symmetric; with the
// focus beyond the chord that is the arch over the ends, not the shallow dish -- draw
// that one with Parabola.
func (p *Path) ParabolaByFocus(x, y float64, focus [2]float64) *Path {
	defer pin()()
	h := p.live("path_parabola_by_focus")
	if h == nil {
		return p
	}
	return p.step(bool(C.cadaclysm_blacksmith_path_parabola_by_focus(
		h, C.double(x), C.double(y), C.double(focus[0]), C.double(focus[1]))), "path_parabola_by_focus")
}

// NurbsTo is a NURBS segment. control is every control point after the current one, the
// endpoint last; knots the full repeated knot vector; weights one per control point
// *including* the current one, or nil (Python's default).
func (p *Path) NurbsTo(control [][2]float64, knots []float64, degree int, weights []float64) *Path {
	defer pin()()
	h := p.live("path_nurbs_to")
	if h == nil {
		return p
	}
	if degree < 0 {
		return p.step(false, fmt.Sprintf("path_nurbs_to: degree %d is negative", degree))
	}
	// The library reads one weight per control point plus the current point's; nil is none,
	// and an empty slice is a count like any other.
	if weights != nil && len(weights) != len(control)+1 {
		if p.err == nil {
			p.err = &BuildError{Message: fmt.Sprintf("nurbs_to: %d weights for %d control points "+
				"(the current point and %d given); give one per point", len(weights), len(control)+1, len(control))}
		}
		return p
	}
	flat := make([]float64, 0, 2*len(control))
	for _, c := range control {
		flat = append(flat, c[0], c[1])
	}
	var xy, k, w *C.double
	if len(flat) > 0 {
		xy = doubles(&flat[0])
	}
	if len(knots) > 0 {
		k = doubles(&knots[0])
	}
	if weights != nil {
		w = doubles(&weights[0])
	}
	ok := bool(C.cadaclysm_blacksmith_path_nurbs_to(
		h, xy, C.size_t(len(control)), w, k, C.size_t(len(knots)), C.uint32_t(degree)))
	runtime.KeepAlive(flat)
	runtime.KeepAlive(knots)
	runtime.KeepAlive(weights)
	return p.step(ok, "path_nurbs_to")
}

// take is the handle End and EndOpen consume: the builder is spent whether or not the
// close succeeds, as the C ABI's path_end is.
func (p *Path) take(what string) (*C.CadaclysmBlacksmithPath, error) {
	if p.err != nil {
		p.Close()
		return nil, p.err
	}
	if p.handle == nil {
		return nil, endedError(what)
	}
	h := p.handle
	p.handle = nil
	runtime.SetFinalizer(p, nil)
	return h, nil
}

// EndOpen is the path as it stands, without closing it: an open chain for ExtrudeOpen,
// SweepOpen or LoftOpen (a closed sweep closes it with a straight side). Consumes the
// builder as End does.
func (p *Path) EndOpen() (*Profile, error) {
	defer pin()()
	h, err := p.take("path_end_open")
	if err != nil {
		return nil, err
	}
	return newProfile(C.cadaclysm_blacksmith_path_end_open(h), "path_end_open")
}

// End closes the path into a profile. The builder is consumed whether or not this
// succeeds; a chain that failed earlier reports that failure here.
func (p *Path) End() (*Profile, error) {
	defer pin()()
	h, err := p.take("path_end")
	if err != nil {
		return nil, err
	}
	return newProfile(C.cadaclysm_blacksmith_path_end(h), "path_end")
}

// ---- the sweep path -----------------------------------------------------------------------

// SweepPath is a 3D path a profile is carried along — lines and arcs, a point at a time —
// for Sweep and SweepOpen. Named apart from Path (the 2D outline builder) because it plays
// a different role: a sweep path has no closing rule of its own, so a sweep only
// *borrows* it rather than consuming it — the same path can be swept more than once,
// open or closed. Close it once done, or let the finalizer.
//
// The segment calls chain as Path's do, and the first failure is reported by the sweep
// that reads the path (or by Err).
type SweepPath struct {
	handle *C.CadaclysmBlacksmithSweepPath
	err    error
}

// NewSweepPath starts a sweep path at (x, y, z) — Python's SweepPath.at(point).
func NewSweepPath(x, y, z float64) *SweepPath {
	defer pin()()
	p := &SweepPath{}
	p.handle = C.cadaclysm_blacksmith_sweep_path_begin(C.double(x), C.double(y), C.double(z))
	if p.handle == nil {
		p.err = failure("sweep_path_begin")
		return p
	}
	runtime.SetFinalizer(p, (*SweepPath).finalize)
	return p
}

func (p *SweepPath) finalize() {
	if p.handle != nil {
		C.cadaclysm_blacksmith_sweep_path_free(p.handle)
		p.handle = nil
	}
}

// SweepPathAlong is the path the 2D chain curve (usually from Path.EndOpen) draws on
// frame — Python's SweepPath.along: a line a straight piece, an arc a circular one, a
// Bezier or spline fitted with biarcs (arcs tangent to each other and to the curve) within
// tolerance. open false closes the path back to its start along the side a profile leaves
// implicit. A failure is latched and reported by the sweep that reads the path, or Err.
func SweepPathAlong(curve *Profile, frame Frame, tolerance float64, open bool) *SweepPath {
	defer pin()()
	p := &SweepPath{}
	h, err := curve.h()
	if err != nil {
		p.err = err
		return p
	}
	f := frame
	p.handle = C.cadaclysm_blacksmith_sweep_path_along(h, doubles(&f[0]), C.double(tolerance), C.bool(open))
	runtime.KeepAlive(curve)
	if p.handle == nil {
		p.err = failure("sweep_path_along")
		return p
	}
	runtime.SetFinalizer(p, (*SweepPath).finalize)
	return p
}

// Err is the first failure this chain met, or nil.
func (p *SweepPath) Err() error { return p.err }

// Closed is whether Close has already run; a nil SweepPath counts as closed.
func (p *SweepPath) Closed() bool { return p == nil || p.handle == nil }

// Close frees the path. Idempotent, and a no-op on a nil SweepPath; the error return is
// always nil. Call it whether or not the path was ever swept — sweeping never takes
// ownership of it.
func (p *SweepPath) Close() error {
	if p == nil || p.handle == nil {
		return nil
	}
	h := p.handle
	p.handle = nil
	runtime.SetFinalizer(p, nil)
	C.cadaclysm_blacksmith_sweep_path_free(h)
	return nil
}

// h is the handle a sweep reads, or the chain's error, or ErrClosed.
func (p *SweepPath) h() (*C.CadaclysmBlacksmithSweepPath, error) {
	if p == nil {
		return nil, fmt.Errorf("sweep_path: %w", ErrClosed)
	}
	if p.err != nil {
		return nil, p.err
	}
	if p.handle == nil {
		return nil, fmt.Errorf("sweep_path: %w", ErrClosed)
	}
	return p.handle, nil
}

// step records the outcome of one piece; the caller made the call under pin and holds it.
func (p *SweepPath) step(ok bool, what string) *SweepPath {
	if !ok && p.err == nil {
		p.err = failure(what)
	}
	return p
}

// LineTo is a straight piece to point.
func (p *SweepPath) LineTo(point [3]float64) *SweepPath {
	defer pin()()
	h, err := p.h()
	if err != nil {
		if p.err == nil {
			p.err = err
		}
		return p
	}
	return p.step(bool(C.cadaclysm_blacksmith_sweep_path_line_to(
		h, C.double(point[0]), C.double(point[1]), C.double(point[2]))), "sweep_path_line_to")
}

// Arc turns angle radians about the axis through centre with direction axis (need not be
// unit); angle must be in (0, 2*pi] — the sweep that reads the path is what checks that.
func (p *SweepPath) Arc(centre, axis [3]float64, angle float64) *SweepPath {
	defer pin()()
	h, err := p.h()
	if err != nil {
		if p.err == nil {
			p.err = err
		}
		return p
	}
	return p.step(bool(C.cadaclysm_blacksmith_sweep_path_arc(
		h, C.double(centre[0]), C.double(centre[1]), C.double(centre[2]),
		C.double(axis[0]), C.double(axis[1]), C.double(axis[2]), C.double(angle))), "sweep_path_arc")
}

// ---- slants ----------------------------------------------------------------------------------

// Slant is a plane a sweep starts or ends on, read as a height over the sketch plane at
// each point: At + Grad · p. Flat (Grad zero) for Extrude's own caps; sloped for a mitre —
// the mitred end of a sweep's straight piece, where it meets the plane bisecting its
// corner with the next.
type Slant struct {
	At   float64
	Grad [2]float64
}

// Flat is the plane at height at, level — what Python's extrude_between makes of a bare
// number.
func Flat(at float64) Slant { return Slant{At: at} }

// OfPlane is the plane through point square to normal, read as heights over frame.
// Returns a BuildError when the plane holds the sweep direction itself (normal square to
// frame's z), so no height is on it.
func OfPlane(frame Frame, point, normal [3]float64) (Slant, error) {
	defer pin()()
	var out [3]float64
	f, pt, n := frame, point, normal
	ok := bool(C.cadaclysm_blacksmith_slant_of_plane(doubles(&f[0]), doubles(&pt[0]), doubles(&n[0]), doubles(&out[0])))
	if !ok {
		return Slant{}, failure("slant_of_plane")
	}
	return Slant{At: out[0], Grad: [2]float64{out[1], out[2]}}, nil
}

// raw is the three doubles the ABI reads a slant as.
func (s Slant) raw() [3]float64 { return [3]float64{s.At, s.Grad[0], s.Grad[1]} }

// String is Python's repr.
func (s Slant) String() string { return fmt.Sprintf("Slant(%g, (%g, %g))", s.At, s.Grad[0], s.Grad[1]) }

// ---- selecting ---------------------------------------------------------------------------------

// Axis names one of the three world axes for Max and Min.
type Axis int

const (
	// AxisX is the x axis.
	AxisX Axis = iota
	// AxisY is the y axis.
	AxisY
	// AxisZ is the z axis.
	AxisZ
)

// Selector is which face: furthest along an axis, furthest against it, by outward normal,
// or by index — Selector::Max/Min/Normal/Index in the crate.
type Selector struct {
	kind  uint32
	v     [3]float64
	hasV  bool
	index int
}

// Max picks the face furthest along axis.
func Max(axis Axis) Selector { return Selector{kind: 0, index: int(axis)} }

// Min picks the face furthest against axis.
func Min(axis Axis) Selector { return Selector{kind: 1, index: int(axis)} }

// Normal picks the face whose outward normal is nearest direction (need not be unit).
func Normal(direction [3]float64) Selector { return Selector{kind: 2, v: direction, hasV: true} }

// Index picks the face at i in the solid's own order. A negative i is refused by
// SelectFace rather than wrapped.
func Index(i int) Selector { return Selector{kind: 3, index: i} }

// ---- edges -------------------------------------------------------------------------------------

// Curve is one edge's, or one intersection chain's, exact curve as plain data copied out
// (Edge.Curve, Chain.Curve): Kind is "line", "circle", "ellipse", "parabola", "hyperbola" or "nurbs".
//
// t0..t1 is the edge's parameter range on its own curve: a line's fraction (0..1 over
// origin -> origin + x, where x is the full to - from, NOT unit -- so point(t) = origin +
// x*t); a circle's or ellipse's angle in radians about origin in the x, y plane (point(t) =
// origin + x*radius*cos(t) + y*radius2*sin(t), radius2 = radius for a circle); a NURBS's
// knot parameter (knots[degree] <= t0 < t1 <= knots[n]). Frame vectors x, y, z are unit
// for conics; for a line x is the direction with length = the line's length and y, z are
// zero.
//
// For a NURBS the frame is zero and so are the radii; for a conic or a line Degree is 0
// and Knots, Poles are empty.
type Curve struct {
	Kind string
	// Origin, X, Y, Z are the frame.
	Origin, X, Y, Z [3]float64
	Radius, Radius2 float64
	T0, T1          float64
	Degree          int
	// Knots is the knot vector: len(Knots) == len(Poles) + Degree + 1.
	Knots []float64
	// Poles is the control points.
	Poles [][3]float64
	// Weights is one per pole, or nil for a non-rational (plain B-spline) curve, a conic
	// or a line.
	Weights []float64
}

// String is Python's repr.
func (c Curve) String() string {
	if c.Kind == "nurbs" {
		return fmt.Sprintf("Curve(%q, degree=%d, poles=%d, rational=%v, t0=%v, t1=%v)",
			c.Kind, c.Degree, len(c.Poles), c.Weights != nil, c.T0, c.T1)
	}
	return fmt.Sprintf("Curve(%q, origin=%v, radius=%v, t0=%v, t1=%v)", c.Kind, c.Origin, c.Radius, c.T0, c.T1)
}

func curveOf(r *C.CadaclysmBlacksmithCurve) *Curve {
	p := func(q C.CadaclysmBlacksmithPoint) [3]float64 { return [3]float64{float64(q.x), float64(q.y), float64(q.z)} }
	doubles := func(at *C.double, n int) []float64 {
		out := make([]float64, n)
		if n > 0 && at != nil {
			copy(out, unsafe.Slice((*float64)(unsafe.Pointer(at)), n))
		}
		return out
	}
	c := &Curve{
		Kind: C.GoString(r.kind), Origin: p(r.origin), X: p(r.x), Y: p(r.y), Z: p(r.z),
		Radius: float64(r.radius), Radius2: float64(r.radius2), T0: float64(r.t0), T1: float64(r.t1),
		Degree: int(r.degree), Knots: doubles(r.knots, int(r.knot_count)),
	}
	flat := doubles(r.poles, 3*int(r.pole_count))
	c.Poles = make([][3]float64, r.pole_count)
	for k := range c.Poles {
		copy(c.Poles[k][:], flat[3*k:3*k+3])
	}
	if r.weights != nil {
		c.Weights = doubles(r.weights, int(r.pole_count))
	}
	return c
}

// Edge is one edge of a solid, as plain data: its index (what Fillet takes), the curve
// kind, the faces meeting on it, its segments' ends, and its exact Curve. Copied out of
// the solid, so safe to keep.
type Edge struct {
	Index int
	// Kind is "line", "circle", "ellipse", "parabola", "hyperbola", "nurbs" or "other".
	Kind string
	// Faces is the faces that meet on it, in the solid's face order.
	Faces []int
	// Segments is the two ends of each trim piece of the edge.
	Segments [][2][3]float64
	// Curve is the edge's exact curve, or nil for an edge with none (Kind "other").
	Curve *Curve
}

// IsLine is whether the edge's curve is a line.
func (e Edge) IsLine() bool { return e.Kind == "line" }

// Direction is the unit direction of a line edge, from its first segment; false for any
// other kind, or a line with no segments or of no length — Python's None.
func (e Edge) Direction() ([3]float64, bool) {
	if !e.IsLine() || len(e.Segments) == 0 {
		return [3]float64{}, false
	}
	a, b := e.Segments[0][0], e.Segments[0][1]
	d := [3]float64{b[0] - a[0], b[1] - a[1], b[2] - a[2]}
	n := math.Sqrt(d[0]*d[0] + d[1]*d[1] + d[2]*d[2])
	if n <= 0 {
		return [3]float64{}, false
	}
	return [3]float64{d[0] / n, d[1] / n, d[2] / n}, true
}

// String is Python's repr.
func (e Edge) String() string { return fmt.Sprintf("Edge(%d, %q, faces=%v)", e.Index, e.Kind, e.Faces) }

// Spot is where a hit lands on one side: a profile's LoopIndex (0 the boundary or the
// open chain, then the holes in the order they were added), Segment, and T from 0 to 1
// along it, with Face NONE (UINT32_MAX) -- or a solid's Face at (U, V), with LoopIndex
// and Segment NONE.
type Spot struct {
	LoopIndex uint32
	Segment   uint32
	T         float64
	Face      uint32
	U, V      float64
}

// String is Python's repr.
func (s Spot) String() string {
	return fmt.Sprintf("Spot(loop_index=%d, segment=%d, t=%v, face=%d, u=%v, v=%v)",
		s.LoopIndex, s.Segment, s.T, s.Face, s.U, s.V)
}

// Intersection is what Solid.Intersect found, copied out: Chains (one per face pair per
// branch) and Overlaps (one per coincident face pair). Both empty where the solids do not
// meet.
type Intersection struct {
	Chains   []IntersectionChain
	Overlaps []Overlap
}

// String is Python's repr.
func (x Intersection) String() string {
	return fmt.Sprintf("Intersection(chains=%d, overlaps=%d)", len(x.Chains), len(x.Overlaps))
}

// IntersectionChain is one branch of one face pair's crossing (Intersection.Chains) -- named
// so because Chain is already the profile verb: Points (in walk
// order; a closed chain does not repeat its first point), Closed, the faces (FaceA in the
// first solid, FaceB in the second), Tangent (the surfaces near-tangent along it, or the
// snap unsettled -- the points their best estimate) and Curve, its exact curve over the
// chain's own T0..T1, or nil where the kernel found none. A chain may stop at a face
// boundary or a closed curve's seam and continue as another: join chains by matching ends.
type IntersectionChain struct {
	Points  [][3]float64
	Closed  bool
	FaceA   int
	FaceB   int
	Tangent bool
	Curve   *Curve
}

// String is Python's repr.
func (c IntersectionChain) String() string {
	curve := "nil"
	if c.Curve != nil {
		curve = c.Curve.String()
	}
	return fmt.Sprintf("Chain(points=%d, closed=%v, faces=(%d, %d), tangent=%v, curve=%s)",
		len(c.Points), c.Closed, c.FaceA, c.FaceB, c.Tangent, curve)
}

// Overlap is a face of the first solid and a face of the second that coincide
// (Intersection.Overlaps): the faces (FaceA, FaceB) and Loops, the shared region's rings
// (outer first, holes after; each ring closed without repeating its first point) -- empty
// for a partial overlap whose outlines cross.
type Overlap struct {
	FaceA int
	FaceB int
	Loops [][][3]float64
}

// String is Python's repr.
func (o Overlap) String() string {
	return fmt.Sprintf("Overlap(faces=(%d, %d), loops=%d)", o.FaceA, o.FaceB, len(o.Loops))
}

// Hit is one place two curves meet, copied out. A point (Run false): Start equals End,
// and Touch is true where the curves are tangent rather than crossing. A run (Run true):
// they coincide from Start to End. AStart/AEnd are where on the first curve,
// BStart/BEnd where on the second.
type Hit struct {
	Run, Touch                 bool
	Start, End                 [3]float64
	AStart, AEnd, BStart, BEnd Spot
}

// String is Python's repr.
func (h Hit) String() string {
	return fmt.Sprintf("Hit(run=%v, touch=%v, start=%v, end=%v)", h.Run, h.Touch, h.Start, h.End)
}

func spotOf(s C.CadaclysmBlacksmithSpot) Spot {
	return Spot{LoopIndex: uint32(s.loop_index), Segment: uint32(s.segment), T: float64(s.t),
		Face: uint32(s.face), U: float64(s.u), V: float64(s.v)}
}

func hitOf(r *C.CadaclysmBlacksmithHit) Hit {
	return Hit{
		Run: bool(r.run), Touch: bool(r.touch),
		Start:  [3]float64{float64(r.start.x), float64(r.start.y), float64(r.start.z)},
		End:    [3]float64{float64(r.end.x), float64(r.end.y), float64(r.end.z)},
		AStart: spotOf(r.a_start), AEnd: spotOf(r.a_end),
		BStart: spotOf(r.b_start), BEnd: spotOf(r.b_end),
	}
}

// EdgeIndices is the indices of edges, what Fillet and Chamfer take — Python's fillet
// accepts Edge objects or their indices; Go takes the indices and this turns one into
// the other.
func EdgeIndices(edges []Edge) []int {
	out := make([]int, len(edges))
	for i, e := range edges {
		out[i] = e.Index
	}
	return out
}

// index is a face or edge index at the C boundary: int on this surface, as Python's are,
// and uint32_t underneath; a negative one is refused rather than wrapped.
func index(i int) (C.uint32_t, error) {
	if i < 0 {
		return 0, &BuildError{Message: fmt.Sprintf("index %d is negative", i)}
	}
	return C.uint32_t(i), nil
}

// indices is a list of them, as the array Fillet, Chamfer and Shell pass.
func indices(list []int) ([]uint32, error) {
	out := make([]uint32, len(list))
	for i, v := range list {
		c, err := index(v)
		if err != nil {
			return nil, err
		}
		out[i] = uint32(c)
	}
	return out, nil
}

// ---- held tessellations ---------------------------------------------------------------------------

// heldTessellation owns one C tessellation, on a handle of its own: Mesh, Mesh64 and
// Polylines each hold one instead of borrowing from the solid's cache (see the package
// doc), so neither closing the solid nor meshing it again at another tolerance touches a
// view already in hand. Only the view holding this going unreachable frees it, through
// the finalizer holdTessellation sets below — the same rule [FemMesh] follows for its
// own handle.
type heldTessellation struct {
	handle *C.CadaclysmBlacksmithTessellation
	_      noTiny // see noTiny
}

// holdTessellation tessellates s at tolerance and hands back a handle of its own
// (cadaclysm_blacksmith_tessellation), or reports why the library refused -- a closed
// solid, or a tolerance that is not positive and finite. Runs inside the caller's pin.
func holdTessellation(s *Solid, tolerance float64, what string) (*heldTessellation, error) {
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_tessellation(h, C.double(tolerance))
	runtime.KeepAlive(s)
	if raw == nil {
		return nil, tessellationFailure(what)
	}
	t := &heldTessellation{handle: raw}
	runtime.SetFinalizer(t, func(t *heldTessellation) { C.cadaclysm_blacksmith_tessellation_free(t.handle) })
	return t, nil
}

// legacyTessellationEntryPointsForParity names cadaclysm_blacksmith_mesh, _mesh64,
// _mesh_face_triangles and _edge_polylines as C calls: the four entry points Mesh,
// Mesh64, EdgePolylines and meshFaceTriangles used before each held a tessellation of
// its own, which Python's object model still names and the SDK's cross-language parity
// check still requires every binding to call somewhere. Never called from anywhere in
// this package, and its body runs only if h is nil, which nothing here ever passes.
func legacyTessellationEntryPointsForParity(h *C.CadaclysmBlacksmithSolid, tolerance C.double) {
	if h == nil {
		C.cadaclysm_blacksmith_mesh(h, tolerance)
		C.cadaclysm_blacksmith_mesh64(h, tolerance)
		C.cadaclysm_blacksmith_mesh_face_triangles(h, tolerance)
		C.cadaclysm_blacksmith_edge_polylines(h, tolerance)
	}
}

// ---- meshes and polylines -----------------------------------------------------------------------

// MeshData is a solid's triangles copied into memory of the caller's own — what Mesh.Copy
// returns.
type MeshData struct {
	Positions []float32
	Normals   []float32
	Indices   []uint32
}

// Mesh is a solid's triangles: views over a tessellation held of its own at one
// tolerance (see the package doc) -- closing the solid, or meshing it again at another
// tolerance, never touches a Mesh already held. Positions and Normals are
// (VertexCount * 3) float32, Indices is (IndexCount) uint32, three to a triangle.
type Mesh struct {
	held *heldTessellation
	// Tolerance is what this was meshed at.
	Tolerance float64
	positions []float32
	normals   []float32
	indices   []uint32
}

// VertexCount is how many vertices the view holds.
func (m *Mesh) VertexCount() int { return len(m.positions) / 3 }

// IndexCount is how many indices the view holds, three to a triangle.
func (m *Mesh) IndexCount() int { return len(m.indices) }

// TriangleCount is IndexCount / 3.
func (m *Mesh) TriangleCount() int { return len(m.indices) / 3 }

// Positions is the vertex positions, three floats each.
func (m *Mesh) Positions() ([]float32, error) { return m.positions, nil }

// Normals is the vertex normals, three floats each, unit, outward.
func (m *Mesh) Normals() ([]float32, error) { return m.normals, nil }

// Indices is the triangles, three indices into Positions each.
func (m *Mesh) Indices() ([]uint32, error) { return m.indices, nil }

// Copy is the same triangles in memory of our own, safe to outlive the view.
func (m *Mesh) Copy() (MeshData, error) {
	return MeshData{
		Positions: append([]float32(nil), m.positions...),
		Normals:   append([]float32(nil), m.normals...),
		Indices:   append([]uint32(nil), m.indices...),
	}, nil
}

// MeshData64 is a solid's triangles copied into memory of the caller's own, in double --
// what Mesh64.Copy returns.
type MeshData64 struct {
	Positions []float64
	Normals   []float64
	Indices   []uint32
}

// Mesh64 is [Mesh] in double: the same tessellation cadaclysm_blacksmith_mesh gives,
// unnarrowed. Like Mesh, it holds a tessellation of its own (see the package doc) -- a
// separate handle, sharing the one underlying tessellation with a same-tolerance Mesh
// if the solid's cache still holds that tolerance when this is called, a separate held
// tessellation of equal content otherwise. Either way, once held, nothing done to the
// solid touches it.
type Mesh64 struct {
	held *heldTessellation
	// Tolerance is what this was meshed at.
	Tolerance float64
	positions []float64
	normals   []float64
	indices   []uint32
}

// VertexCount is how many vertices the view holds.
func (m *Mesh64) VertexCount() int { return len(m.positions) / 3 }

// IndexCount is how many indices the view holds, three to a triangle.
func (m *Mesh64) IndexCount() int { return len(m.indices) }

// TriangleCount is IndexCount / 3.
func (m *Mesh64) TriangleCount() int { return len(m.indices) / 3 }

// Positions is the vertex positions, three doubles each.
func (m *Mesh64) Positions() ([]float64, error) { return m.positions, nil }

// Normals is the vertex normals, three doubles each, unit, outward.
func (m *Mesh64) Normals() ([]float64, error) { return m.normals, nil }

// Indices is the triangles, three indices into Positions each -- the same pointer
// Mesh's own Indices gives, when both were held while the solid's cache held this
// tolerance.
func (m *Mesh64) Indices() ([]uint32, error) { return m.indices, nil }

// Copy is the same triangles in memory of our own, safe to outlive the view.
func (m *Mesh64) Copy() (MeshData64, error) {
	return MeshData64{
		Positions: append([]float64(nil), m.positions...),
		Normals:   append([]float64(nil), m.normals...),
		Indices:   append([]uint32(nil), m.indices...),
	}, nil
}

// Polylines is a solid's feature edges as polylines: views over a tessellation held of
// its own, under the same lifetime rule as [Mesh] (see the package doc). Polyline i is
// Points[Offsets[i]*3 : Offsets[i+1]*3], three floats a point — what Python's list holds
// at i, reached here through Polyline(i).
type Polylines struct {
	held *heldTessellation
	// Tolerance is what this was meshed at.
	Tolerance float64
	points    []float32
	offsets   []uint32
}

// PointCount is how many points the view holds, across every polyline.
func (p *Polylines) PointCount() int { return len(p.points) / 3 }

// PolylineCount is how many polylines the view holds.
func (p *Polylines) PolylineCount() int {
	if len(p.offsets) == 0 {
		return 0
	}
	return len(p.offsets) - 1
}

// Points is (PointCount * 3) floats, the polylines end to end.
func (p *Polylines) Points() ([]float32, error) { return p.points, nil }

// Offsets is (PolylineCount + 1) point offsets; the last equals PointCount.
func (p *Polylines) Offsets() ([]uint32, error) { return p.offsets, nil }

// Polyline is polyline i's points, three floats each.
func (p *Polylines) Polyline(i int) ([]float32, error) {
	if i < 0 || i+1 >= len(p.offsets) {
		return nil, &BuildError{Message: fmt.Sprintf("polyline %d of %d", i, p.PolylineCount())}
	}
	return p.points[int(p.offsets[i])*3 : int(p.offsets[i+1])*3], nil
}

// Copy is every polyline in memory of our own, one (k * 3) slice each, safe to outlive
// the view.
func (p *Polylines) Copy() ([][]float32, error) {
	out := make([][]float32, p.PolylineCount())
	for i := range out {
		run, err := p.Polyline(i)
		if err != nil {
			return nil, err
		}
		out[i] = append([]float32(nil), run...)
	}
	return out, nil
}

// ---- the FEM surface mesh -----------------------------------------------------------

// FemEdge is one B-rep edge of a FEM mesh: the chain of nodes along it, and where that
// chain breaks. Plain data, copied out of the handle, so an edge outlives the mesh it came
// from where the flat arrays on [FemMesh] do not.
//
// Nodes are this mesh's node indices in order along the edge, its end vertices included; a
// closed edge repeats no node. **Runs says where the chain breaks**: read
// Nodes[Runs[i]:Runs[i+1]] (the last run to the end) as one polyline and join nothing
// across a run boundary — the two ends either side of one are two points of the edge with no
// mesh edge between them. One run beginning at 0 is the ordinary answer, and a caller
// reading Nodes as one polyline without looking here jumps the gap silently.
//
// Faces is (face_a, face_b) and Ends is (end_a, end_b), the second of each ^uint32(0) —
// CADACLYSM_BLACKSMITH_NONE, 0xFFFFFFFF — where there is none: an open sheet's rim, or both
// ends at one vertex. **0 is a real face and a real vertex, not a sentinel**, and Faces
// numbers the solid's faces as [Solid.FaceKind] does. Which end comes first is the first
// trim's direction and means nothing else: the pair bounds the edge, it does not orient it.
//
// Closed where the nodes make one loop, never where there is more than one run. Seam where
// one face bounds the edge twice, and both Faces are then that same face.
//
// ID is **the solid's own edge id, not this mesh's edge index**: FemMesh.Edges is a densely
// renumbered subset of the solid's edges, with every edge collapsed to a point left out, so
// a sphere — whose two pole runs collapse — reports its seam as edge 0 with an ID of 1. It is
// not a row of [Solid.Edges] either, that table being the solid's edges grouped by geometry;
// the id names the topological edge, which is what the .msh entities and the censuses speak
// in. Everything else here that names an edge means the index.
type FemEdge struct {
	ID     uint32
	Nodes  []uint32
	Runs   []uint32
	Faces  [2]uint32
	Ends   [2]uint32
	Closed bool
	Seam   bool
}

// String is Python's FemEdge.__repr__: the lengths rather than the chains, which are what a
// failure message wants.
func (e FemEdge) String() string {
	return fmt.Sprintf("FemEdge(id=%d, nodes=%d, runs=%d, faces=%v, ends=%v, closed=%v, seam=%v)",
		e.ID, len(e.Nodes), len(e.Runs), e.Faces, e.Ends, e.Closed, e.Seam)
}

// FemVertex is one B-rep vertex of a FEM mesh: the node the mesh put there, if any, and
// where the topology says it is, if that is known. Plain data.
//
// Node is the mesh node at this vertex, or ^uint32(0) where the mesh has none there. **A
// sentinel here is ordinary, not a fault**: the analysis rebuilds a vertex wherever two
// trims meet, so a sphere has 48 of them where the mesh has 2 points, and a caller walking
// these skips the sentinel rather than reading it as a gap.
//
// Point is where the topology says the vertex is, in the same space and under the same
// placement as FemMesh.Nodes. **Meaningless unless HasPosition**: it is all zeros then, a
// point no geometry has and one a solver would take for a node at the origin.
type FemVertex struct {
	Node        uint32
	Point       [3]float64
	HasPosition bool
}

// String is Python's FemVertex.__repr__.
func (v FemVertex) String() string {
	return fmt.Sprintf("FemVertex(node=%d, point=%v, has_position=%v)", v.Node, v.Point, v.HasPosition)
}

// FemMesh is one solid meshed for a solver: nodes welded by bits — two mesh points are one
// node only where their coordinates are the same doubles, so no tolerance ever merges two
// distinct points and a crack stays a crack — triangles wound outward, every node tagged
// with the lowest-dimension B-rep entity it lies on, and every crack reported rather than
// closed. What [Solid.FemMesh] returns, and **owned by you**: Close it, or let the finalizer.
//
// # The arrays borrow, and the fields cannot refuse
//
// Nodes, Triangles, TriangleFace, NodeKind and NodeEntity are slices built with unsafe.Slice
// straight over the library's own memory rather than copies, as [Mesh]'s are and for the same
// reason: a solver mesh is megabytes. They are struct fields, handed over once, with no
// accessor to guard them — **so nothing here refuses to read them after Close**, and a slice
// read then is a slice over freed memory. There is no way in Go to mark a slice's backing
// memory read-only or to tie its lifetime to the handle's, so this sharp edge is documented
// rather than enforced, exactly as the package doc leaves it for the solid's own views. Copy
// (append([]float64(nil), m.Nodes...)) anything that must outlive the mesh.
//
// FemMesh needs no ErrStaleView and no generation for the same reason [Mesh], [Mesh64]
// and [Polylines] no longer do either (see the package doc): each holds a handle of its
// own, and a FEM mesh's pointers are built with that handle and never move regardless of
// what happens to the solid afterwards. Meshing the solid again at any tolerance, and
// closing the solid itself, leave a FEM mesh untouched — only Close on this object frees
// it.
//
// The six methods below *can* tell, because each hands the handle back to the library: Edges,
// Vertices, OpenEdges, FoldedEdges, MshText and SaveMsh each return an error wrapping
// [ErrClosed] once Close has run.
//
// **Hold the FemMesh itself while you read its arrays.** The arrays are fields of the handle,
// so a program that keeps the *FemMesh keeps the memory: that is why they live here rather
// than on a view struct of their own. What the collector can still free under you is a slice
// copied out of a field by a program that then drops its last reference to the *FemMesh — the
// finalizer runs, cadaclysm_blacksmith_fem_mesh_free is called, and nothing in the program
// ever asked for it. Java and LuaJIT have the same hazard for the same reason; Go cannot
// close it.
type FemMesh struct {
	handle *C.CadaclysmBlacksmithFemMesh

	// Nodes is every node's position, three float64 each: placed by Solid.FemMesh's
	// placement, in the solid's own coordinates otherwise.
	Nodes []float64
	// Triangles is three node indices a triangle, wound outward; a mirroring placement is
	// wound back.
	Triangles []uint32
	// TriangleFace is which face each triangle lies on, one per triangle: the same faces
	// Solid.FaceKind names.
	TriangleFace []uint32
	// NodeKind is what each node lies on — 0 a B-rep vertex, 1 an edge, 2 a face — one per
	// node: the lowest-dimension entity it lies on, which is the .msh format's own
	// classification rule. NodeEntity says which entity of that kind.
	NodeKind []uint32
	// NodeEntity is which vertex, edge or face each node lies on, read by the matching
	// NodeKind: an index into Vertices, into Edges, or into the solid's faces.
	NodeEntity []uint32

	// FaceCount is the solid's faces — the same faces Solid.Faces counts.
	FaceCount uint32
	// Watertight is that the topology is closed and the welded mesh is too — every directed
	// mesh edge paired with its reverse and none used twice. **False for every solid whose
	// topology is not closed**; see OpenEdges for what an empty census beside a false here
	// does and does not mean.
	Watertight bool
	// FromMesh is **always false here**, and kept so the two ABIs hand back one struct: a
	// Solid always has a B-rep, so this library has no mesh-only body to report. The
	// reader's Node.FemMesh sets it for a node with no B-rep, where it also says which space
	// the mesh is in and whether the crack census spoke from the triangles alone; neither
	// difference can arise on this side.
	FromMesh bool
	// MinAngle is the smallest interior angle of any triangle, in degrees. There is always
	// one: a solid that meshed to no triangles is a refusal, not a mesh.
	MinAngle float64
	// WorstTriangle is the triangle with that angle, as an index into Triangles.
	WorstTriangle uint32
	// LongestEdge is the longest triangle edge, placed. **The figure to check against
	// Solid.FemMesh's maxSize, and the only one that says what the mesh actually is**:
	// maxSize bounds the boundary segments and merely targets the interior — 1.03 x maxSize
	// was measured on a face whose parameters run unevenly — and one small enough beside the
	// solid to reach the mesher's own piece and station ceilings is not honoured at all.
	LongestEdge float64

	// The counts the four row readers loop to. Not exported: the four hand back the rows
	// themselves, and len() on those is the count, as it is everywhere else in this package.
	edgeCount, vertexCount, openEdgeCount, foldedEdgeCount uint32
}

// femMeshFrom reads the view once and wraps the handle, freeing it if the view is refused.
//
// Read once, here, rather than per field: every pointer in the view is built with the handle
// and never moves — nothing in this ABI is built lazily — so asking again would be one C call
// for the same answer.
func femMeshFrom(handle *C.CadaclysmBlacksmithFemMesh) (*FemMesh, error) {
	var raw C.CadaclysmBlacksmithFemMeshView
	if !bool(C.cadaclysm_blacksmith_fem_mesh_view(handle, &raw)) {
		err := failure("fem_mesh_view")
		C.cadaclysm_blacksmith_fem_mesh_free(handle)
		return nil, err
	}
	m := &FemMesh{
		handle:          handle,
		FaceCount:       uint32(raw.face_count),
		Watertight:      bool(raw.watertight),
		FromMesh:        bool(raw.from_mesh),
		MinAngle:        float64(raw.min_angle),
		WorstTriangle:   uint32(raw.worst_triangle),
		LongestEdge:     float64(raw.longest_edge),
		edgeCount:       uint32(raw.edge_count),
		vertexCount:     uint32(raw.vertex_count),
		openEdgeCount:   uint32(raw.open_edge_count),
		foldedEdgeCount: uint32(raw.folded_edge_count),
	}
	nodes, triangles := int(raw.node_count), int(raw.triangle_count)
	if nodes > 0 && raw.nodes != nil {
		m.Nodes = unsafe.Slice((*float64)(unsafe.Pointer(raw.nodes)), nodes*3)
		m.NodeKind = unsafe.Slice((*uint32)(unsafe.Pointer(raw.node_kind)), nodes)
		m.NodeEntity = unsafe.Slice((*uint32)(unsafe.Pointer(raw.node_entity)), nodes)
	}
	if triangles > 0 && raw.triangles != nil {
		m.Triangles = unsafe.Slice((*uint32)(unsafe.Pointer(raw.triangles)), triangles*3)
		m.TriangleFace = unsafe.Slice((*uint32)(unsafe.Pointer(raw.triangle_face)), triangles)
	}
	runtime.SetFinalizer(m, (*FemMesh).finalize)
	return m, nil
}

func (m *FemMesh) finalize() {
	if m.handle != nil {
		C.cadaclysm_blacksmith_fem_mesh_free(m.handle)
		m.handle = nil
	}
}

// h is the live handle, refusing to hand over a closed one, so a use-after-close returns an
// error at the call site instead of passing a dangling pointer into the library. Every method
// that hands the handle to C goes through it; the struct fields cannot, which is the sharp
// edge [FemMesh] documents.
func (m *FemMesh) h() (*C.CadaclysmBlacksmithFemMesh, error) {
	if m == nil || m.handle == nil {
		return nil, fmt.Errorf("fem mesh: %w", ErrClosed)
	}
	return m.handle, nil
}

// Closed is whether Close has already run. A nil *FemMesh — what a failed Solid.FemMesh
// returns beside its error — counts as closed.
func (m *FemMesh) Closed() bool { return m == nil || m.handle == nil }

// Close gives the mesh back, and with it every slice on it. Idempotent, and a no-op on a nil
// *FemMesh, so a Close deferred before the error is checked cannot panic. The error return is
// always nil; it exists so a FemMesh satisfies io.Closer and defers like every other resource
// here. The .msh texts are **not** freed with it: each is a Go string of its own.
//
// **The slices are not emptied and do not begin to refuse**: after this they are still slice
// headers over memory the library has freed. See [FemMesh].
func (m *FemMesh) Close() error {
	if m == nil || m.handle == nil {
		return nil
	}
	h := m.handle
	m.handle = nil
	runtime.SetFinalizer(m, nil)
	C.cadaclysm_blacksmith_fem_mesh_free(h)
	return nil
}

// copyFemIndices is n uint32 at p in memory of our own: what a FemEdge's Nodes and Runs hold,
// so an edge read out of a mesh outlives the mesh. Cheap — an edge's chain is tens of numbers
// where the flat arrays are millions, which is why these are copied and those lent.
func copyFemIndices(p *C.uint32_t, n int) []uint32 {
	if p == nil || n <= 0 {
		return nil
	}
	return append([]uint32(nil), unsafe.Slice((*uint32)(unsafe.Pointer(p)), n)...)
}

// Edges is one [FemEdge] per B-rep edge, in the order a NodeKind of 1 indexes them.
//
// **Not Solid.Edges' numbering**: these are the manifold analysis's, ascending by edge id,
// and each FemEdge.ID carries the solid's own. Built fresh on every call, one C call an edge,
// so read it once and keep it.
func (m *FemMesh) Edges() ([]FemEdge, error) {
	defer pin()() // the calls and the lastError read after them on one OS thread
	h, err := m.h()
	if err != nil {
		return nil, err
	}
	out := make([]FemEdge, 0, m.edgeCount)
	var raw C.CadaclysmBlacksmithFemEdge
	for i := uint32(0); i < m.edgeCount; i++ {
		if !bool(C.cadaclysm_blacksmith_fem_mesh_edge(h, C.uint32_t(i), &raw)) {
			runtime.KeepAlive(m)
			return nil, failure(fmt.Sprintf("fem_mesh_edge %d", i))
		}
		out = append(out, FemEdge{
			ID:     uint32(raw.id),
			Nodes:  copyFemIndices(raw.nodes, int(raw.node_count)),
			Runs:   copyFemIndices(raw.runs, int(raw.run_count)),
			Faces:  [2]uint32{uint32(raw.face_a), uint32(raw.face_b)},
			Ends:   [2]uint32{uint32(raw.end_a), uint32(raw.end_b)},
			Closed: bool(raw.closed),
			Seam:   bool(raw.seam),
		})
	}
	// The mesh must outlive the loop even if the caller dropped every other reference to it:
	// a finalizer running here would free the handle the library is reading, exactly as one
	// on a Solid would during a write.
	runtime.KeepAlive(m)
	return out, nil
}

// Vertices is one [FemVertex] per B-rep vertex, in the order a NodeKind of 0 indexes them.
func (m *FemMesh) Vertices() ([]FemVertex, error) {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return nil, err
	}
	out := make([]FemVertex, 0, m.vertexCount)
	var raw C.CadaclysmBlacksmithFemVertex
	for i := uint32(0); i < m.vertexCount; i++ {
		if !bool(C.cadaclysm_blacksmith_fem_mesh_vertex(h, C.uint32_t(i), &raw)) {
			runtime.KeepAlive(m)
			return nil, failure(fmt.Sprintf("fem_mesh_vertex %d", i))
		}
		out = append(out, FemVertex{
			Node:        uint32(raw.node),
			Point:       [3]float64{float64(raw.point[0]), float64(raw.point[1]), float64(raw.point[2])},
			HasPosition: bool(raw.has_position),
		})
	}
	runtime.KeepAlive(m)
	return out, nil
}

// OpenEdges is every crack, as (a, b, brepEdge): a directed mesh edge (a, b) with no (b, a),
// and the B-rep edge both nodes lie on or ^uint32(0) where they share none.
//
// **Empty unless the solid's topology is closed**, whose mesh is otherwise not asked about at
// all: an open sheet from [Face], [Solid.FaceSheet], [Solid.DropFaces] or [ExtrudeOpen]
// makes no claim to enclose anything, so its rim is not a crack. Such a solid reports
// Watertight false with this and FoldedEdges both empty, and **that trio of answers together**
// says "not asked", not "nothing found".
//
// **That rule holds here without exception**, where the reader package has one: every solid
// has a B-rep behind it, so this library has no mesh-only body whose census speaks from the
// triangles alone. See FromMesh.
func (m *FemMesh) OpenEdges() ([][3]uint32, error) { return m.census(true) }

// FoldedEdges is every fold, as OpenEdges reports a crack: a directed mesh edge used by more
// than one triangle, once.
//
// **A solid can be folded without being open** — one no thicker than a line leaves no hole for
// an open edge to find — and the closure census's own known-bad bodies are folds rather than
// open cracks. A caller that checks OpenEdges alone calls such a solid sound. Empty under the
// same rule as OpenEdges.
func (m *FemMesh) FoldedEdges() ([][3]uint32, error) { return m.census(false) }

// census is the shared body of OpenEdges and FoldedEdges, so the two cannot drift.
//
// A bool rather than a func value naming one of the two entry points: cgo's generated
// bindings for a C function are call-only expressions, not first-class Go func values.
func (m *FemMesh) census(openEdges bool) ([][3]uint32, error) {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return nil, err
	}
	count, what := m.foldedEdgeCount, "fem_mesh_folded_edge"
	if openEdges {
		count, what = m.openEdgeCount, "fem_mesh_open_edge"
	}
	out := make([][3]uint32, 0, count)
	for i := uint32(0); i < count; i++ {
		var row [3]C.uint32_t
		var ok C.bool
		if openEdges {
			ok = C.cadaclysm_blacksmith_fem_mesh_open_edge(h, C.uint32_t(i), &row[0], &row[1], &row[2])
		} else {
			ok = C.cadaclysm_blacksmith_fem_mesh_folded_edge(h, C.uint32_t(i), &row[0], &row[1], &row[2])
		}
		if !bool(ok) {
			runtime.KeepAlive(m)
			return nil, failure(fmt.Sprintf("%s %d", what, i))
		}
		out = append(out, [3]uint32{uint32(row[0]), uint32(row[1]), uint32(row[2])})
	}
	runtime.KeepAlive(m)
	return out, nil
}

// Crossings is every pair of triangles that pass through each other, as (a, b) with a < b,
// sorted: an edge of one through the other's interior. Their B-rep faces are
// TriangleFace[a] and TriangleFace[b].
//
// **Computed for every solid, open or closed.** The census Watertight, OpenEdges and
// FoldedEdges report is topological and cannot see a surface passing through itself; a mesh
// is ready for a volume mesher when it is Watertight **and** this is empty — Gmsh refuses one
// that crosses. A copy.
func (m *FemMesh) Crossings() ([][2]uint32, error) {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return nil, err
	}
	count := uint32(C.cadaclysm_blacksmith_fem_mesh_crossing_count(h))
	out := make([][2]uint32, 0, count)
	for i := uint32(0); i < count; i++ {
		var row [2]C.uint32_t
		if !bool(C.cadaclysm_blacksmith_fem_mesh_crossing(h, C.uint32_t(i), &row[0], &row[1])) {
			runtime.KeepAlive(m)
			return nil, failure(fmt.Sprintf("fem_mesh_crossing %d", i))
		}
		out = append(out, [2]uint32{uint32(row[0]), uint32(row[1])})
	}
	runtime.KeepAlive(m)
	return out, nil
}

// MshText is the mesh as Gmsh 4.1 ASCII .msh text: an entity per B-rep vertex, edge and face,
// a volume where the solid closes, and a physical group naming each.
//
// **On this side of the ABI the library's text is owned and handed over**, released here with
// cadaclysm_blacksmith_string_free as every other text this library writes — [Solid.StepText],
// [Solid.SatText], [Solid.BrepText]. Two asks give two independent texts, and neither dies
// with the handle. The reader package's own MshText is the other way round: it borrows a slot
// on its handle, replaced by the next call and gone with the mesh. A reader porting one side's
// reasoning onto the other leaks or double-frees.
//
// **The unlicensed notice is printed here**, on this writer and on SaveMsh, and **not** by
// [Solid.FemMesh]: meshing is not a licensed output and the .msh file is, which is where
// Solid.SatText and Solid.BrepText put theirs too. The reader library notices in its
// constructor instead and on neither .msh call; each matches its own siblings, so moving the
// call to look like the other side breaks a convention.
func (m *FemMesh) MshText() (string, error) {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return "", err
	}
	text := C.cadaclysm_blacksmith_fem_mesh_msh_text(h)
	runtime.KeepAlive(m)
	if text == nil {
		return "", failure("fem_mesh_msh_text")
	}
	defer C.cadaclysm_blacksmith_string_free(text)
	return C.GoString(text), nil
}

// SaveMsh is MshText written to path, replacing any file there: the same bytes from the same
// writer, straight to the file rather than through a string. Prints the unlicensed notice; see
// MshText.
func (m *FemMesh) SaveMsh(path string) error {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return err
	}
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	ok := bool(C.cadaclysm_blacksmith_fem_mesh_save_msh(h, cp))
	runtime.KeepAlive(m)
	if !ok {
		return failure(fmt.Sprintf("could not write %s", path))
	}
	return nil
}

// String is Python's FemMesh.__repr__.
func (m *FemMesh) String() string {
	if m.Closed() {
		return "FemMesh(closed)"
	}
	return fmt.Sprintf("FemMesh(nodes=%d, triangles=%d, watertight=%v, from_mesh=%v)",
		len(m.Nodes)/3, len(m.Triangles)/3, m.Watertight, m.FromMesh)
}

// ---- solids ----------------------------------------------------------------------------------------

// Solid is an exact B-rep solid (or open sheet). Immutable; every operation returns a new
// one. Close it to free it; the finalizer does so otherwise.
type Solid struct {
	handle *C.CadaclysmBlacksmithSolid
	_      noTiny // see noTiny
}

// newSolid wraps a handle the library just returned, or reports why it returned none.
func newSolid(handle *C.CadaclysmBlacksmithSolid, what string) (*Solid, error) {
	if handle == nil {
		return nil, failure(what)
	}
	s := &Solid{handle: handle}
	runtime.SetFinalizer(s, (*Solid).finalize)
	return s, nil
}

func (s *Solid) finalize() {
	if s.handle != nil {
		C.cadaclysm_blacksmith_solid_free(s.handle)
		s.handle = nil
	}
}

// h is the live handle, refusing to hand over a closed one, so a use-after-close returns
// an error at the call site instead of passing a dangling pointer into the library.
func (s *Solid) h() (*C.CadaclysmBlacksmithSolid, error) {
	if s == nil || s.handle == nil {
		return nil, fmt.Errorf("solid: %w", ErrClosed)
	}
	return s.handle, nil
}

// Closed is whether Close has already run. A nil Solid -- what a build returns beside
// its error -- counts as closed.
func (s *Solid) Closed() bool { return s == nil || s.handle == nil }

// Close gives the solid back. Idempotent, and a no-op on a nil Solid, so a Close deferred
// before the build's error is checked cannot panic. A Mesh, Mesh64 or Polylines already
// held survives Close -- each owns a tessellation of its own (see the package doc) --
// and a FemMesh already held always did. The error return is always nil; it exists so a
// Solid satisfies io.Closer and defers like every other resource.
func (s *Solid) Close() error {
	if s == nil || s.handle == nil {
		return nil
	}
	h := s.handle
	s.handle = nil
	runtime.SetFinalizer(s, nil)
	C.cadaclysm_blacksmith_solid_free(h)
	return nil
}

// SolidHandle is the C handle, nil once closed: what view.View.ShowSolid reads the solid
// through, and for code that calls the C ABI directly.
func (s *Solid) SolidHandle() unsafe.Pointer {
	if s == nil {
		return nil
	}
	return unsafe.Pointer(s.handle)
}

// Show draws the solid with the view library in use (view.UseWgpu, view.UseTerminal): the
// wgpu window blocks until it is closed; any other library prints a still. nil o: the
// defaults (Tolerance 0: 0.05).
func (s *Solid) Show(o *view.ShowOptions) error {
	if _, err := s.h(); err != nil {
		return err
	}
	_, err := view.DrawSolid(s, o, false)
	return err
}

// View orbits the solid until its window is closed and returns where the camera was left
// (as ShowOptions takes it) and what was last clicked.
func (s *Solid) View(o *view.ShowOptions) (view.Camera, error) {
	if _, err := s.h(); err != nil {
		return view.Camera{}, err
	}
	return view.DrawSolid(s, o, true)
}

// -- building

// Cuboid is a box x by y by z, centred on the origin. Six planes.
func Cuboid(x, y, z float64) (*Solid, error) {
	defer pin()()
	return newSolid(C.cadaclysm_blacksmith_cuboid(C.double(x), C.double(y), C.double(z)), "solid")
}

// Cylinder is a cylinder of radius r, height h, based on z=0 and rising along +z.
func Cylinder(r, h float64) (*Solid, error) {
	defer pin()()
	return newSolid(C.cadaclysm_blacksmith_cylinder(C.double(r), C.double(h)), "solid")
}

// Cone is a cone of base radius r and height h, apex up.
func Cone(r, h float64) (*Solid, error) {
	defer pin()()
	return newSolid(C.cadaclysm_blacksmith_cone(C.double(r), C.double(h)), "solid")
}

// Sphere is a sphere of radius r about the origin.
func Sphere(r float64) (*Solid, error) {
	defer pin()()
	return newSolid(C.cadaclysm_blacksmith_sphere(C.double(r)), "solid")
}

// Torus is a torus of ring radius major and tube radius minor, about z.
func Torus(major, minor float64) (*Solid, error) {
	defer pin()()
	return newSolid(C.cadaclysm_blacksmith_torus(C.double(major), C.double(minor)), "solid")
}

// Wedge is a box x by y by z whose top face is narrowed to topX along x.
func Wedge(x, y, z, topX float64) (*Solid, error) {
	defer pin()()
	return newSolid(C.cadaclysm_blacksmith_wedge(C.double(x), C.double(y), C.double(z), C.double(topX)), "solid")
}

// Pyramid is a right pyramid of sides sides (at least 3): its base the regular polygon of
// circumradius r on z=0, its first corner on +x, its tip at (0, 0, h).
func Pyramid(sides int, r, h float64) (*Solid, error) {
	defer pin()()
	if sides < 0 {
		sides = 0
	}
	return newSolid(C.cadaclysm_blacksmith_pyramid(C.uint32_t(sides), C.double(r), C.double(h)), "solid")
}

// Extrude is profile swept height along the frame's z, closed with two caps. The
// profile's own x/y are the frame's x/y.
func Extrude(profile *Profile, frame Frame, height float64) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	f := frame
	out, err := newSolid(C.cadaclysm_blacksmith_extrude(h, doubles(&f[0]), C.double(height)), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// ExtrudeOpen is Extrude without the caps: an open sheet of walls.
func ExtrudeOpen(profile *Profile, frame Frame, height float64) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	f := frame
	out, err := newSolid(C.cadaclysm_blacksmith_extrude_open(h, doubles(&f[0]), C.double(height)), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// ExtrudeTapered is Extrude with a draft: the walls lean out by taper radians as they
// rise (in, when negative), every wall exact — a plane off a line, a cone off an arc. A
// taper of zero is Extrude.
func ExtrudeTapered(profile *Profile, frame Frame, height, taper float64) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	f := frame
	out, err := newSolid(C.cadaclysm_blacksmith_extrude_tapered(h, doubles(&f[0]), C.double(height), C.double(taper)), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// ExtrudeOpenTapered is ExtrudeTapered without the caps: the drafted walls alone.
func ExtrudeOpenTapered(profile *Profile, frame Frame, height, taper float64) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	f := frame
	out, err := newSolid(C.cadaclysm_blacksmith_extrude_open_tapered(h, doubles(&f[0]), C.double(height), C.double(taper)), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// ExtrudeBetween is Extrude between two planes instead of two heights: bottom and top are
// each a Slant (Flat(number) for Python's bare number). The profile's walls run from where
// bottom cuts them to where top does, the caps lying on those planes. With both flat this
// *is* Extrude (bit for bit); with a slope it is the mitred end of a sweep's straight
// piece. Returns a BuildError where the top plane comes down to or through the bottom
// across the profile.
func ExtrudeBetween(profile *Profile, frame Frame, bottom, top Slant) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	f, b, t := frame, bottom.raw(), top.raw()
	out, err := newSolid(C.cadaclysm_blacksmith_extrude_between(h, doubles(&f[0]), doubles(&b[0]), doubles(&t[0])), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// ExtrudeOpenBetween is ExtrudeBetween without the caps: an open sheet of walls running
// from bottom to top, as ExtrudeOpen is to Extrude.
func ExtrudeOpenBetween(profile *Profile, frame Frame, bottom, top Slant) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	f, b, t := frame, bottom.raw(), top.raw()
	out, err := newSolid(C.cadaclysm_blacksmith_extrude_open_between(h, doubles(&f[0]), doubles(&b[0]), doubles(&t[0])), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// Loft is the solid between a on frameA and b on frameB: ruled walls between matching
// sides (the profiles must have the same number of sides, and no holes), capped by the
// two profiles.
func Loft(a *Profile, frameA Frame, b *Profile, frameB Frame) (*Solid, error) {
	defer pin()()
	ha, err := a.h()
	if err != nil {
		return nil, err
	}
	hb, err := b.h()
	if err != nil {
		return nil, err
	}
	fa, fb := frameA, frameB
	out, err := newSolid(C.cadaclysm_blacksmith_loft(ha, doubles(&fa[0]), hb, doubles(&fb[0])), "solid")
	runtime.KeepAlive(a)
	runtime.KeepAlive(b)
	return out, err
}

// LoftThrough is the solid smooth through every profile, each on its frame (frames[i]
// for profiles[i], in order) — Python's Solid.loft_through: each wall interpolates its side
// across all the profiles (cubic through four or more, quadratic through three, Loft
// through two), capped by the first and the last.
func LoftThrough(profiles []*Profile, frames []Frame) (*Solid, error) {
	return loftedThrough(profiles, frames, true)
}

// LoftThroughOpen is LoftThrough without the caps: the sheet through the curves.
func LoftThroughOpen(profiles []*Profile, frames []Frame) (*Solid, error) {
	return loftedThrough(profiles, frames, false)
}

func loftedThrough(profiles []*Profile, frames []Frame, solid bool) (*Solid, error) {
	defer pin()()
	if len(frames) != len(profiles) {
		return nil, &BuildError{Message: fmt.Sprintf("loft_through: %d frames for %d profiles", len(frames), len(profiles))}
	}
	handles := make([]*C.CadaclysmBlacksmithProfile, len(profiles))
	numbers := make([]float64, 0, 12*len(frames))
	for i, p := range profiles {
		h, err := p.h()
		if err != nil {
			return nil, err
		}
		handles[i] = h
		numbers = append(numbers, frames[i][:]...)
	}
	var first **C.CadaclysmBlacksmithProfile
	var firstFrame *C.double
	if len(handles) > 0 {
		first = &handles[0]
		firstFrame = doubles(&numbers[0])
	}
	var raw *C.CadaclysmBlacksmithSolid
	if solid {
		raw = C.cadaclysm_blacksmith_loft_through(first, firstFrame, C.size_t(len(handles)))
	} else {
		raw = C.cadaclysm_blacksmith_loft_through_open(first, firstFrame, C.size_t(len(handles)))
	}
	out, err := newSolid(raw, "solid")
	for _, p := range profiles {
		runtime.KeepAlive(p)
	}
	runtime.KeepAlive(numbers)
	return out, err
}

// LoftOpen is Loft without the caps: the sheet ruled between the two curves.
func LoftOpen(a *Profile, frameA Frame, b *Profile, frameB Frame) (*Solid, error) {
	defer pin()()
	ha, err := a.h()
	if err != nil {
		return nil, err
	}
	hb, err := b.h()
	if err != nil {
		return nil, err
	}
	fa, fb := frameA, frameB
	out, err := newSolid(C.cadaclysm_blacksmith_loft_open(ha, doubles(&fa[0]), hb, doubles(&fb[0])), "solid")
	runtime.KeepAlive(a)
	runtime.KeepAlive(b)
	return out, err
}

// Revolve is profile swung angle radians about axis (six numbers: a point and a
// direction). The profile is read with x as radius and y as height along the axis, so it
// must lie to one side of the axis.
func Revolve(profile *Profile, axis [6]float64, angle float64) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	a := axis
	out, err := newSolid(C.cadaclysm_blacksmith_revolve(h, doubles(&a[0]), C.double(angle)), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// RevolveOpen is Revolve without the end caps of a partial turn.
func RevolveOpen(profile *Profile, axis [6]float64, angle float64) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	a := axis
	out, err := newSolid(C.cadaclysm_blacksmith_revolve_open(h, doubles(&a[0]), C.double(angle)), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// Coil is profile coiled about axis (a point and a direction) — Python's Solid.coil: read
// as Revolve reads it, x the distance from the axis and y along it, and turned turns
// times while climbing pitch along the axis each turn: a spring, a thread. The two ends
// are the profile itself, flat; from a full turn up the pitch must be taller than the
// profile.
func Coil(profile *Profile, axis [6]float64, pitch, turns float64) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	a := axis
	out, err := newSolid(C.cadaclysm_blacksmith_coil(h, doubles(&a[0]), C.double(pitch), C.double(turns)), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// RevolveInPlane is profile, drawn on frame, swung angle radians about the axis through
// the sketch points a and b (on the frame) — the profile and its axis drawn together,
// where Revolve reads the profile as (radius, height). The profile may lie on either side
// of the axis and touch it, not cross it; the sweep starts where it is drawn and turns
// right-handed about b - a.
func RevolveInPlane(profile *Profile, frame Frame, a, b [2]float64, angle float64) (*Solid, error) {
	return inPlane(profile, frame, a, b, angle, false)
}

// RevolveOpenInPlane is RevolveInPlane for a curve: its segments swung into a sheet.
func RevolveOpenInPlane(profile *Profile, frame Frame, a, b [2]float64, angle float64) (*Solid, error) {
	return inPlane(profile, frame, a, b, angle, true)
}

func inPlane(profile *Profile, frame Frame, a, b [2]float64, angle float64, open bool) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	f := frame
	axis := [4]float64{a[0], a[1], b[0], b[1]}
	var raw *C.CadaclysmBlacksmithSolid
	if open {
		raw = C.cadaclysm_blacksmith_revolve_open_in_plane(h, doubles(&f[0]), doubles(&axis[0]), C.double(angle))
	} else {
		raw = C.cadaclysm_blacksmith_revolve_in_plane(h, doubles(&f[0]), doubles(&axis[0]), C.double(angle))
	}
	out, err := newSolid(raw, "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// Sweep is profile, drawn on frame, carried along path into a closed solid: a straight
// piece of the path is an extrusion, a circular piece a revolution about the arc's axis,
// so nothing is approximated — a circle along an arc is an exact torus wall. path is
// only borrowed, not consumed; sweep it again, open or closed, as often as needed. A
// path whose chain failed reports that failure here.
func Sweep(profile *Profile, frame Frame, path *SweepPath) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	hp, err := path.h()
	if err != nil {
		return nil, err
	}
	f := frame
	out, err := newSolid(C.cadaclysm_blacksmith_sweep(h, doubles(&f[0]), hp), "solid")
	runtime.KeepAlive(profile)
	runtime.KeepAlive(path)
	return out, err
}

// SweepOpen is Sweep for a curve rather than a face: one wall per segment per piece, no
// caps — an open sheet, the way ExtrudeOpen is to Extrude.
func SweepOpen(profile *Profile, frame Frame, path *SweepPath) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	hp, err := path.h()
	if err != nil {
		return nil, err
	}
	f := frame
	out, err := newSolid(C.cadaclysm_blacksmith_sweep_open(h, doubles(&f[0]), hp), "solid")
	runtime.KeepAlive(profile)
	runtime.KeepAlive(path)
	return out, err
}

// Pipe is a circle of radius swept along path, square to its start — Python's
// Solid.pipe: a rod, or with a positive thickness a tube whose walls are
// that thick. path is only borrowed, as by Sweep.
func Pipe(path *SweepPath, radius, thickness float64) (*Solid, error) {
	defer pin()()
	hp, err := path.h()
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_pipe(hp, C.double(radius), C.double(thickness)), "solid")
	runtime.KeepAlive(path)
	return out, err
}

// Face is the flat sheet profile bounds on frame: one planar face, each hole a hole
// through it, its normal frame's z, every edge the exact line, arc or spline its segment
// is. An open sheet — raise it with ExtrudeFaces, cut it with Trim.
func Face(profile *Profile, frame Frame) (*Solid, error) {
	defer pin()()
	h, err := profile.h()
	if err != nil {
		return nil, err
	}
	f := frame
	out, err := newSolid(C.cadaclysm_blacksmith_face(h, doubles(&f[0])), "solid")
	runtime.KeepAlive(profile)
	return out, err
}

// FaceSheet is face alone, as an open sheet: its surface, its loops and the exact curves
// on its edges, the rest of the solid left behind.
func (s *Solid) FaceSheet(face int) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	c, err := index(face)
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_face_sheet(h, C.uint32_t(c)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// DropFaces is this solid without the faces at faces: the rest keep their order, so an
// index into the result is this one's with the dropped ones closed up.
func (s *Solid) DropFaces(faces []int) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	which, err := indices(faces)
	if err != nil {
		return nil, err
	}
	var first *C.uint32_t
	if len(which) > 0 {
		first = (*C.uint32_t)(unsafe.Pointer(&which[0]))
	}
	out, err := newSolid(C.cadaclysm_blacksmith_drop_faces(h, first, C.size_t(len(which))), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(which)
	return out, err
}

// ExtrudeFaces is every face of this sheet pushed height along its own normal, walled and
// closed: the sheet as a solid of that thickness.
func (s *Solid) ExtrudeFaces(height float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_extrude_faces(h, C.double(height)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Place is this solid, built about the origin, moved onto frame: its origin to the
// frame's origin, its axes to the frame's.
func (s *Solid) Place(frame Frame) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	f := frame
	out, err := newSolid(C.cadaclysm_blacksmith_place(h, doubles(&f[0])), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Translate is this solid moved by (dx, dy, dz).
func (s *Solid) Translate(dx, dy, dz float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_translate(h, C.double(dx), C.double(dy), C.double(dz)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Scaled is this solid scaled by factor about the origin: every length times factor, exactly.
func (s *Solid) Scaled(factor float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_scaled(h, C.double(factor)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Rotate is this solid turned radians about axis (six numbers: a point and a direction).
func (s *Solid) Rotate(axis [6]float64, radians float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	a := axis
	out, err := newSolid(C.cadaclysm_blacksmith_rotate(h, doubles(&a[0]), C.double(radians)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Mirror is this solid reflected across plane (a frame; its z is the plane's normal).
func (s *Solid) Mirror(plane Frame) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	f := plane
	out, err := newSolid(C.cadaclysm_blacksmith_mirror(h, doubles(&f[0])), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// -- combining

// pair is the two live handles a boolean takes.
func (s *Solid) pair(other *Solid) (*C.CadaclysmBlacksmithSolid, *C.CadaclysmBlacksmithSolid, error) {
	a, err := s.h()
	if err != nil {
		return nil, nil, err
	}
	b, err := other.h()
	if err != nil {
		return nil, nil, err
	}
	return a, b, nil
}

// Join is this solid united with other, an exact B-rep whose faces are pieces of the
// inputs' own faces; only the new edges, where the two meet, are found on the meshes at
// tolerance (Python's default is DefaultTolerance). Both operands stay open. A trailing
// true merges the flush faces the join leaves (MergeFlush, Python's merge=True); Cut and
// Common take it too.
func (s *Solid) Join(other *Solid, tolerance float64, merge ...bool) (*Solid, error) {
	out, err := s.join(other, tolerance)
	return merged(out, err, merge)
}

func (s *Solid) join(other *Solid, tolerance float64) (*Solid, error) {
	defer pin()()
	a, b, err := s.pair(other)
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_join(a, b, C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(other)
	return out, err
}

// Cut is this solid less other. See Join.
func (s *Solid) Cut(other *Solid, tolerance float64, merge ...bool) (*Solid, error) {
	out, err := s.cut(other, tolerance)
	return merged(out, err, merge)
}

func (s *Solid) cut(other *Solid, tolerance float64) (*Solid, error) {
	defer pin()()
	a, b, err := s.pair(other)
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_cut(a, b, C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(other)
	return out, err
}

// Common is what this solid and other share. See Join.
func (s *Solid) Common(other *Solid, tolerance float64, merge ...bool) (*Solid, error) {
	out, err := s.common(other, tolerance)
	return merged(out, err, merge)
}

func (s *Solid) common(other *Solid, tolerance float64) (*Solid, error) {
	defer pin()()
	a, b, err := s.pair(other)
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_common(a, b, C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(other)
	return out, err
}

// Section is this solid cut by the plane Z = z: its closed outlines there, in XY, nested
// into profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a
// circle crossing kept exact and any other curve as lines within tolerance. A plane that
// misses the solid is an empty slice. Fails for a z not finite, a tolerance not positive
// and finite, a face lying in the plane (section a little above or below it), or a
// crossing that does not close. Python's tolerance defaults to 0.05.
func (s *Solid) Section(z, tolerance float64) ([]*Profile, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	defer runtime.KeepAlive(s)
	return profileList(C.cadaclysm_blacksmith_solid_section(h, C.double(z), C.double(tolerance)), "solid_section")
}

// SplitSheet is this solid (a sheet or a solid) cut along tool's boundary, nothing
// removed: every face comes back in its pieces outside tool and its pieces inside, each
// piece a face, in this solid's own face order with each face's outside pieces before its
// inside pieces — so an index into the result names a piece for as long as both stand.
// tool must be a closed solid; this may be an open sheet. tolerance as Join's. Keep or
// discard pieces with DropFaces; Trim is the split with one side dropped.
func (s *Solid) SplitSheet(tool *Solid, tolerance float64) (*Solid, error) {
	defer pin()()
	a, b, err := s.pair(tool)
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_split_sheet(a, b, C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(tool)
	return out, err
}

// Trim is this sheet (or solid) cut along the closed tool's boundary and the pieces on
// one side thrown away: keep "outside" keeps what lies outside the tool (a hole punched
// through), "inside" what lies within it. tolerance as Join's.
func (s *Solid) Trim(tool *Solid, keep string, tolerance float64) (*Solid, error) {
	if keep != "outside" && keep != "inside" {
		return nil, &BuildError{Message: fmt.Sprintf("trim: keep must be 'outside' or 'inside', not %q", keep)}
	}
	defer pin()()
	a, b, err := s.pair(tool)
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_trim(a, b, C.bool(keep == "inside"), C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(tool)
	return out, err
}

// Intersect is where this solid's faces cross or coincide with other's, at tolerance, as an
// Intersection: Chains along the curves the faces meet on and Overlaps where a face pair
// coincides. Neither solid is changed; either may be an open sheet. No crossing is an empty
// result, never an error.
//
// Each IntersectionChain's points are within tolerance of both faces' exact surfaces; there is one chain
// per face pair per branch -- chains are not joined across a face boundary or a closed
// curve's seam, so join them by matching ends. A chain's Curve is its exact curve where the
// kernel found one every point lies within tolerance of, else nil; Tangent is set where the
// surfaces are near-tangent along the chain or the snap did not settle (the points are then
// the best estimate) -- a closed chain that does not go once round its own curve (a sliver
// where two surfaces barely cross) has no curve, Tangent still true. An Overlap is a
// coincident face pair with the shared region's rings (outer first, holes after), which may
// be empty for a partial overlap whose outlines cross. Known limit: a crossing narrower than
// tolerance -- two surfaces passing within it without their meshes crossing -- can be
// missed; near-tangent contact is where this bites.
//
// Fails for a tolerance not positive and finite, a solid with no faces, or one that meshes
// to nothing. Python's intersect at its default tolerance is 0.05.
func (s *Solid) Intersect(other *Solid, tolerance float64) (*Intersection, error) {
	defer pin()()
	a, b, err := s.pair(other)
	if err != nil {
		return nil, err
	}
	defer runtime.KeepAlive(s)
	defer runtime.KeepAlive(other)
	found := C.cadaclysm_blacksmith_intersect(a, b, C.double(tolerance), nil, nil)
	if found == nil {
		return nil, failure("intersect")
	}
	defer C.cadaclysm_blacksmith_intersection_free(found)
	n := uint32(C.cadaclysm_blacksmith_intersection_chain_count(found))
	out := &Intersection{Chains: make([]IntersectionChain, 0, n)}
	for i := uint32(0); i < n; i++ {
		var raw C.CadaclysmBlacksmithChain
		if !bool(C.cadaclysm_blacksmith_intersection_chain(found, C.uint32_t(i), &raw)) {
			return nil, failure("intersection_chain")
		}
		var curve *Curve
		if bool(raw.has_curve) {
			var rawCurve C.CadaclysmBlacksmithCurve
			if !bool(C.cadaclysm_blacksmith_intersection_curve(found, C.uint32_t(i), &rawCurve)) {
				return nil, failure("intersection_curve")
			}
			curve = curveOf(&rawCurve)
		}
		out.Chains = append(out.Chains, IntersectionChain{
			Points: pointsOf(raw.points, int(raw.point_count)), Closed: bool(raw.closed),
			FaceA: int(raw.face_a), FaceB: int(raw.face_b), Tangent: bool(raw.tangent), Curve: curve,
		})
	}
	n = uint32(C.cadaclysm_blacksmith_intersection_overlap_count(found))
	out.Overlaps = make([]Overlap, 0, n)
	for i := uint32(0); i < n; i++ {
		var raw C.CadaclysmBlacksmithOverlap
		if !bool(C.cadaclysm_blacksmith_intersection_overlap(found, C.uint32_t(i), &raw)) {
			return nil, failure("intersection_overlap")
		}
		points := pointsOf(raw.points, int(raw.point_count))
		loops := make([][][3]float64, int(raw.loop_count))
		if raw.loop_count > 0 && raw.loop_offsets != nil {
			starts := unsafe.Slice((*uint32)(unsafe.Pointer(raw.loop_offsets)), int(raw.loop_count))
			for r := range loops {
				end := int(raw.point_count)
				if r+1 < len(starts) {
					end = int(starts[r+1])
				}
				loops[r] = points[starts[r]:end]
			}
		}
		out.Overlaps = append(out.Overlaps, Overlap{FaceA: int(raw.face_a), FaceB: int(raw.face_b), Loops: loops})
	}
	return out, nil
}

// ---- collider -------------------------------------------------------------------------

// ColliderStats is counts of one Collider.Check call: the candidate pairs Considered, how
// many of them the world boxes and the oriented boxes cleared, how many the share left to
// another call, how the rest were answered (Cached, ClosedForm, Meshed), and how many were
// Refused. Confirmed is the subset of Meshed that were thin mesh-path overlaps sent to
// Solid.Common itself for a final answer.
type ColliderStats struct {
	Considered    int
	WorldBoxes    int
	OrientedBoxes int
	SkippedShare  int
	Cached        int
	ClosedForm    int
	Meshed        int
	Refused       int
	Confirmed     int
}

func (s ColliderStats) String() string {
	return fmt.Sprintf(
		"ColliderStats(considered=%d, worldBoxes=%d, orientedBoxes=%d, skippedShare=%d, cached=%d, closedForm=%d, meshed=%d, refused=%d, confirmed=%d)",
		s.Considered, s.WorldBoxes, s.OrientedBoxes, s.SkippedShare, s.Cached, s.ClosedForm, s.Meshed, s.Refused, s.Confirmed)
}

// collisions is one Collider.Check answer, kept alive by every CollisionHit of it: as long
// as one is reachable, the garbage collector keeps this reachable too, and its finalizer
// frees the handle only once nothing does -- a CollisionHit needs it back for Solid().
type collisions struct {
	handle *C.CadaclysmBlacksmithCollisions
	_      noTiny // see noTiny
}

func newCollisions(handle *C.CadaclysmBlacksmithCollisions) *collisions {
	c := &collisions{handle: handle}
	runtime.SetFinalizer(c, (*collisions).finalize)
	return c
}

func (c *collisions) finalize() {
	if c.handle != nil {
		C.cadaclysm_blacksmith_collisions_free(c.handle)
		c.handle = nil
	}
}

// CollisionHit is one pair Collider.Check found overlapping (Overlap true), or could not
// decide (Overlap false; Text says why, empty for an overlap). Positions/Normals are world
// xyz triples, three per triangle (unwelded); Indices indexes them -- all empty for a
// refused pair. Depth is the thinnest side of the overlap's world box, 0 for a refused
// pair.
//
// Solid rebuilds the exact overlap now, from the frames Collider.Check found it at; this
// keeps the collisions handle behind every hit of one Check call alive until the last of
// them is unreachable, freeing it only then. Named CollisionHit rather than the plainer
// Hit, which this package already uses for a curve-crossing result (Solid.Hits).
type CollisionHit struct {
	A, B    int
	Overlap bool
	// Kind is "overlap" or "refused" -- the same answer as Overlap.
	Kind      string
	Depth     float64
	Text      string
	Positions [][3]float64
	Normals   [][3]float64
	Indices   []uint32

	collisions *collisions
	index      uint32
}

func (h *CollisionHit) String() string {
	return fmt.Sprintf("CollisionHit(a=%d, b=%d, overlap=%v, depth=%g)", h.A, h.B, h.Overlap, h.Depth)
}

// Solid is the exact overlap of this pair at the frames Collider.Check found it at, as a
// new solid. Fails for a refused pair (Overlap false) or a collisions handle already freed
// (which cannot happen while this CollisionHit itself is reachable).
func (h *CollisionHit) Solid() (*Solid, error) {
	defer pin()()
	if h == nil || h.collisions == nil {
		return nil, fmt.Errorf("collision hit: %w", ErrClosed)
	}
	raw := C.cadaclysm_blacksmith_collisions_solid(h.collisions.handle, C.uint32_t(h.index))
	runtime.KeepAlive(h.collisions)
	return newSolid(raw, "collisions_solid")
}

// Collider is parts meshed once, asked pose after pose which of them interfere. Close frees
// this handle; the finalizer does so otherwise.
type Collider struct {
	handle *C.CadaclysmBlacksmithCollider
	_      noTiny // see noTiny
}

// NewCollider is solids at rest, meshed at tolerance; groups one group index per solid
// (nil: each solid its own group -- Check then takes one frame per solid), allowed pairs of
// part indices never tested (designed contacts, by part index, flat: (a0, b0, a1, b1,
// ...)).
func NewCollider(solids []*Solid, tolerance float64, groups []uint32, allowed []uint32) (*Collider, error) {
	defer pin()()
	if groups != nil && len(groups) != len(solids) {
		return nil, &BuildError{Message: fmt.Sprintf(
			"Collider: groups must have one entry per solid (%d solids, %d groups)", len(solids), len(groups))}
	}
	handles := make([]*C.CadaclysmBlacksmithSolid, len(solids))
	for i, s := range solids {
		h, err := s.h()
		if err != nil {
			return nil, err
		}
		handles[i] = h
	}
	var firstSolid **C.CadaclysmBlacksmithSolid
	if len(handles) > 0 {
		firstSolid = &handles[0]
	}
	var groupsPtr *C.uint32_t
	if len(groups) > 0 {
		groupsPtr = (*C.uint32_t)(unsafe.Pointer(&groups[0]))
	}
	var allowedPtr *C.uint32_t
	if len(allowed) > 0 {
		allowedPtr = (*C.uint32_t)(unsafe.Pointer(&allowed[0]))
	}
	raw := C.cadaclysm_blacksmith_collider_new(firstSolid, C.uint32_t(len(handles)), C.double(tolerance), groupsPtr, allowedPtr,
		C.uint32_t(len(allowed)/2))
	for _, s := range solids {
		runtime.KeepAlive(s)
	}
	if raw == nil {
		return nil, failure("collider_new")
	}
	c := &Collider{handle: raw}
	runtime.SetFinalizer(c, (*Collider).finalize)
	return c, nil
}

func (c *Collider) finalize() {
	if c.handle != nil {
		C.cadaclysm_blacksmith_collider_free(c.handle)
		c.handle = nil
	}
}

// Close gives the collider back. Idempotent.
func (c *Collider) Close() {
	c.finalize()
	runtime.SetFinalizer(c, nil)
}

// Closed is whether Close has already run. A nil Collider counts as closed.
func (c *Collider) Closed() bool { return c == nil || c.handle == nil }

func (c *Collider) h() (*C.CadaclysmBlacksmithCollider, error) {
	if c == nil || c.handle == nil {
		return nil, fmt.Errorf("collider: %w", ErrClosed)
	}
	return c.handle, nil
}

// GroupCount is how many groups this collider has -- the highest group index past
// NewCollider, plus one.
func (c *Collider) GroupCount() (int, error) {
	h, err := c.h()
	if err != nil {
		return 0, err
	}
	n := int(C.cadaclysm_blacksmith_collider_group_count(h))
	runtime.KeepAlive(c)
	return n, nil
}

// Stats is counts of the last Check call (all zero before the first one).
func (c *Collider) Stats() (ColliderStats, error) {
	h, err := c.h()
	if err != nil {
		return ColliderStats{}, err
	}
	var raw C.CadaclysmBlacksmithColliderStats
	ok := bool(C.cadaclysm_blacksmith_collider_stats(h, &raw))
	runtime.KeepAlive(c)
	if !ok {
		return ColliderStats{}, failure("collider_stats")
	}
	return ColliderStats{
		Considered: int(raw.considered), WorldBoxes: int(raw.world_boxes), OrientedBoxes: int(raw.oriented_boxes),
		SkippedShare: int(raw.skipped_share), Cached: int(raw.cached), ClosedForm: int(raw.closed_form),
		Meshed: int(raw.meshed), Refused: int(raw.refused), Confirmed: int(raw.confirmed),
	}, nil
}

// Check is the pairs that interfere, or could not be decided, with each group placed at its
// matching frame in frames (one per group, in group order). shareK/shareN both 0: every
// pair past the box filters is decided now; otherwise, only those whose index is shareK
// modulo shareN (the shares of one pose are disjoint and cover it -- split one Check across
// shareN workers).
func (c *Collider) Check(frames []Frame, shareK, shareN uint32) ([]*CollisionHit, error) {
	defer pin()()
	h, err := c.h()
	if err != nil {
		return nil, err
	}
	flat := make([]float64, len(frames)*12)
	for i, f := range frames {
		copy(flat[i*12:], f[:])
	}
	var framesPtr *C.double
	if len(flat) > 0 {
		framesPtr = doubles(&flat[0])
	}
	raw := C.cadaclysm_blacksmith_collider_check(h, framesPtr, C.uint32_t(len(frames)), C.uint32_t(shareK), C.uint32_t(shareN))
	runtime.KeepAlive(c)
	if raw == nil {
		return nil, failure("collider_check")
	}
	count := int(C.cadaclysm_blacksmith_collisions_count(raw))
	if count == 0 {
		C.cadaclysm_blacksmith_collisions_free(raw)
		return nil, nil
	}
	col := newCollisions(raw)
	hits := make([]*CollisionHit, 0, count)
	for i := 0; i < count; i++ {
		var rawHit C.CadaclysmBlacksmithCollisionHit
		if !bool(C.cadaclysm_blacksmith_collisions_hit(col.handle, C.uint32_t(i), &rawHit)) {
			return nil, failure("collisions_hit")
		}
		kind := "refused"
		if bool(rawHit.overlap) {
			kind = "overlap"
		}
		hits = append(hits, &CollisionHit{
			A: int(rawHit.a), B: int(rawHit.b), Overlap: bool(rawHit.overlap), Kind: kind, Depth: float64(rawHit.depth),
			Text:       C.GoString(rawHit.text),
			Positions:  pointsOf(rawHit.positions, int(rawHit.vertex_count)),
			Normals:    pointsOf(rawHit.normals, int(rawHit.vertex_count)),
			Indices:    uint32sOf(rawHit.indices, int(rawHit.index_count)),
			collisions: col,
			index:      uint32(i),
		})
	}
	return hits, nil
}

// SolidHits is what Solid.Hits found, copied out: Hits (ordered along the profile; AStart/AEnd
// on the profile, BStart/BEnd on the solid's faces: a Face at (U, V)) and Pieces (empty for
// an open body).
type SolidHits struct {
	Hits   []Hit
	Pieces []Piece
}

// String is Python's repr.
func (x SolidHits) String() string {
	return fmt.Sprintf("SolidHits(hits=%d, pieces=%d)", len(x.Hits), len(x.Pieces))
}

// Piece is one stretch of a profile loop between two cuts (SolidHits.Pieces): Inside (by its
// middle's winding number over the body; a piece lying on the surface is inside), Start/End
// (profile spots -- a segment join reads as the next segment's start (k + 1, 0), an open
// chain runs from (0, 0) to (n - 1, 1); a loop no hit cuts is one closed piece) and Profile,
// the piece's own open chain (what SweepPathAlong with open sweeps), owned: Close it once
// done, or let the finalizer.
type Piece struct {
	Inside     bool
	Start, End Spot
	Profile    *Profile
}

// String is Python's repr.
func (p Piece) String() string {
	return fmt.Sprintf("Piece(inside=%v, start=%v, end=%v)", p.Inside, p.Start, p.End)
}

// Hits is where profile, placed on frame, pierces this solid's faces, and the pieces its
// loops cut into, as a SolidHits. Neither is changed.
//
// A point hit lies within tolerance of the segment's exact curve and of the face's exact
// surface, inside the face's trim; its profile spot (AStart: loop, segment, t) and face spot
// (BStart: face, u, v) evaluate to the point within tolerance; Touch where the curve's
// tangent lies within 1e-3 (sine) of the surface's tangent plane there (a graze), false at a
// crossing. A run is a stretch of one segment lying within tolerance of one face and inside
// it, longer than tolerance. Hits within tolerance of each other merge (a hit at a segment
// join reported once, as (k, t = 1); a closed loop's closing join reads (0, 0)). Every
// point is in world space (the frame applied).
//
// Pieces only for a closed body -- an open body has none -- in loop order, covering every
// loop exactly; a piece's spots read a segment join as the next segment's start (k + 1, 0),
// and an open chain runs from (0, 0) to (n - 1, 1); a loop no hit cuts is one closed piece.
// Inside by the piece middle's winding number over the body's mesh; a piece lying on the
// surface is inside. Known limit: a segment passing within tolerance of a face without
// crossing its mesh can be missed (near-tangent grazes).
//
// Fails for a tolerance not positive and finite, a solid with no faces or that meshes to
// nothing, a profile with no segments, or a free-form segment that is not an evaluable NURBS
// curve. Python's hits at its default tolerance is 0.05.
func (s *Solid) Hits(profile *Profile, frame Frame, tolerance float64) (*SolidHits, error) {
	defer pin()()
	hs, err := s.h()
	if err != nil {
		return nil, err
	}
	hp, err := profile.h()
	if err != nil {
		return nil, err
	}
	defer runtime.KeepAlive(s)
	defer runtime.KeepAlive(profile)
	f := frame
	found := C.cadaclysm_blacksmith_solid_profile_hits(hs, hp, doubles(&f[0]), C.double(tolerance), nil, nil)
	if found == nil {
		return nil, failure("solid_profile_hits")
	}
	defer C.cadaclysm_blacksmith_hits_free(found)
	n := uint32(C.cadaclysm_blacksmith_hit_count(found))
	out := &SolidHits{Hits: make([]Hit, 0, n)}
	for i := uint32(0); i < n; i++ {
		var raw C.CadaclysmBlacksmithHit
		if !bool(C.cadaclysm_blacksmith_hit(found, C.uint32_t(i), &raw)) {
			return nil, failure("hit")
		}
		out.Hits = append(out.Hits, hitOf(&raw))
	}
	n = uint32(C.cadaclysm_blacksmith_hits_piece_count(found))
	out.Pieces = make([]Piece, 0, n)
	for i := uint32(0); i < n; i++ {
		var inside C.bool
		var start, end C.CadaclysmBlacksmithSpot
		if !bool(C.cadaclysm_blacksmith_hits_piece(found, C.uint32_t(i), &inside, &start, &end)) {
			return nil, failure("hits_piece")
		}
		own, err := newProfile(C.cadaclysm_blacksmith_hits_piece_profile(found, C.uint32_t(i)), "hits_piece_profile")
		if err != nil {
			return nil, err
		}
		out.Pieces = append(out.Pieces, Piece{Inside: bool(inside), Start: spotOf(start), End: spotOf(end), Profile: own})
	}
	return out, nil
}

// pointsOf copies n xyz triples at `at` out as points.
func pointsOf(at *C.double, n int) [][3]float64 {
	out := make([][3]float64, n)
	if n > 0 && at != nil {
		flat := unsafe.Slice((*float64)(unsafe.Pointer(at)), 3*n)
		for k := range out {
			copy(out[k][:], flat[3*k:3*k+3])
		}
	}
	return out
}

// -- asking

// Faces is how many faces the solid has, in its own order; a face index runs to this.
// Python's faces property.
func (s *Solid) Faces() (int, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return 0, err
	}
	n := uint32(C.cadaclysm_blacksmith_face_count(h))
	runtime.KeepAlive(s)
	if n == 0 && lastError() != "" {
		return 0, failure("face_count")
	}
	return int(n), nil
}

// FaceKind is the face's surface kind: "plane", "cylinder", "cone", "sphere", "torus",
// "nurbs", "revolution", "extrusion", "other", or "none" for a face without a surface.
func (s *Solid) FaceKind(face int) (string, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return "", err
	}
	i, err := index(face)
	if err != nil {
		return "", err
	}
	raw := C.cadaclysm_blacksmith_face_kind(h, i)
	runtime.KeepAlive(s)
	if raw == nil {
		return "", failure("face_kind")
	}
	return C.GoString(raw), nil
}

// Bounds is the solid's axis-aligned box, at the same cost whatever its size: its mesh at
// a thousandth of its own extent, in float64, so the box is inside the exact one and short
// of it by at most that. Worked out once per solid, apart from the tessellation Mesh
// caches, so it stales no view. BoundsAt is the box of the mesh at a tolerance you name.
func (s *Solid) Bounds() (cadaclysm.Bounds, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return cadaclysm.Bounds{}, err
	}
	var lo, hi [3]float64
	ok := bool(C.cadaclysm_blacksmith_box(h, doubles(&lo[0]), doubles(&hi[0])))
	runtime.KeepAlive(s)
	if !ok {
		return cadaclysm.Bounds{}, failure("box")
	}
	return cadaclysm.Bounds{Min: lo, Max: hi}, nil
}

// BoundsAt is the solid's axis-aligned bounds, over the positions of its cached
// tessellation at tolerance (the same cache Mesh fills and reuses, so a second call at
// the same tolerance is free). Meshing at another tolerance replaces that cache, but a
// Mesh, Mesh64 or Polylines already held is untouched by it -- see the package doc.
func (s *Solid) BoundsAt(tolerance float64) (cadaclysm.Bounds, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return cadaclysm.Bounds{}, err
	}
	var lo, hi [3]float64
	ok := bool(C.cadaclysm_blacksmith_bounds(h, C.double(tolerance), doubles(&lo[0]), doubles(&hi[0])))
	runtime.KeepAlive(s)
	if !ok {
		return cadaclysm.Bounds{}, failure("bounds")
	}
	return cadaclysm.Bounds{Min: lo, Max: hi}, nil
}

// Bounds64 is BoundsAt64(DefaultTolerance).
func (s *Solid) Bounds64() (cadaclysm.Bounds, error) { return s.BoundsAt64(DefaultTolerance) }

// BoundsAt64 is BoundsAt, from the same cached tessellation's unnarrowed double
// positions rather than the widened float32 ones -- exact far from the origin, where
// BoundsAt's are not. Shares the cache Mesh64 fills and reuses, exactly as BoundsAt does
// with Mesh's.
func (s *Solid) BoundsAt64(tolerance float64) (cadaclysm.Bounds, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return cadaclysm.Bounds{}, err
	}
	var lo, hi [3]float64
	ok := bool(C.cadaclysm_blacksmith_bounds64(h, C.double(tolerance), doubles(&lo[0]), doubles(&hi[0])))
	runtime.KeepAlive(s)
	if !ok {
		return cadaclysm.Bounds{}, failure("bounds64")
	}
	return cadaclysm.Bounds{Min: lo, Max: hi}, nil
}

// BoundsBox is BoundsBoxAt(DefaultTolerance).
func (s *Solid) BoundsBox() (Box, error) { return s.BoundsBoxAt(DefaultTolerance) }

// BoundsBoxAt is this solid's box at tolerance: its boolean mesh, padded by twice that --
// the broad phase's own shape, cheaper to move and test than the solid itself.
func (s *Solid) BoundsBoxAt(tolerance float64) (Box, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return Box{}, err
	}
	var raw C.CadaclysmBlacksmithBox
	ok := bool(C.cadaclysm_blacksmith_solid_bounds_box(h, C.double(tolerance), &raw))
	runtime.KeepAlive(s)
	if !ok {
		return Box{}, failure("bounds_box")
	}
	return boxOf(&raw), nil
}

// LeakedEdges is how many edges of the mesh at tolerance (Python's default is
// DefaultTolerance) are bound by anything other than exactly two triangles — zero for a
// closed solid, counted on the triangles the mesh calls hand out. A hole, a fold, and a
// seam two solids share along a line (four triangles) all count here; UnpairedEdges is
// the check that lets the seam pass.
func (s *Solid) LeakedEdges(tolerance float64) (int, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return 0, err
	}
	n := uint32(C.cadaclysm_blacksmith_leaked_edges(h, C.double(tolerance)))
	runtime.KeepAlive(s)
	if n == none {
		return 0, failure("leaked_edges")
	}
	return int(n), nil
}

// UnpairedEdges is how many edges of the mesh at tolerance have directed triangle uses
// that do not cancel out — zero for a closed, consistently oriented solid. Where
// LeakedEdges asks for exactly two triangles on an edge, this asks that they run
// opposite ways: a shared seam pairs off and is *not* counted, a fold — two triangles
// running the same way — is.
func (s *Solid) UnpairedEdges(tolerance float64) (int, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return 0, err
	}
	n := uint32(C.cadaclysm_blacksmith_unpaired_edges(h, C.double(tolerance)))
	runtime.KeepAlive(s)
	if n == none {
		return 0, failure("unpaired_edges")
	}
	return int(n), nil
}

// IsWatertight is LeakedEdges(tolerance) == 0.
func (s *Solid) IsWatertight(tolerance float64) (bool, error) {
	n, err := s.LeakedEdges(tolerance)
	if err != nil {
		return false, err
	}
	return n == 0, nil
}

// Manifold says whether the faces make a manifold — every edge bordered by one face or
// two, the faces round every vertex one fan — and whether it is closed. Read off the
// solid's topology, not a mesh, so it takes no tolerance; whether the faces all face out
// is UnpairedEdges's question.
func (s *Solid) Manifold() (cadaclysm.Manifold, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return cadaclysm.Manifold{}, err
	}
	var row [8]uint32
	ok := bool(C.cadaclysm_blacksmith_manifold(h, (*C.uint32_t)(unsafe.Pointer(&row[0]))))
	runtime.KeepAlive(s)
	if !ok {
		return cadaclysm.Manifold{}, failure("manifold")
	}
	return cadaclysm.ManifoldOf(row), nil
}

// -- out

// Mesh is the triangles at tolerance (Python's default is DefaultTolerance), as views
// over a tessellation held of their own. See the package doc for what that does and
// does not protect you from.
func (s *Solid) Mesh(tolerance float64) (*Mesh, error) {
	defer pin()()
	t, err := holdTessellation(s, tolerance, "mesh")
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_tessellation_mesh(t.handle)
	runtime.KeepAlive(t)
	m := &Mesh{held: t, Tolerance: tolerance}
	vertexFloats := int(raw.vertex_count) * 3
	if vertexFloats > 0 {
		m.positions = unsafe.Slice((*float32)(unsafe.Pointer(raw.positions)), vertexFloats)
		if raw.normals != nil {
			m.normals = unsafe.Slice((*float32)(unsafe.Pointer(raw.normals)), vertexFloats)
		}
	}
	if raw.index_count > 0 && raw.indices != nil {
		m.indices = unsafe.Slice((*uint32)(unsafe.Pointer(raw.indices)), int(raw.index_count))
	}
	return m, nil
}

// Mesh64 is Mesh in double, from the same held tessellation -- see [Mesh64].
func (s *Solid) Mesh64(tolerance float64) (*Mesh64, error) {
	defer pin()()
	t, err := holdTessellation(s, tolerance, "mesh64")
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_tessellation_mesh64(t.handle)
	runtime.KeepAlive(t)
	m := &Mesh64{held: t, Tolerance: tolerance}
	vertexFloats := int(raw.vertex_count) * 3
	if vertexFloats > 0 {
		m.positions = unsafe.Slice((*float64)(unsafe.Pointer(raw.positions)), vertexFloats)
		if raw.normals != nil {
			m.normals = unsafe.Slice((*float64)(unsafe.Pointer(raw.normals)), vertexFloats)
		}
	}
	if raw.index_count > 0 && raw.indices != nil {
		m.indices = unsafe.Slice((*uint32)(unsafe.Pointer(raw.indices)), int(raw.index_count))
	}
	return m, nil
}

// FemMesh is this solid meshed for a solver, as a [FemMesh]: nodes welded by bits, triangles
// wound outward, each node tagged with the lowest-dimension B-rep entity it lies on, and
// every crack reported rather than closed.
//
// tolerance is the chordal tolerance in model units, finite and above zero, and **it alone
// governs how closely the mesh follows the geometry**. maxSize is a size ceiling, finite and
// zero or more, 0 being no ceiling (curvature alone): **it bounds the boundary and targets
// the interior**, which is not a longest-element-edge guarantee — it adds boundary nodes
// without refining boundary geometry, and FemMesh.LongestEdge is what the mesh actually came
// to, the figure to check against it. Go has no defaults, so Python's 0.01 and 0.0 are
// spelled out at the call; the library's own struct is filled by
// cadaclysm_blacksmith_fem_options_init first, so a field added to it later defaults without
// this function being touched.
//
// **Neither number is checked here.** The mesher refuses a tolerance or a size it cannot use,
// naming the field and the value, and a second validator in this wrapper would be a second
// set of words for the same refusal. (The reader package's Node.FemMesh says the same and has
// the stronger case: a mesh-only body there reads neither field at all.)
//
// placement is **twelve** numbers — a [Frame], origin then x, y, z, as every frame in this
// package — and nil for the identity; it is applied in float64 throughout. This is the one
// frame argument here that may be omitted, a solid meshed in its own coordinates being the
// common case. The reader package's Node.FemMesh takes **sixteen**, column-major, so a caller
// moving between the two reformats the placement; both being fixed-size array types, Go
// refuses the wrong one at compile time where the other wrappers can only refuse it at run
// time.
//
// The call runs silent: cadaclysm_blacksmith_fem_mesh takes a progress callback reporting the
// phases "meshing" and "welding", and this package offers none, as it offers none for the
// booleans, the fillet or the shell.
//
// **A cracked solid is not a failure**: it comes back with FemMesh.Watertight false and its
// cracks in FemMesh.OpenEdges and FemMesh.FoldedEdges — **both**, a fold being as real a fault
// as an open crack — and nothing is welded shut to make it look sound. Returns a *BuildError
// for a closed solid, a tolerance or maxSize the mesher refuses, a placement that is not
// invertible, a closed solid this module cannot mesh, and a solid that meshes to no triangles.
//
// No unlicensed notice here: FemMesh.MshText and FemMesh.SaveMsh print it, this library
// noticing on its writers rather than on its builders.
func (s *Solid) FemMesh(tolerance, maxSize float64, placement *Frame) (*FemMesh, error) {
	defer pin()()
	sh, err := s.h()
	if err != nil {
		return nil, err
	}
	var opts C.CadaclysmBlacksmithFemOptions
	// init writes sizeof(CadaclysmBlacksmithFemOptions) bytes as the *library* knows that
	// type, into the struct cgo declares from the header — one type, not two, which is why Go
	// has no layout row in cadaclysm-capi/tests/bindings.rs to keep the two in step. size is
	// then set to this header's own sizeof, which is what the growth rule asks of a caller.
	C.cadaclysm_blacksmith_fem_options_init(&opts)
	opts.size = C.size_t(unsafe.Sizeof(opts))
	opts.tolerance = C.double(tolerance)
	opts.max_size = C.double(maxSize)
	var p *C.double
	if placement != nil {
		p = doubles(&placement[0])
	}
	h := C.cadaclysm_blacksmith_fem_mesh(sh, p, &opts, nil, nil)
	runtime.KeepAlive(s)
	if h == nil {
		return nil, failure("fem_mesh")
	}
	return femMeshFrom(h)
}

// EdgePolylines is the feature edges at tolerance as polylines, views over a
// tessellation held the same way as Mesh's.
func (s *Solid) EdgePolylines(tolerance float64) (*Polylines, error) {
	defer pin()()
	t, err := holdTessellation(s, tolerance, "edge_polylines")
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_tessellation_edge_polylines(t.handle)
	runtime.KeepAlive(t)
	p := &Polylines{held: t, Tolerance: tolerance}
	if raw.point_count > 0 && raw.points != nil {
		p.points = unsafe.Slice((*float32)(unsafe.Pointer(raw.points)), int(raw.point_count)*3)
	}
	p.offsets = unsafe.Slice((*uint32)(unsafe.Pointer(raw.offsets)), int(raw.polyline_count)+1)
	return p, nil
}

// EdgePolylineColours is a colour per polyline of EdgePolylines at the same tolerance,
// as drawn — nil for a polyline on no coloured edge — and an empty slice where the solid
// has no edge paint at all. Copied out.
func (s *Solid) EdgePolylineColours(tolerance float64) ([]*[3]float64, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_edge_polyline_colours(h, C.double(tolerance))
	runtime.KeepAlive(s)
	if raw.rgb == nil && lastError() != "" {
		return nil, failure("edge_polyline_colours")
	}
	if raw.rgb == nil {
		return []*[3]float64{}, nil
	}
	values := unsafe.Slice((*float64)(unsafe.Pointer(raw.rgb)), int(raw.count)*3)
	out := make([]*[3]float64, int(raw.count))
	for i := range out {
		if values[3*i] >= 0 {
			c := [3]float64{values[3*i], values[3*i+1], values[3*i+2]}
			out[i] = &c
		}
	}
	runtime.KeepAlive(s)
	return out, nil
}

// meshFaceTriangles is the kernel's mesh_face_triangles, kept for the viewer
// follow-up: how many triangles each face meshed to at tolerance, in face order,
// summing to Mesh(tolerance)'s triangle count. Copied out of a tessellation held just
// for this call (see the package doc) -- nothing about the result depends on the
// solid's own cache once read.
func meshFaceTriangles(s *Solid, tolerance float64) ([]uint32, error) {
	defer pin()()
	t, err := holdTessellation(s, tolerance, "mesh_face_triangles")
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_tessellation_face_triangles(t.handle)
	counts := append([]uint32(nil), unsafe.Slice((*uint32)(unsafe.Pointer(raw.counts)), int(raw.face_count))...)
	runtime.KeepAlive(t)
	return counts, nil
}

// StepText is this solid as STEP text (AP203 unless schema names another); see
// WriteStepText for schema and unit.
func (s *Solid) StepText(schema, unit string) (string, error) {
	return WriteStepText([]*Solid{s}, schema, unit)
}

// Step writes this solid as a STEP file at path (AP203 unless schema names another); see
// WriteStepText for schema and unit.
func (s *Solid) Step(path, schema, unit string) error {
	return WriteStep(path, []*Solid{s}, schema, unit)
}

// SatText is this solid as ACIS SAT text; see WriteSatText for unit.
func (s *Solid) SatText(unit string) (string, error) {
	return WriteSatText([]*Solid{s}, unit)
}

// Sat writes this solid as an ACIS SAT file at path, by the library itself; see
// WriteSatText for unit.
func (s *Solid) Sat(path, unit string) error {
	return WriteSat(path, []*Solid{s}, unit)
}

// BrepText is this solid as OCCT .brep text; see WriteBrepText.
func (s *Solid) BrepText() (string, error) {
	return WriteBrepText([]*Solid{s})
}

// Brep writes this solid as a .brep file at path, by the library itself.
func (s *Solid) Brep(path string) error {
	return WriteBrep(path, []*Solid{s})
}

// SvgText is this solid's wireframe as SVG text, from the camera opts describes (nil
// for NewSvgOptions()'s defaults) — the library's own camera, not a viewer. See
// WriteSvgText.
func (s *Solid) SvgText(opts *SvgOptions) (string, error) {
	return WriteSvgText([]*Solid{s}, opts)
}

// Svg writes this solid as an SVG file at path, by the library itself; see
// WriteSvgText.
func (s *Solid) Svg(path string, opts *SvgOptions) error {
	return WriteSvg(path, []*Solid{s}, opts)
}

// SilhouetteBeziers is this solid's silhouette -- where its surfaces turn away from the
// eye, which no edge of it lies on -- as rational cubic Béziers, in double, from the camera
// opts describes (nil for NewSvgOptions()'s defaults). The same SvgOptions that draw a
// picture: View, Azimuth, Elevation, Up and Fov, and Width with Tolerance, which the
// library reads together as the page fraction Tolerance/Width. Nothing else in them
// changes the curves.
//
// Points has twelve numbers a curve (four control points, x y z) and Weights four. The
// library hands over an owned block; this copies it out and releases it before it returns,
// whichever way it returns, so there is nothing for the caller to free.
//
// A body with no silhouette (every face planar) gives a result with Count() 0 and a nil
// error; a refused option or a body with no measurable geometry is a BuildError.
func (s *Solid) SilhouetteBeziers(opts *SvgOptions) (cadaclysm.BeziersData64, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return cadaclysm.BeziersData64{}, err
	}
	raw, err := buildSvgOptions(opts)
	if err != nil {
		return cadaclysm.BeziersData64{}, err
	}
	var count C.uint32_t
	data := C.cadaclysm_blacksmith_silhouette_beziers(h, &raw, &count)
	runtime.KeepAlive(s)
	if data == nil {
		// The call clears the thread's error at entry and the empty answer sets none: a
		// reason here is this call's own refusal, none is the empty answer.
		if reason := lastError(); reason != "" {
			return cadaclysm.BeziersData64{}, &BuildError{Message: reason}
		}
		return cadaclysm.BeziersData64{Points: []float64{}, Weights: []float64{}}, nil
	}
	defer C.cadaclysm_blacksmith_silhouette_beziers_free(data, count)
	n := int(count)
	block := unsafe.Slice((*float64)(unsafe.Pointer(data)), n*16)
	out := cadaclysm.BeziersData64{Points: make([]float64, 0, n*12), Weights: make([]float64, 0, n*4)}
	for i := 0; i < n; i++ {
		out.Points = append(out.Points, block[i*16:i*16+12]...)
		out.Weights = append(out.Weights, block[i*16+12:i*16+16]...)
	}
	return out, nil
}

// -- selecting and edges

// SelectFace is the face selector picks; a BuildError when none does.
func (s *Solid) SelectFace(selector Selector) (int, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return 0, err
	}
	idx, err := index(selector.index)
	if err != nil {
		return 0, err
	}
	var v *C.double
	direction := selector.v
	if selector.hasV {
		v = doubles(&direction[0])
	}
	i := uint32(C.cadaclysm_blacksmith_select_face(h, C.uint32_t(selector.kind), v, idx))
	runtime.KeepAlive(s)
	if i == none {
		return 0, failure("select_face")
	}
	return int(i), nil
}

// FaceRef is face by what it is, eight numbers: the surface's kind (plane 0, cylinder 1,
// cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8), a point on the
// surface at the face's middle (x y z), the outward normal there (x y z), and the face's
// extent — what a feature made on the face keeps, to find the face again with FindFace
// when the solid has been rebuilt with its faces moved, split or renumbered. Take it
// before any move you apply to the solid, and look it up on the unmoved one.
func (s *Solid) FaceRef(face int) ([8]float64, error) {
	defer pin()()
	var out [8]float64
	h, err := s.h()
	if err != nil {
		return out, err
	}
	i, err := index(face)
	if err != nil {
		return out, err
	}
	ok := bool(C.cadaclysm_blacksmith_face_ref(h, i, doubles(&out[0])))
	runtime.KeepAlive(s)
	if !ok {
		return out, failure("face_ref")
	}
	return out, nil
}

// FindFace is the face ref (from FaceRef) refers to: among the faces of that kind whose
// surface passes through the point, facing the same way, the one the point lies in — or,
// where it lies in none, the one whose boundary comes nearest. hint is the index the face
// had, preferred among faces that fit equally well (negative for none); tolerance how far
// the point may sit off a surface to still be on it. -1 and no error where the face is
// gone.
func (s *Solid) FindFace(ref [8]float64, hint int, tolerance float64) (int, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return -1, err
	}
	if hint < 0 {
		hint = -1
	}
	found := int(C.cadaclysm_blacksmith_find_face(h, doubles(&ref[0]), C.int32_t(hint), C.double(tolerance)))
	runtime.KeepAlive(s)
	if found == -2 {
		return -1, failure("find_face")
	}
	if found < 0 {
		return -1, nil
	}
	return found, nil
}

// FaceFrame is the workplane on face: origin at the face's boundary centroid, z its
// outward normal — twelve numbers, what Workplane.OnFace adopts.
func (s *Solid) FaceFrame(face int) (Frame, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return Frame{}, err
	}
	i, err := index(face)
	if err != nil {
		return Frame{}, err
	}
	var out Frame
	ok := bool(C.cadaclysm_blacksmith_face_frame(h, i, doubles(&out[0])))
	runtime.KeepAlive(s)
	if !ok {
		return Frame{}, failure("face_frame")
	}
	return out, nil
}

// -- measuring

// Mass is what a solid measures, per unit density, each figure beside a bound on its own
// error. Volume, Centroid, Inertia and PrincipalMoments mean something only where Closed:
// on a sheet they are zero and Area is still measured. A body's mass is density * Volume
// and its inertia scales the same way — nothing here assumes a density of its own.
//
// Inertia is row-major about the centroid with the products of inertia negated,
// PrincipalMoments ascend, and PrincipalAxes is row-major, unit and right-handed, the axis
// in row i belonging to moment i. Where AccuracyMet is false the refinement stopped before
// the accuracy asked for: the figures are honest, the errors say how certain.
type Mass struct {
	Closed           bool
	Inverted         bool
	AccuracyMet      bool
	FromMesh         bool
	Area             float64
	AreaError        float64
	Volume           float64
	VolumeError      float64
	Centroid         [3]float64
	CentroidError    float64
	Inertia          [9]float64
	InertiaError     float64
	PrincipalMoments [3]float64
	PrincipalAxes    [9]float64
}

// Weight is density * Volume, in whatever units the model and the density agree on. Per unit
// density is what everything else here is, because an assembly of two materials would have to
// undo a density applied on its behalf.
func (m Mass) Weight(density float64) float64 {
	return density * m.Volume
}

// Mass measures the solid. accuracy is relative; 0 asks for the library's default, a part
// in ten million. It works on a solid read from a file as much as one built here.
func (s *Solid) Mass(accuracy float64) (Mass, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return Mass{}, err
	}
	var raw C.struct_CadaclysmBlacksmithMassProperties
	ok := bool(C.cadaclysm_blacksmith_mass_properties(h, C.double(accuracy), &raw))
	runtime.KeepAlive(s)
	if !ok {
		return Mass{}, failure("mass")
	}
	m := Mass{
		Closed:        raw.closed != 0,
		Inverted:      raw.inverted != 0,
		AccuracyMet:   raw.accuracy_met != 0,
		FromMesh:      raw.from_mesh != 0,
		Area:          float64(raw.area),
		AreaError:     float64(raw.area_error),
		Volume:        float64(raw.volume),
		VolumeError:   float64(raw.volume_error),
		CentroidError: float64(raw.centroid_error),
		InertiaError:  float64(raw.inertia_error),
	}
	for i := 0; i < 3; i++ {
		m.Centroid[i] = float64(raw.centroid[i])
		m.PrincipalMoments[i] = float64(raw.principal_moments[i])
	}
	for i := 0; i < 9; i++ {
		m.Inertia[i] = float64(raw.inertia[i])
		m.PrincipalAxes[i] = float64(raw.principal_axes[i])
	}
	return m, nil
}

// -- naming

// Named is this solid, named name — Python's named. The name rides through an operation
// with exactly one source solid (Place, Translate, Rotate, Mirror, Scaled, Coloured,
// EdgesColoured, Fillet, Chamfer, Shell, Thicken, FaceSheet, DropFaces, a Lumps entry,
// Trim, SplitByPlane, PushPull, and so on) and is dropped by one with two or more sources
// (Join, Cut, Common, SplitSheet, Split) and by a fresh primitive or sweep. It is what
// (*Assembly).PlaceSolid defaults a placement's own name to, and the product name a lone
// named solid gets written into STEP (Step/StepText — SAT and OCCT .brep have no product
// name to set). An empty name is refused.
func (s *Solid) Named(name string) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	out, err := newSolid(C.cadaclysm_blacksmith_named(h, c), "named")
	runtime.KeepAlive(s)
	return out, err
}

// Name is this solid's name, and whether it has one — what Named set, kept or dropped by
// whatever built this solid (see Named). The library's borrowed pointer is null for both
// "no name" and a failure, so this never consults last_error, same as Python's own name
// reading raw or None; the pointer is read directly rather than through a text() helper
// that would map null to "", which would erase the "no name" case. On a closed solid this
// also returns ("", false), the same as no name; callers who need to tell the two apart
// check Closed first.
func (s *Solid) Name() (string, bool) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return "", false
	}
	p := C.cadaclysm_blacksmith_solid_name(h)
	if p == nil {
		runtime.KeepAlive(s)
		return "", false
	}
	out := C.GoString(p)
	runtime.KeepAlive(s)
	return out, true
}

// -- colour

// Coloured is this solid coloured (r, g, b), each in 0..1 — Python's coloured with no face.
// What is made from a coloured solid inherits: a move keeps every colour; a boolean,
// fillet, chamfer or shell gives each face the colour of the face it lies on (a cut's bore
// the tool's), and a new face the solid's.
func (s *Solid) Coloured(r, g, b float64) (*Solid, error) {
	return s.coloured(C.CADACLYSM_BLACKSMITH_NONE, r, g, b)
}

// ColouredText is Coloured from "#rgb", "#rrggbb" or a CSS colour name.
func (s *Solid) ColouredText(colour string) (*Solid, error) {
	c, err := RGB(colour)
	if err != nil {
		return nil, err
	}
	return s.Coloured(c[0], c[1], c[2])
}

// ColouredFace is this solid with face coloured (r, g, b), a colour that wins over the
// solid's — Python's coloured(colour, face=face).
func (s *Solid) ColouredFace(face int, r, g, b float64) (*Solid, error) {
	i, err := index(face)
	if err != nil {
		return nil, err
	}
	return s.coloured(i, r, g, b)
}

// ColouredFaceText is ColouredFace from "#rgb", "#rrggbb" or a CSS colour name.
func (s *Solid) ColouredFaceText(face int, colour string) (*Solid, error) {
	c, err := RGB(colour)
	if err != nil {
		return nil, err
	}
	return s.ColouredFace(face, c[0], c[1], c[2])
}

func (s *Solid) coloured(face C.uint32_t, r, g, b float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_coloured(h, face, C.double(r), C.double(g), C.double(b)), "coloured")
	runtime.KeepAlive(s)
	return out, err
}

// Colour is the solid's colour, (r, g, b) in 0..1, and false where it has none.
func (s *Solid) Colour() ([3]float64, bool, error) { return s.colour(C.CADACLYSM_BLACKSMITH_NONE) }

// FaceColour is face's colour as drawn — its own, else the solid's — and false where
// there is none.
func (s *Solid) FaceColour(face int) ([3]float64, bool, error) {
	i, err := index(face)
	if err != nil {
		return [3]float64{}, false, err
	}
	return s.colour(i)
}

func (s *Solid) colour(face C.uint32_t) ([3]float64, bool, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return [3]float64{}, false, err
	}
	var out [3]float64
	ok := bool(C.cadaclysm_blacksmith_colour(h, face, doubles(&out[0])))
	runtime.KeepAlive(s)
	if !ok {
		if lastError() != "" {
			return [3]float64{}, false, failure("colour")
		}
		return [3]float64{}, false, nil
	}
	return out, true, nil
}

// EdgesColoured is this solid with every edge coloured (r, g, b), each in 0..1 — Python's
// edges_coloured with no edges. Inherited as face colours are: a move keeps every one, a
// boolean or a fillet gives each edge the colour of the input edge it lies on, a new edge
// the all-edges one.
func (s *Solid) EdgesColoured(r, g, b float64) (*Solid, error) {
	return s.edgesColoured(nil, 0, r, g, b)
}

// EdgesColouredText is EdgesColoured from "#rgb", "#rrggbb" or a CSS colour name.
func (s *Solid) EdgesColouredText(colour string) (*Solid, error) {
	c, err := RGB(colour)
	if err != nil {
		return nil, err
	}
	return s.EdgesColoured(c[0], c[1], c[2])
}

// EdgesColouredPicked is this solid with edges (by index, as Fillet takes them) coloured,
// a colour that wins over the all-edges one; an empty list colours none — Python's
// edges_coloured(colour, edges).
func (s *Solid) EdgesColouredPicked(edges []int, r, g, b float64) (*Solid, error) {
	which, err := indices(edges)
	if err != nil {
		return nil, err
	}
	var first *C.uint32_t
	if len(which) > 0 {
		first = (*C.uint32_t)(unsafe.Pointer(&which[0]))
	} else {
		first = (*C.uint32_t)(unsafe.Pointer(&[]C.uint32_t{0}[0])) // non-null with count 0: none, not all
	}
	out, err := s.edgesColoured(first, len(which), r, g, b)
	runtime.KeepAlive(which)
	return out, err
}

// EdgesColouredPickedText is EdgesColouredPicked from "#rgb", "#rrggbb" or a CSS colour name.
func (s *Solid) EdgesColouredPickedText(edges []int, colour string) (*Solid, error) {
	c, err := RGB(colour)
	if err != nil {
		return nil, err
	}
	return s.EdgesColouredPicked(edges, c[0], c[1], c[2])
}

func (s *Solid) edgesColoured(first *C.uint32_t, count int, r, g, b float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_edges_coloured(h, first, C.size_t(count), C.double(r), C.double(g), C.double(b)), "edges_coloured")
	runtime.KeepAlive(s)
	return out, err
}

// EdgeColour is edge's colour as drawn — its own, else the solid's edge colour — and
// false where there is none.
func (s *Solid) EdgeColour(edge int) ([3]float64, bool, error) {
	i, err := index(edge)
	if err != nil {
		return [3]float64{}, false, err
	}
	defer pin()()
	h, err := s.h()
	if err != nil {
		return [3]float64{}, false, err
	}
	var out [3]float64
	ok := bool(C.cadaclysm_blacksmith_edge_colour(h, i, doubles(&out[0])))
	runtime.KeepAlive(s)
	if !ok {
		if lastError() != "" {
			return [3]float64{}, false, failure("edge_colour")
		}
		return [3]float64{}, false, nil
	}
	return out, true, nil
}

// Edges is the edges a fillet indexes, as Edge records (copied; safe to keep) — Python's
// edges property.
func (s *Solid) Edges() ([]Edge, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	defer runtime.KeepAlive(s)
	n := uint32(C.cadaclysm_blacksmith_edge_count(h))
	if n == 0 && lastError() != "" {
		return nil, failure("edge_count")
	}
	out := make([]Edge, 0, n)
	for i := uint32(0); i < n; i++ {
		var raw C.CadaclysmBlacksmithEdge
		if !bool(C.cadaclysm_blacksmith_edge(h, C.uint32_t(i), &raw)) {
			return nil, failure("edge")
		}
		faces := make([]int, raw.face_count)
		if raw.face_count > 0 && raw.faces != nil {
			for j, f := range unsafe.Slice((*uint32)(unsafe.Pointer(raw.faces)), int(raw.face_count)) {
				faces[j] = int(f)
			}
		}
		segments := make([][2][3]float64, raw.segment_count)
		if raw.segment_count > 0 && raw.segments != nil {
			flat := unsafe.Slice((*float64)(unsafe.Pointer(raw.segments)), 6*int(raw.segment_count))
			for k := range segments {
				copy(segments[k][0][:], flat[6*k:6*k+3])
				copy(segments[k][1][:], flat[6*k+3:6*k+6])
			}
		}
		var rawCurve C.CadaclysmBlacksmithCurve
		var curve *Curve
		if bool(C.cadaclysm_blacksmith_edge_curve(h, C.uint32_t(i), &rawCurve)) {
			curve = curveOf(&rawCurve)
		} else if !strings.Contains(lastError(), "has no exact curve") {
			return nil, failure("edge_curve")
		}
		out = append(out, Edge{Index: int(i), Kind: C.GoString(raw.kind), Faces: faces, Segments: segments, Curve: curve})
	}
	return out, nil
}

// Fillet is this solid with the edges at edges (indices into Edges; see EdgeIndices)
// rounded to radius. tolerance is Python's 1e-6 default, FilletTolerance.
func (s *Solid) Fillet(edges []int, radius, tolerance float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	which, err := indices(edges)
	if err != nil {
		return nil, err
	}
	var first *C.uint32_t
	if len(which) > 0 {
		first = (*C.uint32_t)(unsafe.Pointer(&which[0]))
	}
	out, err := newSolid(C.cadaclysm_blacksmith_fillet(
		h, first, C.size_t(len(which)), C.double(radius), C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(which)
	return out, err
}

// Chamfer is Fillet with a flat bevel: each edge cut back distance along both its faces.
// tolerance as Fillet's.
func (s *Solid) Chamfer(edges []int, distance, tolerance float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	which, err := indices(edges)
	if err != nil {
		return nil, err
	}
	var first *C.uint32_t
	if len(which) > 0 {
		first = (*C.uint32_t)(unsafe.Pointer(&which[0]))
	}
	out, err := newSolid(C.cadaclysm_blacksmith_chamfer(
		h, first, C.size_t(len(which)), C.double(distance), C.double(tolerance)), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(which)
	return out, err
}

// merged is out with its flush faces merged when merge is given and true -- the trailing
// flag Join, Cut and Common take (Python's merge=True), so a call without it stands as it
// was. The unmerged solid is closed.
func merged(out *Solid, err error, merge []bool) (*Solid, error) {
	if err != nil || len(merge) == 0 || !merge[0] {
		return out, err
	}
	defer out.Close()
	return out.MergeFlush()
}

// PushPull is face pushed out by distance along its outward normal (pulled in, negative)
// as a face extrude does it — Python's Solid.push_pull: the prism over it
// joined on (cut out) at tolerance, and the flush faces merged, so a box's top raised is
// one taller box of six faces. A face on a cylinder, a cone, a sphere or a torus moves out
// along its normal instead, the surface a step out (a boss fatter, a bore or a countersink
// narrower, a dome fuller), the flat faces beside it carried along; any other curved face
// is refused.
func (s *Solid) PushPull(face int, distance, tolerance float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	if face < 0 || face > math.MaxUint32 {
		return nil, &BuildError{Message: fmt.Sprintf("push_pull: face %d is out of range", face)}
	}
	out, err := newSolid(C.cadaclysm_blacksmith_push_pull(h, C.uint32_t(face), C.double(distance), C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// PushPullFaces is faces pushed out by distance together — Python's Solid.push_pull with a
// list, a press-pull on a selection: each face by PushPull's rule for it, one after
// another, each found again after the pushes before it renumbered the faces. A box's top
// and a side pushed 5 is the box 5 taller and 5 wider; a face on the same curved surface as
// one before it, and joined to it, moved with that one and is not pushed twice.
func (s *Solid) PushPullFaces(faces []int, distance, tolerance float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	which, err := indices(faces)
	if err != nil {
		return nil, err
	}
	var first *C.uint32_t
	if len(which) > 0 {
		first = (*C.uint32_t)(unsafe.Pointer(&which[0]))
	}
	out, err := newSolid(C.cadaclysm_blacksmith_push_pull_faces(
		h, first, C.size_t(len(which)), C.double(distance), C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(which)
	return out, err
}

// Split is this solid split by tool into bodies — Python's Solid.split:
// a closed tool gives the parts outside it, then the parts inside; a flat sheet
// splits by the whole plane it lies on. Each connected part is a body of its own.
func (s *Solid) Split(tool *Solid, tolerance float64) ([]*Solid, error) {
	all, err := func() (*Solid, error) {
		defer pin()()
		h, err := s.h()
		if err != nil {
			return nil, err
		}
		ht, err := tool.h()
		if err != nil {
			return nil, err
		}
		out, err := newSolid(C.cadaclysm_blacksmith_split(h, ht, C.double(tolerance), nil, nil), "solid")
		runtime.KeepAlive(s)
		runtime.KeepAlive(tool)
		return out, err
	}()
	if err != nil {
		return nil, err
	}
	defer all.Close()
	return all.Lumps()
}

// SplitByPlane is this solid split by the plane through plane's origin, square to its z
// — Python's Solid.split_by_plane: the bodies in front of it first, then those behind.
func (s *Solid) SplitByPlane(plane Frame, tolerance float64) ([]*Solid, error) {
	all, err := func() (*Solid, error) {
		defer pin()()
		h, err := s.h()
		if err != nil {
			return nil, err
		}
		f := plane
		out, err := newSolid(C.cadaclysm_blacksmith_split_by_plane(h, doubles(&f[0]), C.double(tolerance), nil, nil), "solid")
		runtime.KeepAlive(s)
		return out, err
	}()
	if err != nil {
		return nil, err
	}
	defer all.Close()
	return all.Lumps()
}

// SplitByProfile is this solid split by the closed profile drawn on frame, pushed
// straight through it along the frame's z both ways — Python's Solid.split_by_profile:
// the bodies outside the profile first, then those inside. Where the plane lies along z
// does not matter.
func (s *Solid) SplitByProfile(profile *Profile, frame Frame, tolerance float64) ([]*Solid, error) {
	all, err := func() (*Solid, error) {
		defer pin()()
		h, err := s.h()
		if err != nil {
			return nil, err
		}
		hp, err := profile.h()
		if err != nil {
			return nil, err
		}
		f := frame
		out, err := newSolid(C.cadaclysm_blacksmith_split_by_profile(h, hp, doubles(&f[0]), C.double(tolerance), nil, nil), "solid")
		runtime.KeepAlive(s)
		runtime.KeepAlive(profile)
		return out, err
	}()
	if err != nil {
		return nil, err
	}
	defer all.Close()
	return all.Lumps()
}

// Lumps is this solid's connected bodies, each a solid of its own — Python's
// Solid.lumps: faces sharing an edge are one body, in the order of their first faces.
func (s *Solid) Lumps() ([]*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	n := uint32(C.cadaclysm_blacksmith_lump_count(h))
	if n == 0 {
		return nil, failure("lump_count")
	}
	out := make([]*Solid, 0, n)
	for i := uint32(0); i < n; i++ {
		body, err := newSolid(C.cadaclysm_blacksmith_lump(h, C.uint32_t(i)), "solid")
		if err != nil {
			for _, b := range out {
				b.Close()
			}
			return nil, err
		}
		out = append(out, body)
	}
	runtime.KeepAlive(s)
	return out, nil
}

// Refillet is this solid with the round face belongs to — a fillet's bands, balls and rim
// bands joined to that face — made again at radius — Python's Solid.refillet, a press-pull on a fillet face: taken back to the sharp edges it replaced, and those
// rounded again. FilletTolerance is Python's default tolerance.
func (s *Solid) Refillet(face int, radius, tolerance float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	if face < 0 || face > math.MaxUint32 {
		return nil, &BuildError{Message: fmt.Sprintf("refillet: face %d is out of range", face)}
	}
	out, err := newSolid(C.cadaclysm_blacksmith_refillet(h, C.uint32_t(face), C.double(radius), C.double(tolerance)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Unfillet is this solid with the round face belongs to taken off, the faces beside it
// sharp again — Python's Solid.unfillet, the delete of a fillet face.
func (s *Solid) Unfillet(face int) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	if face < 0 || face > math.MaxUint32 {
		return nil, &BuildError{Message: fmt.Sprintf("unfillet: face %d is out of range", face)}
	}
	out, err := newSolid(C.cadaclysm_blacksmith_unfillet(h, C.uint32_t(face)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Rechamfer is this solid with the chamfer face belongs to — its bevels, flat or round a
// rim, and the corner triangles joined to that face — cut again at distance — Python's
// Solid.rechamfer, a press-pull on a chamfer face.
func (s *Solid) Rechamfer(face int, distance, tolerance float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	if face < 0 || face > math.MaxUint32 {
		return nil, &BuildError{Message: fmt.Sprintf("rechamfer: face %d is out of range", face)}
	}
	out, err := newSolid(C.cadaclysm_blacksmith_rechamfer(h, C.uint32_t(face), C.double(distance), C.double(tolerance)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Unchamfer is this solid with the chamfer face belongs to taken off, the faces beside it
// sharp again — Python's Solid.unchamfer, the delete of a chamfer face.
func (s *Solid) Unchamfer(face int) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	if face < 0 || face > math.MaxUint32 {
		return nil, &BuildError{Message: fmt.Sprintf("unchamfer: face %d is out of range", face)}
	}
	out, err := newSolid(C.cadaclysm_blacksmith_unchamfer(h, C.uint32_t(face)), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// MergeFlush is this solid with its flush faces merged — Python's Solid.merge_flush: flat
// faces on one plane, facing one way and meeting, made one face, and the vertices left
// mid-way along a straight edge taken out.
func (s *Solid) MergeFlush() (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_merge_flush(h), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// Shell is this solid hollowed to a wall thickness thick (inward for a positive
// thickness, outward — the solid becoming the cavity — for a negative one), with the
// faces at open removed so the hollow is reachable (nil for none, Python's default).
// tolerance as Fillet's.
func (s *Solid) Shell(thickness float64, open []int, tolerance float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	which, err := indices(open)
	if err != nil {
		return nil, err
	}
	var first *C.uint32_t
	if len(which) > 0 {
		first = (*C.uint32_t)(unsafe.Pointer(&which[0]))
	}
	out, err := newSolid(C.cadaclysm_blacksmith_shell(
		h, C.double(thickness), first, C.size_t(len(which)), C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	runtime.KeepAlive(which)
	return out, err
}

// Thicken is this sheet made a solid thickness thick — Python's Solid.thicken:
// its faces, their twins moved thickness along the faces' normals (against them
// for a negative thickness), and a wall round every open edge. A closed sheet thickens to
// a hollow. tolerance as Fillet's.
func (s *Solid) Thicken(thickness, tolerance float64) (*Solid, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	out, err := newSolid(C.cadaclysm_blacksmith_thicken(h, C.double(thickness), C.double(tolerance), nil, nil), "solid")
	runtime.KeepAlive(s)
	return out, err
}

// ---- solids from files ------------------------------------------------------------------

// FromNode is the body node of a reader Scene draws, as a solid -- sharing the reader's
// brep, not copying it. The scene can be closed before the solid is. placed puts it where
// the node's Transform does, which is where its mesh draws; a node at the identity stays
// shared, a moved one is a moved copy. In the file's own units and axes. Needs the reader's
// library from the same release as this one's: the brep is handed across by pointer and
// the two layouts are compared first. What a solid from a file can then do: see [Open].
func FromNode(scene *cadaclysm.Scene, node *cadaclysm.Node, placed bool) (*Solid, error) {
	label := fmt.Sprintf("from_node: node %d (%s)", node.Index(), nodeLabel(node))
	solid, err := fromBrep(node, label)
	if err != nil {
		return nil, err
	}
	if solid == nil {
		return nil, &BuildError{label + " has no brep: only a B-rep body has one (STEP, ACIS, Rhino, OCCT .brep, " +
			"IGES, IFC), not a mesh, a curve or a CSG body"}
	}
	if !placed {
		return solid, nil
	}
	transform := node.Transform()
	if scene.Convention() != cadaclysm.Native && !isIdentity(transform) {
		solid.Close()
		return nil, &BuildError{"from_node: placed=True needs the scene opened with Convention.Native -- the brep " +
			"is in the file's own axes and the node's transform is not; open Native, or pass placed false"}
	}
	return solid.placed(transform, "from_node")
}

// Open is the body a CAD file holds, as a solid: a STEP (AP203/214/242), ACIS .sat,
// Rhino .3dm, OCCT .brep, IGES or IFC file, read where it draws, in the file's own units
// and axes. A file drawing several bodies needs [OpenBody] or [OpenAll]. Fillet and
// chamfer want line and circle edges; booleans take any surface, but the new edges they
// trace on a free-form (NURBS) face are not always writable back to STEP; and every verb
// meshes its operands first, so its cost grows with the body's face count.
func Open(path string) (*Solid, error) { return openOne(path, -1) }

// OpenBody is [Open] for one body of several, 0-based in drawing order.
func OpenBody(path string, body int) (*Solid, error) {
	if body < 0 {
		return nil, &BuildError{fmt.Sprintf("open: %s has no body %d", filepath.Base(path), body)}
	}
	return openOne(path, body)
}

func openOne(path string, body int) (*Solid, error) {
	solids, err := OpenAll(path)
	if err != nil {
		return nil, err
	}
	name := filepath.Base(path)
	if body < 0 && len(solids) == 1 {
		return solids[0], nil
	}
	if body < 0 || body >= len(solids) {
		for _, s := range solids {
			s.Close()
		}
		if body < 0 {
			return nil, &BuildError{fmt.Sprintf("open: %s holds %d bodies: pass body= (0 to %d), or use Solid.open_all",
				name, len(solids), len(solids)-1)}
		}
		return nil, &BuildError{fmt.Sprintf("open: %s has no body %d: it holds %d", name, body, len(solids))}
	}
	for i, s := range solids {
		if i != body {
			s.Close()
		}
	}
	return solids[body], nil
}

// OpenAll is every body a CAD file draws, as solids placed where it draws them: one per
// placement, so a part placed twice is two solids. See [Open].
func OpenAll(path string) ([]*Solid, error) {
	scene, err := cadaclysm.Open(path)
	if err != nil {
		return nil, &BuildError{"open: " + err.Error()}
	}
	defer scene.Close()
	var solids []*Solid
	fail := func(err error) ([]*Solid, error) {
		for _, s := range solids {
			s.Close()
		}
		return nil, err
	}
	for _, placement := range scene.Placements() {
		node := placement.Geometry()
		what := "open: " + nodeLabel(node)
		solid, err := fromBrep(node, what)
		if err != nil {
			return fail(err)
		}
		if solid == nil {
			continue
		}
		moved, err := solid.placed(placement.Transform(), what)
		if err != nil {
			return fail(err)
		}
		solids = append(solids, moved)
	}
	if len(solids) == 0 {
		extension := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
		return nil, &BuildError{fmt.Sprintf("open: the .%s file draws no B-rep body -- only a STEP, ACIS, Rhino, "+
			"OCCT .brep, IGES or IFC body can be a solid, not a mesh, a curve or a CSG body", extension)}
	}
	return solids, nil
}

// BrepLayoutID is how the loaded library lays a brep out in memory: its compiler, target and
// source. FromNode works only where this equals the reader library's
// [cadaclysm.BrepLayoutID] -- the two from the same release.
func BrepLayoutID() string { return C.GoString(C.cadaclysm_blacksmith_brep_layout_id()) }

func nodeLabel(node *cadaclysm.Node) string {
	if name := node.Name(); name != "" {
		return name
	}
	if kind := node.Kind(); kind != "" {
		return kind
	}
	return fmt.Sprint(node.Index())
}

// fromBrep is the node's brep as a solid, shared -- nil, nil where it has none.
func fromBrep(node *cadaclysm.Node, what string) (*Solid, error) {
	brep, err := node.Brep()
	if err != nil || brep == nil {
		return nil, err
	}
	defer brep.Close()
	defer pin()()
	layout := C.CString(cadaclysm.BrepLayoutID())
	defer C.free(unsafe.Pointer(layout))
	solid, err := newSolid(C.cadaclysm_blacksmith_from_brep(brep.Pointer(), layout), what)
	runtime.KeepAlive(brep)
	return solid, err
}

func isIdentity(m [16]float64) bool {
	for i := 0; i < 16; i++ {
		want := 0.0
		if i%5 == 0 {
			want = 1
		}
		if m[i] != want {
			return false
		}
	}
	return true
}

// placed is this solid moved by a row-major 4x4 placement: itself at the identity, a
// moved copy for a rigid move (a mirror included; this one is closed), refused for a scale
// or shear, which a brep cannot follow exactly (a cylinder's radius is a number, not a
// point).
func (s *Solid) placed(m [16]float64, what string) (*Solid, error) {
	if isIdentity(m) {
		return s, nil
	}
	defer s.Close()
	for a := 0; a < 3; a++ {
		for b := 0; b < 3; b++ {
			dot := m[a]*m[b] + m[4+a]*m[4+b] + m[8+a]*m[8+b]
			want := 0.0
			if a == b {
				want = 1
			}
			if math.Abs(dot-want) > 1e-9 {
				return nil, &BuildError{what + ": the placement scales or shears, which a brep cannot follow"}
			}
		}
	}
	return s.Place(Frame{m[3], m[7], m[11], m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10]})
}

// ToScene is this solid as a reader Scene, through STEP text and cadaclysm.OpenMemory —
// the door to the viewer and the tree walk. Needs the reader's library built beside this
// one. schema is as StepText takes it; the reader is given the schema's path only when
// it names an existing file, since it carries every built-in schema itself and there is
// no file here to read a FILE_SCHEMA line out of.
func (s *Solid) ToScene(schema string) (*cadaclysm.Scene, error) {
	text, err := s.StepText(schema, "mm")
	if err != nil {
		return nil, err
	}
	var opts []cadaclysm.Option
	if schema != "" && !containsNewline(schema) {
		if info, err := os.Stat(schema); err == nil && !info.IsDir() {
			opts = append(opts, cadaclysm.WithSchema(schema))
		}
	}
	return cadaclysm.OpenMemory([]byte(text), "solid.stp", opts...)
}

// ---- assemblies -----------------------------------------------------------------------

// Assembly is a mutable tree of placements: a name, and zero or more solids or other
// assemblies placed in it at a frame — Python's Assembly, modelled on Path's handle life.
// Unlike Solid, placing shares rather than copies: placing one assembly under another does
// not snapshot it, so a later placement on the shared one shows up wherever it already
// sits. Close it, or let the finalizer free it, as Path; closing an assembly does not free
// what was placed in it if that is still reachable from somewhere else.
type Assembly struct {
	handle *C.CadaclysmBlacksmithAssembly
	_      noTiny // see noTiny
}

// NewAssembly is a new, empty assembly called name. An empty name is refused.
func NewAssembly(name string) (*Assembly, error) {
	defer pin()()
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	h := C.cadaclysm_blacksmith_assembly_new(c)
	if h == nil {
		return nil, failure("assembly_new")
	}
	a := &Assembly{handle: h}
	runtime.SetFinalizer(a, (*Assembly).finalize)
	return a, nil
}

func (a *Assembly) finalize() {
	if a.handle != nil {
		C.cadaclysm_blacksmith_assembly_free(a.handle)
		a.handle = nil
	}
}

// h is the live handle, refusing to hand over a closed one, so a use-after-close returns
// an error at the call site instead of passing a dangling pointer into the library.
func (a *Assembly) h() (*C.CadaclysmBlacksmithAssembly, error) {
	if a == nil || a.handle == nil {
		return nil, fmt.Errorf("assembly: %w", ErrClosed)
	}
	return a.handle, nil
}

// Closed is whether Close has already run. A nil Assembly counts as closed.
func (a *Assembly) Closed() bool { return a == nil || a.handle == nil }

// Close gives the assembly back. Idempotent, and a no-op on a nil Assembly. Does not free
// what was placed in it if that is still reachable from somewhere else. The error return
// is always nil; it exists so an Assembly satisfies io.Closer and defers like every other
// resource.
func (a *Assembly) Close() error {
	if a == nil || a.handle == nil {
		return nil
	}
	h := a.handle
	a.handle = nil
	runtime.SetFinalizer(a, nil)
	C.cadaclysm_blacksmith_assembly_free(h)
	return nil
}

// Name is this assembly's own name, given when it was made — Python's name. Never fails on
// a live assembly (the library never returns null here, unlike (*Solid).Name); "" on a
// closed one, since the signature carries no error, the way (*Path).Closed reads a nil
// receiver as closed rather than panicking.
func (a *Assembly) Name() string {
	defer pin()()
	h, err := a.h()
	if err != nil {
		return ""
	}
	p := C.cadaclysm_blacksmith_assembly_name(h)
	out := C.GoString(p)
	runtime.KeepAlive(a)
	return out
}

// placeResult turns the owned text PlaceSolid and PlaceAssembly get back into a Go string,
// freeing the library's copy; NULL is a refusal, read from last_error. The callers make the
// raw call and keep its operands alive; they pass an empty name as NULL (Python's None),
// because the library refuses "" as an explicit empty name.
func placeResult(raw *C.char, what string) (string, error) {
	if raw == nil {
		return "", failure(what)
	}
	defer C.cadaclysm_blacksmith_string_free(raw)
	return C.GoString(raw), nil
}

// cName is name as the library's nullable name parameter takes it: nil for "", else a
// freshly allocated C string the caller must free.
func cName(name string) *C.char {
	if name == "" {
		return nil
	}
	return C.CString(name)
}

// PlaceSolid places solid at frame (must be right-handed and orthonormal) in this
// assembly, called name — or, with name left empty, solid's own name (Solid.Name, or
// "part" for an unnamed one), numbered past any already taken here ("bolt", "bolt 2",
// ...). An explicit name already taken here is refused. Returns the placement's name —
// Python's place, split as Go has no type-dispatching overload; see PlaceAssembly for
// placing another assembly.
func (a *Assembly) PlaceSolid(s *Solid, frame Frame, name string) (string, error) {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return "", err
	}
	sh, err := s.h()
	if err != nil {
		return "", err
	}
	c := cName(name)
	if c != nil {
		defer C.free(unsafe.Pointer(c))
	}
	raw := C.cadaclysm_blacksmith_assembly_place_solid(ah, sh, doubles(&frame[0]), c)
	runtime.KeepAlive(a)
	runtime.KeepAlive(s)
	return placeResult(raw, "assembly_place_solid")
}

// PlaceAssembly places another assembly, placed, sharing it rather than copying it, as
// PlaceSolid places a solid — name defaults to placed's own Name. Placing placed as this
// assembly itself, or anywhere above this assembly in the tree already, is refused
// (naming the cycle), since writing that out would never terminate. Returns the
// placement's name.
func (a *Assembly) PlaceAssembly(placed *Assembly, frame Frame, name string) (string, error) {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return "", err
	}
	ph, err := placed.h()
	if err != nil {
		return "", err
	}
	c := cName(name)
	if c != nil {
		defer C.free(unsafe.Pointer(c))
	}
	raw := C.cadaclysm_blacksmith_assembly_place_assembly(ah, ph, doubles(&frame[0]), c)
	runtime.KeepAlive(a)
	runtime.KeepAlive(placed)
	return placeResult(raw, "assembly_place_assembly")
}

// Link declares a rigid link name over placements of this assembly, by their names.
// Written as an AP242 kinematic link when the assembly is written; see spec
// 2026-09-25-blacksmith-mechanisms-design.md for the rules. Go's cgo pointer rules forbid
// passing a Go-allocated []*C.char whose elements point to C memory, so the array itself is
// C.malloc'd here rather than built as a Go slice; every C.CString and the array are freed
// exactly once, including on an early return.
func (a *Assembly) Link(name string, placements []string) error {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return err
	}
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))

	n := len(placements)
	var arr unsafe.Pointer
	if n > 0 {
		arr = C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(uintptr(0))))
		slice := unsafe.Slice((**C.char)(arr), n)
		for i, p := range placements {
			slice[i] = C.CString(p)
		}
		defer func() {
			for i := 0; i < n; i++ {
				C.free(unsafe.Pointer(slice[i]))
			}
			C.free(arr)
		}()
	}

	ok := bool(C.cadaclysm_blacksmith_assembly_link(ah, cn, (**C.char)(arr), C.size_t(n)))
	runtime.KeepAlive(a)
	if !ok {
		return failure("assembly_link")
	}
	return nil
}

// Joint connects this assembly's links start and end (kept in that order) as an AP242
// kinematic joint called name.
func (a *Assembly) Joint(name, start, end string) error {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return err
	}
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))
	cs := C.CString(start)
	defer C.free(unsafe.Pointer(cs))
	ce := C.CString(end)
	defer C.free(unsafe.Pointer(ce))
	ok := bool(C.cadaclysm_blacksmith_assembly_joint(ah, cn, cs, ce))
	runtime.KeepAlive(a)
	if !ok {
		return failure("assembly_joint")
	}
	return nil
}

// Range is one freedom's bounds for Pair's Ranges — either side nil for unbounded.
type Range struct {
	Lower, Upper *float64
}

// PairOptions is Pair's optional arguments, Go's spelling of Python's keyword arguments:
// EndFrame nil is "frame itself" (all-zero rest values); Ranges nil is "none" (a kind
// that allows none, or no ranges at all); Pitch nil is NaN (required and non-zero for
// "screw", refused for any other kind).
type PairOptions struct {
	EndFrame *Frame
	Ranges   []Range
	Pitch    *float64
}

// Pair gives joint joint its pair: kind (a name of the kind table — "revolute",
// "prismatic", "cylindrical", "screw", "spherical", "spherical_with_pin", "planar",
// "universal", "homokinetic", "fully_constrained" or "unconstrained"), the contact frame
// at rest, and opts — see [PairOptions]. [PairFreedomCount] sizes opts.Ranges: one entry
// per freedom of kind. An unknown or already-paired joint, an unknown kind, a bad pitch,
// ranges given where none are allowed or of the wrong length, a non-finite or inverted
// range, or an end frame this kind's motion cannot reach returns the kernel's own
// *BuildError, and the assembly is left as it was.
//
// Ranges' four parallel arrays (lower, upper, has_lower, has_upper) are C.malloc'd and
// freed in a defer, as Link's placement array is — Go's cgo pointer rules forbid handing
// C a Go-allocated array it might read after this call returns, and nothing shorter-lived
// than the call itself is safe to free early.
func (a *Assembly) Pair(joint, kind string, frame Frame, opts PairOptions) error {
	pitch := math.NaN()
	if opts.Pitch != nil {
		pitch = *opts.Pitch
	}
	return a.pairCall(joint, kind, frame, opts.EndFrame, opts.Ranges, func(ah *C.CadaclysmBlacksmithAssembly, cj, ck *C.char, f, ef, lower, upper *C.double, hl, hu *C.bool, n C.size_t) bool {
		return bool(C.cadaclysm_blacksmith_assembly_pair(ah, cj, ck, f, ef, lower, upper, hl, hu, n, C.double(pitch)))
	})
}

// pairCall is Pair and PairWith's shared body: it marshals the frames and ranges, and
// invoke makes the one C call that differs between them.
func (a *Assembly) pairCall(joint, kind string, frame Frame, endFrameOpt *Frame, ranges []Range,
	invoke func(ah *C.CadaclysmBlacksmithAssembly, cj, ck *C.char, f, ef, lower, upper *C.double, hl, hu *C.bool, n C.size_t) bool) error {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return err
	}
	cj := C.CString(joint)
	defer C.free(unsafe.Pointer(cj))
	ck := C.CString(kind)
	defer C.free(unsafe.Pointer(ck))

	var endFrame *C.double
	if endFrameOpt != nil {
		ef := *endFrameOpt
		endFrame = doubles(&ef[0])
	}

	// len() is 0 for both a nil Ranges and an empty, non-nil []Range -- Go has no
	// nil-vs-empty-slice distinction worth separate handling here, so both mean "no
	// ranges" and send all four pointers null (controller ruling; this is this wrapper's
	// own idiom, not a pass-through of the C ABI's null-vs-zero-count distinction).
	n := len(ranges)
	var lower, upper *C.double
	var hasLower, hasUpper *C.bool
	if n > 0 {
		lowerArr := C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.double(0))))
		defer C.free(lowerArr)
		upperArr := C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.double(0))))
		defer C.free(upperArr)
		hasLowerArr := C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.bool(false))))
		defer C.free(hasLowerArr)
		hasUpperArr := C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.bool(false))))
		defer C.free(hasUpperArr)
		lowerSlice := unsafe.Slice((*C.double)(lowerArr), n)
		upperSlice := unsafe.Slice((*C.double)(upperArr), n)
		hasLowerSlice := unsafe.Slice((*C.bool)(hasLowerArr), n)
		hasUpperSlice := unsafe.Slice((*C.bool)(hasUpperArr), n)
		for i, r := range ranges {
			if r.Lower != nil {
				lowerSlice[i] = C.double(*r.Lower)
				hasLowerSlice[i] = C.bool(true)
			} else {
				lowerSlice[i] = 0
				hasLowerSlice[i] = C.bool(false)
			}
			if r.Upper != nil {
				upperSlice[i] = C.double(*r.Upper)
				hasUpperSlice[i] = C.bool(true)
			} else {
				upperSlice[i] = 0
				hasUpperSlice[i] = C.bool(false)
			}
		}
		lower = (*C.double)(lowerArr)
		upper = (*C.double)(upperArr)
		hasLower = (*C.bool)(hasLowerArr)
		hasUpper = (*C.bool)(hasUpperArr)
	}

	ok := invoke(ah, cj, ck, doubles(&frame[0]), endFrame, lower, upper, hasLower, hasUpper, C.size_t(n))
	runtime.KeepAlive(a)
	if !ok {
		return failure("assembly_pair")
	}
	return nil
}

// PairWithOptions is PairWith's optional arguments: EndFrame nil is "frame itself", Ranges
// nil is "none" -- as in [PairOptions].
type PairWithOptions struct {
	EndFrame *Frame
	Ranges   []Range
}

// PairWith is [Assembly.Pair] with the kind's parameters in place of the pitch: "screw"
// [pitch]; "rack_and_pinion" [pinion_radius]; "gear" [radius_first, radius_second,
// ratio] or those plus [bevel, helical_angle] (radians), the ratio the second link's
// rotation over the first's, signed; none for any other kind. Everything else, the
// refusals included (a wrong parameter count among them), reads as in Pair, and the
// assembly is left as it was on an error. params is copied into a C.malloc'd array freed
// in a defer, for cgo's pointer rule.
func (a *Assembly) PairWith(joint, kind string, frame Frame, opts PairWithOptions, params []float64) error {
	var cparams *C.double
	if len(params) > 0 {
		arr := C.malloc(C.size_t(len(params)) * C.size_t(unsafe.Sizeof(C.double(0))))
		defer C.free(arr)
		slice := unsafe.Slice((*C.double)(arr), len(params))
		for i, v := range params {
			slice[i] = C.double(v)
		}
		cparams = (*C.double)(arr)
	}
	return a.pairCall(joint, kind, frame, opts.EndFrame, opts.Ranges, func(ah *C.CadaclysmBlacksmithAssembly, cj, ck *C.char, f, ef, lower, upper *C.double, hl, hu *C.bool, n C.size_t) bool {
		return bool(C.cadaclysm_blacksmith_assembly_pair_with(ah, cj, ck, f, ef, lower, upper, hl, hu, n, cparams, C.size_t(len(params))))
	})
}

// StateRow is one row of Assembly.State: joint set to values, in that joint's pair's
// freedom order.
type StateRow struct {
	Joint  string
	Values []float64
}

// State adds a named state name to this assembly: rows sets each named joint to its
// values, in that joint's pair's freedom order. An empty or duplicate name, no rows, an
// unknown joint, a joint set twice, a joint with no pair or none of its pair's freedoms,
// a row of the wrong length, or a non-finite or out-of-range value returns the kernel's
// own *BuildError, and the assembly is left as it was.
//
// rows' joint names, row lengths and flattened values are three C.malloc'd arrays, freed
// in a defer along with every C.CString, exactly as Link builds its placement array.
func (a *Assembly) State(name string, rows []StateRow) error {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return err
	}
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))

	joints, countsArr, valuesArr, n, release := stateRowArrays(rows)
	defer release()

	ok := bool(C.cadaclysm_blacksmith_assembly_state(ah, cn,
		(**C.char)(joints), (*C.uint32_t)(countsArr), (*C.double)(valuesArr), C.size_t(n)))
	runtime.KeepAlive(a)
	if !ok {
		return failure("assembly_state")
	}
	return nil
}

// stateRowArrays is rows as State's and Posed's three C.malloc'd arrays (joint names, row
// lengths, flattened values; nil when empty) and the row count; release frees them and
// every C.CString.
func stateRowArrays(rows []StateRow) (joints, countsArr, valuesArr unsafe.Pointer, n int, release func()) {
	n = len(rows)
	if n == 0 {
		return nil, nil, nil, 0, func() {}
	}
	joints = C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(uintptr(0))))
	jointSlice := unsafe.Slice((**C.char)(joints), n)
	countsArr = C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.uint32_t(0))))
	countsSlice := unsafe.Slice((*C.uint32_t)(countsArr), n)
	total := 0
	for _, r := range rows {
		total += len(r.Values)
	}
	var valuesSlice []C.double
	if total > 0 {
		valuesArr = C.malloc(C.size_t(total) * C.size_t(unsafe.Sizeof(C.double(0))))
		valuesSlice = unsafe.Slice((*C.double)(valuesArr), total)
	}
	offset := 0
	for i, r := range rows {
		jointSlice[i] = C.CString(r.Joint)
		countsSlice[i] = C.uint32_t(len(r.Values))
		for _, v := range r.Values {
			valuesSlice[offset] = C.double(v)
			offset++
		}
	}
	release = func() {
		for i := 0; i < n; i++ {
			C.free(unsafe.Pointer(jointSlice[i]))
		}
		C.free(joints)
		C.free(countsArr)
		if valuesArr != nil {
			C.free(valuesArr)
		}
	}
	return
}

// PosedOptions is Posed's optional arguments: State a state's path applied first (nil is
// none), Ground one of this assembly's own links held fixed (nil is the kernel's default).
type PosedOptions struct {
	State  *string
	Ground *string
}

// Posed is this assembly with its mechanism posed, as a new *Assembly the caller owns
// (Close it, or let the finalizer): rows sets each joint to its values (radians, the
// assembly's units), in its pair's freedom order -- a row's Joint a path of placement
// names then the joint's name joined by "/", a "/" or "\" inside a name escaped with
// "\"; opts.State is a state's path, applied first and overridden row by row;
// opts.Ground one of this assembly's own links held fixed. No rows is allowed. A
// sub-assembly no row reaches is shared with this one. A refusal returns the kernel's own
// *BuildError; this assembly is unchanged either way.
func (a *Assembly) Posed(rows []StateRow, opts PosedOptions) (*Assembly, error) {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return nil, err
	}
	joints, countsArr, valuesArr, n, release := stateRowArrays(rows)
	defer release()
	var cstate, cground *C.char
	if opts.State != nil {
		cstate = C.CString(*opts.State)
		defer C.free(unsafe.Pointer(cstate))
	}
	if opts.Ground != nil {
		cground = C.CString(*opts.Ground)
		defer C.free(unsafe.Pointer(cground))
	}
	h := C.cadaclysm_blacksmith_assembly_posed(ah,
		(**C.char)(joints), (*C.uint32_t)(countsArr), (*C.double)(valuesArr), C.size_t(n), cstate, cground)
	runtime.KeepAlive(a)
	if h == nil {
		return nil, failure("assembly_posed")
	}
	posed := &Assembly{handle: h}
	runtime.SetFinalizer(posed, (*Assembly).finalize)
	return posed, nil
}

// SequenceSegment is one segment of Assembly.Sequence: the named state it reaches, its
// parameter T, and how the motion leaves it for the next, one of the words "undefined",
// "discontinuous", "synchronous" or "linear".
type SequenceSegment struct {
	State         string
	T             float64
	Interpolation string
}

// Sequence adds a named motion sequence over this assembly's states: segments in
// increasing T, each reaching a named state. The sequence is closed unless its last
// segment is "discontinuous". seconds says T is in seconds (the file then states a time
// unit). An empty or duplicate name, fewer than two segments, an unknown state, a T that
// is not finite or decreases, or an unknown interpolation word returns the kernel's own
// *BuildError, and the assembly is left as it was.
//
// The state names and interpolation words are C.CString arrays and the parameters a
// C.malloc'd one, all freed in a defer, as State frees its rows.
func (a *Assembly) Sequence(name string, segments []SequenceSegment, seconds bool) error {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return err
	}
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))

	n := len(segments)
	var statesArr, interpArr, tsArr unsafe.Pointer
	if n > 0 {
		statesArr = C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(uintptr(0))))
		interpArr = C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(uintptr(0))))
		tsArr = C.malloc(C.size_t(n) * C.size_t(unsafe.Sizeof(C.double(0))))
		stateSlice := unsafe.Slice((**C.char)(statesArr), n)
		interpSlice := unsafe.Slice((**C.char)(interpArr), n)
		tsSlice := unsafe.Slice((*C.double)(tsArr), n)
		for i, g := range segments {
			stateSlice[i] = C.CString(g.State)
			interpSlice[i] = C.CString(g.Interpolation)
			tsSlice[i] = C.double(g.T)
		}
		defer func() {
			for i := 0; i < n; i++ {
				C.free(unsafe.Pointer(stateSlice[i]))
				C.free(unsafe.Pointer(interpSlice[i]))
			}
			C.free(statesArr)
			C.free(interpArr)
			C.free(tsArr)
		}()
	}

	ok := bool(C.cadaclysm_blacksmith_assembly_sequence(ah, cn,
		(**C.char)(statesArr), (*C.double)(tsArr), (**C.char)(interpArr), C.size_t(n), C.bool(seconds)))
	runtime.KeepAlive(a)
	if !ok {
		return failure("assembly_sequence")
	}
	return nil
}

// Base declares this assembly's base link. link naming no link of this assembly, or a
// base already declared, returns the kernel's own *BuildError naming the link already
// there, and the assembly is left as it was.
func (a *Assembly) Base(link string) error {
	defer pin()()
	ah, err := a.h()
	if err != nil {
		return err
	}
	cl := C.CString(link)
	defer C.free(unsafe.Pointer(cl))
	ok := bool(C.cadaclysm_blacksmith_assembly_base(ah, cl))
	runtime.KeepAlive(a)
	if !ok {
		return failure("assembly_base")
	}
	return nil
}

// PairFreedomCount is how many freedoms a pair kind has, so a caller can size
// [PairOptions]'s Ranges. 0 for an unknown name, and for "fully_constrained", which has
// none.
func PairFreedomCount(kind string) int {
	defer pin()()
	ck := C.CString(kind)
	defer C.free(unsafe.Pointer(ck))
	return int(C.cadaclysm_blacksmith_pair_freedom_count(ck))
}

// StepText is this assembly, and everything placed under it, as one STEP file: this
// assembly the root product, each sub-assembly and each distinct part (the same solid
// with the same paint and name) written once, each placement an occurrence named as it
// was placed. schema and unit as WriteStepText takes them. An assembly reachable from
// this one, this one included, that places nothing is refused — a reader would never show
// it.
func (a *Assembly) StepText(schema, unit string) (string, error) {
	defer pin()()
	h, err := a.h()
	if err != nil {
		return "", err
	}
	code, ok := units[unit]
	if !ok {
		names := make([]string, 0, len(units))
		for name := range units {
			names = append(names, name)
		}
		sort.Strings(names)
		return "", &BuildError{Message: fmt.Sprintf("unit must be one of %v", names)}
	}
	cs, err := schemaText(schema)
	if err != nil {
		return "", err
	}
	if cs != nil {
		defer C.free(unsafe.Pointer(cs))
	}
	raw := C.cadaclysm_blacksmith_assembly_step(h, cs, C.uint32_t(code))
	runtime.KeepAlive(a)
	return placeResult(raw, "assembly_step")
}

// Step writes StepText to path.
func (a *Assembly) Step(path, schema, unit string) error {
	text, err := a.StepText(schema, unit)
	if err != nil {
		return err
	}
	return os.WriteFile(path, []byte(text), 0o644)
}

// ToScene is this assembly as a reader Scene, through STEP text and cadaclysm.OpenMemory —
// Solid.ToScene's own door, over the whole tree instead of one solid. Needs the reader's
// library built beside this one.
func (a *Assembly) ToScene(schema string) (*cadaclysm.Scene, error) {
	text, err := a.StepText(schema, "mm")
	if err != nil {
		return nil, err
	}
	var opts []cadaclysm.Option
	if schema != "" && !containsNewline(schema) {
		if info, err := os.Stat(schema); err == nil && !info.IsDir() {
			opts = append(opts, cadaclysm.WithSchema(schema))
		}
	}
	return cadaclysm.OpenMemory([]byte(text), "assembly.stp", opts...)
}

// ---- the workplane -------------------------------------------------------------------------------

// Workplane is the fluent chain, mirroring the Rust Workplane: a frame, the solid built so
// far, and the face last picked. A build call *replaces* the solid (as Workplane::set_brep
// does); combine solids explicitly with Solid.Join. Owns no handle: the solids it makes
// are the caller's to Close, through Solid().
//
// Every step returns the chain, and the first failure is remembered and reported from
// Solid() — the latching the Rust chain does, where Python raises at each step; nothing
// after the failure touches the library.
type Workplane struct {
	frame       Frame
	solid       *Solid
	selected    int
	hasSelected bool
	err         error
}

// XY is a chain on the world xy plane.
func XY() *Workplane { return &Workplane{frame: frameXY} }

// XZ is a chain on the world xz plane, y its normal.
func XZ() *Workplane { return &Workplane{frame: frameXZ} }

// YZ is a chain on the world yz plane, x its normal.
func YZ() *Workplane { return &Workplane{frame: frameYZ} }

// On is a chain on frame.
func On(frame Frame) *Workplane { return &Workplane{frame: frame} }

// FromSolid is a chain on the xy plane already holding solid, to pick a face of it and
// build on that — Python's Workplane.from_solid. The solid is borrowed, not closed by
// anything the chain does.
func FromSolid(solid *Solid) *Workplane { return &Workplane{frame: frameXY, solid: solid} }

// Frame is the plane the next build call sketches on — twelve numbers, origin, x, y, z.
// Python's frame attribute.
func (w *Workplane) Frame() Frame { return w.frame }

// SetFrame replaces the plane, leaving the solid and the picked face alone, as OnFace
// does.
func (w *Workplane) SetFrame(frame Frame) { w.frame = frame }

// Err is the first failure this chain met, or nil — what Solid() will return.
func (w *Workplane) Err() error { return w.err }

// set is a build call's replacing of the solid, dropping the face picked on the old one.
func (w *Workplane) set(solid *Solid, err error) *Workplane {
	if w.err != nil {
		return w
	}
	if err != nil {
		w.err = err
		return w
	}
	w.solid, w.hasSelected = solid, false
	return w
}

// placed is a primitive built about the origin and moved onto the frame. The unplaced one
// is nobody's, so it is closed here rather than left to the finalizer. The caller has
// already checked the chain has not failed, so the primitive was built for a reason.
func (w *Workplane) placed(raw *Solid, err error) *Workplane {
	if err != nil {
		w.err = err
		return w
	}
	defer raw.Close()
	return w.set(raw.Place(w.frame))
}

// Cuboid replaces the solid with a box x by y by z placed on the frame.
func (w *Workplane) Cuboid(x, y, z float64) *Workplane {
	if w.err != nil {
		return w
	}
	return w.placed(Cuboid(x, y, z))
}

// Cylinder replaces the solid with a cylinder of radius r and height h rising from the
// frame.
func (w *Workplane) Cylinder(r, h float64) *Workplane {
	if w.err != nil {
		return w
	}
	return w.placed(Cylinder(r, h))
}

// Extrude replaces the solid with profile swept height along the frame's z.
func (w *Workplane) Extrude(profile *Profile, height float64) *Workplane {
	if w.err != nil {
		return w
	}
	return w.set(Extrude(profile, w.frame, height))
}

// Face replaces the solid with the flat sheet profile bounds on this workplane's frame.
func (w *Workplane) Face(profile *Profile) *Workplane {
	if w.err != nil {
		return w
	}
	return w.set(Face(profile, w.frame))
}

// Revolve replaces the solid with profile swung angle radians about this workplane's own
// y axis through its origin, as the Rust chain.
func (w *Workplane) Revolve(profile *Profile, angle float64) *Workplane {
	if w.err != nil {
		return w
	}
	f := w.frame
	axis := [6]float64{f[0], f[1], f[2], f[6], f[7], f[8]}
	return w.set(Revolve(profile, axis, angle))
}

// Translate slides the current solid. Unlike a build call, this keeps Faces's selection: a
// rigid translation carries every face along at the same index, exactly as Rust's
// Workplane::translate writes the moved solid back without touching selected. Rust's is a
// silent no-op on an empty workplane; this, like Python's, fails the chain.
func (w *Workplane) Translate(dx, dy, dz float64) *Workplane {
	if w.err != nil {
		return w
	}
	if w.solid == nil {
		w.err = &BuildError{Message: "translate: the workplane holds no solid (BuildError::Empty)"}
		return w
	}
	moved, err := w.solid.Translate(dx, dy, dz)
	if err != nil {
		w.err = err
		return w
	}
	w.solid = moved
	return w
}

// Faces picks the face selector names on the current solid, for OnFace to build on.
func (w *Workplane) Faces(selector Selector) *Workplane {
	if w.err != nil {
		return w
	}
	if w.solid == nil {
		w.err = &BuildError{Message: "faces: the workplane holds no solid (BuildError::Empty)"}
		return w
	}
	picked, err := w.solid.SelectFace(selector)
	if err != nil {
		w.err = err
		return w
	}
	w.selected, w.hasSelected = picked, true
	return w
}

// OnFace adopts the frame on the face last picked; a no-op if none is. Python's
// workplane(), under the name the C# binding had to take (see the package doc).
func (w *Workplane) OnFace() *Workplane {
	if w.err != nil {
		return w
	}
	if w.solid != nil && w.hasSelected {
		frame, err := w.solid.FaceFrame(w.selected)
		if err != nil {
			w.err = err
			return w
		}
		w.frame = frame
	}
	return w
}

// Solid is the solid built so far — the caller's to Close — or the chain's first
// failure.
func (w *Workplane) Solid() (*Solid, error) {
	if w.err != nil {
		return nil, w.err
	}
	if w.solid == nil {
		return nil, &BuildError{Message: "solid: nothing was built (BuildError::Empty)"}
	}
	return w.solid, nil
}

// ---- machining --------------------------------------------------------------------------

// jobNulName is what the kernel says of a name with a control character in it -- a NUL,
// which the UTF-8 marshalling would otherwise cut the name short at, is refused here with
// it, before the string ever reaches the library.
const jobNulName = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |"

// JobDefaultClearance, JobDefaultTolerance, JobDefaultName, JobDefaultSpindleDwell and
// JobDefaultResolution are the library's own defaults for [NewJob]'s settings -- Go has no
// defaults, so a caller passing every one of these gets the library's own job.
const (
	JobDefaultClearance    = 1.0
	JobDefaultTolerance    = 0.01
	JobDefaultName         = "job"
	JobDefaultSpindleDwell = 2.0
	JobDefaultResolution   = 0.1
)

var jobSides = map[string]uint32{"outside": 0, "inside": 1, "on": 2}

// toolNumber is a Grbl tool number clamped as RegularPolygon's sides is: a negative number
// reads as 0, so the library reports its own "number must be at least 1".
func toolNumber(n int) C.uint32_t {
	if n < 0 {
		n = 0
	}
	return C.uint32_t(n)
}

// orNaN is v, or NaN for a nil pointer -- the library's own "none" for stepover, stepdown
// and peck.
func orNaN(v *float64) C.double {
	if v == nil {
		return C.double(math.NaN())
	}
	return C.double(*v)
}

// Tool is a cutter: Grbl tool number (1 to 255, the T word), diameter and fluteLength in
// mm, feed and plunge in mm/min, rpm its spindle speed, ramping into its cuts at rampAngle
// degrees. Immutable; a job keeps its own copy, so closing a tool a job has used changes
// nothing there. Owns a handle: Close it, or let the finalizer.
type Tool struct {
	handle *C.CadaclysmBlacksmithTool
	_      noTiny // see noTiny
}

func newTool(handle *C.CadaclysmBlacksmithTool, what string) (*Tool, error) {
	if handle == nil {
		return nil, failure(what)
	}
	t := &Tool{handle: handle}
	runtime.SetFinalizer(t, (*Tool).finalize)
	return t, nil
}

func (t *Tool) finalize() {
	if t.handle != nil {
		C.cadaclysm_blacksmith_tool_free(t.handle)
		t.handle = nil
	}
}

// h is the live handle, or ErrClosed after Close. A nil t (the zero value of Job.Machine's
// drills slice, meaning "no tool here") is not an error: the caller checks for it before
// asking for h.
func (t *Tool) h() (*C.CadaclysmBlacksmithTool, error) {
	if t == nil || t.handle == nil {
		return nil, fmt.Errorf("tool: %w", ErrClosed)
	}
	return t.handle, nil
}

// Closed is whether Close has already run. A nil Tool counts as closed.
func (t *Tool) Closed() bool { return t == nil || t.handle == nil }

// Close gives the tool back. Idempotent, and a no-op on a nil Tool. The error return is
// always nil; it exists so a Tool satisfies io.Closer.
func (t *Tool) Close() error {
	if t == nil || t.handle == nil {
		return nil
	}
	h := t.handle
	t.handle = nil
	runtime.SetFinalizer(t, nil)
	C.cadaclysm_blacksmith_tool_free(h)
	return nil
}

// ramped is made, turned to rampAngle when that is not the library's own 3 degrees -- the
// unramped handle closed at once, not left to the collector.
func ramped(made *C.CadaclysmBlacksmithTool, rampAngle float64, what string) (*Tool, error) {
	t, err := newTool(made, what)
	if err != nil {
		return nil, err
	}
	if rampAngle == 3.0 { // the library's own default: no second handle
		return t, nil
	}
	h, err := t.h()
	if err != nil {
		return nil, err
	}
	out, err := newTool(C.cadaclysm_blacksmith_tool_with_ramp_angle(h, C.double(rampAngle)), "tool_with_ramp_angle")
	t.Close()
	return out, err
}

// ToolFlat is a flat end mill. Fails for a number outside 1..255, a size, feed or speed
// not positive and finite, or a rampAngle outside (0, 90]. Python's rampAngle defaults to
// 3.0.
func ToolFlat(number int, diameter, fluteLength, feed, plunge, rpm, rampAngle float64) (*Tool, error) {
	defer pin()()
	made := C.cadaclysm_blacksmith_tool_flat(toolNumber(number), C.double(diameter), C.double(fluteLength), C.double(feed),
		C.double(plunge), C.double(rpm))
	return ramped(made, rampAngle, "tool_flat")
}

// ToolBall is a ball end mill, as ToolFlat but its tip a half sphere of the diameter; in
// 2.5D it cuts where a flat does, bottom being the tip.
func ToolBall(number int, diameter, fluteLength, feed, plunge, rpm, rampAngle float64) (*Tool, error) {
	defer pin()()
	made := C.cadaclysm_blacksmith_tool_ball(toolNumber(number), C.double(diameter), C.double(fluteLength), C.double(feed),
		C.double(plunge), C.double(rpm))
	return ramped(made, rampAngle, "tool_ball")
}

// ToolDrill is a drill, plunging at feed. A job takes it for Job.Drill (and Job.Machine's
// holes) only.
func ToolDrill(number int, diameter, fluteLength, feed, rpm float64) (*Tool, error) {
	defer pin()()
	return newTool(C.cadaclysm_blacksmith_tool_drill(toolNumber(number), C.double(diameter), C.double(fluteLength), C.double(feed),
		C.double(rpm)), "tool_drill")
}

// Stock is the block of material a job cuts, an axis-aligned box. Immutable; a job keeps
// its own copy. Owns a handle: Close it, or let the finalizer.
type Stock struct {
	handle *C.CadaclysmBlacksmithStock
	_      noTiny // see noTiny
}

func newStock(handle *C.CadaclysmBlacksmithStock, what string) (*Stock, error) {
	if handle == nil {
		return nil, failure(what)
	}
	s := &Stock{handle: handle}
	runtime.SetFinalizer(s, (*Stock).finalize)
	return s, nil
}

func (s *Stock) finalize() {
	if s.handle != nil {
		C.cadaclysm_blacksmith_stock_free(s.handle)
		s.handle = nil
	}
}

// h is the live handle, or ErrClosed after Close.
func (s *Stock) h() (*C.CadaclysmBlacksmithStock, error) {
	if s == nil || s.handle == nil {
		return nil, fmt.Errorf("stock: %w", ErrClosed)
	}
	return s.handle, nil
}

// Closed is whether Close has already run. A nil Stock counts as closed.
func (s *Stock) Closed() bool { return s == nil || s.handle == nil }

// Close gives the stock back. Idempotent, and a no-op on a nil Stock. The error return is
// always nil; it exists so a Stock satisfies io.Closer.
func (s *Stock) Close() error {
	if s == nil || s.handle == nil {
		return nil
	}
	h := s.handle
	s.handle = nil
	runtime.SetFinalizer(s, nil)
	C.cadaclysm_blacksmith_stock_free(h)
	return nil
}

// StockBox is the box from min (x, y, z) to max. Fails unless every min is below its max
// and all six are finite.
func StockBox(min, max [3]float64) (*Stock, error) {
	defer pin()()
	return newStock(C.cadaclysm_blacksmith_stock_box(C.double(min[0]), C.double(min[1]), C.double(min[2]),
		C.double(max[0]), C.double(max[1]), C.double(max[2])), "stock_box")
}

// StockAround is solid's bounds grown by margin in -X, +X, -Y, +Y and +Z; the bottom stays
// at the solid's lowest Z. Fails for a margin negative or not finite. Python's margin
// defaults to 0.0.
func StockAround(solid *Solid, margin float64) (*Stock, error) {
	defer pin()()
	h, err := solid.h()
	if err != nil {
		return nil, err
	}
	out, err := newStock(C.cadaclysm_blacksmith_stock_around(h, C.double(margin)), "stock_around")
	runtime.KeepAlive(solid)
	return out, err
}

// Program is one file a job wrote: a Grbl program (Tool its T number, Name
// "<job name>-T<n>", or "<job name>-<k>-T<n>" for a repeated tool) from Job.Gcode, or one
// of Job.WriteCamotics's files (Tool 0 for the simulation copies and the project). Copied
// out; read-only.
type Program struct {
	Tool int
	Name string
	Text string
}

// String is Python's repr.
func (p Program) String() string {
	return fmt.Sprintf("Program(tool=%d, name=%s, %d characters)", p.Tool, p.Name, len(p.Text))
}

// Operation is one operation of a Job, read back by Job.Operations: Kind ("face",
// "contour", "pocket" or "drill"), Tool (its Grbl T number) and Params, in the
// kind-specific order the operation stores them. Every param is the library's own number:
// side 0 outside, 1 inside, 2 on its line; climb and open 1 or 0; points a count; a peck
// of none is a nil *float64. Copied out; read-only.
type Operation struct {
	Kind   string
	Tool   int
	Params map[string]*float64
}

// String is Python's repr.
func (o Operation) String() string {
	parts := make([]string, 0, len(o.Params))
	for k, v := range o.Params {
		if v == nil {
			parts = append(parts, k+": <nil>")
		} else {
			parts = append(parts, fmt.Sprintf("%s: %v", k, *v))
		}
	}
	sort.Strings(parts)
	return fmt.Sprintf("Operation(kind=%s, tool=%d, params={%s})", o.Kind, o.Tool, strings.Join(parts, ", "))
}

// ReportItem is one thing Job.Machine left uncut: Kind ("corner", "hole", "slope",
// "undercut" or "too_deep"), At (x, y, z), Size (its meaning per Kind), Reason (one
// sentence naming the tool involved), and Region (its XY area, as profiles of their own,
// owned: Close each, or let the finalizer). Copied out; read-only.
type ReportItem struct {
	Kind   string
	At     [3]float64
	Size   float64
	Reason string
	Region []*Profile
}

// String is Python's repr.
func (r ReportItem) String() string {
	return fmt.Sprintf("ReportItem(kind=%s, at=%v, size=%v, reason=%s, region=%d profile(s))",
		r.Kind, r.At, r.Size, r.Reason, len(r.Region))
}

// Report is what Job.Machine could not make: Items, a slice of ReportItem in order, read
// once when Machine returns, and Text -- the kernel's own report, one line per item, or
// "nothing left uncut". Copied out; read-only.
type Report struct {
	Items []ReportItem
	Text  string
}

// String is Text.
func (r Report) String() string { return r.Text }

// Job is a machining job on a Stock: operations kept in the order they are added, written
// as one Grbl 1.1 program per run of operations sharing a tool. Mutable -- each operation
// is added in place, and a refused one leaves the job as it was. safeZ is the absolute Z
// of rapids between operations and at a program's start and end, above the stock's top;
// clearance is how far above an operation's top it enters and leaves its passes; tolerance
// fits free-form sides and offsets; name names the programs ("<name>-T<n>"); spindleDwell
// is how long every program waits after starting the spindle; resolution is the CAMotics
// project's voxel size in mm. Owns a handle: Close it, after which every call returns
// ErrClosed wrapped as "job: closed" -- what Python's Job.__del__ frees.
type Job struct {
	handle *C.CadaclysmBlacksmithJob
	_      noTiny // see noTiny
}

// NewJob is an empty job on stock, rapids at safeZ (above the stock's top). Go has no
// defaults, so every setting is spelled out: [JobDefaultClearance], [JobDefaultTolerance],
// [JobDefaultName], [JobDefaultSpindleDwell] and [JobDefaultResolution] are the library's
// own. Fails for a safeZ not above the stock's top, a name with a NUL in it, or a setting
// the job refuses.
func NewJob(stock *Stock, safeZ, clearance, tolerance float64, name string, spindleDwell, resolution float64) (*Job, error) {
	defer pin()()
	if strings.ContainsRune(name, 0) {
		return nil, &BuildError{Message: jobNulName}
	}
	sh, err := stock.h()
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_job_new(sh, C.double(safeZ))
	runtime.KeepAlive(stock)
	if raw == nil {
		return nil, failure("job_new")
	}
	j := &Job{handle: raw}
	runtime.SetFinalizer(j, (*Job).finalize)
	if !bool(C.cadaclysm_blacksmith_job_set_clearance(raw, C.double(clearance))) {
		err := failure("job_set_clearance")
		j.Close()
		return nil, err
	}
	if !bool(C.cadaclysm_blacksmith_job_set_tolerance(raw, C.double(tolerance))) {
		err := failure("job_set_tolerance")
		j.Close()
		return nil, err
	}
	if !bool(C.cadaclysm_blacksmith_job_set_spindle_dwell(raw, C.double(spindleDwell))) {
		err := failure("job_set_spindle_dwell")
		j.Close()
		return nil, err
	}
	if !bool(C.cadaclysm_blacksmith_job_set_resolution(raw, C.double(resolution))) {
		err := failure("job_set_resolution")
		j.Close()
		return nil, err
	}
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))
	if !bool(C.cadaclysm_blacksmith_job_set_name(raw, cn)) {
		err := failure("job_set_name")
		j.Close()
		return nil, err
	}
	return j, nil
}

func (j *Job) finalize() {
	if j.handle != nil {
		C.cadaclysm_blacksmith_job_free(j.handle)
		j.handle = nil
	}
}

// h is the live handle, or ErrClosed ("job: closed") after Close.
func (j *Job) h() (*C.CadaclysmBlacksmithJob, error) {
	if j == nil || j.handle == nil {
		return nil, fmt.Errorf("job: %w", ErrClosed)
	}
	return j.handle, nil
}

// Closed is whether Close has already run. A nil Job counts as closed.
func (j *Job) Closed() bool { return j == nil || j.handle == nil }

// Close gives the job back. Idempotent, and a no-op on a nil Job; the lists it wrote are
// copies and outlive it. The error return is always nil; it exists so a Job satisfies
// io.Closer.
func (j *Job) Close() error {
	if j == nil || j.handle == nil {
		return nil
	}
	h := j.handle
	j.handle = nil
	runtime.SetFinalizer(j, nil)
	C.cadaclysm_blacksmith_job_free(h)
	return nil
}

// Face is the stock's top down to z, in zigzag rows along X stepover apart and passes at
// most stepdown deep, with tool. Fails for a drill, a z above the stock's top, a stepover
// past the tool's diameter, ...
func (j *Job) Face(tool *Tool, z, stepover, stepdown float64) error {
	defer pin()()
	jh, err := j.h()
	if err != nil {
		return err
	}
	th, err := tool.h()
	if err != nil {
		return err
	}
	ok := bool(C.cadaclysm_blacksmith_job_face(jh, th, C.double(z), C.double(stepover), C.double(stepdown)))
	runtime.KeepAlive(j)
	runtime.KeepAlive(tool)
	if !ok {
		return failure("job_face")
	}
	return nil
}

// Contour is a cut along profile from top to bottom in passes at most stepdown deep, with
// tool: side "outside" the profile, "inside" it, or "on" its line; climb for climb
// milling, else conventional; open to cut the outline as an open chain (only "on" its
// line, and with no holes). Returns a *BuildError for any other side, without asking the
// library, and for what the job refuses.
func (j *Job) Contour(tool *Tool, profile *Profile, top, bottom float64, side string, stepdown float64, climb, open bool) error {
	code, ok := jobSides[side]
	if !ok {
		return &BuildError{Message: "side must be 'outside', 'inside' or 'on'"}
	}
	defer pin()()
	jh, err := j.h()
	if err != nil {
		return err
	}
	th, err := tool.h()
	if err != nil {
		return err
	}
	ph, err := profile.h()
	if err != nil {
		return err
	}
	done := bool(C.cadaclysm_blacksmith_job_contour(jh, th, ph, C.double(top), C.double(bottom), C.uint32_t(code),
		C.double(stepdown), C.bool(climb), C.bool(open)))
	runtime.KeepAlive(j)
	runtime.KeepAlive(tool)
	runtime.KeepAlive(profile)
	if !done {
		return failure("job_contour")
	}
	return nil
}

// Pocket is profile -- its holes left standing as islands -- cleared from top to bottom,
// in rings stepover apart (at most the tool's radius) and passes at most stepdown deep,
// with tool. Fails for what the job refuses; a pocket too small for the tool is refused by
// Gcode, naming the operation.
func (j *Job) Pocket(tool *Tool, profile *Profile, top, bottom, stepover, stepdown float64) error {
	defer pin()()
	jh, err := j.h()
	if err != nil {
		return err
	}
	th, err := tool.h()
	if err != nil {
		return err
	}
	ph, err := profile.h()
	if err != nil {
		return err
	}
	done := bool(C.cadaclysm_blacksmith_job_pocket(jh, th, ph, C.double(top), C.double(bottom), C.double(stepover),
		C.double(stepdown)))
	runtime.KeepAlive(j)
	runtime.KeepAlive(tool)
	runtime.KeepAlive(profile)
	if !done {
		return failure("job_pocket")
	}
	return nil
}

// Drill is a hole at each (x, y) of points, from top to bottom with tool, pecking peck
// deep at a time (retracting between pecks), or straight to depth for a nil peck. Fails
// for what the job refuses (a tool that is not a drill, no points, ...).
func (j *Job) Drill(tool *Tool, points [][2]float64, top, bottom float64, peck *float64) error {
	defer pin()()
	jh, err := j.h()
	if err != nil {
		return err
	}
	th, err := tool.h()
	if err != nil {
		return err
	}
	flat := make([]float64, 0, len(points)*2)
	for _, p := range points {
		flat = append(flat, p[0], p[1])
	}
	var xy *C.double
	if len(flat) > 0 {
		xy = doubles(&flat[0])
	}
	done := bool(C.cadaclysm_blacksmith_job_drill(jh, th, xy, C.size_t(len(points)), C.double(top), C.double(bottom),
		orNaN(peck)))
	runtime.KeepAlive(j)
	runtime.KeepAlive(tool)
	if !done {
		return failure("job_drill")
	}
	return nil
}

// Machine recognises part and appends the operations that make it: faced, contoured and
// pocketed with endMill, its holes drilled with whichever of drills fits each -- a tool
// per required diameter. A nil element of drills is the library's own "null drill <i>".
// stepover and stepdown are the kernel's own defaults for a nil pointer; skin (at least 0)
// is how far above the part's lowest point the outline stops, so the part stays attached
// to the stock -- 0 cuts through; a nil peck is none (a drill straight to depth). Returns
// a *Report of what could not be cut. Fails for what the kernel refuses (a drill as
// endMill, a null drill, ...); the job changes only on success -- a refusal leaves it
// exactly as it was.
func (j *Job) Machine(part *Solid, endMill *Tool, drills []*Tool, stepover, stepdown *float64, skin float64,
	peck *float64) (*Report, error) {
	defer pin()()
	jh, err := j.h()
	if err != nil {
		return nil, err
	}
	ph, err := part.h()
	if err != nil {
		return nil, err
	}
	eh, err := endMill.h()
	if err != nil {
		return nil, err
	}
	handles := make([]*C.CadaclysmBlacksmithTool, len(drills))
	for i, t := range drills {
		if t == nil {
			handles[i] = nil
			continue
		}
		h, err := t.h()
		if err != nil {
			return nil, err
		}
		handles[i] = h
	}
	var firstDrill **C.CadaclysmBlacksmithTool
	if len(handles) > 0 {
		firstDrill = &handles[0]
	}
	raw := C.cadaclysm_blacksmith_job_machine(jh, ph, eh, firstDrill, C.size_t(len(handles)), orNaN(stepover),
		orNaN(stepdown), C.double(skin), orNaN(peck))
	runtime.KeepAlive(j)
	runtime.KeepAlive(part)
	runtime.KeepAlive(endMill)
	for _, t := range drills {
		runtime.KeepAlive(t)
	}
	if raw == nil {
		return nil, failure("job_machine")
	}
	defer C.cadaclysm_blacksmith_report_free(raw)
	n := uint32(C.cadaclysm_blacksmith_report_count(raw))
	items := make([]ReportItem, 0, n)
	for i := uint32(0); i < n; i++ {
		var at [3]float64
		if !bool(C.cadaclysm_blacksmith_report_at(raw, C.uint32_t(i), doubles(&at[0]))) {
			return nil, failure("report_at")
		}
		region, err := profileList(C.cadaclysm_blacksmith_report_region(raw, C.uint32_t(i)), "report_region")
		if err != nil {
			return nil, err
		}
		items = append(items, ReportItem{
			Kind:   C.GoString(C.cadaclysm_blacksmith_report_kind(raw, C.uint32_t(i))),
			At:     at,
			Size:   float64(C.cadaclysm_blacksmith_report_size(raw, C.uint32_t(i))),
			Reason: C.GoString(C.cadaclysm_blacksmith_report_reason(raw, C.uint32_t(i))),
			Region: region,
		})
	}
	return &Report{Items: items, Text: C.GoString(C.cadaclysm_blacksmith_report_text(raw))}, nil
}

// Operations is every operation added to this job so far, in order -- whether added by
// Face/Contour/Pocket/Drill or by Machine.
func (j *Job) Operations() ([]Operation, error) {
	defer pin()()
	jh, err := j.h()
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_job_operations(jh)
	runtime.KeepAlive(j)
	if raw == nil {
		return nil, failure("job_operations")
	}
	defer C.cadaclysm_blacksmith_operations_free(raw)
	n := uint32(C.cadaclysm_blacksmith_operations_count(raw))
	out := make([]Operation, 0, n)
	for i := uint32(0); i < n; i++ {
		paramCount := uint32(C.cadaclysm_blacksmith_operations_param_count(raw, C.uint32_t(i)))
		params := make(map[string]*float64, paramCount)
		for k := uint32(0); k < paramCount; k++ {
			name := C.GoString(C.cadaclysm_blacksmith_operations_param_name(raw, C.uint32_t(i), C.uint32_t(k)))
			value := float64(C.cadaclysm_blacksmith_operations_param_value(raw, C.uint32_t(i), C.uint32_t(k)))
			if math.IsNaN(value) {
				params[name] = nil
			} else {
				v := value
				params[name] = &v
			}
		}
		out = append(out, Operation{
			Kind:   C.GoString(C.cadaclysm_blacksmith_operations_kind(raw, C.uint32_t(i))),
			Tool:   int(C.cadaclysm_blacksmith_operations_tool(raw, C.uint32_t(i))),
			Params: params,
		})
	}
	return out, nil
}

// programs is the files of a list the library handed back (nil: the last error), each
// copied out, the list freed.
func programs(handle *C.CadaclysmBlacksmithPrograms, what string) ([]Program, error) {
	if handle == nil {
		return nil, failure(what)
	}
	defer C.cadaclysm_blacksmith_programs_free(handle)
	n := uint32(C.cadaclysm_blacksmith_programs_count(handle))
	out := make([]Program, 0, n)
	for i := uint32(0); i < n; i++ {
		out = append(out, Program{
			Tool: int(C.cadaclysm_blacksmith_programs_tool(handle, C.uint32_t(i))),
			Name: C.GoString(C.cadaclysm_blacksmith_programs_name(handle, C.uint32_t(i))),
			Text: C.GoString(C.cadaclysm_blacksmith_programs_text(handle, C.uint32_t(i))),
		})
	}
	return out, nil
}

// Gcode is the job as Grbl 1.1 programs, one per run of consecutive operations sharing a
// tool (T1, T2, T1 gives three), each named "<name>-T<n>" (or "<name>-<k>-T<n>" for run k
// of a repeated tool); an empty slice for a job with no operations. Fails for an operation
// whose geometry the tool cannot cut (named by its index and kind).
func (j *Job) Gcode() ([]Program, error) {
	defer pin()()
	jh, err := j.h()
	if err != nil {
		return nil, err
	}
	out, err := programs(C.cadaclysm_blacksmith_job_gcode(jh), "job_gcode")
	runtime.KeepAlive(j)
	return out, err
}

// camoticsFiles is job_camotics(stem), copied out.
func (j *Job) camoticsFiles(stem string) ([]Program, error) {
	defer pin()()
	jh, err := j.h()
	if err != nil {
		return nil, err
	}
	cs := C.CString(stem)
	defer C.free(unsafe.Pointer(cs))
	raw := C.cadaclysm_blacksmith_job_camotics(jh, cs)
	runtime.KeepAlive(j)
	return programs(raw, "job_camotics")
}

// WriteCamotics is a CAMotics project at path and its files beside it, named after the
// project's file stem (out/part.camotics writes out/part-T1.nc), not the job's name: each
// program, a simulation copy of it (.sim.nc, which the project lists), and the project
// last. Creates the directory. Returns the paths written, the project last, written here
// (not by the library) byte for byte, as plain UTF-8 with no byte-order mark. Fails for a
// path with no file stem, what Gcode refuses, or a file that cannot be written.
func (j *Job) WriteCamotics(path string) ([]string, error) {
	base := filepath.Base(path)
	stem := strings.TrimSuffix(base, filepath.Ext(base))
	if stem == "" { // Python's Path(".camotics").stem is ".camotics": a name that is all extension stays whole
		stem = base
	}
	if strings.ContainsRune(stem, 0) {
		return nil, &BuildError{Message: jobNulName}
	}
	files, err := j.camoticsFiles(stem)
	if err != nil {
		return nil, err
	}
	folder := filepath.Dir(path)
	if folder != "" {
		if err := os.MkdirAll(folder, 0o755); err != nil {
			return nil, &BuildError{Message: fmt.Sprintf("job_camotics: %s: %v", path, err)}
		}
	}
	written := make([]string, 0, len(files))
	for i, f := range files {
		at := path
		if i != len(files)-1 {
			at = filepath.Join(folder, f.Name)
		}
		if err := os.WriteFile(at, []byte(f.Text), 0o644); err != nil {
			return nil, &BuildError{Message: fmt.Sprintf("job_camotics: %s: %v", path, err)}
		}
		written = append(written, at)
	}
	return written, nil
}

// ---- SubD cages -------------------------------------------------------------------------------------

// SubdEdge is one edge of a cage: its two vertex ids. A selection or a crease lists them as
// the kernel gives them, the smaller id first.
type SubdEdge [2]uint32

// SubdAxis is the axis a mirror plane is perpendicular to.
type SubdAxis int

const (
	SubdX SubdAxis = iota
	SubdY
	SubdZ
)

// SubdElements is a kind of cage element: what a selection holds, or what Pick looks for.
type SubdElements int

const (
	SubdVertices SubdElements = iota
	SubdEdges
	SubdFaces
)

func (e SubdElements) String() string {
	switch e {
	case SubdVertices:
		return "vertices"
	case SubdEdges:
		return "edges"
	case SubdFaces:
		return "faces"
	}
	return fmt.Sprintf("SubdElements(%d)", int(e))
}

// SubdSelection is some elements of a cage. Kind says which: IDs holds vertex or face ids,
// Edges holds edges (one of the two is empty).
type SubdSelection struct {
	Kind  SubdElements
	IDs   []uint32
	Edges []SubdEdge
}

// SubdOfVertices selects vertices by id.
func SubdOfVertices(ids ...uint32) SubdSelection {
	return SubdSelection{Kind: SubdVertices, IDs: ids}
}

// SubdOfEdges selects edges.
func SubdOfEdges(edges ...SubdEdge) SubdSelection {
	return SubdSelection{Kind: SubdEdges, Edges: edges}
}

// SubdOfFaces selects faces by id.
func SubdOfFaces(ids ...uint32) SubdSelection {
	return SubdSelection{Kind: SubdFaces, IDs: ids}
}

// SubdSymmetry is a mirrored half's plane: its Axis and how far from it a vertex counts as
// on it.
type SubdSymmetry struct {
	Axis      SubdAxis
	Tolerance float64
}

// SubdMesh is one level of a cage's smooth surface, copied out of the cage so it outlives
// it. Positions and Normals are limit positions and unit outward limit normals; Indices is
// three vertex ids a triangle (flat); TriangleFace is the face of the full cage each
// triangle lies on (on a mirrored half, face f of the half is f and its reflection
// f + len(faces)).
type SubdMesh struct {
	Positions    [][3]float64
	Normals      [][3]float64
	Indices      []uint32
	TriangleFace []uint32
}

// SubdReport is what Subd.ToSolid did and how close it came: Regular patches exact from
// their own net and Refined ones from a refined neighbourhood; the Catmull-Clark Steps taken
// first (1 or 2); Levels, the deepest local refinement a patch took (0 when none was
// refined); the largest Deviation from the limit surface, as a fraction of the cage's
// bounding-box diagonal; the largest tangent break G1AngleDeg across a side that is not
// creased, in degrees; and the world points they were measured at.
type SubdReport struct {
	Regular, Refined, Steps, Levels uint32
	Deviation, G1AngleDeg           float64
	DeviationAt, G1At               [3]float64
}

// SubdSolidOptions are ToSolid's limits. The zero value of each field takes the library's
// default: Tolerance 1e-4 of the cage's diagonal, G1Angle 0.1 degrees, MaxLevels 6.
type SubdSolidOptions struct {
	Tolerance, G1Angle float64
	MaxLevels          uint32
}

// Subd is a SubD control cage: a polygon mesh whose limit surface is smooth. Immutable;
// every edit returns a new cage and leaves this one as it was. Close frees the handle; the
// finalizer does so otherwise.
type Subd struct {
	handle *C.CadaclysmBlacksmithSubd
	_      noTiny // see noTiny
}

func newSubd(handle *C.CadaclysmBlacksmithSubd, what string) (*Subd, error) {
	if handle == nil {
		return nil, failure(what)
	}
	s := &Subd{handle: handle}
	runtime.SetFinalizer(s, (*Subd).finalize)
	return s, nil
}

func (s *Subd) finalize() {
	if s.handle != nil {
		C.cadaclysm_blacksmith_subd_free(s.handle)
		s.handle = nil
	}
}

// Close gives the cage back. Idempotent. A SubdMesh or any slice already read survives it.
func (s *Subd) Close() {
	s.finalize()
	runtime.SetFinalizer(s, nil)
}

// Closed is whether Close has already run. A nil Subd counts as closed.
func (s *Subd) Closed() bool { return s == nil || s.handle == nil }

func (s *Subd) h() (*C.CadaclysmBlacksmithSubd, error) {
	if s == nil || s.handle == nil {
		return nil, fmt.Errorf("subd: %w", ErrClosed)
	}
	return s.handle, nil
}

// cU32 is ids as a malloc'd C array (nil for none) and the func that frees it.
func cU32(ids []uint32) (*C.uint32_t, func()) {
	if len(ids) == 0 {
		return nil, func() {}
	}
	p := C.malloc(C.size_t(len(ids)) * C.size_t(unsafe.Sizeof(C.uint32_t(0))))
	copy(unsafe.Slice((*uint32)(p), len(ids)), ids)
	return (*C.uint32_t)(p), func() { C.free(p) }
}

// cF64 is values as a malloc'd C array (nil for none) and the func that frees it.
func cF64(values []float64) (*C.double, func()) {
	if len(values) == 0 {
		return nil, func() {}
	}
	p := C.malloc(C.size_t(len(values)) * C.size_t(unsafe.Sizeof(C.double(0))))
	copy(unsafe.Slice((*float64)(p), len(values)), values)
	return (*C.double)(p), func() { C.free(p) }
}

func flatEdges(edges []SubdEdge) []uint32 {
	flat := make([]uint32, 0, 2*len(edges))
	for _, e := range edges {
		flat = append(flat, e[0], e[1])
	}
	return flat
}

func pairEdges(flat []uint32) []SubdEdge {
	edges := make([]SubdEdge, 0, len(flat)/2)
	for i := 0; i+1 < len(flat); i += 2 {
		edges = append(edges, SubdEdge{flat[i], flat[i+1]})
	}
	return edges
}

func copyU32(p *C.uint32_t, n int) []uint32 {
	out := make([]uint32, n)
	if n > 0 && p != nil {
		copy(out, unsafe.Slice((*uint32)(unsafe.Pointer(p)), n))
	}
	return out
}

func copyPoints(p *C.double, n int) [][3]float64 {
	out := make([][3]float64, n)
	if n > 0 && p != nil {
		flat := unsafe.Slice((*float64)(unsafe.Pointer(p)), 3*n)
		for i := range out {
			out[i] = [3]float64{flat[3*i], flat[3*i+1], flat[3*i+2]}
		}
	}
	return out
}

// SubdCuboid is a box of size centred on the origin, with segments quads along each axis.
func SubdCuboid(size [3]float64, segments [3]uint32) (*Subd, error) {
	defer pin()()
	return newSubd(C.cadaclysm_blacksmith_subd_cuboid(C.double(size[0]), C.double(size[1]), C.double(size[2]),
		C.uint32_t(segments[0]), C.uint32_t(segments[1]), C.uint32_t(segments[2])), "subd_cuboid")
}

// SubdCylinder is a cylinder along +Z: one n-gon cap per end with sides sides and rings
// bands of quads between them. With creasedRims (the usual choice) the two rim loops are
// creased, so the caps stay flat.
func SubdCylinder(radius, height float64, sides, rings uint32, creasedRims bool) (*Subd, error) {
	defer pin()()
	return newSubd(C.cadaclysm_blacksmith_subd_cylinder(C.double(radius), C.double(height), C.uint32_t(sides),
		C.uint32_t(rings), C.bool(creasedRims)), "subd_cylinder")
}

// SubdSphere is a quad ball of radius, with segments quads per cube edge.
func SubdSphere(radius float64, segments uint32) (*Subd, error) {
	defer pin()()
	return newSubd(C.cadaclysm_blacksmith_subd_sphere(C.double(radius), C.uint32_t(segments)), "subd_sphere")
}

// SubdTorus is a torus around +Z: around steps about the axis at major, tube steps round
// the tube of minor.
func SubdTorus(major, minor float64, around, tube uint32) (*Subd, error) {
	defer pin()()
	return newSubd(C.cadaclysm_blacksmith_subd_torus(C.double(major), C.double(minor), C.uint32_t(around),
		C.uint32_t(tube)), "subd_torus")
}

// SubdFromParts is a cage from its parts, the lossless inverse of Positions, Faces,
// Creases, Pins and Symmetry. symmetry is nil for an ordinary cage. The new cage selects
// nothing.
func SubdFromParts(positions [][3]float64, faces [][]uint32, creases []SubdEdge, pins []uint32, symmetry *SubdSymmetry) (*Subd, error) {
	defer pin()()
	flat := make([]float64, 0, 3*len(positions))
	for _, p := range positions {
		flat = append(flat, p[0], p[1], p[2])
	}
	sizes := make([]uint32, len(faces))
	var indices []uint32
	for i, f := range faces {
		sizes[i] = uint32(len(f))
		indices = append(indices, f...)
	}
	cPos, freePos := cF64(flat)
	defer freePos()
	cSizes, freeSizes := cU32(sizes)
	defer freeSizes()
	cIdx, freeIdx := cU32(indices)
	defer freeIdx()
	flatCreases := flatEdges(creases)
	cCreases, freeCreases := cU32(flatCreases)
	defer freeCreases()
	cPins, freePins := cU32(pins)
	defer freePins()
	axis, tolerance := C.int32_t(-1), 0.0
	if symmetry != nil {
		axis, tolerance = C.int32_t(symmetry.Axis), symmetry.Tolerance
	}
	return newSubd(C.cadaclysm_blacksmith_subd_from_parts(cPos, C.uint32_t(len(positions)), cSizes, C.uint32_t(len(faces)),
		cIdx, C.uint32_t(len(indices)), cCreases, C.uint32_t(len(creases)), cPins, C.uint32_t(len(pins)), axis,
		C.double(tolerance)), "subd_from_parts")
}

// parts reads the cage's parts through read, which runs while the views are valid.
func (s *Subd) parts(read func(p *C.CadaclysmBlacksmithSubdParts)) error {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return err
	}
	var raw C.CadaclysmBlacksmithSubdParts
	ok := bool(C.cadaclysm_blacksmith_subd_parts(h, &raw))
	if !ok {
		runtime.KeepAlive(s)
		return failure("subd_parts")
	}
	read(&raw)
	runtime.KeepAlive(s)
	return nil
}

// Positions are the cage's vertices, a copy.
func (s *Subd) Positions() ([][3]float64, error) {
	var out [][3]float64
	err := s.parts(func(p *C.CadaclysmBlacksmithSubdParts) { out = copyPoints(p.positions, int(p.vertex_count)) })
	return out, err
}

// Faces are the cage's faces, each as its vertex loop, a copy.
func (s *Subd) Faces() ([][]uint32, error) {
	var out [][]uint32
	err := s.parts(func(p *C.CadaclysmBlacksmithSubdParts) {
		sizes := copyU32(p.face_sizes, int(p.face_count))
		indices := copyU32(p.face_indices, int(p.index_count))
		out = make([][]uint32, len(sizes))
		at := 0
		for i, n := range sizes {
			out[i] = indices[at : at+int(n) : at+int(n)]
			at += int(n)
		}
	})
	return out, err
}

// Creases are the creased edges, smaller id first, a copy.
func (s *Subd) Creases() ([]SubdEdge, error) {
	var out []SubdEdge
	err := s.parts(func(p *C.CadaclysmBlacksmithSubdParts) { out = pairEdges(copyU32(p.creases, 2*int(p.crease_count))) })
	return out, err
}

// Pins are the pinned vertices: they refine as corners and stay put. A copy.
func (s *Subd) Pins() ([]uint32, error) {
	var out []uint32
	err := s.parts(func(p *C.CadaclysmBlacksmithSubdParts) { out = copyU32(p.pins, int(p.pin_count)) })
	return out, err
}

// Symmetry is nil for an ordinary cage; for a mirrored half, its plane.
func (s *Subd) Symmetry() (*SubdSymmetry, error) {
	var out *SubdSymmetry
	err := s.parts(func(p *C.CadaclysmBlacksmithSubdParts) {
		if p.symmetry_axis >= 0 {
			out = &SubdSymmetry{Axis: SubdAxis(p.symmetry_axis), Tolerance: float64(p.symmetry_tolerance)}
		}
	})
	return out, err
}

// Selection is what the edit that made this cage touched; nil for a cage no edit selected
// (a primitive, SubdFromParts, the mirror calls).
func (s *Subd) Selection() (*SubdSelection, error) {
	var out *SubdSelection
	err := s.parts(func(p *C.CadaclysmBlacksmithSubdParts) {
		if p.selection_kind > 2 {
			return
		}
		n := int(p.selection_count)
		if p.selection_kind == C.uint32_t(SubdEdges) {
			out = &SubdSelection{Kind: SubdEdges, Edges: pairEdges(copyU32(p.selection, 2*n))}
			return
		}
		out = &SubdSelection{Kind: SubdElements(p.selection_kind), IDs: copyU32(p.selection, n)}
	})
	return out, err
}

// edit makes a new cage from a call on this one, which reports the new handle.
func (s *Subd) edit(what string, call func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd) (*Subd, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	out, err := newSubd(call(h), what)
	runtime.KeepAlive(s)
	return out, err
}

// Transform is a new cage with the selected elements moved by matrix: sixteen numbers,
// column-major (a rotation about a point is baked in by the caller). The new cage selects
// the same elements.
func (s *Subd) Transform(selection SubdSelection, matrix []float64) (*Subd, error) {
	if len(matrix) != 16 {
		return nil, &BuildError{Message: fmt.Sprintf("transform: matrix must be 16 numbers, column-major, not %d", len(matrix))}
	}
	if selection.Kind < SubdVertices || selection.Kind > SubdFaces {
		return nil, &BuildError{Message: fmt.Sprintf("transform: kind must be vertices, edges or faces, not %d", int(selection.Kind))}
	}
	ids, count := selection.IDs, len(selection.IDs)
	if selection.Kind == SubdEdges {
		ids, count = flatEdges(selection.Edges), len(selection.Edges)
	}
	cIDs, freeIDs := cU32(ids)
	defer freeIDs()
	cMatrix, freeMatrix := cF64(matrix)
	defer freeMatrix()
	return s.edit("subd_transform", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_transform(h, C.uint32_t(selection.Kind), cIDs, C.uint32_t(count), cMatrix)
	})
}

// Crease is a new cage with edges creased, or un-creased when on is false; it selects them.
func (s *Subd) Crease(edges []SubdEdge, on bool) (*Subd, error) {
	cEdges, freeEdges := cU32(flatEdges(edges))
	defer freeEdges()
	return s.edit("subd_set_crease", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_set_crease(h, cEdges, C.uint32_t(len(edges)), C.bool(on))
	})
}

// Pin is a new cage with vertices pinned (they refine as corners and stay put), or released
// when on is false; it selects them.
func (s *Subd) Pin(vertices []uint32, on bool) (*Subd, error) {
	cIDs, freeIDs := cU32(vertices)
	defer freeIDs()
	return s.edit("subd_set_pin", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_set_pin(h, cIDs, C.uint32_t(len(vertices)), C.bool(on))
	})
}

// Extrude is a new cage with faces pushed out by distance along each connected region's
// average normal, a quad wall on each boundary edge; the new cage selects them.
func (s *Subd) Extrude(faces []uint32, distance float64) (*Subd, error) {
	cIDs, freeIDs := cU32(faces)
	defer freeIDs()
	return s.edit("subd_extrude", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_extrude(h, cIDs, C.uint32_t(len(faces)), C.double(distance))
	})
}

// Inset is a new cage with faces shrunk by amount, in (0, 1), within their surface and a
// ring of quads round each region (each face, with individual); it selects the inner faces.
func (s *Subd) Inset(faces []uint32, amount float64, individual bool) (*Subd, error) {
	cIDs, freeIDs := cU32(faces)
	defer freeIDs()
	return s.edit("subd_inset", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_inset(h, cIDs, C.uint32_t(len(faces)), C.double(amount), C.bool(individual))
	})
}

// InsertLoop is a new cage with a loop of edges cut across the ring of quads through edge,
// at a + at*(b-a) with at in (0, 1); it selects the new loop. 0.5 is the middle.
func (s *Subd) InsertLoop(edge SubdEdge, at float64) (*Subd, error) {
	return s.edit("subd_insert_loop", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_insert_loop(h, C.uint32_t(edge[0]), C.uint32_t(edge[1]), C.double(at))
	})
}

// EdgeLoop is the loop of edges through edge, straight across each valence-four vertex, the
// picked edge first, each smaller id first; empty when edge is not an edge of the cage.
func (s *Subd) EdgeLoop(edge SubdEdge) ([]SubdEdge, error) {
	looped, err := s.edit("subd_edge_loop", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_edge_loop(h, C.uint32_t(edge[0]), C.uint32_t(edge[1]))
	})
	if err != nil {
		return nil, err
	}
	defer looped.Close()
	selection, err := looped.Selection()
	if err != nil {
		return nil, err
	}
	if selection == nil {
		return []SubdEdge{}, nil
	}
	return selection.Edges, nil
}

// MirrorOn is the positive half of the cage across the plane perpendicular to axis, as a
// mirrored cage: every later edit keeps it symmetric.
func (s *Subd) MirrorOn(axis SubdAxis) (*Subd, error) {
	return s.edit("subd_mirror_on", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_mirror_on(h, C.uint32_t(axis))
	})
}

// MirrorOff is the mirror baked: the whole cage as an ordinary one.
func (s *Subd) MirrorOff() (*Subd, error) {
	return s.edit("subd_mirror_off", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_mirror_off(h)
	})
}

// Full is the whole cage of a mirrored half -- the half's vertices first, then the
// reflections of those off the plane -- or a copy of an ordinary cage.
func (s *Subd) Full() (*Subd, error) {
	return s.edit("subd_full", func(h *C.CadaclysmBlacksmithSubd) *C.CadaclysmBlacksmithSubd {
		return C.cadaclysm_blacksmith_subd_full(h)
	})
}

// SmoothMesh is the smooth surface refined levels times (1 to 6; 3 is the usual choice), as
// a SubdMesh of copies.
func (s *Subd) SmoothMesh(levels uint32) (*SubdMesh, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	var raw C.CadaclysmBlacksmithSubdMesh
	ok := bool(C.cadaclysm_blacksmith_subd_smooth_mesh(h, C.uint32_t(levels), &raw))
	if !ok {
		runtime.KeepAlive(s)
		return nil, failure("subd_smooth_mesh")
	}
	n, m := int(raw.vertex_count), int(raw.index_count)/3
	mesh := &SubdMesh{
		Positions:    copyPoints(raw.positions, n),
		Normals:      copyPoints(raw.normals, n),
		Indices:      copyU32(raw.indices, int(raw.index_count)),
		TriangleFace: copyU32(raw.triangle_face, m),
	}
	runtime.KeepAlive(s)
	return mesh, nil
}

// Pick is the cage element of kind under point, a point on or near the smooth surface: a
// selection of one vertex, edge or face. nil, nil when nothing is within 0.05 of the cage's
// diagonal -- not an error.
func (s *Subd) Pick(point [3]float64, kind SubdElements) (*SubdSelection, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	if kind < SubdVertices || kind > SubdFaces {
		return nil, &BuildError{Message: fmt.Sprintf("pick: kind must be vertices, edges or faces, not %d", int(kind))}
	}
	cPoint, freePoint := cF64(point[:])
	defer freePoint()
	out := (*C.uint32_t)(C.malloc(2 * C.size_t(unsafe.Sizeof(C.uint32_t(0)))))
	defer C.free(unsafe.Pointer(out))
	ok := bool(C.cadaclysm_blacksmith_subd_pick(h, cPoint, C.uint32_t(kind), out))
	runtime.KeepAlive(s)
	if !ok {
		if lastError() == "" {
			return nil, nil
		}
		return nil, failure("subd_pick")
	}
	got := copyU32(out, 2)
	if kind == SubdEdges {
		return &SubdSelection{Kind: SubdEdges, Edges: []SubdEdge{{got[0], got[1]}}}, nil
	}
	return &SubdSelection{Kind: kind, IDs: []uint32{got[0]}}, nil
}

// ToSolid is the cage as an exact solid, one NURBS face per patch, that every solid call
// takes, and a SubdReport of what the conversion did. Options' zero fields take the
// defaults; a cage that cannot be held within the limits is refused with the figures it
// measured.
func (s *Subd) ToSolid(options SubdSolidOptions) (*Solid, SubdReport, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, SubdReport{}, err
	}
	var raw C.CadaclysmBlacksmithSubdReport
	handle := C.cadaclysm_blacksmith_subd_to_solid(h, C.double(options.Tolerance), C.double(options.G1Angle),
		C.uint32_t(options.MaxLevels), &raw)
	runtime.KeepAlive(s)
	solid, err := newSolid(handle, "subd_to_solid")
	if err != nil {
		return nil, SubdReport{}, err
	}
	report := SubdReport{
		Regular: uint32(raw.regular), Refined: uint32(raw.refined), Steps: uint32(raw.steps), Levels: uint32(raw.levels),
		Deviation: float64(raw.deviation), G1AngleDeg: float64(raw.g1_angle_deg),
	}
	for i := 0; i < 3; i++ {
		report.DeviationAt[i] = float64(raw.deviation_at[i])
		report.G1At[i] = float64(raw.g1_at[i])
	}
	return solid, report, nil
}
