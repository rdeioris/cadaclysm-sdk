package view_test

import (
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
	"weak"

	"github.com/rdeioris/cadaclysm-sdk/go/blacksmith"
	"github.com/rdeioris/cadaclysm-sdk/go/cadaclysm"
	"github.com/rdeioris/cadaclysm-sdk/go/view"
	"github.com/rdeioris/cadaclysm-sdk/go/view/internal/viewrig"
)

func skipOrFail(t *testing.T, err error) {
	t.Helper()
	if os.Getenv("CADACLYSM_REQUIRE_WGPU") != "" {
		t.Fatalf("CADACLYSM_REQUIRE_WGPU is set, but: %v", err)
	}
	t.Skipf("no GPU view here: %v", err)
}

func useTerminal(t *testing.T) *view.Library {
	t.Helper()
	lib, err := view.UseTerminal()
	if err != nil {
		if os.Getenv("CADACLYSM_REQUIRE_TERMINAL") == "1" {
			t.Fatalf("CADACLYSM_REQUIRE_TERMINAL=1, but: %v", err)
		}
		t.Skipf("no terminal library here: %v", err)
	}
	return lib
}

// mechanism is samples/mechanism-solid.stp: a nested node, and mechanism states to pose.
func mechanism(t *testing.T) string {
	t.Helper()
	// The repository tree first, then the SDK layout (go/ and samples/ side by side).
	repo := filepath.Join("..", "..", "..", "..", "..", "samples", "mechanism-solid.stp")
	sdk := filepath.Join("..", "..", "samples", "mechanism-solid.stp")
	for _, path := range []string{repo, sdk} {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	if os.Getenv("CADACLYSM_SAMPLES_OPTIONAL") != "" {
		t.Skip("samples/mechanism-solid.stp is missing")
	}
	t.Fatalf("samples/mechanism-solid.stp is missing (a worktree: scripts/link-samples.py)")
	return ""
}

// nestedLeaf is a node below a root, with no children, that has geometry.
func nestedLeaf(scene *cadaclysm.Scene) *cadaclysm.Node {
	for _, n := range scene.Nodes() {
		if n.Parent() != nil && len(n.Children()) == 0 && n.CanMesh() {
			return n
		}
	}
	return nil
}

func differing(a, b *image.RGBA) int {
	n := 0
	for i := 0; i+3 < len(a.Pix) && i+3 < len(b.Pix); i += 4 {
		if a.Pix[i] != b.Pix[i] || a.Pix[i+1] != b.Pix[i+1] || a.Pix[i+2] != b.Pix[i+2] || a.Pix[i+3] != b.Pix[i+3] {
			n++
		}
	}
	return n
}

func message(err error) string {
	if err == nil {
		return "<accepted>"
	}
	return err.Error()
}

func TestTheTerminalLoadsAndRefusesAnOffscreenView(t *testing.T) {
	lib := useTerminal(t)
	if !lib.IsTerminal() || lib.IsWgpu() {
		t.Fatalf("the terminal library is %q", lib.Name)
	}
	if v, err := view.Offscreen(64, 64, nil); err == nil {
		v.Close()
		t.Fatal("the terminal made an offscreen view")
	}
}

func TestAMissingLibraryIsRefusedWithTheContractsMessage(t *testing.T) {
	dir := t.TempDir()
	_, err := view.FindForTest("cadaclysm_view_absent", "CADACLYSM_VIEW_ABSENT_LIBRARY", "terminal", []string{dir})
	if err == nil {
		t.Fatal("found a library that does not exist")
	}
	m := err.Error()
	if !strings.HasPrefix(m, "no view library: the terminal library was not found (searched: ") ||
		!strings.Contains(m, dir) ||
		!strings.HasSuffix(m, "-- reinstall cadaclysm, set CADACLYSM_VIEW_ABSENT_LIBRARY to the library, or set CADACLYSM_VIEW") {
		t.Fatalf("message: %s", m)
	}
}

func TestTheLodStructIsTwelveBytes(t *testing.T) {
	size, minTriangles, motion := view.LodLayoutForTest()
	if size != 12 || minTriangles != 4 || motion != 8 {
		t.Fatalf("CadaclysmViewLod: size %d, min_triangles at %d, motion at %d; want 12, 4, 8", size, minTriangles, motion)
	}
}

func TestOccludedStyleRoundTrips(t *testing.T) {
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(160, 120, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	defer v.Close()
	grey := [3]float32{0.5, 0.5, 0.5}
	if err := v.SetOccludedStyle(view.OccludedStyle{Dash: 10, Gap: 5, Dim: 0.25, Colour: &grey}); err != nil {
		t.Fatal(err)
	}
	s, err := v.OccludedStyle()
	if err != nil || s.Dash != 10 || s.Colour == nil || *s.Colour != grey {
		t.Fatalf("got %+v, %v", s, err)
	}
	if err := v.SetOccludedStyle(view.OccludedStyle{Dim: 1.5}); err == nil {
		t.Fatal("dim 1.5 accepted")
	}
	if err := v.SetOccludedStyle(view.OccludedStyle{}); err != nil {
		t.Fatal(err)
	}
	if s, _ := v.OccludedStyle(); s != view.DefaultOccludedStyle() {
		t.Fatalf("zero value is the default, got %+v", s)
	}
}

func TestABrokenVariableNamesItself(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nothing-here")
	t.Setenv("CADACLYSM_TERMINAL_LIBRARY", missing)
	_, err := view.UseTerminal()
	want := "CADACLYSM_TERMINAL_LIBRARY=" + missing + " names nothing that exists"
	if err == nil || err.Error() != want {
		t.Fatalf("got %v, want %s", err, want)
	}
}

// heldSolid is a solid in a block of its own: the Go pointer field keeps it out of the
// tiny allocator (see TestOffscreenSolidByHandle).
type heldSolid struct {
	*blacksmith.Solid
	_ *int
}

// A solid in a material and an opacity, and two of its faces alone (1.21); a material or a
// face the solid does not have is refused, named.
func TestOffscreenSolidMaterialOpacityAndFaces(t *testing.T) {
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(64, 48, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	defer v.Close()
	cube, err := blacksmith.Cuboid(1, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	half := float32(0.5)
	if _, err := v.ShowSolid(cube, blacksmith.DefaultTolerance, nil, view.SolidOptions{Material: "glass", Opacity: &half, Faces: []uint32{0, 1}}); err != nil {
		t.Fatal(err)
	}
	if _, err := v.ShowSolid(cube, blacksmith.DefaultTolerance, nil, view.SolidOptions{Material: "metal"}); err != nil {
		t.Fatal(err)
	}
	if _, err := v.ShowSolid(cube, blacksmith.DefaultTolerance, nil, view.SolidOptions{Material: "chrome"}); !strings.HasPrefix(message(err), "material: \"chrome\" is not") {
		t.Fatalf("material chrome: %v", err)
	}
	if _, err := v.ShowSolid(cube, blacksmith.DefaultTolerance, nil, view.SolidOptions{Faces: []uint32{99}}); !strings.Contains(message(err), "face 99 is not one of the solid's 6 faces") {
		t.Fatalf("face 99: %v", err)
	}
}

func TestOffscreenSolidByHandle(t *testing.T) {
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(320, 240, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	defer v.Close()
	if err := v.Standard("front"); err != nil {
		t.Fatal(err)
	}
	empty, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	s, err := blacksmith.Sphere(10)
	if err != nil {
		t.Fatal(err)
	}
	// Shown through a wrapper with a Go pointer field: a *blacksmith.Solid alone is an 8-byte
	// object without Go pointers (its handle is a C pointer), which the tiny allocator packs
	// beside other objects -- a weak pointer to it may stay set while a neighbour lives.
	held := &heldSolid{Solid: s}
	kept := weak.Make(held)
	item, err := v.ShowSolid(held, blacksmith.DefaultTolerance, &[3]float32{0.9, 0.2, 0.1})
	if err != nil {
		t.Fatal(err)
	}
	s, held = nil, nil
	runtime.GC() // the item keeps the solid reachable: neither the collector nor the Solid's
	runtime.GC() // finalizer (which frees the C solid) may run under the item
	if kept.Value() == nil {
		t.Fatal("the item let go of the solid")
	}
	if err := v.Frame(); err != nil {
		t.Fatal(err)
	}
	drawn, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if drawn.RGBAAt(160, 120) == empty.RGBAAt(160, 120) {
		t.Fatalf("nothing drawn at the centre: %v", drawn.RGBAAt(160, 120))
	}
	pick, err := v.Pick(160, 120, 0)
	if err != nil || pick.Item != item.ID() {
		t.Fatalf("pick: %+v %v, want item %d", pick, err, item.ID())
	}
	// Master's three: levels on and off, the wake answer, node transforms refused on a solid.
	if err := v.Lod("smooth", 0); err != nil {
		t.Fatalf("lod smooth: %v", err)
	}
	if _, _, err := v.WakeMs(); err != nil {
		t.Fatalf("wake_ms: %v", err)
	}
	if err := v.Lod("", 0); err != nil {
		t.Fatalf("lod off: %v", err)
	}
	if err := item.NodeTransforms([][16]float64{}); err == nil {
		t.Fatal("node transforms on a solid were accepted")
	}
	// 1.9's lighting: the headlight by default, studio set and read back, another name refused
	// before C (the lighting unchanged), and the headlight again.
	lit := func(want string) {
		t.Helper()
		if got, err := v.Lighting(); err != nil || got != want {
			t.Fatalf("lighting: %q %v, want %q", got, err, want)
		}
	}
	lit("headlight")
	if err := v.SetLighting("studio"); err != nil {
		t.Fatalf("lighting studio: %v", err)
	}
	lit("studio")
	if got := message(v.SetLighting("noon")); got != "lighting 'noon': 'headlight' or 'studio'" {
		t.Fatalf("lighting noon: %s", got)
	}
	lit("studio")
	if err := v.SetLighting("headlight"); err != nil {
		t.Fatalf("lighting headlight: %v", err)
	}
	lit("headlight")
	// Plain triangles and a picture: Go slices inside a C struct, pinned for the call.
	mesh, err := v.ShowMesh(view.Mesh{Positions: []float32{0, 0, 0, 1, 0, 0, 0, 0, 1}, Indices: []uint32{0, 1, 2},
		Normals: []float32{0, -1, 0, 0, -1, 0, 0, -1, 0}, Edges: []float32{0, 0, 0, 1, 0, 0}, RGB: &[3]float32{0, 1, 0}})
	if err != nil {
		t.Fatalf("show_mesh: %v", err)
	}
	picture, err := v.ShowImage([12]float32{0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 1}, []byte{255, 0, 0, 255}, 1, 1, 1)
	if err != nil {
		t.Fatalf("show_image: %v", err)
	}
	// Two points on the real library: an item.
	points, err := v.ShowPoints([]float32{0, 0, 0, 1, 1, 1}, "red", 8)
	if err != nil || points.ID() == 0 {
		t.Fatalf("show_points: %v", err)
	}
	for _, extra := range []*view.Item{mesh, picture, points} {
		if err := extra.Remove(); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(t.TempDir(), "view.png")
	if err := v.Save(path); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := png.Decode(f)
	f.Close()
	if err != nil || decoded.Bounds().Dx() != 320 || decoded.Bounds().Dy() != 240 {
		t.Fatalf("saved PNG: %v %v", err, decoded)
	}
	if err := item.Remove(); err != nil {
		t.Fatal(err)
	}
	// Let go of: unreachable within a few collections (one may find a stale copy of the
	// pointer in a conservatively scanned frame, so a few are allowed).
	for i := 0; i < 20 && kept.Value() != nil; i++ {
		runtime.GC()
		time.Sleep(5 * time.Millisecond)
	}
	if kept.Value() != nil {
		t.Fatal("a removed item still keeps the solid")
	}
	if n := view.ShownForTest(v); n != 0 {
		t.Fatalf("a removed item is still an owner: %d", n)
	}
	removed, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if removed.RGBAAt(160, 120) != empty.RGBAAt(160, 120) {
		t.Fatal("a removed item is still drawn")
	}
	v.Close()
	_, err = v.ShowLines([]float32{0, 0, 0, 1, 1, 1}, nil)
	if !errors.Is(err, view.ErrClosed) || err.Error() != "cadaclysm_view_show_lines: the view is closed" {
		t.Fatalf("a closed view answered: %v", err)
	}
	if err := item.Frame(); !errors.Is(err, view.ErrClosed) || err.Error() != "cadaclysm_view_frame: the view is closed" {
		t.Fatalf("an item of a closed view answered: %v", err)
	}
}

// A pose's transforms on a shown scene draw it posed; nil is the rest pose again; an empty
// list reaches the library, which refuses it.
func TestAPoseDrawsAndTheRestPoseReturns(t *testing.T) {
	path := mechanism(t)
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(320, 240, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	defer v.Close()
	scene, err := cadaclysm.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer scene.Close()
	shown, err := v.ShowScene(scene)
	if err != nil {
		t.Fatal(err)
	}
	if err := v.Standard("iso"); err != nil {
		t.Fatal(err)
	}
	if err := v.Frame(); err != nil {
		t.Fatal(err)
	}
	rest, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	states := scene.States()
	if len(states) == 0 {
		t.Fatal("mechanism-solid.stp records no state")
	}
	pose, err := scene.PoseState(states[0], nil)
	if err != nil {
		t.Fatal(err)
	}
	nodes := scene.Nodes()
	transforms := make([][16]float64, len(nodes))
	for _, n := range nodes {
		transforms[n.Index()] = pose.RawTransform(n)
	}
	if err := shown.NodeTransforms(transforms); err != nil {
		t.Fatalf("node transforms: %v", err)
	}
	posed, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if differing(rest, posed) == 0 {
		t.Fatal("the posed image is the rest image")
	}
	if err := shown.NodeTransforms(nil); err != nil {
		t.Fatalf("the rest pose: %v", err)
	}
	back, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if d := differing(rest, back); d > len(rest.Pix)/4/1000 {
		t.Fatalf("the rest pose again differs from the rest image in %d pixels", d)
	}
	if err := shown.NodeTransforms([][16]float64{}); err == nil || !strings.Contains(err.Error(), "0 transforms were given") {
		t.Fatalf("an empty pose: %s", message(err))
	}
}

// Scene.Close removes the items of this thread's views first; a view of another thread
// keeps the scene open, refused in Python's words.
func TestClosingASceneReleasesItsItems(t *testing.T) {
	path := mechanism(t)
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(64, 64, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	defer v.Close()
	scene, err := cadaclysm.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	item, err := v.ShowScene(scene)
	if err != nil {
		t.Fatal(err)
	}
	if n := view.ShownForTest(v); n != 1 {
		t.Fatalf("the item keeps %d", n)
	}
	if err := scene.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if n := view.ShownForTest(v); n != 0 || !scene.Closed() {
		t.Fatalf("an item of a closed scene is still shown (%d kept, closed %v)", n, scene.Closed())
	}
	if _, err := v.Image(); err != nil {
		t.Fatalf("the view after the release: %v", err)
	}
	if err := item.Remove(); err == nil {
		t.Fatal("the release left the scene's item in the library")
	}

	other, err := cadaclysm.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	ready, done, finished := make(chan error), make(chan struct{}), make(chan struct{})
	go func() {
		defer close(finished)
		w, err := view.Offscreen(64, 64, nil)
		if err != nil {
			ready <- err
			return
		}
		defer w.Close()
		_, err = w.ShowScene(other)
		ready <- err
		<-done
	}()
	if err := <-ready; err != nil {
		close(done)
		t.Fatal(err)
	}
	err = other.Close()
	want := "1 view(s) made on another thread still show this -- close them from their own thread first; it stays open until then"
	if err == nil || err.Error() != want || other.Closed() {
		close(done)
		<-finished
		t.Fatalf("the scene was closed under another thread's view: %s (closed %v)", message(err), other.Closed())
	}
	close(done)
	<-finished
	if err := other.Close(); err != nil || !other.Closed() {
		t.Fatalf("close once that view is gone: %s", message(err))
	}
}

// Show on the terminal prints a still of a solid, a scene, a node and a pose; the refusals
// come before any drawing.
func TestTheTerminalDrawsStills(t *testing.T) {
	useTerminal(t)
	small := &view.ShowOptions{Width: 16, Height: 8}
	cube, err := blacksmith.Cuboid(5, 5, 5)
	if err != nil {
		t.Fatal(err)
	}
	defer cube.Close()
	if err := cube.Show(small); err != nil {
		t.Fatalf("a solid's still: %v", err)
	}
	tolerant := *small
	tolerant.Tolerance = 0.1
	if err := cube.Show(&tolerant); err != nil {
		t.Fatalf("a solid takes a tolerance: %v", err)
	}
	sideways := *small
	sideways.Up = "x"
	if err := cube.Show(&sideways); message(err) != "up 'x': 'y' or 'z'" {
		t.Fatalf("up: %s", message(err))
	}
	sideways = *small
	sideways.View = "sideways"
	if err := cube.Show(&sideways); !strings.HasPrefix(message(err), "view 'sideways': one of front") {
		t.Fatalf("view: %s", message(err))
	}

	scene, err := cadaclysm.Open(mechanism(t))
	if err != nil {
		t.Fatal(err)
	}
	defer scene.Close()
	if err := scene.Show(small); err != nil {
		t.Fatalf("a scene's still: %v", err)
	}
	const rest = " takes no tolerance: a document is drawn at the tolerance it was read with"
	if err := scene.Show(&tolerant); message(err) != "Scene.Show"+rest {
		t.Fatalf("scene tolerance: %s", message(err))
	}
	if _, err := scene.View(&tolerant); message(err) != "Scene.View"+rest {
		t.Fatalf("scene view tolerance: %s", message(err))
	}
	leaf := nestedLeaf(scene)
	if leaf == nil {
		t.Fatal("mechanism-solid.stp has no leaf below a root with geometry")
	}
	if err := leaf.Show(small); err != nil {
		t.Fatalf("a node's still: %v", err)
	}
	if _, err := leaf.View(&tolerant); message(err) != "Node.View"+rest {
		t.Fatalf("node tolerance: %s", message(err))
	}
	states := scene.States()
	if len(states) == 0 {
		t.Fatal("mechanism-solid.stp records no state")
	}
	pose, err := scene.PoseState(states[0], nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := pose.Show(small); err != nil {
		t.Fatalf("a pose's still: %v", err)
	}
	if err := pose.Show(&tolerant); message(err) != "Pose.Show"+rest {
		t.Fatalf("pose tolerance: %s", message(err))
	}
	closed, err := cadaclysm.Open(mechanism(t))
	if err != nil {
		t.Fatal(err)
	}
	closed.Close()
	if err := closed.Show(small); message(err) != "mechanism-solid.stp: the scene is closed" {
		t.Fatalf("a closed scene: %s", message(err))
	}
}

// rig is a copy of the wgpu library whose named calls are viewrig's stand-ins, in use until
// the test ends.
func rig(t *testing.T, calls ...string) {
	t.Helper()
	base, err := view.UseWgpu()
	if err != nil {
		skipOrFail(t, err)
	}
	lib, err := view.RiggedForTest(base, viewrig.Calls(calls...))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(view.UseForTest(lib))
	viewrig.Reset()
}

// Every buffer is checked before C, in Python's words; an empty one reaches C as a non-NULL
// pointer with count 0, NULL only where the call means "none".
func TestBuffersAreCheckedAndEmptyOnesAreNotNull(t *testing.T) {
	rig(t, "last_error", "create", "destroy", "orbit", "frame", "remove", "show_lines", "show_curves", "show_mesh",
		"show_image", "set_face_colours", "set_node_transforms", "set_viewports")
	v, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	item, err := v.ShowLines([]float32{0, 0, 0, 1, 1, 1}, nil)
	if err != nil {
		t.Fatal(err)
	}
	viewrig.Reset()
	corners := [12]float32{}
	for _, c := range []struct {
		err  error
		want string
	}{
		{second(v.ShowLines(make([]float32, 7), nil)), "segments is two points a segment (6 numbers), not 7"},
		{second(v.ShowCurves(make([]float32, 15), nil)), "show_curves takes four x, y, z, w control points (16 numbers) a curve, not 15"},
		{second(v.ShowMesh(view.Mesh{Positions: make([]float32, 4)})), "positions is three numbers a point, not 4"},
		{second(v.ShowMesh(view.Mesh{Positions: make([]float32, 9), Normals: make([]float32, 6)})), "a mesh has 3 positions but 2 normals"},
		{second(v.ShowMesh(view.Mesh{Positions: make([]float32, 9), Edges: make([]float32, 5)})), "edges is two points a segment (6 numbers), not 5"},
		{second(v.ShowImage(corners, make([]byte, 3), 1, 1, 1)), "show_image: 1 x 1 pixels need 4 bytes (rgba), not 3"},
		{second(v.ShowImage(corners, make([]byte, 5), 1, 1, 1)), "show_image: 1 x 1 pixels need 4 bytes (rgba), not 5"},
		{second(v.ShowImage(corners, nil, math.MaxUint32, math.MaxUint32, 1)), "show_image: 4294967295 x 4294967295 pixels is too large"},
		{item.FaceColours([]uint32{1, 2}, [][4]float32{{1, 0, 0, 1}}), "8 numbers (rgba, 4 a face), not 4"},
	} {
		if message(c.err) != c.want {
			t.Errorf("got %s, want %s", message(c.err), c.want)
		}
	}
	if _, _, calls := viewrig.Seen(); calls != 0 {
		t.Fatalf("%d refused buffers reached the library", calls)
	}
	for _, c := range []struct {
		what  string
		call  func() error
		null  bool
		count uint32
	}{
		{"show_lines(nil)", func() error { return second(v.ShowLines(nil, nil)) }, false, 0},
		{"show_lines([])", func() error { return second(v.ShowLines([]float32{}, nil)) }, false, 0},
		{"show_curves(nil)", func() error { return second(v.ShowCurves(nil, nil)) }, false, 0},
		{"show_mesh({})", func() error { return second(v.ShowMesh(view.Mesh{})) }, false, 0},
		{"show_image(0 x 0)", func() error { return second(v.ShowImage(corners, nil, 0, 0, 1)) }, false, 0},
		{"face_colours([], [])", func() error { return item.FaceColours(nil, nil) }, false, 0},
		{"node_transforms([])", func() error { return item.NodeTransforms([][16]float64{}) }, false, 0},
		{"node_transforms(nil)", func() error { return item.NodeTransforms(nil) }, true, 0},
		{"viewports(nil)", func() error { return v.Viewports(nil) }, true, 0},
	} {
		if err := c.call(); err != nil {
			t.Errorf("%s: %v", c.what, err)
			continue
		}
		if null, count, _ := viewrig.Seen(); null != c.null || count != c.count {
			t.Errorf("%s reached the library as NULL %v, count %d; want NULL %v, count %d", c.what, null, count, c.null, c.count)
		}
	}
	// A void call's refusal is the message it left; a refusal with none is Python's fallback.
	viewrig.Say("orbit: refused")
	if err := v.Orbit(1, 1); message(err) != "orbit: refused" {
		t.Errorf("a void call's refusal: %s", message(err))
	}
	viewrig.Say("")
	if err := v.Orbit(1, 1); err != nil {
		t.Errorf("orbit: %v", err)
	}
	if err := v.Frame(); message(err) != "the view library failed" {
		t.Errorf("a silent refusal: %s", message(err))
	}
}

func second(_ *view.Item, err error) error { return err }

func sameFloats(a, b []float32) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// show_points (view ABI 1.11): the points, their count, the colour and the size reach the
// library as given and an item comes back; no colour is rgb NULL; four numbers and a
// two-number colour are refused before the library.
func TestShowPointsReachesTheContractAndReturnsAnItem(t *testing.T) {
	rig(t, "last_error", "create", "destroy", "show_points")
	v, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	item, err := v.ShowPoints([]float32{0, 0, 0, 1, 2, 3}, "red", 12)
	if err != nil || item == nil || item.ID() != 17 {
		t.Fatalf("show_points: %v", err)
	}
	positions, rgb, size, calls := viewrig.Points()
	if calls != 1 || !sameFloats(positions, []float32{0, 0, 0, 1, 2, 3}) {
		t.Fatalf("the library got %d calls, positions %v", calls, positions)
	}
	if !sameFloats(rgb, []float32{1, 0, 0}) || size != 12 {
		t.Fatalf("red at 12 reached the library as rgb %v, size %v", rgb, size)
	}
	// Go has no default arguments: 8 is the other wrappers' default, passed here.
	item, err = v.ShowPoints([]float32{1, 2, 3}, nil, 8)
	if err != nil || item.ID() != 17 {
		t.Fatalf("one point: %v", err)
	}
	positions, rgb, size, calls = viewrig.Points()
	if calls != 2 || !sameFloats(positions, []float32{1, 2, 3}) || rgb != nil || size != 8 {
		t.Fatalf("no colour at 8 reached the library as %v, rgb %v, size %v (%d calls)", positions, rgb, size, calls)
	}
	if _, err := v.ShowPoints([]float32{1, 2, 3, 4}, nil, 8); message(err) != "show_points: three numbers a point, not 4" {
		t.Errorf("four numbers: %s", message(err))
	}
	if _, err := v.ShowPoints([]float32{1, 2, 3}, []float32{1, 0}, 8); message(err) != "colour: 3 or 4 numbers, not 2" {
		t.Errorf("a two-number colour: %s", message(err))
	}
	if _, _, _, calls := viewrig.Points(); calls != 2 {
		t.Fatalf("a refused show_points reached the library (%d calls)", calls)
	}
}

// A failed create is the library's message, with the hint where it says "no display".
func TestAFailedCreateIsTheLibrarysMessage(t *testing.T) {
	rig(t, "last_error", "create_fails")
	hint := " -- draw without a display with view.Offscreen, or the terminal (view.UseTerminal())"
	viewrig.Say("cadaclysm_view_create: no display (DISPLAY is not set)")
	if _, err := view.New(nil); message(err) != "cadaclysm_view_create: no display (DISPLAY is not set)"+hint {
		t.Errorf("no display: %s", message(err))
	}
	viewrig.Say("cadaclysm_view_create: no adapter")
	if _, err := view.Offscreen(8, 8, nil); message(err) != "cadaclysm_view_create: no adapter" {
		t.Errorf("no adapter: %s", message(err))
	}
	viewrig.Say("")
	if _, err := view.Offscreen(8, 8, nil); message(err) != "the view library failed" {
		t.Errorf("a silent failure: %s", message(err))
	}
	s, err := blacksmith.Sphere(1)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	viewrig.Say("cadaclysm_view_create: no display")
	if err := s.Show(nil); message(err) != "cadaclysm_view_create: no display"+hint {
		t.Errorf("show without a display: %s", message(err))
	}
}

// Pump waits on the first window only, pumps every window before the first failure,
// keeps a failed window open, clamps its wait; Input and NeedsDraw refuse.
func TestPumpInputAndNeedsDraw(t *testing.T) {
	rig(t, "last_error", "create", "destroy", "pump", "input", "needs_draw")
	a, err := view.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := view.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	viewrig.PumpAnswers(0, view.ClosedForTest)
	viewrig.Say("pump: refused")
	open, err := view.Pump(time.Second)
	n, waits := viewrig.Pumps()
	if message(err) != "pump: refused" || n != 2 || len(waits) != 2 || waits[0] != 1000 || waits[1] != 0 {
		t.Fatalf("every window pumped before the failure: %s, %d calls, waits %v", message(err), n, waits)
	}
	if open != 1 || a.Closed() || !b.Closed() {
		t.Fatalf("open %d; the failure closed the first %v; CLOSED closed the second %v", open, a.Closed(), b.Closed())
	}
	if _, err := b.NeedsDraw(); !errors.Is(err, view.ErrWindowClosed) || err.Error() != "cadaclysm_view_needs_draw: the window is closed" {
		t.Fatalf("a closed window's needs_draw: %s", message(err))
	}
	for _, c := range []struct {
		timeout time.Duration
		want    uint32
	}{{-time.Second, 0}, {time.Duration(math.MaxInt64), math.MaxUint32}, {1500 * time.Microsecond, 1}} {
		viewrig.Reset()
		if open, err := view.Pump(c.timeout); err != nil || open != 1 {
			t.Fatalf("pump(%v): %d open, %v", c.timeout, open, err)
		}
		if _, waits := viewrig.Pumps(); len(waits) != 1 || waits[0] != c.want {
			t.Fatalf("pump(%v) waited %v ms, want %d", c.timeout, waits, c.want)
		}
	}
	if needs, err := a.NeedsDraw(); err != nil || !needs {
		t.Fatalf("needs_draw: %v %v", needs, err)
	}
	viewrig.Reset()
	viewrig.Say("input: refused")
	if _, err := a.Input(view.Event{Kind: view.EventKey, Key: "KeyT", KeyDown: true}); message(err) != "input: refused" {
		t.Fatalf("input's refusal: %s", message(err))
	}
	viewrig.Reset()
	viewrig.InputBits(view.InputClose)
	if bits, err := a.Input(view.Event{Kind: view.EventKey, Key: "Escape", KeyDown: true}); err != nil || bits != view.InputClose {
		t.Fatalf("input: %d %v", bits, err)
	}
	if !a.Closed() {
		t.Fatal("Escape did not close a window of its own")
	}
	if open, err := view.Pump(0); err != nil || open != 0 {
		t.Fatalf("pump with every window closed: %d %v", open, err)
	}
	a.Close()
	if _, err := a.NeedsDraw(); !errors.Is(err, view.ErrClosed) || err.Error() != "cadaclysm_view_needs_draw: the view is closed" {
		t.Fatalf("a closed view's needs_draw: %s", message(err))
	}
	if _, err := a.Input(view.Event{}); err == nil || err.Error() != "cadaclysm_view_input: the view is closed" {
		t.Fatalf("a closed view's input: %s", message(err))
	}
}

// Run reads the camera in the view's own up axis, then the window is closed.
func TestRunReadsTheCameraInTheViewsUpAxis(t *testing.T) {
	rig(t, "last_error", "create", "destroy", "run")
	for _, c := range []struct {
		up        string
		elevation float64
	}{{"y", 90}, {"z", 0}} {
		v, err := view.New(&view.Options{Up: c.up})
		if err != nil {
			t.Fatal(err)
		}
		cam, err := v.Run()
		if err != nil || math.Abs(cam.Elevation-c.elevation) > 1e-6 || cam.Pick != nil {
			t.Errorf("run, up %s: elevation %v (want %v), pick %v, %v", c.up, cam.Elevation, c.elevation, cam.Pick, err)
		}
		if _, err := v.Run(); !errors.Is(err, view.ErrWindowClosed) || err.Error() != "cadaclysm_view_run: the window is closed" {
			t.Errorf("run after run: %s", message(err))
		}
		v.Close()
	}
}

// A view belongs to the goroutine that made it: another goroutine's calls and Close are
// refused and change nothing; the maker's view works on.
func TestAnotherGoroutinesCallsAreRefused(t *testing.T) {
	rig(t, "last_error", "create", "destroy", "orbit", "needs_draw")
	v, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	refusals := make(chan [3]string)
	go func() {
		_, needs := v.NeedsDraw()
		refusals <- [3]string{message(v.Orbit(1, 1)), message(needs), message(v.Close())}
	}()
	got := <-refusals
	want := [3]string{"cadaclysm_view_orbit: a view belongs to the thread that made it",
		"cadaclysm_view_needs_draw: a view belongs to the thread that made it",
		"close: a view belongs to the thread that made it"}
	if got != want {
		t.Fatalf("another goroutine's calls: %q, want %q", got, want)
	}
	if v.Closed() {
		t.Fatal("another goroutine's Close closed the view")
	}
	if err := v.Orbit(1, 1); err != nil {
		t.Fatalf("the maker's view after another goroutine's calls: %v", err)
	}
	if _, err := v.NeedsDraw(); err != nil {
		t.Fatalf("the maker's needs_draw: %v", err)
	}
	if err := v.Close(); err != nil || !v.Closed() {
		t.Fatalf("the maker's close: %v", err)
	}
	if err := v.Orbit(1, 1); !errors.Is(err, view.ErrClosed) {
		t.Fatalf("closed: %s", message(err))
	}
}

// With no window of its own Pump just waits: a loop around it does not spin.
func TestPumpWithNoWindowWaits(t *testing.T) {
	start := time.Now()
	if open, err := view.Pump(40 * time.Millisecond); err != nil || open != 0 {
		t.Fatalf("pump: %d %v", open, err)
	}
	if waited := time.Since(start); waited < 40*time.Millisecond {
		t.Fatalf("pump(40 ms) returned after %v", waited)
	}
	start = time.Now()
	if _, err := view.Pump(-time.Hour); err != nil {
		t.Fatal(err)
	}
	if waited := time.Since(start); waited > 500*time.Millisecond {
		t.Fatalf("pump(-1 h) waited %v", waited)
	}
}

// The loader binds 95 calls of cadaclysm_view.h 1.22 (all but 1.14's analysis calls, 1.16's
// layers, 1.19's KMS pair and 1.12's texture targets): a 1.21 library (no snapping) is
// refused before any call is bound, in Python's words; 1.22 and later 1.x are taken.
func TestTheLoaderNeedsViewABI122(t *testing.T) {
	for _, ok := range []uint32{0x10016, 0x10017} {
		if err := view.CheckABIForTest(ok, "lib"); err != nil {
			t.Fatalf("%#x refused: %v", ok, err)
		}
	}
	for version, want := range map[uint32]string{
		0x10015: "lib: view ABI 1.21, this SDK needs 1.22 or a later 1.x",
		0x20016: "lib: view ABI 2.22, this SDK needs 1.22 or a later 1.x",
	} {
		if got := message(view.CheckABIForTest(version, "lib")); got != want {
			t.Fatalf("%#x: %s, want %s", version, got, want)
		}
	}
}

// coloursDrawn is one picture of everything that takes a colour, each given as text or as
// the numbers the text names (in the forms the package took before colour text, so those
// keep compiling): the background, a mesh, a solid and its face colours, an item
// recoloured, lines, curves; with a scene, a node's colour and highlight.
func coloursDrawn(t *testing.T, text bool, scene *cadaclysm.Scene) *image.RGBA {
	t.Helper()
	v, err := view.Offscreen(160, 120, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	defer v.Close()
	pick := func(words string, numbers view.Colour) view.Colour {
		if text {
			return words
		}
		return numbers
	}
	check := func(what string, err error) {
		t.Helper()
		if err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	check("grid off", v.Layer(view.LayerGrid, false))
	check("background", v.Background(pick("#ff0", [3]float32{1, 1, 0})))
	square := []float32{-4, -1, 0, -2, -1, 0, -2, 1, 0, -4, 1, 0}
	triangles := []uint32{0, 1, 2, 0, 2, 3}
	_, err = v.ShowMesh(view.Mesh{Positions: square, Indices: triangles, RGB: pick("Red", &[3]float32{1, 0, 0})})
	check("show_mesh", err)
	lifted := append([]float32(nil), square...)
	for i := 1; i < len(lifted); i += 3 {
		lifted[i] += 2.5
	}
	recoloured, err := v.ShowMesh(view.Mesh{Positions: lifted, Indices: triangles})
	check("show_mesh", err)
	check("colour", recoloured.Colour(pick("#00f", [3]float32{0, 0, 1})))
	cube, err := blacksmith.Cuboid(2, 2, 2)
	check("cuboid", err)
	defer cube.Close()
	solid, err := v.ShowSolid(cube, blacksmith.DefaultTolerance, pick("LIME", &[3]float32{0, 1, 0}))
	check("show_solid", err)
	if text {
		check("face_colours", solid.FaceColours([]uint32{0, 1}, []string{"00ff80", "black"}))
	} else {
		check("face_colours", solid.FaceColours([]uint32{0, 1}, [][4]float32{{0, 1, 128.0 / 255, 1}, {0, 0, 0, 1}}))
	}
	_, err = v.ShowLines([]float32{3, 0, 0, 5, 2, 2}, pick("#ffffff", &[3]float32{1, 1, 1}))
	check("show_lines", err)
	_, err = v.ShowCurves([]float32{3, -2, 0, 1, 4, -1, 0, 1, 5, -2, 1, 1, 6, -1, 0, 1},
		pick("purple", &[3]float32{128.0 / 255, 0, 128.0 / 255}))
	check("show_curves", err)
	if scene != nil {
		whole, err := v.ShowScene(scene)
		check("show the scene", err)
		check("node_colour", whole.NodeColour(0, pick("white", &[4]float32{1, 1, 1, 1})))
		check("node_highlight", whole.NodeHighlight(0, pick("#f00", &[4]float32{1, 0, 0, 1})))
	}
	check("iso", v.Standard("iso"))
	check("frame", v.Frame())
	picture, err := v.Image()
	check("image", err)
	return picture
}

// Colour text, read by the library's cadaclysm_view_parse_colour, draws the pixels its
// numbers draw in every call that takes a colour.
func TestColourTextDrawsItsNumbers(t *testing.T) {
	path := mechanism(t)
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	scene, err := cadaclysm.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer scene.Close()
	for _, with := range []*cadaclysm.Scene{nil, scene} {
		numbers, text := coloursDrawn(t, false, with), coloursDrawn(t, true, with)
		if n := differing(numbers, text); n != 0 || len(numbers.Pix) == 0 {
			t.Fatalf("colour text drew %d pixels unlike its numbers (with a scene: %v)", n, with != nil)
		}
	}
}

// Text the library refuses is refused with its message, and nothing reaches the view.
func TestRefusedColourTextIsTheLibrarysMessage(t *testing.T) {
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(64, 48, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	defer v.Close()
	square, err := v.ShowMesh(view.Mesh{Positions: []float32{-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0},
		Indices: []uint32{0, 1, 2, 0, 2, 3}, RGB: "gray"})
	if err != nil {
		t.Fatal(err)
	}
	if err := v.Standard("top"); err != nil {
		t.Fatal(err)
	}
	if err := v.Frame(); err != nil {
		t.Fatal(err)
	}
	before, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"blurple", "transparent", "rgb(1, 2, 3)", "#f00a", ""} {
		want := `cadaclysm_view_parse_colour: colour: "#rgb", "#rrggbb" or a CSS colour name, not '` + bad + "'"
		if got := message(square.Colour(bad)); got != want {
			t.Errorf("Colour(%q): %s", bad, got)
		}
	}
	cube, err := blacksmith.Cuboid(1, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer cube.Close()
	for what, err := range map[string]error{
		"Background":    v.Background("nope"),
		"ShowLines":     second(v.ShowLines([]float32{0, 0, 0, 1, 1, 1}, "nope")),
		"ShowCurves":    second(v.ShowCurves(make([]float32, 16), "nope")),
		"ShowMesh":      second(v.ShowMesh(view.Mesh{Positions: make([]float32, 9), Indices: []uint32{0, 1, 2}, RGB: "nope"})),
		"ShowSolid":     second(v.ShowSolid(cube, blacksmith.DefaultTolerance, "nope")),
		"FaceColours":   square.FaceColours([]uint32{0}, []string{"nope"}),
		"NodeColour":    square.NodeColour(0, "nope"),
		"NodeHighlight": square.NodeHighlight(0, "nope"),
	} {
		if !strings.HasSuffix(message(err), "not 'nope'") {
			t.Errorf("%s: %s", what, message(err))
		}
	}
	// Not a colour at all, and nil where a colour is needed: the package's own refusals.
	if got := message(square.Colour(42)); got != "colour 42: numbers ([3]float32, [4]float32) or text, not a int" {
		t.Errorf("Colour(42): %s", got)
	}
	if got := message(v.Background(nil)); got != "colour: nil is no colour (numbers or text)" {
		t.Errorf("Background(nil): %s", got)
	}
	after, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if n := differing(before, after); n != 0 {
		t.Fatalf("a refused colour reached the view: %d pixels changed", n)
	}
}

// textView is an offscreen wgpu view of size x size, the grid off, on a black background.
func textView(t *testing.T, size uint32) *view.View {
	t.Helper()
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(size, size, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	if err := v.Layer(view.LayerGrid, false); err != nil {
		t.Fatal(err)
	}
	if err := v.Background("black"); err != nil {
		t.Fatal(err)
	}
	return v
}

// pixelsOf counts img's pixels near pure red, lime (green) and blue.
func pixelsOf(img *image.RGBA) (red, lime, blue int) {
	for i := 0; i+3 < len(img.Pix); i += 4 {
		r, g, b := img.Pix[i], img.Pix[i+1], img.Pix[i+2]
		switch {
		case r > 200 && g < 60 && b < 60:
			red++
		case g > 200 && r < 60 && b < 60:
			lime++
		case b > 200 && r < 60 && g < 60:
			blue++
		}
	}
	return
}

// bundledFont is the bundled font's file in the repository tree; "" in an SDK layout.
func bundledFont(t *testing.T) string {
	t.Helper()
	path := filepath.Join("..", "..", "..", "..", "cadaclysm-text", "fonts", "LiberationSans-Regular.ttf")
	if _, err := os.Stat(path); err != nil {
		t.Logf("the bundled font's file is not here (an SDK layout): %v", err)
		return ""
	}
	return path
}

// Python's test_text_shows_changes_and_picks_its_line_on_the_real_library: a label shown,
// SetText giving it a second line, a pick answering the item and the line hit as its face;
// the bundled font's own bytes load, and a label in that font shows.
func TestTextShowsChangesAndPicksItsLine(t *testing.T) {
	v := textView(t, 96)
	defer v.Close()
	// Top left at the anchor, the picture's centre (48, 48): line 0 runs y 48..68, line 1 68..88.
	item, err := v.ShowText("one", [3]float32{}, &view.TextOptions{Size: 20, Colour: "red", Align: "top-left", OnTop: true})
	if err != nil {
		t.Fatal(err)
	}
	if hit, err := v.Pick(52, 58, 0); err != nil || ids(hit) != [4]uint32{item.ID(), 0, 0, 1} {
		t.Fatalf("pick on line 0: %+v %v (item %d)", hit, err, item.ID())
	}
	if hit, err := v.Pick(52, 78, 0); err != nil || hit.Item != 0 {
		t.Fatalf("one line: nothing below it, but %+v %v", hit, err)
	}
	before, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if err := item.SetText("one\ntwo"); err != nil {
		t.Fatal(err)
	}
	if hit, err := v.Pick(52, 78, 0); err != nil || ids(hit) != [4]uint32{item.ID(), 0, 1, 1} {
		t.Fatalf("the second line, after SetText: %+v %v (item %d)", hit, err, item.ID())
	}
	after, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if differing(before, after) == 0 {
		t.Fatal("SetText changed nothing in the picture")
	}
	path := bundledFont(t)
	if path == "" {
		return
	}
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	font, err := view.LoadFont(bytes)
	if err != nil || font < 1 {
		t.Fatalf("LoadFont of the bundled font's bytes: %d %v", font, err)
	}
	fromFile, err := view.LoadFontFile(path)
	if err != nil || fromFile < 1 {
		t.Fatalf("LoadFontFile of the bundled font: %d %v", fromFile, err)
	}
	other, err := v.ShowText("HHH", [3]float32{}, &view.TextOptions{Size: 20, Colour: "red", OnTop: true, Font: font})
	if err != nil {
		t.Fatalf("a label in a loaded font: %v", err)
	}
	if other.ID() <= item.ID() {
		t.Fatalf("the label in a loaded font is item %d, after %d", other.ID(), item.ID())
	}
}

// Lime glyphs on a red box draw both colours, the box the larger; without a box no red
// remains; a nil Padding is 4 (a larger box than Padding 0).
func TestTextDrawsItsColourOnItsBox(t *testing.T) {
	label := func(o *view.TextOptions) *image.RGBA {
		t.Helper()
		v := textView(t, 64)
		defer v.Close()
		if _, err := v.ShowText("HH", [3]float32{}, o); err != nil {
			t.Fatal(err)
		}
		img, err := v.Image()
		if err != nil {
			t.Fatal(err)
		}
		return img
	}
	red, lime, _ := pixelsOf(label(&view.TextOptions{Colour: "lime", Size: 24, Align: "centre", Box: "red", OnTop: true}))
	if lime <= 20 || red <= 50 || red <= lime {
		t.Fatalf("lime glyphs on a red box: %d lime, %d red pixels", lime, red)
	}
	noBoxRed, noBoxLime, _ := pixelsOf(label(&view.TextOptions{Colour: "lime", Size: 24, Align: "center", OnTop: true}))
	if noBoxRed != 0 || noBoxLime <= 20 {
		t.Fatalf("without a box: %d red, %d lime pixels", noBoxRed, noBoxLime)
	}
	// Numbers as well: three for the glyphs, four (with an alpha) for the box.
	_, numberLime, numberBlue := pixelsOf(label(&view.TextOptions{Colour: [3]float32{0, 1, 0}, Size: 24, Align: "centre",
		Box: [4]float32{0, 0, 1, 1}, OnTop: true}))
	if numberLime <= 20 || numberBlue <= 50 {
		t.Fatalf("number colours: %d lime, %d blue pixels", numberLime, numberBlue)
	}
	zero := float32(0)
	tight, _, _ := pixelsOf(label(&view.TextOptions{Colour: "lime", Size: 24, Align: "centre", Box: "red", Padding: &zero, OnTop: true}))
	if tight >= red {
		t.Fatalf("Padding 0 drew a box of %d red pixels, the default (4) %d", tight, red)
	}
}

// A nil *TextOptions, a zero TextOptions and DefaultTextOptions draw the same white
// 12-pixel label; the text layer off hides text (the picture of a blank view), on shows it.
func TestTextDefaultsAndItsLayer(t *testing.T) {
	blankView := textView(t, 64)
	defer blankView.Close()
	blank, err := blankView.Image()
	if err != nil {
		t.Fatal(err)
	}
	drawn := func(o *view.TextOptions) *image.RGBA {
		t.Helper()
		v := textView(t, 64)
		defer v.Close()
		if _, err := v.ShowText("Hi", [3]float32{}, o); err != nil {
			t.Fatal(err)
		}
		img, err := v.Image()
		if err != nil {
			t.Fatal(err)
		}
		return img
	}
	defaults := drawn(view.DefaultTextOptions())
	if differing(defaults, blank) == 0 {
		t.Fatal("the default label drew nothing")
	}
	for what, img := range map[string]*image.RGBA{"nil": drawn(nil), "zero": drawn(&view.TextOptions{})} {
		if n := differing(img, defaults); n != 0 {
			t.Fatalf("%s options drew %d pixels unlike DefaultTextOptions", what, n)
		}
	}
	if n := differing(drawn(&view.TextOptions{Size: 16}), defaults); n == 0 {
		t.Fatal("Size 16 drew the default 12-pixel label")
	}
	if n := differing(drawn(&view.TextOptions{Align: "top-right"}), defaults); n == 0 {
		t.Fatal("Align top-right drew the default bottom-left label")
	}
	v := textView(t, 64)
	defer v.Close()
	if _, err := v.ShowText("HH", [3]float32{}, &view.TextOptions{Size: 24, Align: "centre", OnTop: true}); err != nil {
		t.Fatal(err)
	}
	if err := v.Layer(view.LayerText, false); err != nil {
		t.Fatal(err)
	}
	off, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if n := differing(off, blank); n != 0 {
		t.Fatalf("the text layer off: %d pixels unlike a blank view", n)
	}
	if err := v.Layer(view.LayerText, true); err != nil {
		t.Fatal(err)
	}
	on, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if differing(on, blank) == 0 {
		t.Fatal("the text layer on shows nothing")
	}
}

// Text's refusals, in Python's words: an unknown mode or align, a NUL (before any call),
// the library's own reasons (a size not finite and positive, an unknown font, bytes that
// are no font), a font file that cannot be read, and a closed view.
func TestTextRefusals(t *testing.T) {
	v := textView(t, 64)
	item, err := v.ShowText("ok", [3]float32{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	for what, c := range map[string]struct {
		got  error
		want string
	}{
		"mode":              {second(v.ShowText("x", [3]float32{}, &view.TextOptions{Mode: "screen"})), "mode 'screen': one of label, world"},
		"align":             {second(v.ShowText("x", [3]float32{}, &view.TextOptions{Align: "middle"})), "align 'middle': one of top-left, top, top-right, left, centre, center, right, bottom-left, bottom, bottom-right"},
		"NUL":               {second(v.ShowText("a\x00b", [3]float32{}, nil)), `text 'a\x00b': a NUL character cannot be shown (the C string ends there)`},
		"NUL in SetText":    {item.SetText("a\x00b"), `text 'a\x00b': a NUL character cannot be shown (the C string ends there)`},
		"mode before align": {second(v.ShowText("a\x00b", [3]float32{}, &view.TextOptions{Mode: "screen", Align: "middle"})), "mode 'screen': one of label, world"},
		"align before NUL":  {second(v.ShowText("a\x00b", [3]float32{}, &view.TextOptions{Align: "middle"})), "align 'middle': one of top-left, top, top-right, left, centre, center, right, bottom-left, bottom, bottom-right"},
	} {
		if got := message(c.got); got != c.want {
			t.Errorf("%s: %s, want %s", what, got, c.want)
		}
	}
	// "world" and "center" are taken.
	if _, err := v.ShowText("w", [3]float32{}, &view.TextOptions{Mode: "world", Align: "center", Size: 0.5}); err != nil {
		t.Errorf("world text, centred: %v", err)
	}
	if got := message(second(v.ShowText("x", [3]float32{}, &view.TextOptions{Size: -1}))); !strings.HasPrefix(got, "cadaclysm_view_show_text: ") || !strings.Contains(got, "height") {
		t.Errorf("Size -1: %s", got)
	}
	if got := message(second(v.ShowText("x", [3]float32{}, &view.TextOptions{Font: 999}))); !strings.HasPrefix(got, "cadaclysm_view_show_text: ") || !strings.Contains(got, "font") {
		t.Errorf("an unknown font: %s", got)
	}
	parallel := [3]float32{1, 0, 0}
	if got := message(second(v.ShowText("x", [3]float32{}, &view.TextOptions{Mode: "world", Right: &parallel, Up: &parallel}))); !strings.HasPrefix(got, "cadaclysm_view_show_text: ") {
		t.Errorf("world Right and Up parallel: %s", got)
	}
	if got := message(second(v.ShowText("x", [3]float32{}, &view.TextOptions{Colour: "nope"}))); !strings.HasSuffix(got, "not 'nope'") {
		t.Errorf("colour text refused: %s", got)
	}
	if got := message(second(v.ShowText("x", [3]float32{}, &view.TextOptions{Box: "nope"}))); !strings.HasSuffix(got, "not 'nope'") {
		t.Errorf("box colour text refused: %s", got)
	}
	if got := message(second2(view.LoadFont([]byte("not a font at all")))); !strings.HasPrefix(got, "cadaclysm_view_load_font: ") || !strings.Contains(got, "font") {
		t.Errorf("garbage font bytes: %s", got)
	}
	if _, err := view.LoadFont(nil); err == nil {
		t.Error("no font bytes at all were taken")
	}
	missing := filepath.Join(t.TempDir(), "no-such-font.ttf")
	if got := message(second2(view.LoadFontFile(missing))); !strings.HasPrefix(got, missing+": the font could not be read (") {
		t.Errorf("an unreadable font file: %s", got)
	}
	if err := v.Close(); err != nil {
		t.Fatal(err)
	}
	if err := second(v.ShowText("x", [3]float32{}, nil)); !errors.Is(err, view.ErrClosed) || message(err) != "cadaclysm_view_show_text: the view is closed" {
		t.Errorf("ShowText on a closed view: %s", message(err))
	}
	if err := item.SetText("x"); !errors.Is(err, view.ErrClosed) || message(err) != "cadaclysm_view_set_text: the view is closed" {
		t.Errorf("SetText on a closed view: %s", message(err))
	}
}

func second2(_ uint32, err error) error { return err }

// A NUL is refused before the library is reached: the label keeps its picture (the library
// would have taken "cut", the C string's part before the NUL).
func TestANulInTextNeverReachesTheLibrary(t *testing.T) {
	v := textView(t, 64)
	defer v.Close()
	item, err := v.ShowText("ok", [3]float32{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	before, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if err := item.SetText("cut\x00short"); err == nil {
		t.Fatal("a NUL in SetText was taken")
	}
	after, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if n := differing(before, after); n != 0 {
		t.Fatalf("a refused SetText reached the view: %d pixels changed", n)
	}
}

// ---- view ABI 1.8: the pick's clicks and point, the double-click opt-in, focus, navigation ----

// ids is a pick's numbers: item, node, face, clicks.
func ids(p view.Pick) [4]uint32 { return [4]uint32{p.Item, p.Node, p.Face, p.Clicks} }

// A pick answer and Run's pick carry Clicks, and Point only where the library set one.
func TestAPickCarriesClicksAndThePointOnlyWhereSet(t *testing.T) {
	rig(t, "last_error", "create", "destroy", "draw", "request_pick_in", "pick_result", "run")
	v, err := view.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	viewrig.SetPick(3, 4, 5, 2, true, [3]float32{1.5, -2, 0.25})
	hit, err := v.Pick(1, 1, 0)
	if err != nil || ids(hit) != [4]uint32{3, 4, 5, 2} {
		t.Fatalf("a double click's hit: %+v %v", hit, err)
	}
	if !hit.HasPoint || hit.Point != [3]float32{1.5, -2, 0.25} {
		t.Fatalf("the point it hit: %v %v", hit.HasPoint, hit.Point)
	}
	// A Pick is a value: == compares what was picked, never where it was kept.
	if want := (view.Pick{Item: 3, Node: 4, Face: 5, Clicks: 2, HasPoint: true, Point: [3]float32{1.5, -2, 0.25}}); hit != want {
		t.Fatalf("a pick compared by value: %+v != %+v", hit, want)
	}
	viewrig.SetPick(3, 4, 5, 1, false, [3]float32{9, 9, 9})
	flat, err := v.Pick(1, 1, 0)
	if err != nil || flat != (view.Pick{Item: 3, Node: 4, Face: 5, Clicks: 1}) {
		t.Fatalf("has_point 0: the point bytes mean nothing, but %+v %v", flat, err)
	}
	viewrig.SetPick(7, 0, 0, 2, true, [3]float32{1, 2, 3})
	if hit, landed, err := v.LastPick(); err != nil || !landed || hit != (view.Pick{Item: 7, Clicks: 2, HasPoint: true, Point: [3]float32{1, 2, 3}}) {
		t.Fatalf("the landed answer: %+v %v %v", hit, landed, err)
	}
	viewrig.SetPick(7, 0, 0, 2, false, [3]float32{1, 2, 3})
	cam, err := v.Run()
	if err != nil || cam.Pick == nil || *cam.Pick != (view.Pick{Item: 7, Clicks: 2}) {
		t.Fatalf("run's pick: %+v %v", cam.Pick, err)
	}
}

func TestTheSnapStructIsTheHeaders(t *testing.T) {
	want := [12]uintptr{88, 4, 8, 32, 36, 40, 44, 48, 60, 72, 80, 84}
	if got := view.SnapLayoutForTest(); got != want {
		t.Fatalf("CadaclysmViewSnap: size and offsets %v, want %v", got, want)
	}
	if view.SnapVertex != 1 || view.SnapFace != 32 || view.SnapPlane != 128 || view.SnapAll != 0xFF {
		t.Fatal("the snap kinds' bits moved")
	}
	if got := (view.SnapVertex | view.SnapEdge).String(); got != "vertex|edge" {
		t.Fatalf("kinds' names: %q", got)
	}
	if got := view.SnapKind(0).String(); got != "" {
		t.Fatalf("no kind: %q", got)
	}
}

// SetSnap hands the library the kinds' bits, the aperture and the marker; Snap and LastSnap
// read the answer whole (no edge for a face snap, Kind 0 for nothing); ClearSnap,
// SetWorkPlane and ClearWorkPlane reach the library with their arguments.
func TestSnapSettingsAndAnswersReachTheLibrary(t *testing.T) {
	rig(t, "last_error", "create", "destroy", "draw", "set_snap", "request_snap_in", "snap_result", "clear_snap",
		"set_work_plane", "clear_work_plane")
	v, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	for _, c := range []struct {
		kinds      view.SnapKind
		aperture   float32
		marker     bool
		wantMarker uint32
	}{
		{view.SnapAll, 0, true, 1},
		{view.SnapVertex | view.SnapEdge, 6, false, 0},
		{0, 0, true, 1},
	} {
		if err := v.SetSnap(c.kinds, c.aperture, c.marker); err != nil {
			t.Fatal(err)
		}
		size, kinds, aperture, marker, _ := viewrig.SnapSettings()
		if size != 16 || kinds != uint32(c.kinds) || aperture != c.aperture || marker != c.wantMarker {
			t.Fatalf("SetSnap(%#x, %v, %v) handed size %d, kinds %#x, aperture %v, marker %d",
				uint32(c.kinds), c.aperture, c.marker, size, kinds, aperture, marker)
		}
	}

	viewrig.SetSnapAnswer(viewrig.Answer{Kind: 1, Point: [3]float64{-1, 1, 0}, Item: 3, Node: 4, Face: 5, Edge: 2,
		Tangent: [3]float32{1, 0, 0}, DistancePx: 2.5})
	s, err := v.Snap(10, 20, 1)
	want := view.Snap{Kind: view.SnapVertex, Point: [3]float64{-1, 1, 0}, Item: 3, Node: 4, Face: 5, Edge: 2, HasEdge: true,
		Tangent: [3]float32{1, 0, 0}, DistancePx: 2.5}
	if err != nil || s != want {
		t.Fatalf("the vertex snap: %+v %v, want %+v", s, err, want)
	}
	if got := viewrig.Log(); got != "snap 1 10 20" {
		t.Fatalf("snap asked %q", got)
	}
	viewrig.SetSnapAnswer(viewrig.Answer{Kind: 4, Item: 3, Axis: [3]float32{0, 0, 1}, Radius: 2.5})
	if s, err := v.Snap(1, 1, 0); err != nil || s.Kind != view.SnapCentre || s.Axis != [3]float32{0, 0, 1} || s.Radius != 2.5 {
		t.Fatalf("the centre snap: %+v %v", s, err)
	}
	viewrig.SetSnapAnswer(viewrig.Answer{Kind: 32, Item: 3, Face: 5, Edge: 0xFFFFFFFF})
	if s, err := v.Snap(1, 1, 0); err != nil || s.Kind != view.SnapFace || s.HasEdge || s.Edge != 0 {
		t.Fatalf("a face snap has no edge: %+v %v", s, err)
	}
	viewrig.SetSnapAnswer(viewrig.Answer{Edge: 0xFFFFFFFF})
	if s, err := v.Snap(1, 1, 0); err != nil || s.Kind != 0 {
		t.Fatalf("kind 0 is nothing snapped: %+v %v", s, err)
	}

	viewrig.SetSnapAnswer(viewrig.Answer{Kind: 16, Item: 3, Edge: 1, Clicks: 1})
	if s, landed, err := v.LastSnap(); err != nil || !landed || s.Kind != view.SnapEdge || s.Clicks != 1 {
		t.Fatalf("the landed answer: %+v %v %v", s, landed, err)
	}
	viewrig.SnapLanded(false)
	viewrig.Say("cadaclysm_view_snap_result: no snap result")
	if _, landed, err := v.LastSnap(); err != nil || landed {
		t.Fatalf("nothing landed yet: %v %v", landed, err)
	}
	viewrig.Say("boom from snap_result")
	if _, _, err := v.LastSnap(); message(err) != "boom from snap_result" {
		t.Fatalf("the library's refusal: %s", message(err))
	}
	viewrig.Say("")
	viewrig.SnapLanded(true)

	if err := v.ClearSnap(); err != nil {
		t.Fatal(err)
	}
	if err := v.SetWorkPlane([3]float64{1, 2, 3}, [3]float64{1, 0, 0}, [3]float64{0, 0, 1}, 0.5); err != nil {
		t.Fatal(err)
	}
	if err := v.ClearWorkPlane(); err != nil {
		t.Fatal(err)
	}
	if got, tail := viewrig.Log(), "clear snap; work plane 1 2 3, 1 0 0, 0 0 1, 0.5; ground plane"; !strings.HasSuffix(got, tail) {
		t.Fatalf("the library saw %q", got)
	}
}

// Python's test_a_snap_on_the_real_library_finds_the_squares_corner and
// test_snapping_is_off_until_set_snap: the red square with its four sides, from the top, on a
// 64 x 48 view. Snapping is off until SetSnap; then a snap 3 pixels inside the topmost (then
// leftmost) pixel that is not the background answers that corner, (-1, 1, 0), as a vertex of
// the square's item; a face snap lands on the face; off again, nothing.
func TestASnapFindsTheSquaresCorner(t *testing.T) {
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(64, 48, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	defer v.Close()
	if err := v.Layer(view.LayerGrid, false); err != nil {
		t.Fatal(err)
	}
	square := []float32{-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0}
	var outline []float32
	for i := 0; i < 4; i++ {
		for _, k := range []int{i, (i + 1) % 4} {
			outline = append(outline, square[3*k:3*k+3]...)
		}
	}
	item, err := v.ShowMesh(view.Mesh{Positions: square, Indices: []uint32{0, 1, 2, 0, 2, 3}, Edges: outline,
		RGB: &[3]float32{1, 0, 0}})
	if err != nil {
		t.Fatal(err)
	}
	if err := v.Standard("top"); err != nil {
		t.Fatal(err)
	}
	if err := v.Frame(); err != nil {
		t.Fatal(err)
	}
	img, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	if s, err := v.Snap(32, 24, 0); err != nil || s.Kind != 0 {
		t.Fatalf("a view starts with snapping off: %+v %v", s, err)
	}
	if err := v.SetSnap(view.SnapAll, 0, true); err != nil {
		t.Fatal(err)
	}
	bg := img.RGBAAt(0, 0)
	cx, cy := -1, -1
	for y := 0; y < img.Bounds().Dy() && cy < 0; y++ {
		for x := 0; x < img.Bounds().Dx(); x++ {
			if p := img.RGBAAt(x, y); p.R != bg.R || p.G != bg.G || p.B != bg.B {
				cx, cy = x, y
				break
			}
		}
	}
	if cy < 0 {
		t.Fatal("the square drew nothing")
	}
	s, err := v.Snap(uint32(cx+3), uint32(cy+3), 0)
	if err != nil || s.Kind != view.SnapVertex || s.Item != item.ID() {
		t.Fatalf("the corner's snap: %+v %v (item %d)", s, err, item.ID())
	}
	for i, want := range [3]float64{-1, 1, 0} {
		if math.Abs(s.Point[i]-want) > 1e-6 {
			t.Fatalf("the corner is (-1, 1, 0), not %v", s.Point)
		}
	}
	if !s.HasEdge || s.Clicks != 0 {
		t.Fatalf("a vertex snap lies on an edge, asked by the host: %+v", s)
	}
	if err := v.ClearSnap(); err != nil {
		t.Fatal(err)
	}
	if err := v.SetSnap(view.SnapFace, 0, true); err != nil {
		t.Fatal(err)
	}
	if f, err := v.Snap(32, 24, 0); err != nil || f.Kind != view.SnapFace || f.Item != item.ID() || f.HasEdge {
		t.Fatalf("the face snap: %+v %v", f, err)
	}
	if err := v.SetSnap(0, 0, true); err != nil {
		t.Fatal(err)
	}
	if n, err := v.Snap(32, 24, 0); err != nil || n.Kind != 0 {
		t.Fatalf("snapping off answers nothing: %+v %v", n, err)
	}
}

// SetDoubleClickFrames, Focus and Navigation reach the library with their arguments; a
// point the library refuses is its own reason.
func TestDoubleClickFramesFocusAndNavigationReachTheLibrary(t *testing.T) {
	rig(t, "last_error", "create", "destroy", "set_double_click_frames", "focus", "navigation")
	v, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	if err := v.SetDoubleClickFrames(true); err != nil {
		t.Fatal(err)
	}
	if err := v.SetDoubleClickFrames(false); err != nil {
		t.Fatal(err)
	}
	if err := v.Focus([3]float32{1, -2, 3.5}); err != nil {
		t.Fatal(err)
	}
	if n, err := v.Navigation(); err != nil || n != view.NavigationOrbit || n.String() != "orbit" {
		t.Fatalf("navigation: %v %v", n, err)
	}
	viewrig.SetNavigation(1)
	if n, err := v.Navigation(); err != nil || n != view.NavigationFly || n.String() != "fly" {
		t.Fatalf("navigation: %v %v", n, err)
	}
	want := "double click frames on; double click frames off; focus 1 -2 3.5; navigation; navigation"
	if got := viewrig.Log(); got != want {
		t.Fatalf("the library saw %q, want %q", got, want)
	}
	if err := v.Focus([3]float32{float32(math.NaN()), 0, 0}); message(err) != "cadaclysm_view_focus: the point is not finite" {
		t.Fatalf("a point not finite: %s", message(err))
	}
	v.Close()
	if err := v.Focus([3]float32{}); !errors.Is(err, view.ErrClosed) || err.Error() != "cadaclysm_view_focus: the view is closed" {
		t.Fatalf("focus on a closed view: %s", message(err))
	}
	if _, err := v.Navigation(); !errors.Is(err, view.ErrClosed) {
		t.Fatalf("navigation on a closed view: %s", message(err))
	}
	if err := v.SetDoubleClickFrames(true); !errors.Is(err, view.ErrClosed) {
		t.Fatalf("set_double_click_frames on a closed view: %s", message(err))
	}
}

// framedSquare is a red square seen from the top, zoomed out so a framing visibly changes the
// picture, on a 64 x 48 offscreen wgpu view.
func framedSquare(t *testing.T) (*view.View, *view.Item) {
	t.Helper()
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(64, 48, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	if err := v.Layer(view.LayerGrid, false); err != nil {
		t.Fatal(err)
	}
	item, err := v.ShowMesh(view.Mesh{Positions: []float32{-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0},
		Indices: []uint32{0, 1, 2, 0, 2, 3}, RGB: &[3]float32{1, 0, 0}})
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range []error{v.Standard("top"), v.Frame(), v.Zoom(-3), v.Draw()} {
		if step != nil {
			t.Fatal(step)
		}
	}
	return v, item
}

// doubleClick is down, up, down, up of the left button at one pixel within the double-click time.
func doubleClick(t *testing.T, v *view.View, x, y float32) {
	t.Helper()
	for _, e := range []struct {
		kind uint32
		at   float64
	}{{view.EventDown, 0}, {view.EventUp, 10}, {view.EventDown, 60}, {view.EventUp, 70}} {
		if _, err := v.Input(view.Event{Kind: e.kind, Pointer: view.PointerMouse, Button: view.ButtonLeft, X: x, Y: y, TimeMS: 1000 + e.at}); err != nil {
			t.Fatal(err)
		}
	}
}

// land is the answer an input asked for, read through LastPick as the view's draws land it
// (ten seconds of wall time, 10 ms a draw, as Python's pick waits).
func land(t *testing.T, v *view.View) view.Pick {
	t.Helper()
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		if err := v.Draw(); err != nil {
			t.Fatal(err)
		}
		hit, landed, err := v.LastPick()
		if err != nil {
			t.Fatal(err)
		}
		if landed {
			return hit
		}
	}
	t.Fatal("the pick never landed")
	return view.Pick{}
}

func image0(t *testing.T, v *view.View) *image.RGBA {
	t.Helper()
	img, err := v.Image()
	if err != nil {
		t.Fatal(err)
	}
	return img
}

// A double click through Input answers Clicks 2 with the point hit and leaves the picture.
func TestADoubleClickAnswersClicks2AndLeavesThePicture(t *testing.T) {
	v, item := framedSquare(t)
	defer v.Close()
	before := image0(t, v)
	if hit, landed, err := v.LastPick(); err != nil || landed {
		t.Fatalf("nothing clicked yet, but LastPick: %+v %v %v", hit, landed, err)
	}
	doubleClick(t, v, 32, 24)
	hit := land(t, v)
	if hit.Item != item.ID() || hit.Clicks != 2 {
		t.Fatalf("a double click's answer: %+v (item %d)", hit, item.ID())
	}
	if !hit.HasPoint || math.Abs(float64(hit.Point[2])) > 1e-3 || math.Abs(float64(hit.Point[0])) > 0.2 {
		t.Fatalf("the square's centre, z 0: %v %v", hit.HasPoint, hit.Point)
	}
	if n := differing(before, image0(t, v)); n != 0 {
		t.Fatalf("a double click moved the picture by default: %d pixels changed", n)
	}
	if again, landed, err := v.LastPick(); err != nil || landed {
		t.Fatalf("each answer is read once, but LastPick: %+v %v %v", again, landed, err)
	}
	// One click on the background, well after: landed, with nothing hit.
	for _, e := range []struct {
		kind uint32
		at   float64
	}{{view.EventDown, 5000}, {view.EventUp, 5010}} {
		if _, err := v.Input(view.Event{Kind: e.kind, Pointer: view.PointerMouse, Button: view.ButtonLeft, X: 1, Y: 1, TimeMS: e.at}); err != nil {
			t.Fatal(err)
		}
	}
	if miss := land(t, v); miss.Item != 0 || miss.HasPoint || miss.Clicks != 1 {
		t.Fatalf("a click on the background: %+v, want Item 0, no point, Clicks 1", miss)
	}
}

// SetDoubleClickFrames(true) makes the same double click frame what it hit.
func TestOptedInADoubleClickFrames(t *testing.T) {
	v, _ := framedSquare(t)
	defer v.Close()
	before := image0(t, v)
	if err := v.SetDoubleClickFrames(true); err != nil {
		t.Fatal(err)
	}
	doubleClick(t, v, 32, 24)
	if hit := land(t, v); hit.Clicks != 2 {
		t.Fatalf("opted in: still a pick of clicks 2, but %+v", hit)
	}
	if n := differing(before, image0(t, v)); n == 0 {
		t.Fatal("opted in, the double click did not frame what it hit")
	}
}

// Navigation is fly after a fly key (and stays after it is let go), Tab toggles it, Focus
// leaves it.
func TestNavigationFliesAfterAFlyKeyUntilTabOrFocus(t *testing.T) {
	v, _ := framedSquare(t)
	defer v.Close()
	key := func(k string) {
		for _, down := range []bool{true, false} {
			if _, err := v.Input(view.Event{Kind: view.EventKey, Key: k, KeyDown: down}); err != nil {
				t.Fatal(err)
			}
		}
	}
	nav := func() view.Navigation {
		n, err := v.Navigation()
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := nav(); n != view.NavigationOrbit {
		t.Fatalf("a new view: %v", n)
	}
	key("KeyW")
	if n := nav(); n != view.NavigationFly {
		t.Fatalf("after KeyW (let go): %v, want fly", n)
	}
	key("Tab")
	if n := nav(); n != view.NavigationOrbit {
		t.Fatalf("after Tab: %v, want orbit", n)
	}
	key("KeyW")
	if err := v.Focus([3]float32{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	if n := nav(); n != view.NavigationOrbit {
		t.Fatalf("after Focus: %v, want orbit", n)
	}
}

// Focus moves the orbit point -- the centre then looks at it -- and focus back restores the
// picture; a point not finite is the library's refusal.
func TestFocusMovesTheOrbitPoint(t *testing.T) {
	v, _ := framedSquare(t)
	defer v.Close()
	before := image0(t, v)
	if hit, err := v.Pick(32, 24, 0); err != nil || !hit.HasPoint || math.Abs(float64(hit.Point[0])) > 0.2 {
		t.Fatalf("the centre looks at the middle of the square: %+v %v", hit, err)
	}
	if err := v.Focus([3]float32{0.5, 0, 0}); err != nil {
		t.Fatal(err)
	}
	if hit, err := v.Pick(32, 24, 0); err != nil || !hit.HasPoint || math.Abs(float64(hit.Point[0])-0.5) > 0.1 {
		t.Fatalf("the centre now looks at x = 0.5: %+v %v", hit, err)
	}
	if n := differing(before, image0(t, v)); n == 0 {
		t.Fatal("focus did not move the picture")
	}
	if err := v.Focus([3]float32{0, 0, 0}); err != nil {
		t.Fatal(err)
	}
	if n := differing(before, image0(t, v)); n != 0 {
		t.Fatalf("focus back did not restore the picture: %d pixels changed", n)
	}
	if err := v.Focus([3]float32{float32(math.Inf(1)), 0, 0}); err == nil || !strings.HasPrefix(err.Error(), "cadaclysm_view_focus") {
		t.Fatalf("a point not finite: %s", message(err))
	}
}

// ---- view ABI 1.7: the machining view and the timeline ----

var machiningCalls = []string{"last_error", "create", "destroy", "show_machining", "remove", "machining_seek",
	"machining_colour_by", "machining_overlays", "machining_info", "machining_heights", "timeline_play",
	"timeline_pause", "timeline_seek", "timeline_set_loop", "timeline_time", "timeline_duration",
	"timeline_playing", "timeline_status"}

func ptr(x float64) *float64 { return &x }

var (
	flatTool   = view.MachiningTool{Number: 3, Shape: "flat", Diameter: 6, FluteLength: 20}
	boxStock   = view.MachiningStock{Min: [3]float64{-42, -27, 0}, Max: [3]float64{42, 27, 14}}
	oneProgram = []view.MachiningProgram{{Tool: flatTool, Gcode: "G0 X1"}}
)

func machiningRig(t *testing.T) (*view.View, *view.Machining) {
	t.Helper()
	rig(t, machiningCalls...)
	v, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { v.Close() })
	m, err := v.ShowMachining(oneProgram, boxStock, nil, nil)
	if err != nil || m == nil || m.ID() != 21 {
		t.Fatalf("show_machining: %v", err)
	}
	return v, m
}

// F1: programs, stock, part and options reach the library as given (every array C memory
// the library could read), with the struct sizes, and no part and no options are NULL and
// zeros -- a skin of 0 is given (skin_set 1), no skin is not.
func TestShowMachiningReachesTheContractAndReturnsAMachining(t *testing.T) {
	rig(t, machiningCalls...)
	v, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	programs := []view.MachiningProgram{
		{Tool: view.MachiningTool{Number: 1, Shape: "flat", Diameter: 6, FluteLength: 20}, Gcode: "G0 X1\nG1 Z-1 F100"},
		{Tool: view.MachiningTool{Number: 2, Shape: "vbit", Diameter: 8, Angle: 90}, Gcode: "M30"},
		{Tool: view.MachiningTool{Number: 3, Shape: "bullnose", Diameter: 10, CornerRadius: 1.5}, Gcode: ""},
	}
	part := &view.MachiningPart{Positions: []float32{0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0}, Indices: []uint32{0, 1, 2, 2, 1, 3}}
	m, err := v.ShowMachining(programs, boxStock, part, &view.MachiningOptions{Cell: ptr(0.5), Tolerance: ptr(0.02), Skin: ptr(0), RapidRate: ptr(4000)})
	if err != nil || m == nil || m.ID() != 21 || m.Item == nil {
		t.Fatalf("show_machining: %v", err)
	}
	s := viewrig.Machining()
	if s.Calls != 1 || s.ProgramCount != 3 || len(s.Programs) != 3 {
		t.Fatalf("the library saw %d calls, %d programs", s.Calls, s.ProgramCount)
	}
	if s.Size == 0 || s.ProgramSize == 0 || s.Programs[1].Size != s.ProgramSize || s.Programs[2].Size != s.ProgramSize {
		t.Fatalf("sizes: struct %d, programs %d, %d, %d", s.Size, s.ProgramSize, s.Programs[1].Size, s.Programs[2].Size)
	}
	want := []viewrig.ProgramSeen{
		{Size: s.ProgramSize, Number: 1, Shape: 0, Diameter: 6, FluteLength: 20, Gcode: "G0 X1\nG1 Z-1 F100"},
		{Size: s.ProgramSize, Number: 2, Shape: 3, Diameter: 8, Angle: 90, Gcode: "M30"},
		{Size: s.ProgramSize, Number: 3, Shape: 4, Diameter: 10, CornerRadius: 1.5, Gcode: ""},
	}
	for i := range want {
		if s.Programs[i] != want[i] {
			t.Errorf("program %d: %+v, wanted %+v", i, s.Programs[i], want[i])
		}
	}
	if s.StockMin != boxStock.Min || s.StockMax != boxStock.Max {
		t.Errorf("stock %v %v", s.StockMin, s.StockMax)
	}
	if s.PartNull || s.PartVertices != 4 || s.PartIndices != 6 || !sameFloats(s.PartPositions, part.Positions) || len(s.PartTriangles) != 6 || s.PartTriangles[5] != 3 {
		t.Errorf("part: %+v", s)
	}
	if s.Cell != 0.5 || s.Tolerance != 0.02 || s.Skin != 0 || s.SkinSet != 1 || s.RapidRate != 4000 {
		t.Errorf("options: %+v", s)
	}

	if _, err := v.ShowMachining(oneProgram, boxStock, nil, nil); err != nil {
		t.Fatal(err)
	}
	s = viewrig.Machining()
	if !s.PartNull || s.PartVertices != 0 || s.PartIndices != 0 || s.Cell != 0 || s.Tolerance != 0 || s.RapidRate != 0 || s.SkinSet != 0 {
		t.Errorf("no part, no options: %+v", s)
	}
	if _, err := v.ShowMachining(oneProgram, boxStock, nil, &view.MachiningOptions{}); err != nil || viewrig.Machining().SkinSet != 0 {
		t.Errorf("empty options: %v, skin_set %d", err, viewrig.Machining().SkinSet)
	}
	// An empty part is a part of nothing: counts 0, the arrays not NULL.
	if _, err := v.ShowMachining(oneProgram, boxStock, &view.MachiningPart{}, nil); err != nil || viewrig.Machining().PartNull || viewrig.Machining().PartVertices != 0 {
		t.Errorf("an empty part: %v, %+v", err, viewrig.Machining())
	}
	// No programs reach the library, which refuses them in its own words, as Python's.
	viewrig.Say("cadaclysm_view_show_machining: at least one program")
	before := viewrig.Machining().Calls
	if _, err := v.ShowMachining(nil, boxStock, nil, nil); message(err) != "cadaclysm_view_show_machining: at least one program" || viewrig.Machining().Calls != before+1 {
		t.Errorf("no programs: %s", message(err))
	}
}

// F2: what is wrong is refused before the library, in Python's words.
func TestShowMachiningRefusalsNeverReachTheLibrary(t *testing.T) {
	rig(t, machiningCalls...)
	v, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	nan, inf := math.NaN(), math.Inf(1)
	withTool := func(f func(*view.MachiningTool)) []view.MachiningProgram {
		tool := flatTool
		f(&tool)
		return []view.MachiningProgram{{Tool: tool, Gcode: "G0"}}
	}
	triangle := []float32{0, 0, 0, 1, 0, 0, 0, 1, 0}
	cases := []struct {
		name     string
		programs []view.MachiningProgram
		stock    view.MachiningStock
		part     *view.MachiningPart
		options  *view.MachiningOptions
		want     string
	}{
		{"shape", withTool(func(x *view.MachiningTool) { x.Shape = "laser" }), boxStock, nil, nil, "shape 'laser': one of flat, ball, drill, vbit, bullnose"},
		{"no shape", withTool(func(x *view.MachiningTool) { x.Shape = "" }), boxStock, nil, nil, "shape '': one of flat, ball, drill, vbit, bullnose"},
		{"diameter", withTool(func(x *view.MachiningTool) { x.Diameter = nan }), boxStock, nil, nil, "tool: diameter, flute_length, angle and corner_radius are finite numbers"},
		{"flute", withTool(func(x *view.MachiningTool) { x.FluteLength = inf }), boxStock, nil, nil, "tool: diameter, flute_length, angle and corner_radius are finite numbers"},
		{"angle", withTool(func(x *view.MachiningTool) { x.Angle = inf }), boxStock, nil, nil, "tool: diameter, flute_length, angle and corner_radius are finite numbers"},
		{"corner", withTool(func(x *view.MachiningTool) { x.CornerRadius = nan }), boxStock, nil, nil, "tool: diameter, flute_length, angle and corner_radius are finite numbers"},
		{"nul", []view.MachiningProgram{{Tool: flatTool, Gcode: "G0\x00X1"}}, boxStock, nil, nil, "gcode: a NUL character cannot be sent (the C string ends there)"},
		{"stock", oneProgram, view.MachiningStock{Min: [3]float64{0, 0, nan}, Max: boxStock.Max}, nil, nil, "stock: min and max are finite numbers"},
		{"stock max", oneProgram, view.MachiningStock{Min: boxStock.Min, Max: [3]float64{0, inf, 0}}, nil, nil, "stock: min and max are finite numbers"},
		{"positions", oneProgram, boxStock, &view.MachiningPart{Positions: []float32{0, 0, 0, 1, 0}, Indices: nil}, nil, "part positions: 5 numbers is not a whole number of x y z triples"},
		{"nan position", oneProgram, boxStock, &view.MachiningPart{Positions: []float32{0, 0, float32(nan)}, Indices: nil}, nil, "part positions: finite numbers"},
		{"indices", oneProgram, boxStock, &view.MachiningPart{Positions: triangle, Indices: []uint32{0, 1}}, nil, "part indices: 2 is not a whole number of triangles"},
		{"past", oneProgram, boxStock, &view.MachiningPart{Positions: triangle, Indices: []uint32{0, 1, 3}}, nil, "part indices: 3 is past the last of 3 vertices"},
		{"past a lot", oneProgram, boxStock, &view.MachiningPart{Positions: triangle, Indices: []uint32{0, 1, math.MaxUint32}}, nil, "part indices: 4294967295 is past the last of 3 vertices"},
		{"cell", oneProgram, boxStock, nil, &view.MachiningOptions{Cell: ptr(nan)}, "show_machining options: cell, tolerance, skin and rapid_rate are finite numbers"},
		{"rapid", oneProgram, boxStock, nil, &view.MachiningOptions{RapidRate: ptr(inf)}, "show_machining options: cell, tolerance, skin and rapid_rate are finite numbers"},
	}
	for _, c := range cases {
		m, err := v.ShowMachining(c.programs, c.stock, c.part, c.options)
		if message(err) != c.want || m != nil {
			t.Errorf("%s: %s", c.name, message(err))
		}
	}
	if _, _, calls := viewrig.Seen(); calls != 0 {
		t.Fatalf("a refused show_machining reached the library (%d calls)", calls)
	}
	// A closed view is refused with the call's name.
	w, err := view.Offscreen(8, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	if _, err := w.ShowMachining(oneProgram, boxStock, nil, nil); !errors.Is(err, view.ErrClosed) || !strings.HasPrefix(err.Error(), "cadaclysm_view_show_machining") {
		t.Errorf("a closed view: %s", message(err))
	}
}

// F3: every Machining method reaches its call with the item's id and its arguments; Info
// hands the library a struct of its size; Heights asks for exactly nx * ny floats, row y then x.
func TestMachiningMethodsReachTheirCalls(t *testing.T) {
	_, m := machiningRig(t)
	for _, err := range []error{m.SeekMove(7), m.ColourBy("height"), m.ColourBy("tool"), m.ColourBy("deviation"),
		m.Overlays(true, false), m.Overlays(false, true)} {
		if err != nil {
			t.Fatal(err)
		}
	}
	viewrig.SetInfo(638, 370, 3, 2, 0.5, [2]float32{-1.5, 2.5}, 893.25)
	info, err := m.Info()
	if err != nil || info != (view.MachiningInfo{Moves: 638, Move: 370, Nx: 3, Ny: 2, Cell: 0.5, Min: [2]float32{-1.5, 2.5}, CycleTime: 893.25}) {
		t.Fatalf("info %+v: %v", info, err)
	}
	if viewrig.InfoSize() < 40 {
		t.Errorf("info was handed a struct of %d bytes", viewrig.InfoSize())
	}
	z, err := m.Heights()
	if err != nil || !sameFloats(z, []float32{0, 0.5, 1, 1.5, 2, 2.5}) || viewrig.HeightsCapacity() != 6 {
		t.Fatalf("heights %v (capacity %d): %v", z, viewrig.HeightsCapacity(), err)
	}
	want := "seek 21 7; colour_by 21 0; colour_by 21 1; colour_by 21 2; overlays 21 1 0; overlays 21 0 1; info 21; info 21; heights 21 6"
	if got := viewrig.Log(); got != want {
		t.Fatalf("the library saw\n %s\nwanted\n %s", got, want)
	}
	// An empty grid is an empty slice, with a buffer the library may point at.
	viewrig.SetInfo(0, 0, 0, 0, 0.5, [2]float32{}, 0)
	if z, err := m.Heights(); err != nil || len(z) != 0 {
		t.Errorf("an empty grid: %v %v", z, err)
	}
}

// F4: a mode that is none of the three is refused before the library; the library's
// refusals are its own words; a machining of a closed view says so.
func TestMachiningRefusals(t *testing.T) {
	v, m := machiningRig(t)
	if err := m.ColourBy("rainbow"); message(err) != "mode 'rainbow': one of height, tool, deviation" {
		t.Errorf("a mode: %s", message(err))
	}
	if viewrig.Log() != "" {
		t.Errorf("a refused mode reached the library: %s", viewrig.Log())
	}
	viewrig.Say("cadaclysm_view_machining_colour_by: no machining 21 is shown")
	viewrig.Refusing(true)
	words := "refused by the rig"
	for name, err := range map[string]error{"seek": m.SeekMove(1), "colour_by": m.ColourBy("tool"), "overlays": m.Overlays(true, true)} {
		if message(err) != words {
			t.Errorf("%s: %s", name, message(err))
		}
	}
	if _, err := m.Info(); message(err) != words {
		t.Errorf("info: %s", message(err))
	}
	if _, err := m.Heights(); message(err) != words {
		t.Errorf("heights: %s", message(err))
	}
	viewrig.Refusing(false)
	v.Close()
	for name, err := range map[string]error{"seek": m.SeekMove(1), "colour_by": m.ColourBy("tool"), "overlays": m.Overlays(true, true)} {
		if !errors.Is(err, view.ErrClosed) {
			t.Errorf("%s on a closed view: %s", name, message(err))
		}
	}
	if _, err := m.Info(); !errors.Is(err, view.ErrClosed) || !strings.HasPrefix(err.Error(), "cadaclysm_view_machining_info") {
		t.Errorf("info on a closed view: %s", message(err))
	}
	if _, err := m.Heights(); !errors.Is(err, view.ErrClosed) {
		t.Errorf("heights on a closed view: %s", message(err))
	}
}

// F5: the transport reaches its calls with its arguments, and the answers come back.
func TestTimelineTransportReachesItsCallsAndAnswers(t *testing.T) {
	v, _ := machiningRig(t)
	for _, err := range []error{v.Play(2.5), v.Pause(), v.Seek(12.25), v.Loop(true), v.Loop(false)} {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got, want := viewrig.Log(), "play 2.5; pause; timeline_seek 12.25; loop on; loop off"; got != want {
		t.Fatalf("the library saw\n %s\nwanted\n %s", got, want)
	}
	viewrig.SetTimeline(12.25, 893.5, true)
	if x, err := v.Time(); err != nil || x != 12.25 {
		t.Errorf("time %v: %v", x, err)
	}
	if x, err := v.Duration(); err != nil || x != 893.5 {
		t.Errorf("duration %v: %v", x, err)
	}
	if x, err := v.Playing(); err != nil || !x {
		t.Errorf("playing %v: %v", x, err)
	}
	viewrig.SetTimeline(0, 0, false)
	if x, err := v.Playing(); err != nil || x {
		t.Errorf("not playing %v: %v", x, err)
	}
	// Not finite: refused before the library.
	viewrig.Reset()
	nan := math.NaN()
	if err := v.Play(nan); message(err) != "play speed: a finite number" {
		t.Errorf("play nan: %s", message(err))
	}
	if err := v.Seek(math.Inf(-1)); message(err) != "seek seconds: a finite number" {
		t.Errorf("seek inf: %s", message(err))
	}
	if viewrig.Log() != "" {
		t.Errorf("a refusal reached the library: %s", viewrig.Log())
	}
	// The library's refusal.
	viewrig.Refusing(true)
	for name, err := range map[string]error{"play": v.Play(1), "pause": v.Pause(), "seek": v.Seek(1), "loop": v.Loop(true)} {
		if message(err) != "refused by the rig" {
			t.Errorf("%s: %s", name, message(err))
		}
	}
	viewrig.Refusing(false)
	// A closed view, with each call's name.
	v.Close()
	calls := map[string]error{
		"cadaclysm_view_timeline_play":     v.Play(1),
		"cadaclysm_view_timeline_pause":    v.Pause(),
		"cadaclysm_view_timeline_seek":     v.Seek(1),
		"cadaclysm_view_timeline_set_loop": v.Loop(true),
	}
	_, calls["cadaclysm_view_timeline_time"] = v.Time()
	_, calls["cadaclysm_view_timeline_duration"] = v.Duration()
	_, calls["cadaclysm_view_timeline_playing"] = v.Playing()
	_, calls["cadaclysm_view_timeline_status"] = v.Status()
	for name, err := range calls {
		if !errors.Is(err, view.ErrClosed) || !strings.HasPrefix(err.Error(), name+":") {
			t.Errorf("%s on a closed view: %s", name, message(err))
		}
	}
}

// F6: Status is the two-call idiom -- measure, fill -- and asks again with room when the line
// grew between the two calls; lines are split at newlines; none is an empty slice.
func TestTimelineStatusMeasuresFillsAndRetries(t *testing.T) {
	v, _ := machiningRig(t)
	if lines, err := v.Status(); err != nil || lines == nil || len(lines) != 0 {
		t.Fatalf("no tracks: %#v %v", lines, err)
	}
	viewrig.StatusAnswers("move 3 of 9 - T1 flat 6 mm\nmove 1 of 2 - T2 drill 3 mm")
	lines, err := v.Status()
	if err != nil || len(lines) != 2 || lines[0] != "move 3 of 9 - T1 flat 6 mm" || lines[1] != "move 1 of 2 - T2 drill 3 mm" || viewrig.StatusCalls() != 2 {
		t.Fatalf("two tracks: %q (%d calls) %v", lines, viewrig.StatusCalls(), err)
	}
	// The line grew between the measure and the fill: ask again, the way Python does.
	viewrig.Reset()
	viewrig.StatusAnswers("a", "a longer line than measured", "a longer line than measured")
	lines, err = v.Status()
	if err != nil || len(lines) != 1 || lines[0] != "a longer line than measured" || viewrig.StatusCalls() != 3 {
		t.Fatalf("a grown line: %q (%d calls) %v", lines, viewrig.StatusCalls(), err)
	}
	// An empty answer is no line.
	viewrig.Reset()
	viewrig.StatusAnswers("")
	if lines, err := v.Status(); err != nil || len(lines) != 0 || viewrig.StatusCalls() != 1 {
		t.Fatalf("an empty status: %q (%d calls) %v", lines, viewrig.StatusCalls(), err)
	}
	// The line emptied between the measure and the fill: no line, not one empty line.
	viewrig.Reset()
	viewrig.StatusAnswers("move 9 of 9", "")
	if lines, err := v.Status(); err != nil || lines == nil || len(lines) != 0 || viewrig.StatusCalls() != 2 {
		t.Fatalf("an emptied status: %q (%d calls) %v", lines, viewrig.StatusCalls(), err)
	}
}

// The plate of web/test/fixtures/machining-plate/job.json, from the repository tree: the
// fixture's directory found by walking up from the test's.
type plateJob struct {
	dir      string
	programs []view.MachiningProgram
	options  *view.MachiningOptions
}

func plate(t *testing.T) plateJob {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for at := dir; ; at = filepath.Dir(at) {
		fixture := filepath.Join(at, "web", "test", "fixtures", "machining-plate")
		if _, err := os.Stat(filepath.Join(fixture, "job.json")); err == nil {
			read := func(name string) string {
				text, err := os.ReadFile(filepath.Join(fixture, name))
				if err != nil {
					t.Fatal(err)
				}
				return string(text)
			}
			return plateJob{dir: fixture, options: &view.MachiningOptions{Cell: ptr(0.5), RapidRate: ptr(5000)},
				programs: []view.MachiningProgram{
					{Tool: view.MachiningTool{Number: 1, Shape: "flat", Diameter: 6, FluteLength: 20}, Gcode: read("program-0.gcode")},
					{Tool: view.MachiningTool{Number: 2, Shape: "drill", Diameter: 6, FluteLength: 30}, Gcode: read("program-1.gcode")},
				}}
		}
		if filepath.Dir(at) == at {
			break
		}
	}
	if os.Getenv("CADACLYSM_SAMPLES_OPTIONAL") != "" {
		t.Skip("web/test/fixtures/machining-plate is missing")
	}
	t.Fatalf("web/test/fixtures/machining-plate is missing above %s", dir)
	return plateJob{}
}

// compareAtWalls is web/test/machining-selftest.js's rule, as Python's _compare_at_walls
// and Java's: a cell off the oracle's by more than 2e-3 fails, unless it is a wall (the
// oracle's 3x3 neighbourhood spans more than 0.5 mm) and one of the neighbours is within
// 2e-3 of it -- excused. Returns failed, excused and walls.
func compareAtWalls(gpu, oracle []float32, nx, ny int) (failed, excused, walls int) {
	for j := 0; j < ny; j++ {
		for i := 0; i < nx; i++ {
			lo, hi := float32(math.Inf(1)), float32(math.Inf(-1))
			for b := max(0, j-1); b < min(ny, j+2); b++ {
				for a := max(0, i-1); a < min(nx, i+2); a++ {
					lo, hi = min(lo, oracle[b*nx+a]), max(hi, oracle[b*nx+a])
				}
			}
			wall := hi-lo > 0.5
			if wall {
				walls++
			}
			g := gpu[j*nx+i]
			if math.Abs(float64(g-oracle[j*nx+i])) <= 2e-3 {
				continue
			}
			near := false
			if wall {
				for b := max(0, j-1); b < min(ny, j+2); b++ {
					for a := max(0, i-1); a < min(nx, i+2); a++ {
						near = near || math.Abs(float64(oracle[b*nx+a]-g)) <= 2e-3
					}
				}
			}
			if near {
				excused++
			} else {
				failed++
			}
		}
	}
	return
}

func machiningOffscreen(t *testing.T) *view.View {
	t.Helper()
	if _, err := view.UseWgpu(); err != nil {
		skipOrFail(t, err)
	}
	v, err := view.Offscreen(64, 48, nil)
	if err != nil {
		skipOrFail(t, err)
	}
	t.Cleanup(func() { v.Close() })
	return v
}

// must is a call's answer, or a panic that fails the running test with the error.
func must[T any](x T, err error) T {
	if err != nil {
		panic(err)
	}
	return x
}

// F7: the plate, seeked to its end, is the fixture's heights on the real library -- by the
// wall rule -- and the status line says so.
func TestMachiningPlatePlaysToTheFixturesHeightsOffscreen(t *testing.T) {
	job := plate(t)
	v := machiningOffscreen(t)
	m := must(v.ShowMachining(job.programs, boxStock, nil, job.options))
	if d := must(v.Duration()); math.Abs(d-893.247024) > 1e-3 {
		t.Errorf("duration %v", d)
	}
	info := must(m.Info())
	if info.Moves == 0 {
		t.Fatal("no moves")
	}
	if err := m.SeekMove(info.Moves); err != nil {
		t.Fatal(err)
	}
	gpu := must(m.Heights())
	raw, err := os.ReadFile(filepath.Join(job.dir, "heights.bin"))
	if err != nil {
		t.Fatal(err)
	}
	nx, ny := int(binary.LittleEndian.Uint32(raw[8:])), int(binary.LittleEndian.Uint32(raw[12:]))
	if int(info.Nx) != nx || int(info.Ny) != ny || len(gpu) != nx*ny {
		t.Fatalf("the grid %dx%d with %d floats, wanted %dx%d", info.Nx, info.Ny, len(gpu), nx, ny)
	}
	oracle := make([]float32, nx*ny)
	for k := range oracle {
		oracle[k] = math.Float32frombits(binary.LittleEndian.Uint32(raw[28+4*k:]))
	}
	failed, excused, walls := compareAtWalls(gpu, oracle, nx, ny)
	if failed != 0 || excused > max(4, walls/100) {
		t.Errorf("heights against heights.bin: failed %d, excused %d, walls %d", failed, excused, walls)
	}
	if err := v.Draw(); err != nil {
		t.Fatal(err)
	}
	lines := must(v.Status())
	if len(lines) == 0 || !strings.HasPrefix(lines[0], fmt.Sprintf("move %d of %d", info.Moves, info.Moves)) {
		t.Errorf("status %q", lines)
	}
	if err := m.Remove(); err != nil {
		t.Fatal(err)
	}
}

// F7b: every one of the fourteen calls on the real library, not only the plate's own.
func TestMachiningAndTimelineCallsOnTheRealLibrary(t *testing.T) {
	job := plate(t)
	v := machiningOffscreen(t)
	m := must(v.ShowMachining(job.programs, boxStock, nil, job.options))
	duration := must(v.Duration())
	if must(v.Playing()) {
		t.Error("a fresh machining is paused")
	}
	if err := v.Play(2); err != nil || !must(v.Playing()) {
		t.Errorf("play(2) did not play: %v", err)
	}
	if err := v.Pause(); err != nil || must(v.Playing()) {
		t.Errorf("pause did not pause: %v", err)
	}
	if err := v.Seek(10); err != nil {
		t.Fatal(err)
	}
	if err := v.Draw(); err != nil {
		t.Fatal(err)
	}
	if x := must(v.Time()); math.Abs(x-10) > 1e-6 {
		t.Errorf("time after seek(10): %v", x)
	}
	if err := v.Seek(duration + 100); err != nil {
		t.Fatal(err)
	}
	if err := v.Draw(); err != nil {
		t.Fatal(err)
	}
	if x := must(v.Time()); math.Abs(x-duration) > 1e-6 {
		t.Errorf("seek past the end clamps: %v", x)
	}
	for _, on := range []bool{true, false} {
		if err := v.Loop(on); err != nil {
			t.Fatal(err)
		}
	}
	if lines := must(v.Status()); len(lines) == 0 {
		t.Error("no status line")
	}
	for _, mode := range []string{"tool", "height"} {
		if err := m.ColourBy(mode); err != nil {
			t.Fatal(err)
		}
	}
	if err := m.ColourBy("deviation"); err == nil || !strings.Contains(err.Error(), "cadaclysm_view_machining_colour_by") {
		t.Errorf("deviation with no part: %s", message(err))
	}
	if err := m.Overlays(false, false); err != nil {
		t.Fatal(err)
	}
	if err := m.Overlays(true, true); err != nil {
		t.Fatal(err)
	}
	if err := v.Draw(); err != nil {
		t.Fatal(err)
	}
	if err := m.Remove(); err != nil {
		t.Fatal(err)
	}
	// With a part, colouring by deviation works.
	part := &view.MachiningPart{Positions: []float32{-42, -27, 14, 42, -27, 14, 0, 27, 14}, Indices: []uint32{0, 1, 2}}
	withPart := must(v.ShowMachining(job.programs, boxStock, part, job.options))
	if err := withPart.ColourBy("deviation"); err != nil {
		t.Errorf("deviation with a part: %v", err)
	}
	if err := v.Draw(); err != nil {
		t.Fatal(err)
	}
	if err := withPart.Remove(); err != nil {
		t.Fatal(err)
	}
}
