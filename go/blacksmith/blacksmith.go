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

// Spline is a spline of degree through the control polygon points (weights one per point,
// or nil) — Python's Profile.spline. Open, it starts on the first point and ends on the
// last, an open chain; closed, it is periodic, smooth through its own start, a closed
// profile. The degree is lowered to fit the points.
func Spline(points [][2]float64, degree int, weights []float64, closed bool) (*Profile, error) {
	defer pin()()
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
	if len(weights) > 0 {
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

// Edge is one edge of a solid, as plain data: its index (what Fillet takes), the curve
// kind, the faces meeting on it, and its segments' ends. Copied out of the solid, so safe
// to keep.
type Edge struct {
	Index int
	// Kind is "line", "circle", "ellipse", "nurbs" or "other".
	Kind string
	// Faces is the faces that meet on it, in the solid's face order.
	Faces []int
	// Segments is the two ends of each trim piece of the edge.
	Segments [][2][3]float64
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
// Solid.pipe, Fusion's Pipe: a rod, or with a positive thickness a tube whose walls are
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
		out = append(out, Edge{Index: int(i), Kind: C.GoString(raw.kind), Faces: faces, Segments: segments})
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
// the way Fusion and Rhino extrude a face — Python's Solid.push_pull: the prism over it
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

// Split is this solid split by tool into bodies — Python's Solid.split, Fusion's Split
// Body: a closed tool gives the parts outside it, then the parts inside; a flat sheet
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
// bands joined to that face — made again at radius — Python's Solid.refillet, Fusion's
// press-pull on a fillet face: taken back to the sharp edges it replaced, and those
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
// sharp again — Python's Solid.unfillet, Fusion's delete of a fillet face.
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
