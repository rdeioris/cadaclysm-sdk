// The cadaclysm C ABI, and nothing else: this file is the whole binding.
//
// It uses the published header and the shared library, the way any Go program would.
// No generated bindings, no Rust, no build system — if this draws your part, so will
// your engine.
package cadaclysm

// The first -I/-L pair is the SDK checkout's own layout: go/cadaclysm/ sits beside
// include/ and lib/ at the checkout root, two levels up from this file. The second is
// this repository's: crates/cadaclysm-capi/examples/go/cadaclysm/ under the crate's own
// include/ (three levels up) and the workspace's target/release (five levels up to the
// repo root, then down into target/release).
//
// Windows links straight against the DLL by name (-l:cadaclysm_capi.dll, binutils' colon
// form for an exact filename) rather than through -lcadaclysm_capi: a `cargo build`
// targeting *-pc-windows-gnu drops a static cadaclysm_capi.lib next to the DLL's own
// import library, cadaclysm_capi.dll.lib, and plain -lcadaclysm_capi's search order
// picks the static one — pulling in Rust's std built for MSVC's exception ABI, which
// this MinGW gcc cannot link (undefined __CxxFrameHandler3, __imp_bind, and the rest of
// std::net's Winsock imports). Elsewhere -lcadaclysm_capi resolves libcadaclysm_capi.so
// or .dylib with no such name collision, so that line names no file itself.
//
// There is no CADACLYSM_LIBRARY equivalent for Go: cgo cannot read an environment
// variable while linking. Point CGO_LDFLAGS=-L<dir> at build time, and at run time rely
// on the platform loader's own search — PATH on Windows, LD_LIBRARY_PATH on Linux,
// DYLD_LIBRARY_PATH on macOS.

/*
#cgo CFLAGS: -I${SRCDIR}/../../include -I${SRCDIR}/../../../include
#cgo windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -l:cadaclysm_capi.dll
#cgo !windows LDFLAGS: -L${SRCDIR}/../../lib -L${SRCDIR}/../../../../../target/release -lcadaclysm_capi
#include <stdlib.h>
#include "cadaclysm.h"
*/
import "C"

import (
	"fmt"
	"strconv"
	"strings"
	"unsafe"
)

// Scene is an open document. Close it when done; every slice this hands back borrows
// from it and must not outlive it.
type Scene struct{ p *C.CadaclysmScene }

// Convention is the coordinate space to open a file into.
//
// The library converts on the way out, so nothing here rotates anything: a caller names
// the space it draws in and reads geometry already in it. The values come from the header
// rather than being written out again, so this cannot drift from it — which is the whole
// reason this binding is cgo over the published header and not a hand-declared copy.
type Convention uint32

const (
	// Native keeps the file's own axes and its own units.
	Native = Convention(C.CADACLYSM_NATIVE)
	// Unreal is Z up, left-handed, centimetres.
	Unreal = Convention(C.CADACLYSM_UNREAL)
	// Unity is Y up, left-handed, metres.
	Unity = Convention(C.CADACLYSM_UNITY)
	// YUp is Y up, right-handed, metres — glTF, three.js, Bevy, wgpu.
	YUp = Convention(C.CADACLYSM_Y_UP)
	// Blender is Z up, right-handed, metres: Native's axes at Blender's unit, which is
	// the only difference between the two.
	Blender = Convention(C.CADACLYSM_BLENDER)

	// FileUnits ORs into a convention to keep the preset's axes but the file's own
	// units. Bit 8, so it cannot collide with a sixth preset.
	//
	// The header no longer names this bit: CADACLYSM_FILE_UNITS and CADACLYSM_UV_WORLD
	// moved to fields of CadaclysmOpenOptions (cadaclysm.h's own comment on
	// CadaclysmConvention still mentions the old names, but the enum itself does not, and
	// cadaclysm_open now refuses either bit — see the Python binding's FILE_UNITS/UV_WORLD,
	// which carry the same two literals for the same reason). Kept as a plain literal
	// rather than removed so ParseConvention's "+file-units" parsing still compiles and
	// reports its existing "no convention flag" error the same way; wiring it through
	// CadaclysmOpenOptions instead is unrelated to this binding's move and out of scope
	// here.
	FileUnits = Convention(0x100)

	// UVWorld ORs into a convention to ask for texture coordinates at world scale, which
	// is what fills the `uvs` return of Mesh.
	//
	// Off by default in the library and unused by this viewer, which draws no textures —
	// it is here because the mesh has the field and a caller reaching for it needs the
	// bit that fills it. What it turns on is *generating* coordinates from a surface's
	// own parameters; a format that stores them is not gated by it. See FileUnits above:
	// same header drift, same literal-not-symbol fix.
	UVWorld = Convention(0x200)
)

