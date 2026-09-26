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
// [FemMesh] is the one thing here that does not borrow from the scene: it is a handle of
// your own, and its arrays borrow from *it* — [Scene.Close] neither frees one nor stales one,
// and neither does [Scene.ForgetMeshes]. They are unsafe.Slice struct fields there too, with
// the same sharp edge and for the same reason, so hold the FemMesh itself while you read
// them; its own doc comment says what that does and does not protect you from.
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

// LodLevels is how many coarser levels Node.MeshLod offers above the mesh itself (level 0).
func LodLevels() uint32 { return uint32(C.cadaclysm_lod_levels()) }

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

// MeshFormat is one format Node.SaveMesh writes, as a name ("stl"), the extension it
// writes ("stl") -- carried separately because the two are not always the same word:
// "stl-ascii" writes a .stl -- and a label for a menu ("STL (binary)").
type MeshFormat struct {
	Name      string
	Extension string
	Label     string
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
			Label:     C.GoString(C.cadaclysm_mesh_format_label(C.uint32_t(i))),
		}
	}
	return out
}

// Format is one format this build reads: its name and the extensions its files take.
type Format struct {
	Name       string
	Extensions []string
}

// Formats is every format this build reads, for an open dialog's filter. The library
// hands the extensions over semicolon-separated; they are split here.
func Formats() []Format {
	n := uint32(C.cadaclysm_format_count())
	out := make([]Format, n)
	for i := uint32(0); i < n; i++ {
		joined := C.GoString(C.cadaclysm_format_extensions(C.uint32_t(i)))
		var extensions []string
		for _, e := range strings.Split(joined, ";") {
			if e != "" {
				extensions = append(extensions, e)
			}
		}
		out[i] = Format{Name: C.GoString(C.cadaclysm_format_name(C.uint32_t(i))), Extensions: extensions}
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

// PickSave asks the user where to save, through the library's own dialog, with
// suggestedName prefilled. The second return is false if they cancelled or no dialog
// was available. Blocks; on macOS it must be called from the main thread.
func PickSave(suggestedName string) (string, bool) {
	name := C.CString(suggestedName)
	defer C.free(unsafe.Pointer(name))
	p := C.cadaclysm_pick_save(nil, name)
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

// Mesh64 is [Mesh] in double: the document's own mesh, lent **as it is**, where Node.Mesh
// hands back a float32 copy of it -- the float32 positions are exactly these narrowed.
// For a caller that uses the mesh as geometry (an exporter, a measurement, a solver) and
// wants the file's own coordinates, which float32 cannot hold far from the origin.
//
// Colours stay float32 (RGBA in 0..1 needs no more). Shares Indices' very pointer with
// Mesh.
//
// A forget drops it: the pointers borrow the document's own mesh, which
// Scene.ForgetMeshes frees -- read none of them after a forget; ask again, and the mesh
// is built again. (Mesh's float32 copy survives a forget, its own memory being kept.)
type Mesh64 struct {
	Positions []float64
	Normals   []float64
	Uvs       []float64
	Colours   []float32
	Indices   []uint32
}

// TriangleCount is len(Indices) / 3.
func (m *Mesh64) TriangleCount() int { return len(m.Indices) / 3 }

func meshFrom64(raw C.CadaclysmMesh64) *Mesh64 {
	if raw.index_count == 0 || raw.positions == nil {
		return nil
	}
	vertexFloats := int(raw.vertex_count) * 3
	m := &Mesh64{
		Positions: unsafe.Slice((*float64)(unsafe.Pointer(raw.positions)), vertexFloats),
		Indices:   unsafe.Slice((*uint32)(unsafe.Pointer(raw.indices)), int(raw.index_count)),
	}
	if raw.normals != nil {
		m.Normals = unsafe.Slice((*float64)(unsafe.Pointer(raw.normals)), vertexFloats)
	}
	if raw.uvs != nil {
		m.Uvs = unsafe.Slice((*float64)(unsafe.Pointer(raw.uvs)), int(raw.vertex_count)*2)
	}
	if raw.colors != nil {
		m.Colours = unsafe.Slice((*float32)(unsafe.Pointer(raw.colors)), int(raw.vertex_count)*4)
	}
	return m
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

// Beziers is a node's edges, curves or isocurves as cubic Bézier curves -- exact where the
// file's curves were, where Polylines are their chords. A view over the scene's own
// memory, valid until Scene.Close.
//
// Points is (count * 4 * 3) float32: four control points a curve. Weights is (count * 4):
// a weight per control point, all ones for a polynomial curve and the weights that make
// a circular arc exact for a rational one.
type Beziers struct {
	Points  []float32
	Weights []float32
}

// Count is how many curves this holds.
func (b *Beziers) Count() int { return len(b.Weights) / 4 }

// BeziersData is a Beziers copied into memory of the caller's own.
type BeziersData struct {
	Points  []float32
	Weights []float32
}

// Copy is the same curves in memory of our own, safe to outlive the scene.
func (b *Beziers) Copy() BeziersData {
	return BeziersData{Points: append([]float32(nil), b.Points...), Weights: append([]float32(nil), b.Weights...)}
}

func beziersFrom(raw C.CadaclysmBeziers) *Beziers {
	if raw.count == 0 || raw.points == nil {
		return &Beziers{}
	}
	return &Beziers{
		Points:  unsafe.Slice((*float32)(unsafe.Pointer(raw.points)), int(raw.count)*12),
		Weights: unsafe.Slice((*float32)(unsafe.Pointer(raw.weights)), int(raw.count)*4),
	}
}

// Beziers64 is [Beziers] in double: the same segments, unnarrowed -- the float32 ones are
// these narrowed. A view over the scene's own memory, valid until Scene.Close.
type Beziers64 struct {
	Points  []float64
	Weights []float64
}

// Count is how many curves this holds.
func (b *Beziers64) Count() int { return len(b.Weights) / 4 }

// BeziersData64 is a Beziers64 copied into memory of the caller's own.
type BeziersData64 struct {
	Points  []float64
	Weights []float64
}

// Copy is the same curves in memory of our own, safe to outlive the scene.
func (b *Beziers64) Copy() BeziersData64 {
	return BeziersData64{Points: append([]float64(nil), b.Points...), Weights: append([]float64(nil), b.Weights...)}
}

func beziersFrom64(raw C.CadaclysmBeziers64) *Beziers64 {
	if raw.count == 0 || raw.points == nil {
		return &Beziers64{}
	}
	return &Beziers64{
		Points:  unsafe.Slice((*float64)(unsafe.Pointer(raw.points)), int(raw.count)*12),
		Weights: unsafe.Slice((*float64)(unsafe.Pointer(raw.weights)), int(raw.count)*4),
	}
}

// Collision is what a node turned out to be for a physics engine: a box, sphere,
// capsule or cylinder where one fits within Error, else a convex hull. Frame
// (column-major) and HalfExtent are always the true oriented box. Plain data, copied
// out of the scene.
type Collision struct {
	Shape, Confidence, Axis         uint32
	Frame                           [16]float64
	HalfExtent                      [3]float64
	Radius, Height, Error           float64
	HullVertexCount, HullIndexCount uint32
}

var collisionNames = [...]string{"none", "box", "sphere", "capsule", "cylinder", "hull"}

// ShapeName is "none", "box", "sphere", "capsule", "cylinder" or "hull".
func (c *Collision) ShapeName() string {
	if int(c.Shape) < len(collisionNames) {
		return collisionNames[c.Shape]
	}
	return strconv.Itoa(int(c.Shape))
}

// CollisionHull is a node's convex hull for a physics engine, as triangles -- a view
// over the scene's own memory, valid until Scene.Close.
type CollisionHull struct {
	Positions []float32
	Indices   []uint32
}

// VertexCount is len(Positions) / 3.
func (h *CollisionHull) VertexCount() int { return len(h.Positions) / 3 }

// IndexCount is len(Indices).
func (h *CollisionHull) IndexCount() int { return len(h.Indices) }

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

// ---- kinematics -------------------------------------------------------------------------

// Link is a rigid body of the file's mechanism: the nodes that move together when a
// joint moves it. From Scene.Links; other formats record none. Unlike Placement, this
// keeps no Scene accessor of its own: a caller keeps the *Scene it opened, the same way
// Placement and Node already ask it to.
type Link struct {
	scene *Scene
	index uint32
}

// Index is this link's position in Scene.Links() -- Python's link.index, a public
// attribute there for the same reason this is a method here: a caller keying a map of
// links, or comparing against the file's own numbering, needs a stable identity.
func (l *Link) Index() uint32 { return l.index }

// Name is the link's own name, as the file gives it.
func (l *Link) Name() string {
	return C.GoString(C.cadaclysm_link_name(l.scene.h(), C.uint32_t(l.index)))
}

// Nodes are the topmost node of each subtree the link moves, in node order: moving
// these moves everything under them.
func (l *Link) Nodes() []*Node {
	h := l.scene.h()
	n := uint32(C.cadaclysm_link_node_count(h, C.uint32_t(l.index)))
	out := make([]*Node, n)
	for i := uint32(0); i < n; i++ {
		out[i] = &Node{scene: l.scene, index: uint32(C.cadaclysm_link_node(h, C.uint32_t(l.index), C.uint32_t(i)))}
	}
	return out
}

// Joint is a connection between two links. Its two ends keep the file's order, not a
// parent and a child, since a mechanism may be a network with loops. From Scene.Joints.
type Joint struct {
	scene *Scene
	index uint32
}

// Index is this joint's position in Scene.Joints() -- Python's joint.index, a public
// attribute there for the same reason this is a method here: a caller keying a map of
// joints, or comparing against the file's own numbering, needs a stable identity.
func (j *Joint) Index() uint32 { return j.index }

// Name is the joint's own name, as the file gives it.
func (j *Joint) Name() string {
	return C.GoString(C.cadaclysm_joint_name(j.scene.h(), C.uint32_t(j.index)))
}

// Start is the link this joint starts at, in the file's order.
func (j *Joint) Start() *Link {
	return &Link{scene: j.scene, index: uint32(C.cadaclysm_joint_start(j.scene.h(), C.uint32_t(j.index)))}
}

// End is the link this joint ends at, as Start gives its other end.
func (j *Joint) End() *Link {
	return &Link{scene: j.scene, index: uint32(C.cadaclysm_joint_end(j.scene.h(), C.uint32_t(j.index)))}
}

// ---- breps -------------------------------------------------------------------------------

// Brep is a body's exact B-rep -- the trimmed surfaces its mesh is cut from -- shared with
// the scene rather than copied: a reference of this value's own, given back by Close (or
// the finalizer). It is for the blacksmith library, which operates on it without a copy
// (blacksmith.FromNode), and for asking whether it is a manifold ([Brep.Manifold]). It
// outlives its scene for as long as
// anything holds it. In the node's own frame and the file's own units and axes, whatever
// convention the scene was opened with. The blacksmith library must come from the same
// release; it checks [BrepLayoutID] and refuses otherwise.
type Brep struct {
	ptr *C.CadaclysmBrep
}

// BrepLayoutID is how this library lays a brep out in memory: its compiler, target and
// source. The blacksmith library shares a brep only with a library whose id equals its own.
func BrepLayoutID() string { return C.GoString(C.cadaclysm_brep_layout_id()) }

// Pointer is the brep's C pointer, for blacksmith.FromNode to hand across; nil once
// closed.
func (b *Brep) Pointer() unsafe.Pointer {
	if b == nil {
		return nil
	}
	return unsafe.Pointer(b.ptr)
}

// Manifold says whether its faces make a manifold — every edge bordered by one face or
// two, the faces round every vertex one fan — and whether it is closed. Read off the
// topology the file wrote, not a mesh: faces that name no shared edge (IGES, each surface
// its own sheet; an IFC face written as one polygon) read as open however well they meet
// in space.
func (b *Brep) Manifold() (Manifold, error) {
	defer pin()()
	if b == nil || b.ptr == nil {
		return Manifold{}, &CadaclysmError{Message: "brep: released"}
	}
	var row [8]uint32
	ok := bool(C.cadaclysm_brep_manifold(b.ptr, (*C.uint32_t)(unsafe.Pointer(&row[0]))))
	runtime.KeepAlive(b)
	if !ok {
		return Manifold{}, &CadaclysmError{Message: lastErrorOr("manifold")}
	}
	return ManifoldOf(row), nil
}

// Manifold is whether a brep's or a solid's faces make a manifold, as plain data
// ([Brep.Manifold], and the blacksmith package's Solid.Manifold): its faces, edges and
// vertices; the edges one face borders (a sheet's rim), the edges three or more do, and
// the vertices whose faces make more than one fan (two solids touching at a corner).
// IsManifold where there are none of the last two, IsClosed where there is no boundary
// edge either — it encloses a solid.
type Manifold struct {
	Faces, Edges, Vertices                               int
	BoundaryEdges, NonManifoldEdges, NonManifoldVertices int
	IsManifold, IsClosed                                 bool
}

// ManifoldOf reads the eight counts cadaclysm_brep_manifold and
// cadaclysm_blacksmith_manifold write, in their order.
func ManifoldOf(row [8]uint32) Manifold {
	return Manifold{
		Faces: int(row[0]), Edges: int(row[1]), Vertices: int(row[2]),
		BoundaryEdges: int(row[3]), NonManifoldEdges: int(row[4]), NonManifoldVertices: int(row[5]),
		IsManifold: row[6] == 1, IsClosed: row[7] == 1,
	}
}

// Close gives this reference back. Idempotent, and a no-op on a nil Brep. The error
// return is always nil; it exists so a Brep defers like every other resource.
func (b *Brep) Close() error {
	if b == nil || b.ptr == nil {
		return nil
	}
	p := b.ptr
	b.ptr = nil
	runtime.SetFinalizer(b, nil)
	C.cadaclysm_brep_release(p)
	return nil
}

// Meshlet is one meshlet, copied out: the slices are yours.
type Meshlet struct {
	Index, Level, Group        int
	Error                      float32
	VertexCount, TriangleCount int
	Positions, Normals         []float32
	Indices, Children          []uint32
}

// Meshlets is a mesh split into meshlets, optionally with coarser levels above them,
// for a mesh-shader or meshlet-based renderer. Built from any mesh and owned by the
// caller: Close it.
type Meshlets struct {
	handle *C.CadaclysmMeshlets
}

// BuildMeshlets splits positions (three floats a vertex), normals (the same, or nil)
// and indices (three a triangle) into meshlets of at most maxTriangles and maxVertices
// each -- the consumer's own limits, with no default: Nanite takes 128/256, a
// mesh-shader pipeline 124/64. levels above 0 groups and simplifies each level into
// the next until one meshlet is left.
func BuildMeshlets(positions, normals []float32, indices []uint32, maxTriangles, maxVertices uint32, levels int32) (*Meshlets, error) {
	defer pin()() // the call and the lastError read after it on one OS thread
	if maxTriangles == 0 || maxVertices == 0 {
		return nil, &CadaclysmError{Message: "meshlets: maxTriangles and maxVertices are required"}
	}
	if len(positions)%3 != 0 || len(indices)%3 != 0 {
		return nil, &CadaclysmError{Message: "meshlets: positions must hold three floats a vertex and indices three a triangle"}
	}
	if normals != nil && len(normals) != len(positions) {
		return nil, &CadaclysmError{Message: "meshlets: normals must hold one per vertex, three floats each"}
	}
	var normalsPtr *C.float
	if len(normals) > 0 {
		normalsPtr = (*C.float)(unsafe.Pointer(&normals[0]))
	}
	var positionsPtr *C.float
	if len(positions) > 0 {
		positionsPtr = (*C.float)(unsafe.Pointer(&positions[0]))
	}
	var indicesPtr *C.uint32_t
	if len(indices) > 0 {
		indicesPtr = (*C.uint32_t)(unsafe.Pointer(&indices[0]))
	}
	h := C.cadaclysm_meshlets_build(positionsPtr, normalsPtr, C.size_t(len(positions)/3), indicesPtr, C.size_t(len(indices)),
		C.uint32_t(maxTriangles), C.uint32_t(maxVertices), C.int32_t(levels))
	runtime.KeepAlive(positions)
	runtime.KeepAlive(normals)
	runtime.KeepAlive(indices)
	if h == nil {
		return nil, &CadaclysmError{Message: lastErrorOr("meshlets: build failed")}
	}
	m := &Meshlets{handle: h}
	runtime.SetFinalizer(m, (*Meshlets).Close)
	return m, nil
}

func (m *Meshlets) h() *C.CadaclysmMeshlets {
	if m.handle == nil {
		panic(&CadaclysmError{Message: "meshlets: freed"})
	}
	return m.handle
}

// Closed is whether Close has run.
func (m *Meshlets) Closed() bool { return m.handle == nil }

// Close gives the meshlets back. Idempotent; the collector does it otherwise.
func (m *Meshlets) Close() {
	if m.handle != nil {
		C.cadaclysm_meshlets_free(m.handle)
		m.handle = nil
		runtime.SetFinalizer(m, nil)
	}
}

// Count is how many meshlets, every level counted.
func (m *Meshlets) Count() int { return int(C.cadaclysm_meshlets_count(m.h())) }

func (m *Meshlets) TriangleCount(i int) int {
	return int(C.cadaclysm_meshlet_triangle_count(m.h(), C.uint32_t(i)))
}
func (m *Meshlets) VertexCount(i int) int {
	return int(C.cadaclysm_meshlet_vertex_count(m.h(), C.uint32_t(i)))
}

// Level is 0 for a leaf over the mesh itself, higher for a simplified level above it.
func (m *Meshlets) Level(i int) int { return int(C.cadaclysm_meshlet_level(m.h(), C.uint32_t(i))) }
func (m *Meshlets) Group(i int) int { return int(C.cadaclysm_meshlet_group(m.h(), C.uint32_t(i))) }
func (m *Meshlets) Error(i int) float32 {
	return float32(C.cadaclysm_meshlet_error(m.h(), C.uint32_t(i)))
}
func (m *Meshlets) ChildCount(i int) int {
	return int(C.cadaclysm_meshlet_child_count(m.h(), C.uint32_t(i)))
}

// Meshlet is one meshlet's arrays and numbers, copied out.
func (m *Meshlets) Meshlet(i int) Meshlet {
	h := m.h()
	idx := C.uint32_t(i)
	out := Meshlet{
		Index: i, Level: int(C.cadaclysm_meshlet_level(h, idx)), Group: int(C.cadaclysm_meshlet_group(h, idx)),
		Error:       float32(C.cadaclysm_meshlet_error(h, idx)),
		VertexCount: int(C.cadaclysm_meshlet_vertex_count(h, idx)), TriangleCount: int(C.cadaclysm_meshlet_triangle_count(h, idx)),
	}
	childCount := int(C.cadaclysm_meshlet_child_count(h, idx))
	out.Positions = make([]float32, out.VertexCount*3)
	out.Normals = make([]float32, out.VertexCount*3)
	out.Indices = make([]uint32, out.TriangleCount*3)
	out.Children = make([]uint32, childCount)
	if out.VertexCount > 0 {
		C.cadaclysm_meshlet_positions(h, idx, (*C.float)(unsafe.Pointer(&out.Positions[0])))
		C.cadaclysm_meshlet_normals(h, idx, (*C.float)(unsafe.Pointer(&out.Normals[0])))
	}
	if out.TriangleCount > 0 {
		C.cadaclysm_meshlet_indices(h, idx, (*C.uint32_t)(unsafe.Pointer(&out.Indices[0])))
	}
	if childCount > 0 {
		C.cadaclysm_meshlet_children(h, idx, (*C.uint32_t)(unsafe.Pointer(&out.Children[0])))
	}
	return out
}

// ---- the FEM surface mesh -----------------------------------------------------------

// FemEdge is one B-rep edge of a FEM mesh: the chain of nodes along it, and where that
// chain breaks. Plain data, copied out of the handle, so an edge outlives the mesh it came
// from where the flat arrays on [FemMesh] do not.
//
// Nodes are this mesh's node indices in order along the edge, its end vertices included; a
// closed edge repeats no node. **Runs says where the chain breaks**: read
// Nodes[Runs[i]:Runs[i+1]] (the last run to the end) as one polyline and join nothing
// across a run boundary — the two ends either side of one are two points of the edge with
// no mesh edge between them, a crack along the edge or a stretch of it the mesher sampled
// on one face only. One run beginning at 0 is the ordinary answer, and a caller reading
// Nodes as one polyline without looking here jumps the gap silently.
//
// Faces is (face_a, face_b) and Ends is (end_a, end_b), the second of each ^uint32(0) —
// CADACLYSM_NONE, 0xFFFFFFFF — where there is none: an open body's rim, or both ends at one
// vertex (a closed edge, a circle's rim, a full-turn seam). **0 is a real face and a real
// vertex, not a sentinel.** Which end comes first is the first trim's direction and means
// nothing else: the pair bounds the edge, it does not orient it.
//
// Closed where the nodes make one loop, never where there is more than one run. Seam where
// one face bounds the edge twice — a closed surface's seam rather than a real boundary — and
// both Faces are then that same face.
//
// ID is **the body's own B-rep edge id, not this mesh's edge index**: FemMesh.Edges is a
// densely renumbered subset of the body's edges, ascending by id, with every edge collapsed
// to a point left out, so edge 0 of a STEP body's mesh routinely has an ID in the hundreds.
// Everything else here that names an edge means the index — a NodeKind of 1 read through
// NodeEntity, the third number of an OpenEdges or FoldedEdges row, and the edge_<i> physical
// group of MshText — and this is the one way back from any of them to the topology the file
// wrote.
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
// trims meet, and a pole's polyline runs give a sphere 48 of them where the mesh has 2
// points, so a caller walking these skips the sentinel rather than reading it as a gap.
//
// Point is where the vertex is, in the same space and under the same placement as
// FemMesh.Nodes — the file's own vertex rather than a mesh node, so the two can differ by
// the reader's rounding. **Meaningless unless HasPosition**: it is all zeros then, a point
// no geometry has and one a solver would take for a node at the origin.
type FemVertex struct {
	Node        uint32
	Point       [3]float64
	HasPosition bool
}

// String is Python's FemVertex.__repr__.
func (v FemVertex) String() string {
	return fmt.Sprintf("FemVertex(node=%d, point=%v, has_position=%v)", v.Node, v.Point, v.HasPosition)
}

// FemMesh is one body meshed for a solver: nodes welded by bits — two mesh points are one
// node only where their coordinates are the same doubles, so no tolerance ever merges two
// distinct points and a crack stays a crack — triangles wound outward, every node tagged
// with the lowest-dimension B-rep entity it lies on, and every crack reported rather than
// closed. What [Node.FemMesh] returns, and **owned by you**: Close it, or let the finalizer.
//
// # The arrays borrow, and the fields cannot refuse
//
// Nodes, Triangles, TriangleFace, NodeKind and NodeEntity are slices built with unsafe.Slice
// straight over the library's own memory rather than copies, exactly as [Mesh]'s and
// [Mesh64]'s are and for the reason the package doc gives: a solver mesh is megabytes, and
// copying it to hand it over would cost that twice. They are struct fields, handed over
// once, with no accessor to guard them — **so nothing here refuses to read them after
// Close**, and a slice read then is a slice over freed memory. There is no way in Go to mark
// a slice's backing memory read-only or to tie its lifetime to the handle's, so this sharp
// edge is documented rather than enforced, exactly as the package doc leaves it for the
// scene and exactly as the Python client this package mirrors leaves the same case. Copy
// (append([]float64(nil), m.Nodes...)) anything that must outlive the mesh.
//
// The eight methods below *can* tell, because each hands the handle back to the library:
// Edges, Vertices, OpenEdges, FoldedEdges, MshText and SaveMsh each return a
// *CadaclysmError saying "fem mesh: freed" once Close has run.
//
// **Hold the FemMesh itself while you read its arrays.** The arrays are fields of the
// handle, so a program that keeps the *FemMesh keeps the memory: that is why they live here
// rather than on a view struct of their own. What the collector can still free under you is
// a slice copied out of a field by a program that then drops its last reference to the
// *FemMesh — the finalizer runs, cadaclysm_fem_mesh_free is called, and nothing in the
// program ever asked for it. Java and LuaJIT have the same hazard for the same reason; Go
// cannot close it.
//
// # Its own lifetime, not the scene's
//
// [Scene.Close] neither frees a FEM mesh nor stales one, and [Scene.ForgetMeshes] does not
// either: the handle owns its arrays outright, where [Mesh]'s borrow the scene's. Only Close
// on this object, or the finalizer, frees them.
type FemMesh struct {
	handle *C.CadaclysmFemMesh

	// Nodes is every node's position, three float64 each — placed, and in the space
	// Node.FemMesh and FromMesh describe. Every node is used by at least one triangle.
	Nodes []float64
	// Triangles is three node indices a triangle, wound outward; a mirroring placement is
	// wound back.
	Triangles []uint32
	// TriangleFace is which B-rep face each triangle lies on, one per triangle, into the
	// body's FaceCount faces.
	TriangleFace []uint32
	// NodeKind is what each node lies on — 0 a B-rep vertex, 1 an edge, 2 a face — one per
	// node: the lowest-dimension entity it lies on, which is the .msh format's own
	// classification rule. NodeEntity says which entity of that kind.
	NodeKind []uint32
	// NodeEntity is which vertex, edge or face each node lies on, read by the matching
	// NodeKind: an index into Vertices, into Edges, or into the body's faces.
	NodeEntity []uint32

	// FaceCount is the body's faces; TriangleFace and a NodeKind of 2 index them. The same
	// faces Node.Surfaces hands over, in the same order.
	FaceCount uint32
	// Watertight is that the welded mesh closes — every directed mesh edge paired with its
	// reverse and none used twice — and, for a B-rep body, that the topology behind it does
	// too. **False for every B-rep body whose topology is not closed**, whose mesh is then
	// not asked about at all; see OpenEdges for what an empty census beside a false here
	// does and does not mean. A FromMesh body has no topology to ask of, so this says only
	// that its triangles close.
	Watertight bool
	// FromMesh is that this came from the scene's own mesh rather than from a brep: one
	// face, every node on face 0, no edges and no vertices.
	//
	// **It is also which space the mesh is in.** A B-rep body's FEM mesh is in the file's own
	// units and axes, whatever Convention the scene was opened with, because it is taken off
	// the brep — and a brep is in the file's own space for the reason Node.Brep gives. A node
	// with no brep falls back to the scene's mesh, which *is* converted, so that one comes
	// back in the scene's convention, wound counter-clockwise about the outward normal even
	// where the convention winds the other way. Under a convention other than the native one
	// those are two different spaces, so a caller mixing these nodes with Node.Transform on
	// a Y-up scene gets a rotated part unless it reads this.
	//
	// **And it is which contract the census is reporting under**: see OpenEdges.
	FromMesh bool
	// MinAngle is the smallest interior angle of any triangle, in degrees. There is always
	// one: a body that meshed to no triangles is a refusal, not a mesh.
	MinAngle float64
	// WorstTriangle is the triangle with that angle, as an index into Triangles.
	WorstTriangle uint32
	// LongestEdge is the longest triangle edge, placed. **The figure to check against
	// Node.FemMesh's maxSize, and the only one that says what the mesh actually is**: maxSize
	// bounds the boundary segments and merely targets the interior — 1.03 x maxSize was
	// measured on a face whose parameters run unevenly — and one small enough beside the body
	// to reach the mesher's own piece and station ceilings is not honoured at all.
	LongestEdge float64

	// The counts the four row readers loop to. Not exported: Edges/Vertices/OpenEdges/
	// FoldedEdges hand back the rows themselves, and len() on those is the count, as it is
	// everywhere else in this package.
	edgeCount, vertexCount, openEdgeCount, foldedEdgeCount uint32
}

// femMeshFrom reads the view once and wraps the handle, freeing it if the view is refused.
//
// Read once, here, rather than per field: every pointer in the view is built with the handle
// and never moves — nothing in this ABI is built lazily — so asking again would be one C
// call for the same answer. There is no generation to check either, which is what the kernel
// package's Mesh needs for the solid's tessellation cache and what a FEM mesh has no
// equivalent of.
func femMeshFrom(handle *C.CadaclysmFemMesh) (*FemMesh, error) {
	var raw C.CadaclysmFemMeshView
	if !bool(C.cadaclysm_fem_mesh_view(handle, &raw)) {
		why := lastErrorOr("fem mesh view")
		C.cadaclysm_fem_mesh_free(handle)
		return nil, &CadaclysmError{Message: why}
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
	runtime.SetFinalizer(m, (*FemMesh).Close)
	return m, nil
}

// h is the live handle, refusing to hand over a freed one, so a use-after-free returns an
// error at the call site instead of passing a dangling pointer into the library. Every
// method that hands the handle to C goes through it; the struct fields cannot, which is the
// sharp edge [FemMesh] documents.
func (m *FemMesh) h() (*C.CadaclysmFemMesh, error) {
	if m == nil || m.handle == nil {
		return nil, &CadaclysmError{Message: "fem mesh: freed"}
	}
	return m.handle, nil
}

// Closed is whether Close has run. A nil *FemMesh — what a failed Node.FemMesh returns
// beside its error — counts as closed.
func (m *FemMesh) Closed() bool { return m == nil || m.handle == nil }

// Close gives the mesh back, and with it every slice on it and the .msh text the library
// holds for it. Idempotent, and a no-op on a nil *FemMesh, so a Close deferred before the
// error is checked cannot panic. The error return is always nil; it exists so a FemMesh
// defers like every other resource here and satisfies io.Closer, as [Brep] and the kernel
// package's Solid do.
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
	C.cadaclysm_fem_mesh_free(h)
	return nil
}

// copyFemIndices is n uint32 at p in memory of our own: what a FemEdge's Nodes and Runs
// hold, so an edge read out of a mesh outlives the mesh. Cheap — an edge's chain is tens of
// numbers where the flat arrays are millions, which is why these are copied and those lent.
func copyFemIndices(p *C.uint32_t, n int) []uint32 {
	if p == nil || n <= 0 {
		return nil
	}
	return append([]uint32(nil), unsafe.Slice((*uint32)(unsafe.Pointer(p)), n)...)
}

// Edges is one [FemEdge] per B-rep edge, in the order a NodeKind of 1 indexes them. Empty
// for a FromMesh body, which has no B-rep edges at all.
//
// **This list's own numbering, not the body's**: each FemEdge.ID carries the body's own edge
// id. Built fresh on every call, one C call an edge, so read it once and keep it.
func (m *FemMesh) Edges() ([]FemEdge, error) {
	defer pin()() // the calls and the lastError read after them on one OS thread
	h, err := m.h()
	if err != nil {
		return nil, err
	}
	out := make([]FemEdge, 0, m.edgeCount)
	var raw C.CadaclysmFemEdge
	for i := uint32(0); i < m.edgeCount; i++ {
		if !bool(C.cadaclysm_fem_mesh_edge(h, C.uint32_t(i), &raw)) {
			runtime.KeepAlive(m)
			return nil, &CadaclysmError{Message: lastErrorOr(fmt.Sprintf("fem mesh edge %d", i))}
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
	// a finalizer running here would free the handle the library is reading. Java's
	// reachabilityFence, in Go's spelling.
	runtime.KeepAlive(m)
	return out, nil
}

// Vertices is one [FemVertex] per B-rep vertex, in the order a NodeKind of 0 indexes them.
// Empty for a FromMesh body.
func (m *FemMesh) Vertices() ([]FemVertex, error) {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return nil, err
	}
	out := make([]FemVertex, 0, m.vertexCount)
	var raw C.CadaclysmFemVertex
	for i := uint32(0); i < m.vertexCount; i++ {
		if !bool(C.cadaclysm_fem_mesh_vertex(h, C.uint32_t(i), &raw)) {
			runtime.KeepAlive(m)
			return nil, &CadaclysmError{Message: lastErrorOr(fmt.Sprintf("fem mesh vertex %d", i))}
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
// **Empty unless the body's topology is closed — for a B-rep body**, whose mesh is otherwise
// not asked about at all. The census asks whether a body that ought to enclose a solid does,
// and an open one — a sheet, a bag of surfaces, a shell the file itself wrote open — makes no
// such claim to check: its rim is not a crack. So such a body reports Watertight false with
// this and FoldedEdges both empty, and **that trio of answers together** says "not asked",
// not "nothing found".
//
// **A FromMesh body is the exception, and the opposite case.** A bare mesh carries no
// topology to say whether it ought to close, so its census always runs over the welded
// triangles: an open one lists its cracks here with Watertight false, a closed one reports
// Watertight true with no topology consulted at all, and an empty census there really does
// mean "nothing found".
func (m *FemMesh) OpenEdges() ([][3]uint32, error) { return m.census(true) }

// FoldedEdges is every fold, as OpenEdges reports a crack: a directed mesh edge used by more
// than one triangle, once.
//
// **A body can be folded without being open** — a solid no thicker than a line leaves no hole
// for an open edge to find — and the closure census's own known-bad bodies are folds rather
// than open cracks. A caller that checks OpenEdges alone calls such a body sound. Empty
// under the same rule as OpenEdges.
func (m *FemMesh) FoldedEdges() ([][3]uint32, error) { return m.census(false) }

// census is the shared body of OpenEdges and FoldedEdges, so the two cannot drift.
//
// A bool rather than a func value naming one of the two entry points: cgo's generated
// bindings for a C function are call-only expressions, not first-class Go func values, the
// same reason polylinesFrom above takes an already-called struct.
func (m *FemMesh) census(openEdges bool) ([][3]uint32, error) {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return nil, err
	}
	count, what := m.foldedEdgeCount, "folded edge"
	if openEdges {
		count, what = m.openEdgeCount, "open edge"
	}
	out := make([][3]uint32, 0, count)
	for i := uint32(0); i < count; i++ {
		var row [3]C.uint32_t
		var ok C.bool
		if openEdges {
			ok = C.cadaclysm_fem_mesh_open_edge(h, C.uint32_t(i), &row[0], &row[1], &row[2])
		} else {
			ok = C.cadaclysm_fem_mesh_folded_edge(h, C.uint32_t(i), &row[0], &row[1], &row[2])
		}
		if !bool(ok) {
			runtime.KeepAlive(m)
			return nil, &CadaclysmError{Message: lastErrorOr(fmt.Sprintf("fem mesh %s %d", what, i))}
		}
		out = append(out, [3]uint32{uint32(row[0]), uint32(row[1]), uint32(row[2])})
	}
	runtime.KeepAlive(m)
	return out, nil
}

// MshText is the mesh as Gmsh 4.1 ASCII .msh text: an entity per B-rep vertex, edge and
// face, a volume where the body closes, and a physical group naming each.
//
// **The library's text is borrowed from this handle** and replaced by the next call on it —
// this ABI's convention, and the opposite of the kernel package's, where
// cadaclysm_blacksmith_fem_mesh_msh_text hands over an owned string the wrapper releases
// with cadaclysm_blacksmith_string_free. Nothing here has to free anything either way:
// C.GoString copies the char* into a Go string on the way out, so what comes back is a
// string of your own that outlives the handle. A reader porting one side's reasoning onto
// the other leaks or double-frees.
//
// **No unlicensed notice is printed here.** [Node.FemMesh] gave it once when the mesh was
// built, and this ABI deliberately does not repeat it on either .msh call — where the kernel
// library notices on both of its writers and *not* on its builder. Each matches its own
// siblings, so moving the call to look like the other side breaks a convention.
func (m *FemMesh) MshText() (string, error) {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return "", err
	}
	p := C.cadaclysm_fem_mesh_msh_text(h)
	runtime.KeepAlive(m)
	if p == nil {
		return "", &CadaclysmError{Message: lastErrorOr("msh text")}
	}
	return C.GoString(p), nil
}

// SaveMsh is MshText written to path by the library itself: the same bytes from the same
// writer, straight to the file rather than through the borrowed slot, so a MshText call on
// this handle from another goroutine cannot free the text under the write. No notice here
// either; see MshText.
func (m *FemMesh) SaveMsh(path string) error {
	defer pin()()
	h, err := m.h()
	if err != nil {
		return err
	}
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	ok := bool(C.cadaclysm_fem_mesh_save_msh(h, cp))
	runtime.KeepAlive(m)
	if !ok {
		return &CadaclysmError{Message: lastErrorOr(fmt.Sprintf("could not write %s", path))}
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

// Bounds64 is Bounds, taken from the document's box, unnarrowed, rather than from Bounds'
// own widened float32 positions -- exact far from the origin, where those are not. Bounds
// is already double in this package, so this returns the same [Bounds] type; only the
// precision of what filled it differs.
func (n *Node) Bounds64() Bounds {
	b := C.cadaclysm_node_bounds64(n.scene.h(), C.uint32_t(n.index))
	var out Bounds
	for i := 0; i < 3; i++ {
		out.Min[i] = float64(b.min[i])
		out.Max[i] = float64(b.max[i])
	}
	return out
}

func meshFrom(raw C.CadaclysmMesh) *Mesh {
	if raw.index_count == 0 || raw.positions == nil {
		return nil
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
	return m
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
	return meshFrom(C.cadaclysm_node_mesh(n.scene.h(), C.uint32_t(n.index))), nil
}

// Mesh64 is Mesh in double: see [Mesh64]. The error is non-nil only for a closed scene,
// as Mesh's.
func (n *Node) Mesh64() (*Mesh64, error) {
	if err := n.scene.closedError(); err != nil {
		return nil, err
	}
	return meshFrom64(C.cadaclysm_node_mesh64(n.scene.h(), C.uint32_t(n.index))), nil
}

// FemMesh is this node's body meshed for a solver, as a [FemMesh]: nodes welded by bits,
// triangles wound outward, each node tagged with the lowest-dimension B-rep entity it lies
// on, and every crack reported rather than closed. Meshed in the part's own frame and
// following the hop from an instance to the shape it draws that Mesh follows, so a node
// instanced six times meshes once, where it is defined.
//
// tolerance is the chordal tolerance in model units, finite and above zero, and **it alone
// governs how closely the mesh follows the geometry**. maxSize is a size ceiling, finite and
// zero or more, 0 being no ceiling (curvature alone): **it bounds the boundary and targets
// the interior**, which is not a longest-element-edge guarantee — it adds boundary nodes
// without refining boundary geometry, and FemMesh.LongestEdge is what the mesh actually came
// to, the figure to check against it. Go has no defaults, so Python's 0.01 and 0.0 are
// spelled out at the call; the library's own struct is filled by cadaclysm_fem_options_init
// first, so a field added to it later defaults without this function being touched.
//
// **Neither number is checked here.** cadaclysm_node_fem_mesh refuses a tolerance or a size
// it cannot use, naming the field and the value, and a mesh-only body goes through
// fem_mesh_of_mesh, which takes no options at all and so reads neither — a tolerance of 0,
// -1 or NaN and a maxSize of -1 or NaN all come back with a mesh there. A wrapper that
// validated either field itself would refuse calls this ABI accepts.
//
// placement is 16 numbers, column-major, as [Node.BoundsPlaced] takes them (nil for the
// identity), applied in float64 throughout. The kernel package's Solid.FemMesh takes
// **twelve** instead — a blacksmith.Frame, origin then x, y, z — so a caller moving between
// the two reformats the placement; both being fixed-size array types, Go refuses the wrong
// one at compile time where the other wrappers can only refuse it at run time.
//
// **The space is the body's own for a B-rep and the scene's for a mesh**, which
// FemMesh.FromMesh is the flag for: under a convention other than the native one those are
// two different spaces. Read it there.
//
// **A cracked body is not a failure**: it comes back with FemMesh.Watertight false and its
// cracks in FemMesh.OpenEdges and FemMesh.FoldedEdges — **both**, a fold being as real a
// fault as an open crack — and nothing is welded shut to make it look sound. Returns a
// *CadaclysmError for a closed scene, a tolerance or size the mesher refuses, a placement
// that is not finite and invertible, a node with neither a brep nor a mesh (an assembly, a
// storey, a layer, an empty definition, a curve), and a body that meshes to no triangles at
// all.
//
// Prints the unlicensed notice once, here, and not again on either of FemMesh's .msh calls.
func (n *Node) FemMesh(tolerance, maxSize float64, placement *[16]float64) (*FemMesh, error) {
	if err := n.scene.closedError(); err != nil {
		return nil, err
	}
	defer pin()() // the call and the lastError read after it on one OS thread
	var opts C.CadaclysmFemOptions
	// init writes sizeof(CadaclysmFemOptions) bytes as the *library* knows that type, into
	// the struct cgo declares from the header — one type, not two, which is why Go has no
	// layout row in tests/bindings.rs to keep the two in step. size is then set to this
	// header's own sizeof, which is what the growth rule asks of a caller.
	C.cadaclysm_fem_options_init(&opts)
	opts.size = C.size_t(unsafe.Sizeof(opts))
	opts.tolerance = C.double(tolerance)
	opts.max_size = C.double(maxSize)
	var p *C.double
	if placement != nil {
		p = (*C.double)(unsafe.Pointer(&placement[0]))
	}
	h := C.cadaclysm_node_fem_mesh(n.scene.h(), C.uint32_t(n.index), p, &opts)
	if h == nil {
		return nil, &CadaclysmError{Message: lastErrorOr("fem_mesh")}
	}
	return femMeshFrom(h)
}

// MeshLod is this node's triangles at a coarser level of detail: 0 is Mesh itself, 1 up
// to LodLevels each about a quarter of the triangles of the one before, and past that
// nil. Every level shares the level-0 vertices -- the same Positions, only Indices
// differ -- so upload the vertices once and switch level by drawing a different index
// range.
func (n *Node) MeshLod(level uint32) (*Mesh, error) {
	if err := n.scene.closedError(); err != nil {
		return nil, err
	}
	return meshFrom(C.cadaclysm_node_mesh_lod(n.scene.h(), C.uint32_t(n.index), C.uint32_t(level))), nil
}

// LodError is how far MeshLod at this level moved the surface, in the scene's units --
// what to pick a level by. Zero at level 0.
func (n *Node) LodError(level uint32) float32 {
	return float32(C.cadaclysm_node_lod_error(n.scene.h(), C.uint32_t(n.index), C.uint32_t(level)))
}

// Brep is this node's exact B-rep, for the blacksmith package's FromNode to operate on --
// nil, with a nil error, where it has none (a mesh, a curve, a CSG body, a JT or OpenSCAD
// part). Shared with the scene, not copied; see [Brep]. The error is non-nil only for a
// closed scene, as Mesh's.
func (n *Node) Brep() (*Brep, error) {
	if err := n.scene.closedError(); err != nil {
		return nil, err
	}
	p := C.cadaclysm_node_brep(n.scene.h(), C.uint32_t(n.index))
	if p == nil {
		return nil, nil
	}
	b := &Brep{ptr: p}
	runtime.SetFinalizer(b, (*Brep).Close)
	return b, nil
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

// EdgeColours is one RGBA per polyline of Edges, nil for an edge the file does not
// style; empty when nothing is styled.
func (n *Node) EdgeColours() [][]float32 {
	return edgeColoursFrom(C.cadaclysm_node_edge_colors(n.scene.h(), C.uint32_t(n.index)))
}

func edgeColoursFrom(raw C.CadaclysmEdgeColors) [][]float32 {
	if raw.rgba == nil || raw.count == 0 {
		return [][]float32{}
	}
	flat := unsafe.Slice((*float32)(unsafe.Pointer(raw.rgba)), int(raw.count)*4)
	out := make([][]float32, raw.count)
	for i := range out {
		if flat[4*i+3] >= 0 {
			out[i] = append([]float32(nil), flat[4*i:4*i+4]...)
		}
	}
	return out
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

// EdgeBeziers is this node's feature edges as cubic Bézier curves -- exact where the
// file's curves were, where Edges are their chords. Builds the geometry if needed.
func (n *Node) EdgeBeziers() *Beziers {
	return beziersFrom(C.cadaclysm_node_edge_beziers(n.scene.h(), C.uint32_t(n.index)))
}

// EdgeBeziers64 is EdgeBeziers in double; see [Beziers64].
func (n *Node) EdgeBeziers64() *Beziers64 {
	return beziersFrom64(C.cadaclysm_node_edge_beziers64(n.scene.h(), C.uint32_t(n.index)))
}

// CurveBeziers is this node's free curves as cubic Béziers; see EdgeBeziers.
func (n *Node) CurveBeziers() *Beziers {
	return beziersFrom(C.cadaclysm_node_curve_beziers(n.scene.h(), C.uint32_t(n.index)))
}

// CurveBeziers64 is CurveBeziers in double; see EdgeBeziers64.
func (n *Node) CurveBeziers64() *Beziers64 {
	return beziersFrom64(C.cadaclysm_node_curve_beziers64(n.scene.h(), C.uint32_t(n.index)))
}

// IsocurveBeziers is this node's isocurves as cubic Béziers; see EdgeBeziers.
func (n *Node) IsocurveBeziers() *Beziers {
	return beziersFrom(C.cadaclysm_node_isocurve_beziers(n.scene.h(), C.uint32_t(n.index)))
}

// IsocurveBeziers64 is IsocurveBeziers in double; see EdgeBeziers64.
func (n *Node) IsocurveBeziers64() *Beziers64 {
	return beziersFrom64(C.cadaclysm_node_isocurve_beziers64(n.scene.h(), C.uint32_t(n.index)))
}

// Collision is the collision body for what this node draws, building its mesh if it
// is not built. hullBudget is the most triangles a hull may have; 0 asks for the Unity
// limit (255) and is not clamped to it. The second return is false for a node that
// draws nothing. Cached per node and budget.
func (n *Node) Collision(hullBudget uint32) (*Collision, bool) {
	var raw C.CadaclysmCollision
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	if !bool(C.cadaclysm_node_collision(n.scene.h(), C.uint32_t(n.index), C.uint32_t(hullBudget), &raw)) {
		return nil, false
	}
	out := &Collision{
		Shape: uint32(raw.shape), Confidence: uint32(raw.confidence), Axis: uint32(raw.axis),
		Radius: float64(raw.radius), Height: float64(raw.height), Error: float64(raw.error),
		HullVertexCount: uint32(raw.hull_vertex_count), HullIndexCount: uint32(raw.hull_index_count),
	}
	for i := 0; i < 16; i++ {
		out.Frame[i] = float64(raw.frame[i])
	}
	for i := 0; i < 3; i++ {
		out.HalfExtent[i] = float64(raw.half_extent[i])
	}
	return out, true
}

// CollisionHull is the convex hull Collision counted, as triangles. Empty for a node
// that draws nothing. A view into the scene, good until it closes or this node is
// asked for a different hullBudget, which refits and frees it.
func (n *Node) CollisionHull(hullBudget uint32) *CollisionHull {
	raw := C.cadaclysm_node_collision_hull(n.scene.h(), C.uint32_t(n.index), C.uint32_t(hullBudget))
	if raw.vertex_count == 0 || raw.positions == nil {
		return &CollisionHull{}
	}
	return &CollisionHull{
		Positions: unsafe.Slice((*float32)(unsafe.Pointer(raw.positions)), int(raw.vertex_count)*3),
		Indices:   unsafe.Slice((*uint32)(unsafe.Pointer(raw.indices)), int(raw.index_count)),
	}
}

// -- the surface path: for a renderer drawing exact surfaces, never triangles --

// BoundsPlaced is the box of what this node draws under placement (16 numbers,
// column-major, as Placement.RawTransform; nil for the identity), for a part drawn from
// its surfaces: every sample is carried through the convention and the placement before
// it is boxed, so it is tighter than placing the corners of Bounds. All zeros for a
// part with no surfaces.
func (n *Node) BoundsPlaced(placement *[16]float64) Bounds {
	var p *C.double
	if placement != nil {
		p = (*C.double)(unsafe.Pointer(&placement[0]))
	}
	b := C.cadaclysm_node_bounds_placed(n.scene.h(), C.uint32_t(n.index), p)
	var out Bounds
	for i := 0; i < 3; i++ {
		out.Min[i] = float64(b.min[i])
		out.Max[i] = float64(b.max[i])
	}
	return out
}

// BoundsPlaced64 is BoundsPlaced, taken from the surfaces' unnarrowed double positions;
// see Bounds64.
func (n *Node) BoundsPlaced64(placement *[16]float64) Bounds {
	var p *C.double
	if placement != nil {
		p = (*C.double)(unsafe.Pointer(&placement[0]))
	}
	b := C.cadaclysm_node_bounds_placed64(n.scene.h(), C.uint32_t(n.index), p)
	var out Bounds
	for i := 0; i < 3; i++ {
		out.Min[i] = float64(b.min[i])
		out.Max[i] = float64(b.max[i])
	}
	return out
}

// IsMeshed is whether its mesh has been built and is held -- by Scene.RealizeAll, by an
// ask for it, or by anything else that needed it.
func (n *Node) IsMeshed() bool { return bool(C.cadaclysm_node_is_meshed(n.scene.h(), C.uint32_t(n.index))) }

// SurfaceEdges is its face boundaries taken from its trimmed surfaces -- the outline
// that costs no tessellation, where Edges meshes the part. In the surfaces' own frame
// (see Scene.SurfaceMatrix); empty without surfaces.
func (n *Node) SurfaceEdges() *Polylines {
	return polylinesFrom(C.cadaclysm_node_surface_edges(n.scene.h(), C.uint32_t(n.index)))
}

// SurfaceEdgeBeziers is its edges as the exact curves, where the reader has them without
// meshing -- a Rhino extrusion's rims are its profile -- and empty everywhere else, so a
// caller drawing from surfaces tries this before SurfaceEdges, whose trims are thinned to
// the mesh tolerance. The same segments as EdgeBeziers, in the same space: not the
// surfaces' frame, so no Scene.SurfaceMatrix.
func (n *Node) SurfaceEdgeBeziers() *Beziers {
	return beziersFrom(C.cadaclysm_node_surface_edge_beziers(n.scene.h(), C.uint32_t(n.index)))
}

// SurfaceEdgeColours is EdgeColours for SurfaceEdges.
func (n *Node) SurfaceEdgeColours() [][]float32 {
	return edgeColoursFrom(C.cadaclysm_node_surface_edge_colors(n.scene.h(), C.uint32_t(n.index)))
}

// SurfaceIsocurves is its isocurves taken from its trimmed surfaces and clipped to the
// trims, without meshing; a flat face gets none. In the surfaces' frame; empty without
// surfaces.
func (n *Node) SurfaceIsocurves() *Polylines {
	return polylinesFrom(C.cadaclysm_node_surface_isocurves(n.scene.h(), C.uint32_t(n.index)))
}

// SurfacePick is where the segment from..to first meets this part's surfaces; the
// second return is false where it meets none. Exact, and in the surfaces' own frame:
// carry a ray from the scene's space through the inverse of Scene.SurfaceMatrix first.
func (n *Node) SurfacePick(from, to [3]float64) ([3]float64, bool) {
	var hit [3]float64
	ok := C.cadaclysm_node_surface_pick(n.scene.h(), C.uint32_t(n.index),
		(*C.double)(unsafe.Pointer(&from[0])), (*C.double)(unsafe.Pointer(&to[0])), (*C.double)(unsafe.Pointer(&hit[0])))
	return hit, bool(ok)
}

// SurfaceProxyMesh is a coarse mesh over its surfaces for what needs triangles and not
// a picture (ray tracing, distance fields): each face gridded cells by cells, never
// welded, built once per part at the first size asked. Nil without surfaces or for zero
// cells.
func (n *Node) SurfaceProxyMesh(cells uint32) (*Mesh, error) {
	if err := n.scene.closedError(); err != nil {
		return nil, err
	}
	return meshFrom(C.cadaclysm_node_surface_proxy_mesh(n.scene.h(), C.uint32_t(n.index), C.uint32_t(cells))), nil
}

// TriangleEstimate is about how many triangles Mesh would give, without building it;
// -1 where the reader cannot say without doing the work. Treat -1 as unknown, never as
// zero.
func (n *Node) TriangleEstimate() int64 {
	return int64(C.cadaclysm_node_triangle_estimate(n.scene.h(), C.uint32_t(n.index)))
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

// Bounds64 is Bounds, taken from the unnarrowed double positions; see Node.Bounds64.
// This meshes all of it, being the only way to know how far it reaches, exactly as
// Bounds does.
func (s *Scene) Bounds64() Bounds {
	b := C.cadaclysm_bounds64(s.h())
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

// GeometryDiagnostics is what the reader built but the geometry stage could not
// finish: a face that would not trim, a surface that would not mesh. Diagnostics is
// what the file held that could not be read; this is what the geometry did.
func (s *Scene) GeometryDiagnostics() []string {
	n := uint32(C.cadaclysm_geometry_diagnostic_count(s.h()))
	out := make([]string, n)
	for i := uint32(0); i < n; i++ {
		out[i] = C.GoString(C.cadaclysm_geometry_diagnostic(s.h(), C.uint32_t(i)))
	}
	return out
}

// Links are the rigid bodies of the file's mechanism, in the file's order. A file with
// no mechanism gives none.
func (s *Scene) Links() []*Link {
	n := uint32(C.cadaclysm_link_count(s.h()))
	out := make([]*Link, n)
	for i := uint32(0); i < n; i++ {
		out[i] = &Link{scene: s, index: i}
	}
	return out
}

// Joints are the connections between the links, in the file's order.
func (s *Scene) Joints() []*Joint {
	n := uint32(C.cadaclysm_joint_count(s.h()))
	out := make([]*Joint, n)
	for i := uint32(0); i < n; i++ {
		out[i] = &Joint{scene: s, index: i}
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

// RealizeMeshes is RealizeAll leaving alone every node that carries surfaces when
// skipSurfaced is true: a renderer drawing those from their surfaces never pays for
// their triangles. Returns how many were built.
func (s *Scene) RealizeMeshes(skipSurfaced bool) uint32 {
	skip := C.uint32_t(0)
	if skipSurfaced {
		skip = 1
	}
	return uint32(C.cadaclysm_realize_meshes(s.h(), skip))
}

// Realized is how many nodes RealizeAll has finished with. Safe to read from another
// goroutine.
func (s *Scene) Realized() uint32 { return uint32(C.cadaclysm_realized(s.h())) }

// RealizeTotal is how many there will be in all — zero until RealizeAll starts.
func (s *Scene) RealizeTotal() uint32 { return uint32(C.cadaclysm_realize_total(s.h())) }

// Cancel asks a running RealizeAll to stop. One-way, and for the life of the scene:
// every later RealizeAll on this scene returns 0 at once.
func (s *Scene) Cancel() { C.cadaclysm_cancel(s.h()) }

// ForgetMeshes drops every mesh the scene has built; the next ask rebuilds. Every Mesh
// and Polylines handed out before this is over freed memory.
func (s *Scene) ForgetMeshes() { C.cadaclysm_forget_meshes(s.h()) }

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

// ---- svg ----------------------------------------------------------------------------

// SvgView is one of the seven camera angles SvgOptions.View understands — the same
// table cadaclysm_viewer.VIEWS gives Python's show() and svg() both.
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

// SvgOptions is how an SVG drawing is made — the camera in the viewer's words, the
// page, the pen and which line sets. Mirrors CadaclysmSvgOptions, defaulted the way
// cadaclysm_svg_options_init defaults the struct: build one with NewSvgOptions rather
// than a bare SvgOptions{}, whose zero value turns every line-set flag off, which the
// library refuses ("no line set in flags"). Passed to Scene.SvgText, Scene.Svg,
// Node.SvgText and Node.Svg; a nil *SvgOptions at any of those four is NewSvgOptions()'s
// defaults. A refused option (an out-of-range Fov, say) is a *CadaclysmError naming the
// field, worded by the library itself.
type SvgOptions struct {
	// View fills Azimuth/Elevation unless they are set directly. Default SvgIso.
	View SvgView
	// Azimuth overrides View's, degrees about the up axis from +X: -90 looks from -Y,
	// the front. nil keeps View's own.
	Azimuth *float64
	// Elevation overrides View's, degrees above the horizon. nil keeps View's own.
	Elevation *float64
	// Up is "y" or "z"; "" keeps the scene's own convention — Unity and YUp default to
	// "y", every other convention to "z".
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
	// Background is "#rrggbb", or nil (the default) for no <rect> behind the drawing —
	// the page left to whatever the viewer composites it onto.
	Background *string
	// Edges draws each shape's feature edges — the exact curves the flattened
	// polylines are drawn from. Default true.
	Edges bool
	// Curves draws each shape's free curves — the ones that are not the edge of any
	// face. Default false.
	Curves bool
	// Isocurves draws each shape's isocurves — the constant-parameter lines across a
	// curved face. Default false.
	Isocurves bool
	// Polylines writes every line as straight segments within Tolerance, instead of
	// being fitted back to cubic Béziers. Default false.
	Polylines bool
}

// NewSvgOptions is the defaults cadaclysm_svg_options_init fills: the viewer's iso,
// orthographic, a 1000-square page, black edges one unit wide on nothing.
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
		return 0, &CadaclysmError{Message: fmt.Sprintf("colour %s: expected '#rrggbb'", colour)}
	}
	v, err := strconv.ParseUint(hex, 16, 32)
	if err != nil {
		return 0, &CadaclysmError{Message: fmt.Sprintf("colour %s: expected '#rrggbb'", colour)}
	}
	return uint32(v), nil
}

// buildSvgOptions packs opts (nil for NewSvgOptions()'s defaults) into a
// C.CadaclysmSvgOptions: View fills Azimuth/Elevation unless they are set directly, Up
// defaults to defaultUp, colours are "#rrggbb". Shared by Scene.SvgText/Scene.Svg and
// Node.SvgText/Node.Svg, as Python's _svg_options is shared by Scene.svg and Node.svg.
func buildSvgOptions(opts *SvgOptions, defaultUp string) (C.CadaclysmSvgOptions, error) {
	o := NewSvgOptions()
	if opts != nil {
		o = *opts
	}
	var raw C.CadaclysmSvgOptions
	C.cadaclysm_svg_options_init(&raw)
	angles, ok := svgViewAngles[o.View]
	if !ok {
		return raw, &CadaclysmError{Message: fmt.Sprintf("svg: no view numbered %d", int(o.View))}
	}
	up := o.Up
	if up == "" {
		up = defaultUp
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
		raw.background = C.uint32_t(C.CADACLYSM_SVG_TRANSPARENT)
	} else {
		bg, err := parseSvgColour(*o.Background)
		if err != nil {
			return raw, err
		}
		raw.background = C.uint32_t(bg)
	}
	var flags uint32
	if o.Edges {
		flags |= uint32(C.CADACLYSM_SVG_EDGES)
	}
	if o.Curves {
		flags |= uint32(C.CADACLYSM_SVG_CURVES)
	}
	if o.Isocurves {
		flags |= uint32(C.CADACLYSM_SVG_ISOCURVES)
	}
	if o.Polylines {
		flags |= uint32(C.CADACLYSM_SVG_POLYLINES)
	}
	raw.flags = C.uint32_t(flags)
	return raw, nil
}

// defaultUp is "y" or "z": which axis is up by default, from Convention — Unity and
// YUp give "y", every other convention "z". What SvgOptions.Up defaults to when left
// "". FileUnits and UVWorld are masked out first since they OR into the packed
// Convention this scene carries.
func (s *Scene) defaultUp() string {
	base := Convention(uint32(s.convention) &^ (uint32(FileUnits) | uint32(UVWorld)))
	if base == Unity || base == YUp {
		return "y"
	}
	return "z"
}

// SvgText is every visible placement's wireframe as SVG text, from the camera opts
// describes (nil for NewSvgOptions()'s defaults) — the library's own camera, not a
// viewer. See SvgOptions. Borrowed: copied out before this returns, and replaced by
// this scene's next SvgText or Svg call.
func (s *Scene) SvgText(opts *SvgOptions) (string, error) {
	if err := s.closedError(); err != nil {
		return "", err
	}
	defer pin()()
	raw, err := buildSvgOptions(opts, s.defaultUp())
	if err != nil {
		return "", err
	}
	p := C.cadaclysm_scene_svg_text(s.h(), &raw)
	if p == nil {
		return "", &CadaclysmError{Message: lastErrorOr("svg")}
	}
	return C.GoString(p), nil
}

// Svg is SvgText written to path by the library itself.
func (s *Scene) Svg(path string, opts *SvgOptions) error {
	if err := s.closedError(); err != nil {
		return err
	}
	defer pin()()
	raw, err := buildSvgOptions(opts, s.defaultUp())
	if err != nil {
		return err
	}
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	if !bool(C.cadaclysm_scene_svg(s.h(), cp, &raw)) {
		return &CadaclysmError{Message: lastErrorOr(fmt.Sprintf("could not write %s", path))}
	}
	return nil
}

// SvgText is this node's own wireframe as SVG text, in its own frame — Scene.SvgText's
// options, read from just this node rather than every placement.
func (n *Node) SvgText(opts *SvgOptions) (string, error) {
	if err := n.scene.closedError(); err != nil {
		return "", err
	}
	defer pin()()
	raw, err := buildSvgOptions(opts, n.scene.defaultUp())
	if err != nil {
		return "", err
	}
	p := C.cadaclysm_node_svg_text(n.scene.h(), C.uint32_t(n.index), &raw)
	if p == nil {
		return "", &CadaclysmError{Message: lastErrorOr("svg")}
	}
	return C.GoString(p), nil
}

// Svg is SvgText written to path by the library itself.
func (n *Node) Svg(path string, opts *SvgOptions) error {
	if err := n.scene.closedError(); err != nil {
		return err
	}
	defer pin()()
	raw, err := buildSvgOptions(opts, n.scene.defaultUp())
	if err != nil {
		return err
	}
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	if !bool(C.cadaclysm_node_svg(n.scene.h(), C.uint32_t(n.index), cp, &raw)) {
		return &CadaclysmError{Message: lastErrorOr(fmt.Sprintf("could not write %s", path))}
	}
	return nil
}
