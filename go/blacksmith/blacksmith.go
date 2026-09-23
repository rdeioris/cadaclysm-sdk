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
// [Profile], [Path], [SweepPath] and [Solid] own a C handle: Close them, or let the
// finalizer free them as Python's __del__ does. Close is idempotent, and a call on a closed
// object returns [ErrClosed] wrapped with what it was. [Workplane], [Selector], [Slant],
// [Edge] and [Axis] are plain values. Join, Cut, Common and SplitSheet return a new
// solid and leave both operands open; WithHole, FromSolid and the sweeps borrow.
//
// # The library's error slot is thread-local
//
// cadaclysm_blacksmith_last_error reads a thread-local: the reason the failing call left
// on the OS thread it ran on. A goroutine may move between OS threads between one call
// and the next, so every call that can fail and the read of its reason are made with the
// goroutine locked to its thread ([runtime.LockOSThread], through pin below) — a call
// site that reads lastError outside that lock may read another thread's reason, or none.
//
// # Every array borrows from its solid
//
// Solid.Mesh and Solid.EdgePolylines hand back slices built with unsafe.Slice over the
// library's own cache rather than copies, as the reader's Mesh does. Two things
// invalidate a view: closing the solid, which frees the handle; and meshing the same
// solid again (through Mesh, EdgePolylines or BoundsAt) at a *different* tolerance,
// which replaces the cache the earlier views point into — and going back to the first
// tolerance does not bring the old memory back. Python reads freed memory in either
// case; here a view remembers which filling of the cache it was cut from, and its
// accessors return [ErrStaleView] instead. Call Copy on any view that must outlive
// either. Strings are copied on the way out and are always safe.
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
#include "cadaclysm_blacksmith.h"
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
	"strconv"
	"strings"
	"unsafe"

	"github.com/rdeioris/cadaclysm-sdk/go/cadaclysm"
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

// ErrStaleView is what a Mesh or Polylines accessor returns once the solid's tessellation
// cache has been replaced underneath it — see the package doc. Test for it with errors.Is.
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
	// Stroke is the pen colour, "#rrggbb". Default black.
	Stroke string
	// StrokeWidth is the pen's width, page units. Default 1.
	StrokeWidth float64
	// Background is "#rrggbb", or nil (the default) for no <rect> behind the drawing.
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
}

// NewSvgOptions is the defaults cadaclysm_blacksmith_svg_options_init fills: the
// viewer's iso, orthographic, a 1000-square page, black edges one unit wide on nothing.
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
	}
}

// parseSvgColour is a colour as the ABI's packed 0xRRGGBB: "#rrggbb", the leading '#'
// optional.
func parseSvgColour(colour string) (uint32, error) {
	hex := strings.TrimPrefix(colour, "#")
	if len(hex) != 6 {
		return 0, &BuildError{Message: fmt.Sprintf("colour %s: expected '#rrggbb'", colour)}
	}
	v, err := strconv.ParseUint(hex, 16, 32)
	if err != nil {
		return 0, &BuildError{Message: fmt.Sprintf("colour %s: expected '#rrggbb'", colour)}
	}
	return uint32(v), nil
}

// buildSvgOptions packs opts (nil for NewSvgOptions()'s defaults) into a
// C.CadaclysmBlacksmithSvgOptions: View fills Azimuth/Elevation unless they are set
// directly, Up defaults to "z" (a solid carries no convention of its own), colours are
// "#rrggbb" — as the reader package's own buildSvgOptions, but with no scene to default
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

// ---- profiles -------------------------------------------------------------------------

// Profile is a closed outline with holes, in its own x/y. Immutable; every method returns
// a new one. Owns a handle: Close it once done, or let the finalizer.
type Profile struct{ handle *C.CadaclysmBlacksmithProfile }

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

// ---- meshes and polylines -----------------------------------------------------------------------

// MeshData is a solid's triangles copied into memory of the caller's own — what Mesh.Copy
// returns.
type MeshData struct {
	Positions []float32
	Normals   []float32
	Indices   []uint32
}