// ParseConvention reads a name a user typed, as `-convention` takes it: "unreal", or
// "unreal+file-units" to keep the file's own units under the preset's axes.
//
// Reports failure rather than falling back to Native: an unrecognised name silently read
// as the file's own space is the one outcome that looks like success and draws the wrong
// thing.
func ParseConvention(text string) (Convention, error) {
	parts := strings.Split(strings.ToLower(strings.TrimSpace(text)), "+")
	presets := map[string]Convention{
		"native": Native, "unreal": Unreal, "unity": Unity, "y-up": YUp, "blender": Blender,
	}
	packed, ok := presets[parts[0]]
	if !ok {
		return 0, fmt.Errorf("no convention called %q: native, unreal, unity, y-up or blender",
			parts[0])
	}
	for _, flag := range parts[1:] {
		if flag != "file-units" {
			return 0, fmt.Errorf("no convention flag called %q: file-units", flag)
		}
		packed |= FileUnits
	}
	return packed, nil
}

// LastError is what the library said about the most recent failure.
func LastError() string { return C.GoString(C.cadaclysm_last_error()) }

// Version of the library actually loaded, which is the one worth reporting.
func Version() string { return C.GoString(C.cadaclysm_version()) }

// LicenseSet loads a license: the certificate text, or the path of a file holding it.
// Without it the library looks in CADACLYSM_LICENSE, then for cadaclysm.lic beside the
// executable and in the working directory. False, with the reason in LastError, when
// the text does not verify; the previous license stays.
func LicenseSet(textOrPath string) bool {
	c := C.CString(textOrPath)
	defer C.free(unsafe.Pointer(c))
	return bool(C.cadaclysm_license_set(c))
}

// LicenseInfo is one line about the license in use; ok is false (see LastError) when none resolves.
func LicenseInfo() (info string, ok bool) {
	p := C.cadaclysm_license_info()
	if p == nil {
		return "", false
	}
	return C.GoString(p), true
}

// BuildDate is when the loaded library was built, YYYY-MM-DD.
func BuildDate() string { return C.GoString(C.cadaclysm_build_date()) }

// Open a file. `schema` is the EXPRESS schema STEP and IFC need and every other
// format ignores; pass "" for none.
//
// `convention` is the space to read the file into. The library does the converting, so
// every slice this scene hands back is already in it and there is nothing left for the
// caller to rotate or scale. An unrecognised value is refused rather than read as Native,
// so it comes back false with the reason at LastError.
//
// cadaclysm_open takes a CadaclysmOpenOptions now, not a bare schema/convention pair —
// see FileUnits above for why FileUnits and UVWorld are unpacked into it here rather
// than passed straight through, the same way the Python binding's `_options` does it.
func Open(path, schema string, convention Convention) (*Scene, bool) {
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))

	var opts C.CadaclysmOpenOptions
	C.cadaclysm_open_options_init(&opts)
	packed := uint32(convention)
	opts.convention = C.uint32_t(packed &^ (uint32(FileUnits) | uint32(UVWorld)))
	opts.file_units = C.bool(packed&uint32(FileUnits) != 0)
	if packed&uint32(UVWorld) != 0 {
		opts.uvs = C.uint32_t(C.CADACLYSM_UV_WORLD_SCALE)
	}

	var cs *C.char
	var schemas [1]*C.char
	if schema != "" {
		cs = C.CString(schema)
		defer C.free(unsafe.Pointer(cs))
		schemas[0] = cs
		opts.schemas = (**C.char)(unsafe.Pointer(&schemas[0]))
		opts.schema_count = 1
	}

	p := C.cadaclysm_open(cp, &opts)
	if p == nil {
		return nil, false
	}
	return &Scene{p}, true
}

