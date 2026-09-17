// Package cadaclysm is the cadaclysm C ABI, as Go objects: this file is the whole binding.
//
//	scene, err := cadaclysm.Open("part.stp")
//	if err != nil { ... }
//	defer scene.Close()
//	fmt.Println(scene.Version(), scene.Schema(), scene.MetresPerUnit())
//	for _, root := range scene.Roots() {
//	    walk(root, 0)
//	}
//
// It uses cgo and the published header, the way any Go program would — no generated
// bindings, no Rust, no build system beyond a C toolchain for cgo itself. Point
// CGO_LDFLAGS at the shared library's directory if it is not where the #cgo lines below
// already look.
//
// # Everything borrows from the scene
//
// Every pointer this ABI hands back — names, ids, attribute text, vertex and index
// arrays — points into the open document and dies with it. [Mesh] and [Polylines] hand
// back Go slices built with unsafe.Slice straight over the library's own memory rather
// than copies: an assembly with tens of millions of triangles makes a defensive copy of
// every mesh a cost most callers never asked for, most meshes being uploaded to a GPU and
// dropped. Call [Mesh.Copy] for one that must outlive the scene, or read the slice before
// [Scene.Close] runs — there is no way in Go to mark a slice's backing memory read-only or
// to tie its lifetime to the scene's, so this sharp edge is documented rather than
// enforced, exactly as it is left in the Python client this package mirrors.
//
// Strings are the easy half: every char* this ABI returns is copied into a Go string on
// the way out through C.GoString, so Node.Name and friends outlive anything.
//
// # A closed scene refuses, it does not answer
//
// After [Scene.Close] the library's own reads of a nil scene hand back empty values —
// no nodes, zero bounds, "" for every name — which is a plausible nothing, not an
// error. Every method here reads the handle through one accessor instead, and a closed
// scene is refused the way Python, C# and Java refuse it: a method that already returns
// an error ([Scene.Query], [Scene.Save], [Node.SaveMesh], [Node.Mesh], [Node.Surfaces])
// returns a *CadaclysmError saying "the scene is closed"; an error-less accessor
// ([Scene.Bounds], [Node.Name], [Placement.Geometry] and the rest) panics with that same
// *CadaclysmError, a use-after-close being a programmer error rather than a condition to
// handle — recover it if a program must go on. The kernel package's ErrClosed follows the
// same rule, every one of its calls having an error to return it in.
//
// # The library's error slot is thread-local
//
// cadaclysm_last_error reads a thread-local: the reason the failing call left on the OS
// thread it ran on. A goroutine may move between OS threads between one call and the
// next, so every call that can fail and the read of its reason are made with the
// goroutine locked to its thread ([runtime.LockOSThread], through pin below) — a call
// site that reads lastError outside that lock may read another thread's reason, or none.
//
// The object model — Scene, Node, Placement, Mesh, Polylines, Surfaces — is transcribed
// from examples/cadaclysm.py, member for member: the same names in Go's own casing, the
// same arguments (as functional options where Python takes keyword arguments), the same
// things left None/nil, the same things raised as errors. examples/csharp/Cad.cs is a
// second transcription of the same module and is worth reading for how a member not
// obvious in Go was mapped, but Go has its own idioms and does not copy C#'s shapes
// blindly — a Mesh's arrays are struct fields here, not properties, because Go has no
// properties to give them.
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
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unsafe"
)

// noneIndex is what the ABI returns for "no such node": a parent that is a root, an
// instance_of that is not an instance, an index past the end. CADACLYSM_NONE in the
// header, UINT32_MAX underneath.
const noneIndex = ^uint32(0)

// ---- errors and value kinds ------------------------------------------------------

// CadaclysmError is what a call into the library failed with, carrying what it said
// about it — Python's CadaclysmError, C#'s CadaclysmException.
type CadaclysmError struct{ Message string }

// Error satisfies the error interface.
func (e *CadaclysmError) Error() string { return e.Message }

// pin locks the goroutine to its OS thread until the func it returns runs, so a call that
// can fail and the lastError read after it see the same thread-local slot (see the package
// doc). Every function below that reads lastError starts with `defer pin()()`; the locks
// nest, so a caller already pinned loses nothing.
func pin() func() {
	runtime.LockOSThread()
	return runtime.UnlockOSThread
}

// lastError is the library's own reason for the last failure on this OS thread, or "".
// Read only under pin, in the function that made the failing call.
func lastError() string { return C.GoString(C.cadaclysm_last_error()) }

// lastErrorOr is the library's own reason for the last failure, or fallback if it left
// none — the "could not write %s" style message every writer below raises with.
func lastErrorOr(fallback string) string {
	if e := lastError(); e != "" {
		return e
	}
	return fallback
}

// ValueKind says which field of an Attribute holds its value — CadaclysmValueKind in
// the header. One-based, with zero meaning the attribute was not there; a zero-based
// reading of this type is off by one for every kind.
type ValueKind int32

const (
	// ValueKindNone marks an attribute that was not there.
	ValueKindNone ValueKind = iota
	// ValueKindText is a plain string value.
	ValueKindText
	// ValueKindInteger is a signed integer value.
	ValueKindInteger
	// ValueKindReal is a floating-point value.
	ValueKindReal
	// ValueKindBoolean is a true/false value.
	ValueKindBoolean
	// ValueKindList is a list of values: the flat C struct cannot hold the elements,
	// so Attribute.Value carries a "[a, b, c]" rendering of them.
	ValueKindList
	// ValueKindReference is another entity, with the id the file gave ("#4") as the
	// value. Its own kind rather than ValueKindText so a consumer can follow it
	// instead of showing it as prose.
	ValueKindReference
)

// ---- convention -------------------------------------------------------------------

// Convention is the coordinate space to open a file into — CadaclysmConvention in the
// header.
//
// The library converts on the way out, so nothing here rotates anything: a caller names
// the space it draws in and reads geometry already in it. The values come from the
// header rather than being written out again, so this cannot drift from it.
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

	// FileUnits ORs into a Convention to keep the preset's axes but the file's own
	// units. A packing of this package's own, not the ABI's — see WithConvention.
	FileUnits = Convention(0x100)

	// UVWorld ORs into a Convention to ask for texture coordinates at world scale,
	// filling Mesh.Uvs where the reader honours it. Off by default: a (u, v) is
	// eight bytes a vertex, not a cost to impose on a caller who never asked.
	UVWorld = Convention(0x200)
)

// ParseConvention reads a name a user typed, as a "-convention" flag would take it:
// "unreal", or "unreal+file-units" to keep the file's own units under the preset's axes.
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

// ---- module-level entry points -----------------------------------------------------

// Version is the version of the library actually loaded, which is the one worth
// reporting.
func Version() string { return C.GoString(C.cadaclysm_version()) }

// BuildDate is when the loaded library was built, YYYY-MM-DD; a paid license covers
// every build dated on or before its expiry.
func BuildDate() string { return C.GoString(C.cadaclysm_build_date()) }