// Mesh is a solid's triangles: views over the library's own cache at one tolerance,
// valid until the solid is closed or meshed again at another tolerance (see the package
// doc). Positions and Normals are (VertexCount * 3) float32, Indices is (IndexCount)
// uint32, three to a triangle. Each accessor checks the view is still the cache's
// current filling and returns ErrStaleView otherwise.
type Mesh struct {
	solid      *Solid
	generation int
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
func (m *Mesh) Positions() ([]float32, error) {
	if err := m.solid.checkCache(m.generation); err != nil {
		return nil, err
	}
	return m.positions, nil
}

// Normals is the vertex normals, three floats each, unit, outward.
func (m *Mesh) Normals() ([]float32, error) {
	if err := m.solid.checkCache(m.generation); err != nil {
		return nil, err
	}
	return m.normals, nil
}

// Indices is the triangles, three indices into Positions each.
func (m *Mesh) Indices() ([]uint32, error) {
	if err := m.solid.checkCache(m.generation); err != nil {
		return nil, err
	}
	return m.indices, nil
}

// Copy is the same triangles in memory of our own, safe to outlive the solid.
func (m *Mesh) Copy() (MeshData, error) {
	if err := m.solid.checkCache(m.generation); err != nil {
		return MeshData{}, err
	}
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
// unnarrowed -- shares Mesh's cache, under the same lifetime rule (see the package doc).
// The library replaces the cache whole whenever it is asked for another tolerance, so a
// Mesh64 view and a Mesh view of the same filling share one generation: meshing again at
// a different tolerance through either Solid.Mesh or Solid.Mesh64 stales views from both.
type Mesh64 struct {
	solid      *Solid
	generation int
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
func (m *Mesh64) Positions() ([]float64, error) {
	if err := m.solid.checkCache(m.generation); err != nil {
		return nil, err
	}
	return m.positions, nil
}

// Normals is the vertex normals, three doubles each, unit, outward.
func (m *Mesh64) Normals() ([]float64, error) {
	if err := m.solid.checkCache(m.generation); err != nil {
		return nil, err
	}
	return m.normals, nil
}

// Indices is the triangles, three indices into Positions each -- the very pointer Mesh's
// own Indices views for the same filling, not a copy.
func (m *Mesh64) Indices() ([]uint32, error) {
	if err := m.solid.checkCache(m.generation); err != nil {
		return nil, err
	}
	return m.indices, nil
}

// Copy is the same triangles in memory of our own, safe to outlive the solid.
func (m *Mesh64) Copy() (MeshData64, error) {
	if err := m.solid.checkCache(m.generation); err != nil {
		return MeshData64{}, err
	}
	return MeshData64{
		Positions: append([]float64(nil), m.positions...),
		Normals:   append([]float64(nil), m.normals...),
		Indices:   append([]uint32(nil), m.indices...),
	}, nil
}

// Polylines is a solid's feature edges as polylines: views over the library's own cache
// at one tolerance, under the same lifetime rule as Mesh. Polyline i is
// Points[Offsets[i]*3 : Offsets[i+1]*3], three floats a point — what Python's list holds
// at i, reached here through Polyline(i).
type Polylines struct {
	solid      *Solid
	generation int
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
func (p *Polylines) Points() ([]float32, error) {
	if err := p.solid.checkCache(p.generation); err != nil {
		return nil, err
	}
	return p.points, nil
}

// Offsets is (PolylineCount + 1) point offsets; the last equals PointCount.
func (p *Polylines) Offsets() ([]uint32, error) {
	if err := p.solid.checkCache(p.generation); err != nil {
		return nil, err
	}
	return p.offsets, nil
}

// Polyline is polyline i's points, three floats each.
func (p *Polylines) Polyline(i int) ([]float32, error) {
	if err := p.solid.checkCache(p.generation); err != nil {
		return nil, err
	}
	if i < 0 || i+1 >= len(p.offsets) {
		return nil, &BuildError{Message: fmt.Sprintf("polyline %d of %d", i, p.PolylineCount())}
	}
	return p.points[int(p.offsets[i])*3 : int(p.offsets[i+1])*3], nil
}

// Copy is every polyline in memory of our own, one (k * 3) slice each, safe to outlive
// the solid.
func (p *Polylines) Copy() ([][]float32, error) {
	if err := p.solid.checkCache(p.generation); err != nil {
		return nil, err
	}
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

// ---- solids ----------------------------------------------------------------------------------------

// Solid is an exact B-rep solid (or open sheet). Immutable; every operation returns a new
// one. Close it to free it; the finalizer does so otherwise.
type Solid struct {
	handle *C.CadaclysmBlacksmithSolid

	// The tolerance the library's tessellation cache was last filled at (meaningful only
	// once cacheFilled), and how many times it has been filled. The library replaces the
	// cache whole whenever it is asked for a tolerance other than the one it holds, so a
	// view is tied to a *filling*, not a tolerance: after 0.05, 0.5, 0.05 the first
	// view's memory is gone even though the cache is back at its tolerance. A view checks
	// the generation it was cut from, never the tolerance.
	cacheFilled     bool
	cacheTolerance  float64
	cacheGeneration int
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
// before the build's error is checked cannot panic. Every Mesh and Polylines still held
// returns ErrClosed on its next read. The error return is always nil; it exists so a
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

// filled records that a call just tessellated at tolerance: a new filling if it differs
// from the one the cache held. Returns the generation a view made now belongs to.
func (s *Solid) filled(tolerance float64) int {
	if !s.cacheFilled || s.cacheTolerance != tolerance {
		s.cacheFilled = true
		s.cacheTolerance = tolerance
		s.cacheGeneration++
	}
	return s.cacheGeneration
}

// checkCache is whether a view cut from filling generation may still read: only while
// that filling is the one the solid holds, and never once the solid is closed.
func (s *Solid) checkCache(generation int) error {
	if _, err := s.h(); err != nil {
		return err
	}
	if s.cacheGeneration != generation {
		return fmt.Errorf("%w: the solid's tessellation has been replaced since (now at tolerance %g)",
			ErrStaleView, s.cacheTolerance)
	}
	return nil
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

// Bounds is BoundsAt(DefaultTolerance) — Python's bounds property.
func (s *Solid) Bounds() (cadaclysm.Bounds, error) { return s.BoundsAt(DefaultTolerance) }

// BoundsAt is the solid's axis-aligned bounds, over the positions of its cached
// tessellation at tolerance (the same cache Mesh fills and reuses, so a second call at
// the same tolerance is free — and a call at another tolerance replaces it, staling
// every view).
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
	s.filled(tolerance)
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
	s.filled(tolerance)
	return cadaclysm.Bounds{Min: lo, Max: hi}, nil
}

// LeakedEdges is how many edges of the mesh at tolerance (Python's default is
// DefaultTolerance) are bound by anything other than exactly two triangles — zero for a
// closed solid. A seam two solids share along a line (four triangles, two pairs) does
// *not* count here; a genuine hole or a fold does.
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
// into the solid's cache. See the package doc for what invalidates them.
func (s *Solid) Mesh(tolerance float64) (*Mesh, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_mesh(h, C.double(tolerance))
	runtime.KeepAlive(s)
	if raw.positions == nil {
		return nil, failure("mesh")
	}
	m := &Mesh{solid: s, generation: s.filled(tolerance), Tolerance: tolerance}
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

// Mesh64 is Mesh in double, from the same cache -- see [Mesh64].
func (s *Solid) Mesh64(tolerance float64) (*Mesh64, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_mesh64(h, C.double(tolerance))
	runtime.KeepAlive(s)
	if raw.positions == nil {
		return nil, failure("mesh64")
	}
	m := &Mesh64{solid: s, generation: s.filled(tolerance), Tolerance: tolerance}
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

// EdgePolylines is the feature edges at tolerance as polylines, views into the same cache
// as Mesh, under the same rule.
func (s *Solid) EdgePolylines(tolerance float64) (*Polylines, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_edge_polylines(h, C.double(tolerance))
	runtime.KeepAlive(s)
	if raw.offsets == nil {
		return nil, failure("edge_polylines")
	}
	p := &Polylines{solid: s, generation: s.filled(tolerance), Tolerance: tolerance}
	if raw.point_count > 0 && raw.points != nil {
		p.points = unsafe.Slice((*float32)(unsafe.Pointer(raw.points)), int(raw.point_count)*3)
	}
	p.offsets = unsafe.Slice((*uint32)(unsafe.Pointer(raw.offsets)), int(raw.polyline_count)+1)
	return p, nil
}

// meshFaceTriangles is the kernel's mesh_face_triangles, kept for the viewer
// follow-up: how many triangles each face meshed to at tolerance, in face order,
// summing to Mesh(tolerance)'s triangle count. Copied out of the solid's cache.
func meshFaceTriangles(s *Solid, tolerance float64) ([]uint32, error) {
	defer pin()()
	h, err := s.h()
	if err != nil {
		return nil, err
	}
	raw := C.cadaclysm_blacksmith_mesh_face_triangles(h, C.double(tolerance))
	if raw.counts == nil {
		runtime.KeepAlive(s)
		return nil, failure("mesh_face_triangles")
	}
	counts := append([]uint32(nil), unsafe.Slice((*uint32)(unsafe.Pointer(raw.counts)), int(raw.face_count))...)
	runtime.KeepAlive(s)
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

// -- colour

// Coloured is this solid coloured (r, g, b), each in 0..1 — Python's coloured with no face.
// What is made from a coloured solid inherits: a move keeps every colour; a boolean,
// fillet, chamfer or shell gives each face the colour of the face it lies on (a cut's bore
// the tool's), and a new face the solid's.
func (s *Solid) Coloured(r, g, b float64) (*Solid, error) {
	return s.coloured(C.CADACLYSM_BLACKSMITH_NONE, r, g, b)
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