func (s *Scene) Close()                 { C.cadaclysm_close(s.p) }
func (s *Scene) PartCount() uint32      { return uint32(C.cadaclysm_node_count(s.p)) }
func (s *Scene) Schema() string         { return C.GoString(C.cadaclysm_schema(s.p)) }
func (s *Scene) MetresPerUnit() float64 { return float64(C.cadaclysm_metres_per_unit(s.p)) }
func (s *Scene) CanMesh(part uint32) bool {
	return bool(C.cadaclysm_node_can_mesh(s.p, C.uint32_t(part)))
}

// RealizeAll tessellates every part up front, across threads, and returns how many it
// built.
//
// Asking part by part instead meshes them one at a time on one core, because the reader
// is lazy and each mesh call realizes only the part it is asked about. On a large STEP
// file that is the difference between a demo and a wait.
func (s *Scene) RealizeAll() uint32 { return uint32(C.cadaclysm_realize_all(s.p)) }

// Bounds of the whole scene, in world units.
func (s *Scene) Bounds() (min, max [3]float64) {
	b := C.cadaclysm_bounds(s.p)
	for i := 0; i < 3; i++ {
		min[i] = float64(b.min[i])
		max[i] = float64(b.max[i])
	}
	return
}

// Transform places a part's own frame in the world, column-major as OpenGL writes it.
func (s *Scene) Transform(part uint32) (m [16]float64) {
	C.cadaclysm_node_transform(s.p, C.uint32_t(part), (*C.double)(unsafe.Pointer(&m[0])))
	return
}

// Color the file gave a part, and whether it gave one at all. A part with no colour is
// the caller's to decide about — see UNSTYLED in main.go.
func (s *Scene) Color(part uint32) ([3]float32, bool) {
	var rgba [4]C.float
	ok := bool(C.cadaclysm_node_color(s.p, C.uint32_t(part), &rgba[0]))
	return [3]float32{float32(rgba[0]), float32(rgba[1]), float32(rgba[2])}, ok
}

// Mesh borrows a part's triangles, in the part's own frame.
//
// `uv` is two floats a vertex where `pos` and `nrm` are three, and nil for a part whose
// reader produced none — which is most of them unless the scene was opened with UVWorld.
func (s *Scene) Mesh(part uint32) (pos, nrm, uv []float32, idx []uint32) {
	m := C.cadaclysm_node_mesh(s.p, C.uint32_t(part))
	if m.index_count == 0 || m.positions == nil {
		return nil, nil, nil, nil
	}
	n := int(m.vertex_count) * 3
	pos = unsafe.Slice((*float32)(unsafe.Pointer(m.positions)), n)
	if m.normals != nil {
		nrm = unsafe.Slice((*float32)(unsafe.Pointer(m.normals)), n)
	}
	if m.uvs != nil {
		uv = unsafe.Slice((*float32)(unsafe.Pointer(m.uvs)), int(m.vertex_count)*2)
	}
	idx = unsafe.Slice((*uint32)(unsafe.Pointer(m.indices)), int(m.index_count))
	return
}

// Polylines borrows a part's feature edges (`edges`) or its free curves.
func (s *Scene) Polylines(part uint32, edges bool) (pos []float32, counts []uint32) {
	var p C.CadaclysmPolylines
	if edges {
		p = C.cadaclysm_node_edges(s.p, C.uint32_t(part))
	} else {
		p = C.cadaclysm_node_curves(s.p, C.uint32_t(part))
	}
	if p.vertex_count == 0 || p.positions == nil {
		return nil, nil
	}
	pos = unsafe.Slice((*float32)(unsafe.Pointer(p.positions)), int(p.vertex_count)*3)
	counts = unsafe.Slice((*uint32)(unsafe.Pointer(p.counts)), int(p.polyline_count))
	return
}