// License loads a license: the certificate text, or the path of a file holding it.
// Without it the library looks in CADACLYSM_LICENSE, then for cadaclysm.lic beside the
// running executable and in the working directory. Returns the library's reason when the
// text does not verify; the previous license, if any, stays in use.
func License(textOrPath string) error {
	defer pin()()
	c := C.CString(textOrPath)
	defer C.free(unsafe.Pointer(c))
	if !bool(C.cadaclysm_license_set(c)) {
		return &CadaclysmError{Message: lastErrorOr("license refused")}
	}
	return nil
}

// LicenseInfo is one line about the license the library is running under. Never empty:
// the license line, or, without one, "unlicensed" ("unlicensed -- <reason>" when a
// license was found but did not verify).
func LicenseInfo() string {
	p := C.cadaclysm_license_info()
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
func LicenseNoticeCount() uint64 { return uint64(C.cadaclysm_license_notice_count()) }

// MeshFormat is one format Node.SaveMesh writes, as a name ("stl") and the extension it
// writes ("stl") — carried separately because the two are not always the same word:
// "stl-ascii" writes a .stl.
type MeshFormat struct {
	Name      string
	Extension string
}

// MeshFormats is every format Node.SaveMesh writes. Ask rather than hard-code: a format
// added to the library turns up here without this package being touched.
func MeshFormats() []MeshFormat {
	n := uint32(C.cadaclysm_mesh_format_count())
	out := make([]MeshFormat, n)
	for i := uint32(0); i < n; i++ {
		out[i] = MeshFormat{
			Name:      C.GoString(C.cadaclysm_mesh_format(C.uint32_t(i))),
			Extension: C.GoString(C.cadaclysm_mesh_format_extension(C.uint32_t(i))),
		}
	}
	return out
}

// PickFile asks the user for a file to open, through the library's own dialog. The
// second return is false if they cancelled, or if no dialog was available — the ABI
// cannot tell those two apart and neither can this, so a caller treats both as "no
// file". Blocks until the user acts; on macOS it must be called from the main thread.
func PickFile() (string, bool) {
	p := C.cadaclysm_pick_file(nil)
	if p == nil {
		return "", false
	}
	return C.GoString(p), true
}

var declaredSchemaPattern = regexp.MustCompile(`(?i)FILE_SCHEMA\s*\(\s*\(\s*'([^']+)'`)

// DeclaredSchema is the schema a STEP or IFC file says it speaks, from its own header:
// FILE_SCHEMA(('IFC2X3')) sits near the top of the file, so a few kilobytes is plenty
// and a 300 MB IFC costs nothing to ask.
func DeclaredSchema(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	buf := make([]byte, 8192)
	n, err := io.ReadFull(f, buf)
	if err != nil && err != io.ErrUnexpectedEOF && err != io.EOF {
		return "", err
	}
	m := declaredSchemaPattern.FindStringSubmatch(string(buf[:n]))
	if m == nil {
		return "", nil
	}
	return m[1], nil
}

// plainSchemaName is a schema name reduced to its letters and digits, upper-cased, so
// "ap203e2_mim_lf" and "AP203E2MIMLF" compare equal.
func plainSchemaName(name string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(name) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// ResolveSchema resolves schema (a file, a directory of .exp files, or "" for none) to
// one chosen .exp, or a list of fallbacks to try in turn.
//
// A file is taken as given. A directory is matched against what modelPath says it
// speaks: the ABI registers exactly one schema per open, so something has to choose, and
// the file itself is the one that knows. Where the declared name resembles no filename
// the whole directory comes back as fallbacks — AP203 calls itself
// CONFIG_CONTROL_DESIGN, and there will be others.
func ResolveSchema(modelPath, schema string) (chosen string, fallbacks []string, err error) {
	if schema == "" {
		return "", nil, nil
	}
	info, statErr := os.Stat(schema)
	if statErr == nil && !info.IsDir() {
		return schema, nil, nil
	}
	if statErr != nil {
		return "", nil, &CadaclysmError{Message: fmt.Sprintf("schema %s is neither a file nor a directory", schema)}
	}
	available, _ := filepath.Glob(filepath.Join(schema, "*.exp"))
	sort.Strings(available)
	if len(available) == 0 {
		return "", nil, &CadaclysmError{Message: fmt.Sprintf("no .exp schemas in %s", schema)}
	}
	declared, _ := DeclaredSchema(modelPath)
	declaredPlain := plainSchemaName(declared)
	stemOf := func(exp string) string {
		return plainSchemaName(strings.TrimSuffix(filepath.Base(exp), filepath.Ext(exp)))
	}
	var matches []string
	for _, exp := range available {
		stem := stemOf(exp)
		if declaredPlain != "" && (strings.HasPrefix(declaredPlain, stem) || strings.HasPrefix(stem, declaredPlain)) {
			matches = append(matches, exp)
		}
	}
	if len(matches) == 0 {
		return "", available, nil
	}
	// The longest name that still matches is the most specific one.
	best := matches[0]
	for _, m := range matches[1:] {
		if len(stemOf(m)) > len(stemOf(best)) {
			best = m
		}
	}
	return best, nil, nil
}

// ---- opening ------------------------------------------------------------------------

// Option configures Open or OpenMemory — Go's idiom for the keyword arguments Python's
// open() and open_memory() take.
type Option func(*openConfig)

type openConfig struct {
	convention          Convention
	schema              string
	format              string
	colours             bool
	sourceMetresPerUnit float64
}

// WithFormat names the kind of the bytes OpenMemory is given, as an extension would —
// "step", "ifc", "igs", "brep", "3dm", "scad" — Python's own `format` argument. A leading
// dot is allowed and ignored. Without it OpenMemory takes the extension of the name it is
// given. Open ignores it: a file on disk names its own kind.
func WithFormat(format string) Option { return func(cfg *openConfig) { cfg.format = format } }

// WithConvention sets the space to read the file into. The library does the converting,
// so every array read out of the scene is already in it. The default is Native.
func WithConvention(c Convention) Option { return func(cfg *openConfig) { cfg.convention = c } }

// WithSchema names an EXPRESS schema (.exp) beyond the ones built into the library, or a
// directory of them matched against what the file says it speaks. Every schema the
// project ships is compiled in, so a STEP or IFC file opens without this.
func WithSchema(schema string) Option { return func(cfg *openConfig) { cfg.schema = schema } }

// WithColours asks for a per-vertex colour on Mesh.Colours, for a body whose faces carry
// more than one colour between them. Off by default: a colour is sixteen bytes a vertex.
func WithColours() Option { return func(cfg *openConfig) { cfg.colours = true } }

// WithSourceMetresPerUnit says what one of the file's own units is worth in metres, for
// a format that states none — OpenSCAD is the case, being unitless. Zero (the default)
// means "not said".
func WithSourceMetresPerUnit(v float64) Option {
	return func(cfg *openConfig) { cfg.sourceMetresPerUnit = v }
}

// buildOptions is a CadaclysmOpenOptions built from cfg, minus its schema fields: Open
// and OpenMemory each set those themselves, immediately before the call that reads them,
// so the C strings backing them stay alive exactly as long as they must.
func buildOptions(cfg openConfig) C.CadaclysmOpenOptions {
	var opts C.CadaclysmOpenOptions
	C.cadaclysm_open_options_init(&opts)
	packed := uint32(cfg.convention)
	opts.convention = C.uint32_t(packed &^ (uint32(FileUnits) | uint32(UVWorld)))
	opts.file_units = C.bool(packed&uint32(FileUnits) != 0)
	if packed&uint32(UVWorld) != 0 {
		opts.uvs = C.uint32_t(C.CADACLYSM_UV_WORLD_SCALE)
	}
	if cfg.colours {
		opts.colors = C.uint32_t(C.CADACLYSM_COLORS_PER_FACE)
	}
	opts.source_meters_per_unit = C.double(cfg.sourceMetresPerUnit)
	return opts
}

// schemaList wires schema (a file, a directory, or "" for none) into opts as a one-entry
// list, and returns what frees it once the call that reads opts has returned.
//
// The list itself lives in C memory, not in a Go array: opts is a struct handed to C by
// pointer, and cgo's pointer check refuses a Go pointer stored inside memory it passes
// ("cgo argument has Go pointer to unpinned Go pointer") -- a panic on every Open or
// OpenMemory given a schema, which is every ToScene from the kernel package. C.malloc'd
// memory carries no such rule.
func schemaList(schema string, opts *C.CadaclysmOpenOptions) (free func()) {
	if schema == "" {
		return func() {}
	}
	cs := C.CString(schema)
	list := (**C.char)(C.malloc(C.size_t(unsafe.Sizeof(cs))))
	*list = cs
	opts.schemas = list
	opts.schema_count = 1
	return func() {
		C.free(unsafe.Pointer(list))
		C.free(unsafe.Pointer(cs))
	}
}

// openNative calls cadaclysm_open with schema (a file, a directory, or "" for none)
// wired into opts for the duration of the call. The error carries the library's reason,
// read here on the thread the call ran on; Open reports it rather than reading again.
func openNative(path, schema string, opts C.CadaclysmOpenOptions) (*C.CadaclysmScene, error) {
	defer pin()()
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	defer schemaList(schema, &opts)()
	p := C.cadaclysm_open(cp, &opts)
	if p == nil {
		// The library's own message alone, as Python's f"{path.name}: {_last_error()}";
		// "open failed" only stands in when it left none.
		return nil, &CadaclysmError{Message: lastErrorOr("open failed")}
	}
	return p, nil
}

// Open opens a CAD file, or a .zip holding one.
//
// Raises no panic and never returns a nil Scene with a nil error: failure always comes
// back as an error carrying what the library said. An unrecognised WithConvention is one
// of the failures Convention validation itself catches before this is ever reached; a
// convention this package cannot build is refused by the library instead, at open.
//
// A .zip opens its first readable member; Scene.SourceName says which.
func Open(path string, opts ...Option) (*Scene, error) {
	cfg := openConfig{convention: Native}
	for _, opt := range opts {
		opt(&cfg)
	}
	if _, err := os.Stat(path); err != nil {
		return nil, &CadaclysmError{Message: fmt.Sprintf("%s: no such file", path)}
	}
	label := filepath.Base(path)

	// A directory goes over whole rather than being narrowed to one file here: the
	// library walks it and keys each schema under the name that schema itself
	// declares, which is the only authority on the matter.
	if cfg.schema != "" {
		if info, err := os.Stat(cfg.schema); err == nil && info.IsDir() {
			handle, oerr := openNative(path, cfg.schema, buildOptions(cfg))
			if oerr != nil {
				return nil, &CadaclysmError{Message: fmt.Sprintf("%s: %s", label, oerr)}
			}
			return &Scene{handle: handle, label: label, path: path, schemaPath: cfg.schema, convention: cfg.convention}, nil
		}
	}

	chosen, fallbacks, err := ResolveSchema(path, cfg.schema)
	if err != nil {
		return nil, err
	}
	candidates := []string{chosen}
	if chosen == "" && len(fallbacks) > 0 {
		candidates = fallbacks
	}
	var last error
	for _, candidate := range candidates {
		handle, oerr := openNative(path, candidate, buildOptions(cfg))
		if oerr == nil {
			return &Scene{handle: handle, label: label, path: path, schemaPath: candidate, convention: cfg.convention}, nil
		}
		last = oerr
	}
	return nil, &CadaclysmError{Message: fmt.Sprintf("%s: %s", label, last)}
}

// OpenMemory opens a CAD file already in bytes.
//
// The format is WithFormat's if given — Python's open_memory takes it as a separate
// required argument — else name's own extension, so a caller opening bytes it already
// knows the name of (as the smoke does) need not repeat it. The name stands as the
// scene's Path, as Python keeps it. WithSchema must name a file here: there is no file on
// disk to read a FILE_SCHEMA line out of, so a directory is passed through unmatched
// rather than resolved.
func OpenMemory(data []byte, name string, opts ...Option) (*Scene, error) {
	defer pin()()
	cfg := openConfig{convention: Native}
	for _, opt := range opts {
		opt(&cfg)
	}
	format := cfg.format
	if format == "" {
		format = filepath.Ext(name)
	}
	format = strings.TrimPrefix(format, ".")
	options := buildOptions(cfg)
	defer schemaList(cfg.schema, &options)()
	cf := C.CString(format)
	defer C.free(unsafe.Pointer(cf))
	var dataPtr *C.uint8_t
	if len(data) > 0 {
		dataPtr = (*C.uint8_t)(unsafe.Pointer(&data[0]))
	}
	handle := C.cadaclysm_open_memory(dataPtr, C.size_t(len(data)), cf, &options)
	if handle == nil {
		return nil, &CadaclysmError{Message: fmt.Sprintf("%s: %s", name, lastErrorOr("open failed"))}
	}
	return &Scene{handle: handle, label: name, path: name, schemaPath: cfg.schema, convention: cfg.convention}, nil
}

// ---- bounds, attributes -------------------------------------------------------------

// Bounds is an axis-aligned box, or all zeros where there was nothing to bound.
type Bounds struct{ Min, Max [3]float64 }

// IsEmpty is whether this is the all-zero box the ABI uses for "nothing here".
func (b Bounds) IsEmpty() bool {
	return b.Min == [3]float64{} && b.Max == [3]float64{}
}

// Size is Max minus Min, a component at a time.
func (b Bounds) Size() [3]float64 {
	return [3]float64{b.Max[0] - b.Min[0], b.Max[1] - b.Min[1], b.Max[2] - b.Min[2]}
}

// Centre is the midpoint of Min and Max, a component at a time.
func (b Bounds) Centre() [3]float64 {
	return [3]float64{(b.Min[0] + b.Max[0]) / 2, (b.Min[1] + b.Max[1]) / 2, (b.Min[2] + b.Max[2]) / 2}
}

// Attribute is one thing the file said about a node.
//
// Value is this value in Go's own natural rendering for its Kind: the raw text for
// ValueKindText/List/Reference, strconv.FormatInt for ValueKindInteger, a "natural"
// strconv.FormatFloat('g', ...) for ValueKindReal, and "true"/"false" for
// ValueKindBoolean. Text renders it the way cadaclysm's own Rust Display renders it,
// which is what agrees byte for byte with the Go, C# and Python clients for every finite
// value — the two diverge only on the infinities, where Text follows Rust.
type Attribute struct {
	Name  string
	Kind  ValueKind
	Value string
}

// Text is the value rendered for display, as cadaclysm's own Rust Display does.
func (a Attribute) Text() string {
	switch a.Kind {
	case ValueKindNone:
		return ""
	case ValueKindReal:
		v, err := strconv.ParseFloat(a.Value, 64)
		if err != nil {
			return a.Value
		}
		switch {
		case math.IsNaN(v):
			return "NaN"
		case math.IsInf(v, 1):
			return "inf"
		case math.IsInf(v, -1):
			return "-inf"
		default:
			return strconv.FormatFloat(v, 'f', -1, 64)
		}
	default:
		return a.Value
	}
}

// buildAttribute is a CadaclysmAttribute as an Attribute. The caller has already
// checked raw.name is not nil, which is the ABI's sentinel for "past the end".
func buildAttribute(raw C.CadaclysmAttribute) Attribute {
	kind := ValueKind(raw.kind)
	if kind < ValueKindNone || kind > ValueKindReference {
		kind = ValueKindNone
	}
	var value string
	switch kind {
	case ValueKindText, ValueKindList, ValueKindReference:
		value = C.GoString(raw.text)
	case ValueKindInteger:
		value = strconv.FormatInt(int64(raw.integer), 10)
	case ValueKindReal:
		value = strconv.FormatFloat(float64(raw.real), 'g', -1, 64)
	case ValueKindBoolean:
		value = strconv.FormatBool(bool(raw.boolean))
	}
	return Attribute{Name: C.GoString(raw.name), Kind: kind, Value: value}
}

// ---- meshes and polylines -----------------------------------------------------------

// Mesh is a node's triangles, in the node's own frame — slices over the scene's own
// memory, valid until Scene.Close.
//
// Positions and Normals are (vertex_count * 3) float32, Uvs is (vertex_count * 2),
// Colours is (vertex_count * 4) RGBA, and Indices is (index_count) uint32, three to a
// triangle. A nil slice stands in for Python's None: Normals, Uvs and Colours are all
// commonly nil, and only Positions/Indices are guaranteed for a mesh Node.Mesh returned
// at all.
type Mesh struct {
	Positions []float32
	Normals   []float32
	Uvs       []float32
	Colours   []float32
	Indices   []uint32
}

// TriangleCount is len(Indices) / 3.
func (m *Mesh) TriangleCount() int { return len(m.Indices) / 3 }

// MeshData is a node's triangles, copied into memory of the caller's own — what
// Mesh.Copy returns.
type MeshData struct {
	Positions []float32
	Normals   []float32
	Uvs       []float32
	Colours   []float32
	Indices   []uint32
}

// Copy is the same triangles in memory of our own, safe to outlive the scene. Expensive
// on purpose to be visible: this is where the gigabytes go on a large assembly, and it
// should be a line a reader can point at.
func (m *Mesh) Copy() MeshData {
	return MeshData{
		Positions: append([]float32(nil), m.Positions...),
		Normals:   append([]float32(nil), m.Normals...),
		Uvs:       append([]float32(nil), m.Uvs...),
		Colours:   append([]float32(nil), m.Colours...),
		Indices:   append([]uint32(nil), m.Indices...),
	}
}

// Polylines is a node's feature edges or free curves, already flattened to points — a
// view over the scene's own memory, valid until Scene.Close.
//
// Positions is (vertex count * 3) float32 with the runs end to end; Counts is
// (polyline count) uint32 saying where each run stops. Both lengths are read straight
// off the slices, so there is nothing further to carry beside them.
type Polylines struct {
	Positions []float32
	Counts    []uint32
}

// PolylineCount is how many runs this holds.
func (p *Polylines) PolylineCount() int { return len(p.Counts) }

// VertexCount is how many points this holds, across every run.
func (p *Polylines) VertexCount() int { return len(p.Positions) / 3 }

// SegmentIndices are indices into Positions making line-segment endpoint pairs: a
// polyline of n points is n - 1 segments, so each interior point is named twice.
func (p *Polylines) SegmentIndices() []int {
	if len(p.Counts) == 0 {
		return nil
	}
	var out []int
	at := 0
	for _, c := range p.Counts {
		n := int(c)
		for i := 0; i+1 < n; i++ {
			out = append(out, at+i, at+i+1)
		}
		at += n
	}
	return out
}

// Segments is the endpoint pairs themselves, (2 * segment count, 3) in the node's own
// frame.
func (p *Polylines) Segments() []float32 {
	idx := p.SegmentIndices()
	out := make([]float32, len(idx)*3)
	for i, id := range idx {
		copy(out[i*3:i*3+3], p.Positions[id*3:id*3+3])
	}
	return out
}

// ---- surfaces -------------------------------------------------------------------------

// Face is one trimmed face: the surface itself, plus the loops that cut it.
//
// Kind is 0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus, 5 revolution, 6 extrusion,
// 7 NURBS, 8 sum. Origin, Ax, Ay, Az are the frame; Scalars is kind-dependent; Domain is
// (u_min, v_min, u_max, v_max). Loops is one flat []float32 of (u, v) pairs per loop,
// each closing implicitly; Profile and Profile2 are flat (x, y, z, parameter) samples,
// four floats each; Nurbs is a NURBS surface's packed net and knots. See CadaclysmFace
// in the header for the whole story.
//
// Unlike Mesh and Polylines, every array here is copied out at construction rather than
// kept as a borrowed view: a face's trim loops and profile samples are a handful of
// points next to a mesh's millions of vertices, so the copy this struct pays once is not
// the cost the package doc's "everything borrows" rule exists to avoid.
type Face struct {
	Kind       uint32
	Reversed   bool
	Transposed bool
	Origin     [3]float32
	Ax         [3]float32
	Ay         [3]float32
	Az         [3]float32
	Domain     [4]float32
	Scalars    [4]float32
	Loops      [][]float32
	Profile    []float32
	Profile2   []float32
	Nurbs      []float32
}

// Surfaces is a node's faces as surfaces and trims. Everything here is in the file's own
// frame, unlike every other product this package hands back — see Scene.SurfaceMatrix.
type Surfaces struct{ Faces []Face }

func copyFloatRange(src []C.float, start, count, stride uint32) []float32 {
	if count == 0 {
		return nil
	}
	out := make([]float32, count*stride)
	for i := uint32(0); i < count*stride; i++ {
		out[i] = float32(src[start*stride+i])
	}
	return out
}

// ---- placements -----------------------------------------------------------------------

// Placement is one drawing of one node's geometry, at one place.
//
// A node is not a drawing, and the difference is a bug this library shipped. Most nodes
// are structure and draw nothing; a node that places a block draws everything inside
// that block; and a block's members draw once per placement of it rather than once on
// their own account. So iterate Scene.Placements to draw, and nodes to build a tree.
type Placement struct {
	scene *Scene
	index uint32
}

// Index is this placement's position in Scene.Placements() — Python's placement.index,
// which is a public attribute there for the same reason this is a method here: a
// caller keying a map of what it has drawn needs a stable identity to key it with.
func (p *Placement) Index() uint32 { return p.index }

// Geometry is the node whose mesh, edges and curves this draws. Two drawings of one
// shape name the same node and so hand back the same arrays, which is what lets a
// caller upload it once and draw it twice.
func (p *Placement) Geometry() *Node {
	return &Node{scene: p.scene, index: uint32(C.cadaclysm_placement_geometry(p.scene.h(), C.uint32_t(p.index)))}
}

// Select is what a click on this drawing should select — the placement rather than the
// shape it draws, since the shape is shared with every sibling copy.
func (p *Placement) Select() *Node {
	return &Node{scene: p.scene, index: uint32(C.cadaclysm_placement_select(p.scene.h(), C.uint32_t(p.index)))}
}

// RawTransform is where to draw this, sixteen doubles in the ABI's own column-major
// order.
func (p *Placement) RawTransform() [16]float64 {
	var raw [16]C.double
	C.cadaclysm_placement_transform(p.scene.h(), C.uint32_t(p.index), (*C.double)(unsafe.Pointer(&raw[0])))
	var out [16]float64
	for i := range raw {
		out[i] = float64(raw[i])
	}
	return out
}

// Transform is RawTransform in row-major order: Transform()[row*4+col] is
// RawTransform()[col*4+row], so the rotation and scale block sits at rows/cols 0..2 and
// the offset at column 3 of each row — the textbook convention.
func (p *Placement) Transform() [16]float64 {
	raw := p.RawTransform()
	var out [16]float64
	for col := 0; col < 4; col++ {
		for row := 0; row < 4; row++ {
			out[row*4+col] = raw[col*4+row]
		}
	}
	return out
}

// ---- nodes ------------------------------------------------------------------------------

// Node is one node of the document: an assembly, a shape, a placement.
//
// A handle rather than a snapshot — every method below asks the scene when you call it,
// so nothing here goes stale and nothing is read that a caller never looks at.
type Node struct {
	scene *Scene
	index uint32
}

// Index is this node's position in Scene.Nodes() — Python's node.index, which is a
// public attribute there for the same reason this is a method here: a caller keying a
// map of what it has drawn, or matching a selection back to a row, needs a stable
// identity to key it with.
func (n *Node) Index() uint32 { return n.index }

// Name is the node's own name, or "" past the end.
func (n *Node) Name() string {
	return C.GoString(C.cadaclysm_node_name(n.scene.h(), C.uint32_t(n.index)))
}

// ID is what the file calls it — a STEP #N, an IFC GlobalId, a Rhino UUID. Text rather
// than a number because that is what the formats carry.
func (n *Node) ID() string {
	return C.GoString(C.cadaclysm_node_id(n.scene.h(), C.uint32_t(n.index)))
}

// Kind is what the file calls it — an IFC type, an openNURBS class, a shape kind.
func (n *Node) Kind() string {
	return C.GoString(C.cadaclysm_node_kind(n.scene.h(), C.uint32_t(n.index)))
}

// Visible is whether the file says to show this when it is opened. The file's opening
// state, and not inherited — see VisibleNow for that.
func (n *Node) Visible() bool {
	return bool(C.cadaclysm_node_visible(n.scene.h(), C.uint32_t(n.index)))
}

// VisibleNow is Visible, but with every ancestor consulted: a layer switched off hides
// what hangs under it however the members' own switches are set.
func (n *Node) VisibleNow() bool {
	for node := n; node != nil; node = node.Parent() {
		if !node.Visible() {
			return false
		}
	}
	return true
}

// Locked is whether the file says this cannot be selected or edited. Rhino's idea, so it
// rides as a derived value rather than a field: an object is locked by its own flag or
// by its layer's, and the reader has already combined the two. Formats without the
// concept answer false. Locking is not hiding — a locked thing is drawn exactly as any
// other and only refuses to be picked. Only a Locked attribute of ValueKindBoolean
// counts; one of any other kind reads as unlocked here, where Python truth-tests
// whatever value it finds.
func (n *Node) Locked() bool {
	for _, a := range n.Attributes() {
		if a.Name == "Locked" {
			return a.Kind == ValueKindBoolean && a.Value == "true"
		}
	}
	return false
}

// Label is something to put in a tree row: the name, else the kind, else "#index".
func (n *Node) Label() string {
	if name := n.Name(); name != "" {
		return name
	}
	if kind := n.Kind(); kind != "" {
		return kind
	}
	return fmt.Sprintf("#%d", n.index)
}

// Depth is how far down the tree this node sits, a root being zero. For indenting.
func (n *Node) Depth() uint32 {
	return uint32(C.cadaclysm_node_depth(n.scene.h(), C.uint32_t(n.index)))
}

// Generator is what its geometry was before it was triangles — "brep", "mesh", "csg".
// Empty for a node that draws nothing, there being no geometry to have come from
// anything.
func (n *Node) Generator() string {
	return C.GoString(C.cadaclysm_node_generator(n.scene.h(), C.uint32_t(n.index)))
}

// Parent is the node containing this one, or nil for a root.
func (n *Node) Parent() *Node {
	p := uint32(C.cadaclysm_node_parent(n.scene.h(), C.uint32_t(n.index)))
	if p == noneIndex {
		return nil
	}
	return &Node{scene: n.scene, index: p}
}

// Children is every node this one contains directly.
func (n *Node) Children() []*Node {
	count := uint32(C.cadaclysm_node_child_count(n.scene.h(), C.uint32_t(n.index)))
	out := make([]*Node, count)
	for i := uint32(0); i < count; i++ {
		out[i] = &Node{scene: n.scene, index: uint32(C.cadaclysm_node_child(n.scene.h(), C.uint32_t(n.index), C.uint32_t(i)))}
	}
	return out
}

// InstanceOf is the node whose geometry this one is a placement of, or nil. The point of
// meshes coming over in their own frame: a shell placed seventy-four times is one mesh
// and seventy-four transforms, and this is how a caller knows to upload the buffer once.
func (n *Node) InstanceOf() *Node {
	p := uint32(C.cadaclysm_node_instance_of(n.scene.h(), C.uint32_t(n.index)))
	if p == noneIndex {
		return nil
	}
	return &Node{scene: n.scene, index: p}
}

// SelectAs is what a click on this node's geometry should select — itself, usually. A
// format that hangs geometry on a child of the object it belongs to points the child
// back at the object.
func (n *Node) SelectAs() *Node {
	chosen := uint32(C.cadaclysm_node_select_as(n.scene.h(), C.uint32_t(n.index)))
	if chosen == noneIndex {
		return n
	}
	return &Node{scene: n.scene, index: chosen}
}

// Attributes is everything the file said about this node.
func (n *Node) Attributes() []Attribute {
	count := uint32(C.cadaclysm_node_attribute_count(n.scene.h(), C.uint32_t(n.index)))
	out := make([]Attribute, 0, count)
	for i := uint32(0); i < count; i++ {
		raw := C.cadaclysm_node_attribute(n.scene.h(), C.uint32_t(n.index), C.uint32_t(i))
		if raw.name == nil {
			continue
		}
		out = append(out, buildAttribute(raw))
	}
	return out
}

// CanMesh is whether this node is drawn — whether it has geometry of its own to show.
// Asks for nothing to be built. Most nodes of a model are structure and answer false.
func (n *Node) CanMesh() bool {
	return bool(C.cadaclysm_node_can_mesh(n.scene.h(), C.uint32_t(n.index)))
}

// SaveMesh writes this node's mesh to path in format — one of MeshFormats(). Returns an
// error if the node draws nothing, which most of them do, or if format is not one the
// library writes. Ask CanMesh first if a menu should grey the row out rather than let
// the write fail.
//
// No tolerance parameter: cadaclysm_node_save_mesh takes none, and neither does
// Python's save_mesh(path, fmt="stl") — its default is "stl", and this package has no
// defaults for a caller to lean on, so format is always spelled out here.
func (n *Node) SaveMesh(path, format string) error {
	if err := n.scene.closedError(); err != nil {
		return err
	}
	defer pin()()
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	cf := C.CString(format)
	defer C.free(unsafe.Pointer(cf))
	if !bool(C.cadaclysm_node_save_mesh(n.scene.h(), C.uint32_t(n.index), cp, cf)) {
		return &CadaclysmError{Message: lastErrorOr(fmt.Sprintf("could not write %s", path))}
	}
	return nil
}

// Colour is the (r, g, b, a) the file gave this node, if it gave one. None rather than a
// default: most STEP files carry no colour at all, and the honest answer lets the
// caller use its own.
func (n *Node) Colour() ([4]float32, bool) {
	var rgba [4]C.float
	ok := bool(C.cadaclysm_node_color(n.scene.h(), C.uint32_t(n.index), (*C.float)(unsafe.Pointer(&rgba[0]))))
	if !ok {
		return [4]float32{}, false
	}
	var out [4]float32
	for i := range rgba {
		out[i] = float32(rgba[i])
	}
	return out, true
}

// RawTransform is where this node's geometry sits, sixteen doubles in the ABI's own
// column-major order — the order OpenGL and every engine write. Doubles, while the mesh
// is floats, on purpose: a building at UTM coordinates baked into f32 world positions
// loses millimetres, where an f32 mesh about its own origin under an f64 transform does
// not.
func (n *Node) RawTransform() [16]float64 {
	var raw [16]C.double
	C.cadaclysm_node_transform(n.scene.h(), C.uint32_t(n.index), (*C.double)(unsafe.Pointer(&raw[0])))
	var out [16]float64
	for i := range raw {
		out[i] = float64(raw[i])
	}
	return out
}

// Transform is RawTransform in row-major order: Transform()[row*4+col] is
// RawTransform()[col*4+row], so M[0..2, 0..2] is the rotation and scale block and
// M[0..2, 3] is the offset — the textbook convention Python and C# use through numpy
// and a 2D array respectively, kept flat here for the reason RawTransform gives.
func (n *Node) Transform() [16]float64 {
	raw := n.RawTransform()
	var out [16]float64
	for col := 0; col < 4; col++ {
		for row := 0; row < 4; row++ {
			out[row*4+col] = raw[col*4+row]
		}
	}
	return out
}

// Bounds is the extent of the geometry this node draws, in that geometry's own frame.
// Builds the geometry if it has not been built. Carry it through Transform for world
// coordinates, exactly as with the mesh it bounds.
func (n *Node) Bounds() Bounds {
	b := C.cadaclysm_node_bounds(n.scene.h(), C.uint32_t(n.index))
	var out Bounds
	for i := 0; i < 3; i++ {
		out.Min[i] = float64(b.min[i])
		out.Max[i] = float64(b.max[i])
	}
	return out
}

// Mesh is this node's triangles, in their own frame, built now if they have not been —
// nil where the node has no triangles (structure, or geometry drawn only as curves).
// The error is non-nil only for a closed scene: nothing in the ABI reports this call
// failing otherwise, but the signature matches Node.Surfaces so both read the same way
// at the call site.
func (n *Node) Mesh() (*Mesh, error) {
	if err := n.scene.closedError(); err != nil {
		return nil, err
	}
	raw := C.cadaclysm_node_mesh(n.scene.h(), C.uint32_t(n.index))
	if raw.index_count == 0 || raw.positions == nil {
		return nil, nil
	}
	vertexFloats := int(raw.vertex_count) * 3
	m := &Mesh{
		Positions: unsafe.Slice((*float32)(unsafe.Pointer(raw.positions)), vertexFloats),
		Indices:   unsafe.Slice((*uint32)(unsafe.Pointer(raw.indices)), int(raw.index_count)),
	}
	if raw.normals != nil {
		m.Normals = unsafe.Slice((*float32)(unsafe.Pointer(raw.normals)), vertexFloats)
	}
	if raw.uvs != nil {
		m.Uvs = unsafe.Slice((*float32)(unsafe.Pointer(raw.uvs)), int(raw.vertex_count)*2)
	}
	if raw.colors != nil {
		m.Colours = unsafe.Slice((*float32)(unsafe.Pointer(raw.colors)), int(raw.vertex_count)*4)
	}
	return m, nil
}

// Surfaces is this node's faces as surfaces and trim loops, where the reader built them.
// Empty where the reader has no parametric read of this body or of this format. The
// error is non-nil only for a closed scene, as Mesh's.
func (n *Node) Surfaces() (*Surfaces, error) {
	if err := n.scene.closedError(); err != nil {
		return nil, err
	}
	raw := C.cadaclysm_node_surfaces(n.scene.h(), C.uint32_t(n.index))
	if raw.face_count == 0 {
		return &Surfaces{}, nil
	}
	faces := unsafe.Slice((*C.CadaclysmFace)(unsafe.Pointer(raw.faces)), int(raw.face_count))
	var loops []C.uint32_t
	if raw.loops != nil {
		loops = unsafe.Slice((*C.uint32_t)(unsafe.Pointer(raw.loops)), int(raw.loop_count)*2)
	}
	var points []C.float
	if raw.points != nil {
		points = unsafe.Slice((*C.float)(unsafe.Pointer(raw.points)), int(raw.point_count)*2)
	}
	var profiles []C.float
	if raw.profiles != nil {
		profiles = unsafe.Slice((*C.float)(unsafe.Pointer(raw.profiles)), int(raw.profile_count)*4)
	}
	var nurbs []C.float
	if raw.nurbs != nil {
		nurbs = unsafe.Slice((*C.float)(unsafe.Pointer(raw.nurbs)), int(raw.nurbs_count))
	}

	out := make([]Face, raw.face_count)
	for i := range out {
		f := faces[i]
		loopList := make([][]float32, f.loop_count)
		for k := uint32(0); k < uint32(f.loop_count); k++ {
			li := uint32(f.loop_start) + k
			start, length := uint32(loops[li*2]), uint32(loops[li*2+1])
			loop := make([]float32, length*2)
			for p := uint32(0); p < length*2; p++ {
				loop[p] = float32(points[start*2+p])
			}
			loopList[k] = loop
		}
		out[i] = Face{
			Kind:       uint32(f.kind),
			Reversed:   f.reversed != 0,
			Transposed: f.transposed != 0,
			Origin:     [3]float32{float32(f.origin[0]), float32(f.origin[1]), float32(f.origin[2])},
			Ax:         [3]float32{float32(f.ax[0]), float32(f.ax[1]), float32(f.ax[2])},
			Ay:         [3]float32{float32(f.ay[0]), float32(f.ay[1]), float32(f.ay[2])},
			Az:         [3]float32{float32(f.az[0]), float32(f.az[1]), float32(f.az[2])},
			Domain:     [4]float32{float32(f.domain[0]), float32(f.domain[1]), float32(f.domain[2]), float32(f.domain[3])},
			Scalars:    [4]float32{float32(f.scalars[0]), float32(f.scalars[1]), float32(f.scalars[2]), float32(f.scalars[3])},
			Loops:      loopList,
			Profile:    copyFloatRange(profiles, uint32(f.profile_start), uint32(f.profile_count), 4),
			Profile2:   copyFloatRange(profiles, uint32(f.profile2_start), uint32(f.profile2_count), 4),
			Nurbs:      copyFloatRange(nurbs, uint32(f.nurbs_start), uint32(f.nurbs_count), 1),
		}
	}
	return &Surfaces{Faces: out}, nil
}

// polylinesFrom is the shared body of Edges, Curves and Isocurves: raw is what one of
// the three cadaclysm_node_* entry points that return a CadaclysmPolylines gave back.
//
// A plain function taking the already-called struct, not a function value taking one of
// C.cadaclysm_node_edges/curves/isocurves themselves: cgo's generated bindings for a C
// function are call-only expressions, not first-class Go func values, so there is no
// func(*C.CadaclysmScene, C.uint32_t) C.CadaclysmPolylines to pass one of them as.
func polylinesFrom(raw C.CadaclysmPolylines) *Polylines {
	if raw.vertex_count == 0 || raw.positions == nil {
		return &Polylines{}
	}
	return &Polylines{
		Positions: unsafe.Slice((*float32)(unsafe.Pointer(raw.positions)), int(raw.vertex_count)*3),
		Counts:    unsafe.Slice((*uint32)(unsafe.Pointer(raw.counts)), int(raw.polyline_count)),
	}
}

// Edges is this node's feature edges, as polylines to draw an overlay from.
func (n *Node) Edges() *Polylines {
	return polylinesFrom(C.cadaclysm_node_edges(n.scene.h(), C.uint32_t(n.index)))
}

// Curves is this node's free curves, as polylines. A 2D drawing is all of these.
func (n *Node) Curves() *Polylines {
	return polylinesFrom(C.cadaclysm_node_curves(n.scene.h(), C.uint32_t(n.index)))
}

// Isocurves is this node's interior surface lines, as polylines — distinct from Edges:
// those bound the faces, these rule across them, so a curved face reads as curved
// rather than as a flat patch.
func (n *Node) Isocurves() *Polylines {
	return polylinesFrom(C.cadaclysm_node_isocurves(n.scene.h(), C.uint32_t(n.index)))
}

// Walk is this node and every node under it, parents before children.
func (n *Node) Walk() []*Node {
	out := make([]*Node, 0)
	stack := []*Node{n}
	for len(stack) > 0 {
		node := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		out = append(out, node)
		children := node.Children()
		for i := len(children) - 1; i >= 0; i-- {
			stack = append(stack, children[i])
		}
	}
	return out
}

// ---- the scene --------------------------------------------------------------------------

// Scene is an open document. Close it when done — everything it hands back borrows from
// it, see the package doc comment.
type Scene struct {
	handle     *C.CadaclysmScene
	label      string
	path       string
	schemaPath string
	convention Convention
}

// Close gives the scene back. Idempotent. Every Mesh and Polylines still held is reading
// freed memory afterwards.
//
// The error return is always nil: nothing in the ABI reports a close failing. It exists
// so Scene satisfies io.Closer and so a caller need not special-case this one call among
// every other resource it defers closing.
func (s *Scene) Close() error {
	if s.handle == nil {
		return nil
	}
	h := s.handle
	s.handle = nil
	C.cadaclysm_close(h)
	return nil
}

// Closed is whether Close has already run.
func (s *Scene) Closed() bool { return s.handle == nil }

// closedError is the *CadaclysmError a closed scene is refused with, or nil while it is
// open — what a method with an error return hands back (see the package doc).
func (s *Scene) closedError() error {
	if s.handle == nil {
		return &CadaclysmError{Message: s.label + ": the scene is closed"}
	}
	return nil
}

// h is the handle every call into the library reads through, so a closed scene is refused
// at the call site rather than handed to the library as nil: a panic carrying
// closedError, the rule the package doc states for an accessor with no error to return
// it in. A method that has one checks closedError first and never reaches the panic.
func (s *Scene) h() *C.CadaclysmScene {
	if err := s.closedError(); err != nil {
		panic(err)
	}
	return s.handle
}

// Path is the file this was read from — or, for a scene OpenMemory opened, the name it
// was given, as Python's Scene.path keeps it.
func (s *Scene) Path() string { return s.path }

// SchemaPath is the .exp actually used to open this, or "". Worth reporting when Open
// was given a directory and chose from it.
func (s *Scene) SchemaPath() string { return s.schemaPath }

// Convention is the packed Convention this scene was opened with — a Convention OR'd
// with FileUnits and UVWorld. Kept because nothing the ABI hands back says what space it
// is in, and every array out of this scene is in this one.
func (s *Scene) Convention() Convention { return s.convention }

// Version is the version of the library that read this scene.
func (s *Scene) Version() string { return Version() }

// Schema is the schema the file named, or "" for a format that names none.
func (s *Scene) Schema() string { return C.GoString(C.cadaclysm_schema(s.h())) }

// SchemaRead is the schema that actually read this file, which is not always the one it
// named — see Substituted.
func (s *Scene) SchemaRead() string { return C.GoString(C.cadaclysm_schema_read(s.h())) }

// Substituted is whether something other than the file's own schema read it. Compared
// on the bare names: a FILE_SCHEMA entry may carry a formal identifier and the library
// matches on the text before the braces, so comparing the whole entry would call every
// AP214 file substituted when nothing was substituted at all.
func (s *Scene) Substituted() bool {
	read := s.SchemaRead()
	if read == "" {
		return false
	}
	bare := func(entry string) string {
		entry = strings.SplitN(entry, "{", 2)[0]
		return strings.ToLower(strings.Trim(strings.TrimSpace(entry), "."))
	}
	target := bare(read)
	for _, part := range strings.Split(s.Schema(), ",") {
		if bare(part) == target {
			return false
		}
	}
	return true
}

// MetresPerUnit is what one length in the file is worth in metres, or 1 where it did not
// say.
func (s *Scene) MetresPerUnit() float64 { return float64(C.cadaclysm_metres_per_unit(s.h())) }

// Bounds is everything the model covers, in world coordinates — the one figure here not
// in a node's own frame. This meshes all of it, being the only way to know how far it
// reaches; a caller that has not the time should frame from the nodes it has built.
func (s *Scene) Bounds() Bounds {
	b := C.cadaclysm_bounds(s.h())
	var out Bounds
	for i := 0; i < 3; i++ {
		out.Min[i] = float64(b.min[i])
		out.Max[i] = float64(b.max[i])
	}
	return out
}

// Diagnostics is what this file held that the reader could not build.
func (s *Scene) Diagnostics() []string {
	n := uint32(C.cadaclysm_diagnostic_count(s.h()))
	out := make([]string, n)
	for i := uint32(0); i < n; i++ {
		out[i] = C.GoString(C.cadaclysm_diagnostic(s.h(), C.uint32_t(i)))
	}
	return out
}

// SourceName is the archive member this was read from, or "" for a plain file. Open on a
// .zip chose one member, and this is the only way to learn which.
func (s *Scene) SourceName() string {
	p := C.cadaclysm_source_name(s.h())
	if p == nil {
		return ""
	}
	return C.GoString(p)
}

// Nodes is every node, in index order.
func (s *Scene) Nodes() []*Node {
	n := uint32(C.cadaclysm_node_count(s.h()))
	out := make([]*Node, n)
	for i := uint32(0); i < n; i++ {
		out[i] = &Node{scene: s, index: i}
	}
	return out
}

// Query is the nodes a filter matches, in document order.
//
// The filter is one boolean expression over a node —
// "class == ON_Brep and within(class == ON_Layer and name == Walls)". Returns an error
// carrying the parser's own message if the filter will not parse. An empty result is not
// an error — a filter that matches nothing is a perfectly good answer, and the ABI
// distinguishes the two by whether it left a reason behind.
func (s *Scene) Query(filter string) ([]*Node, error) {
	if err := s.closedError(); err != nil {
		return nil, err
	}
	defer pin()()
	cf := C.CString(filter)
	defer C.free(unsafe.Pointer(cf))
	total := uint32(C.cadaclysm_query(s.h(), cf, nil, 0))
	if total == 0 {
		if reason := lastError(); reason != "" {
			return nil, &CadaclysmError{Message: fmt.Sprintf("%s: %s", s.label, reason)}
		}
		return nil, nil
	}
	buf := make([]uint32, total)
	written := uint32(C.cadaclysm_query(s.h(), cf, (*C.uint32_t)(unsafe.Pointer(&buf[0])), C.uint32_t(total)))
	if written > total {
		written = total
	}
	out := make([]*Node, written)
	for i := uint32(0); i < written; i++ {
		out[i] = &Node{scene: s, index: buf[i]}
	}
	return out, nil
}

// Placements is what this document draws and where — not the nodes, and the difference
// is the point. A node walk draws a Rhino block once at its definition's frame and every
// placement of it not at all; this is the list to iterate to draw.
func (s *Scene) Placements() []*Placement {
	n := uint32(C.cadaclysm_placement_count(s.h()))
	out := make([]*Placement, n)
	for i := uint32(0); i < n; i++ {
		out[i] = &Placement{scene: s, index: i}
	}
	return out
}

// Roots is the nodes nothing else contains.
func (s *Scene) Roots() []*Node {
	n := uint32(C.cadaclysm_root_count(s.h()))
	out := make([]*Node, 0, n)
	for i := uint32(0); i < n; i++ {
		idx := uint32(C.cadaclysm_root(s.h(), C.uint32_t(i)))
		if idx != noneIndex {
			out = append(out, &Node{scene: s, index: idx})
		}
	}
	return out
}

// Walk is every node reachable from the roots, parents before children.
func (s *Scene) Walk() []*Node {
	out := make([]*Node, 0)
	for _, root := range s.Roots() {
		out = append(out, root.Walk()...)
	}
	return out
}

// RealizeAll builds every mesh now, across threads, and returns how many were built.
// Reading is lazy so a caller can put the tree on screen while the shapes are still to
// come; asking node by node instead meshes them one at a time on one core, where this
// does the same work over every core.
func (s *Scene) RealizeAll() uint32 { return uint32(C.cadaclysm_realize_all(s.h())) }

// Realized is how many nodes RealizeAll has finished with. Safe to read from another
// goroutine.
func (s *Scene) Realized() uint32 { return uint32(C.cadaclysm_realized(s.h())) }

// RealizeTotal is how many there will be in all — zero until RealizeAll starts.
func (s *Scene) RealizeTotal() uint32 { return uint32(C.cadaclysm_realize_total(s.h())) }

// Cancel asks a running RealizeAll to stop. One-way, and for the life of the scene:
// every later RealizeAll on this scene returns 0 at once.
func (s *Scene) Cancel() { C.cadaclysm_cancel(s.h()) }

// Save writes the whole scene to path: "glb" (binary glTF), "gltf" (text glTF) or "obj"
// (Wavefront). Every placement of every shape, named and placed as the tree is, with a
// material per colour — where Node.SaveMesh writes one node's mesh on its own. Python's
// default format is "glb"; this package has no defaults, so format is always given.
func (s *Scene) Save(path, format string) error {
	if err := s.closedError(); err != nil {
		return err
	}
	defer pin()()
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	cf := C.CString(format)
	defer C.free(unsafe.Pointer(cf))
	if !bool(C.cadaclysm_scene_save(s.h(), cp, cf)) {
		return &CadaclysmError{Message: lastErrorOr(fmt.Sprintf("could not write %s", path))}
	}
	return nil
}

// SurfaceMatrix is the 4x4 that puts Node.Surfaces in the space everything else is
// already in, sixteen floats in the ABI's own column-major order. Only the surfaces need
// it: meshes, polylines and the scene's other products arrive in the convention the
// document was opened with; a surface does not, because converting one means converting
// its parameter space too. For a document opened Native at the file's own units this is
// the identity.
func (s *Scene) SurfaceMatrix() [16]float64 {
	var raw [16]C.float
	C.cadaclysm_surface_matrix(s.h(), (*C.float)(unsafe.Pointer(&raw[0])))
	var out [16]float64
	for i := range raw {
		out[i] = float64(raw[i])
	}
	return out
}