// Isocurves borrows a part's isocurves — the interior isoparametric lines across a
// curved face, which a flat face draws as its own outline instead.
func (s *Scene) Isocurves(part uint32) (pos []float32, counts []uint32) {
	p := C.cadaclysm_node_isocurves(s.p, C.uint32_t(part))
	if p.vertex_count == 0 || p.positions == nil {
		return nil, nil
	}
	pos = unsafe.Slice((*float32)(unsafe.Pointer(p.positions)), int(p.vertex_count)*3)
	counts = unsafe.Slice((*uint32)(unsafe.Pointer(p.counts)), int(p.polyline_count))
	return
}

// none is what the ABI returns for "no such part": a parent that is a root, an instance_of
// that is not an instance. UINT32_MAX, spelled CADACLYSM_NONE in the header.
const none = ^uint32(0)

// Parent is the part containing this one, and whether it has one at all.
func (s *Scene) Parent(part uint32) (uint32, bool) {
	p := uint32(C.cadaclysm_node_parent(s.p, C.uint32_t(part)))
	return p, p != none
}

// Depth is how far down the tree a part sits, a root being zero. For indenting.
func (s *Scene) Depth(part uint32) uint32 {
	return uint32(C.cadaclysm_node_depth(s.p, C.uint32_t(part)))
}

func (s *Scene) Name(part uint32) string {
	return C.GoString(C.cadaclysm_node_name(s.p, C.uint32_t(part)))
}

func (s *Scene) Kind(part uint32) string {
	return C.GoString(C.cadaclysm_node_kind(s.p, C.uint32_t(part)))
}

func (s *Scene) ID(part uint32) string {
	return C.GoString(C.cadaclysm_node_id(s.p, C.uint32_t(part)))
}

// Generator is what a part's geometry was before it was triangles — "brep", "mesh", "csg".
// Empty for a part that draws nothing, there being no geometry to have come from anything.
func (s *Scene) Generator(part uint32) string {
	return C.GoString(C.cadaclysm_node_generator(s.p, C.uint32_t(part)))
}

// InstanceOf is the part whose geometry this one is a placement of, and whether it is one.
func (s *Scene) InstanceOf(part uint32) (uint32, bool) {
	p := uint32(C.cadaclysm_node_instance_of(s.p, C.uint32_t(part)))
	return p, p != none
}

// Attribute is one thing the file said about a part, rendered as text.
//
// The ABI hands these over typed — an IFC property set's numbers are numbers — and a viewer
// that wanted to total them would keep the types. This one only prints them.
type Attribute struct{ Name, Value string }

// Attributes is everything the file said about a part.
func (s *Scene) Attributes(part uint32) []Attribute {
	n := uint32(C.cadaclysm_node_attribute_count(s.p, C.uint32_t(part)))
	out := make([]Attribute, 0, n)
	for i := uint32(0); i < n; i++ {
		a := C.cadaclysm_node_attribute(s.p, C.uint32_t(part), C.uint32_t(i))
		if a.name == nil {
			continue
		}
		value := ""
		switch a.kind {
		case C.CadaclysmValueText, C.CadaclysmValueList, C.CadaclysmValueReference:
			value = C.GoString(a.text)
		case C.CadaclysmValueInteger:
			value = fmt.Sprintf("%d", int64(a.integer))
		case C.CadaclysmValueReal:
			// Not "%g": it switches to exponent notation past a handful of digits, where
			// cadaclysm's own `Display for Value` in Rust never does — 1234567.0 prints
			// "1.234567e+06" under "%g" and "1234567" in Rust. FormatFloat's 'f' verb is
			// fixed notation always, and precision -1 is the shortest decimal that
			// round-trips, which together is exactly what Rust's float Display does.
			value = strconv.FormatFloat(float64(a.real), 'f', -1, 64)
		case C.CadaclysmValueBoolean:
			value = fmt.Sprintf("%t", bool(a.boolean))
		}
		out = append(out, Attribute{Name: C.GoString(a.name), Value: value})
	}
	return out
}
