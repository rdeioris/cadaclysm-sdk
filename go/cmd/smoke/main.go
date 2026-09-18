// Open one file through the Go binding and check what comes back, then build a part
// through the kernel binding, write it as STEP and read it back through the reader. The
// exit code is the verdict: the release pipeline runs this against every library it ships.
package main

import (
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"

	"github.com/rdeioris/cadaclysm-sdk/go/blacksmith"
	"github.com/rdeioris/cadaclysm-sdk/go/cadaclysm"
)

func main() {
	path := "samples/cube.scad"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	license := ""
	if len(os.Args) > 2 {
		license = os.Args[2]
		if err := cadaclysm.License(license); err != nil {
			fail("license: " + err.Error())
		}
	}
	fmt.Printf("cadaclysm %s built %s\n", cadaclysm.Version(), cadaclysm.BuildDate())
	fmt.Println("license:", cadaclysm.LicenseInfo())

	scene, err := cadaclysm.Open(path)
	if err != nil {
		fail(err.Error())
	}
	defer scene.Close()
	bounds := scene.Bounds()
	fmt.Printf("bounds min=(%g,%g,%g) max=(%g,%g,%g)\n",
		bounds.Min[0], bounds.Min[1], bounds.Min[2], bounds.Max[0], bounds.Max[1], bounds.Max[2])

	var triangles int
	for _, node := range scene.Walk() {
		if !node.CanMesh() {
			continue
		}
		mesh, merr := node.Mesh()
		if merr != nil {
			fail(merr.Error())
		}
		if mesh == nil {
			continue
		}
		triangles += mesh.TriangleCount()
	}
	fmt.Printf("triangles=%d\n", triangles)
	// All six bounds values, not just the three the brief's own draft checked: a bug that
	// only flips the Y axis (min/max swapped, or Y left at zero on both ends) still passes
	// min[0]/max[0]/max[2]/triangles alone, so every component of both corners is compared.
	if filepath.Base(path) == "cube.scad" &&
		(bounds.Min != [3]float64{0, 0, 0} || bounds.Max != [3]float64{20, 20, 20} || triangles != 12) {
		fail("the cube did not come back as a 20-unit cube of 12 triangles")
	}

	// The reader's own extras: a query, the diagnostics, an in-memory open of the same
	// bytes. "class == mesh" does not match here: the OpenSCAD reader's own Kind() for
	// cube.scad's solid is "solid", not "mesh".
	matched, qerr := scene.Query("class == solid")
	if qerr != nil {
		fail(qerr.Error())
	}
	fmt.Printf("query: %d node(s)\n", len(matched))
	fmt.Printf("diagnostics: %d\n", len(scene.Diagnostics()))

	data, rerr := os.ReadFile(path)
	if rerr != nil {
		fail(rerr.Error())
	}
	again, aerr := cadaclysm.OpenMemory(data, filepath.Base(path))
	if aerr != nil {
		fail("open_memory: " + aerr.Error())
	}
	if again.Bounds().Max[2] != bounds.Max[2] {
		fail("open_memory disagrees with open")
	}
	// An in-memory scene keeps the name it was given as its path, as Python's does.
	if again.Path() != filepath.Base(path) {
		fail("open_memory's path is " + again.Path())
	}
	again.Close()
	// A closed scene refuses rather than answers: a method with an error returns the
	// scene's own error, an accessor without one panics with it -- both *CadaclysmError.
	if _, cerr := again.Query("class == solid"); cerr == nil {
		fail("a closed scene answered a query")
	} else if _, ok := cerr.(*cadaclysm.CadaclysmError); !ok {
		fail("a closed scene's refusal is not a CadaclysmError: " + cerr.Error())
	}
	func() {
		defer func() {
			if r := recover(); r == nil {
				fail("a closed scene answered Bounds")
			} else if _, ok := r.(*cadaclysm.CadaclysmError); !ok {
				panic(r)
			}
		}()
		again.Bounds()
	}()
	// The format given on its own, as Python's open_memory takes it -- the name has no
	// extension to fall back on here, so this is the option and nothing else.
	typed, terr := cadaclysm.OpenMemory(data, "cube-bytes", cadaclysm.WithFormat("scad"))
	if terr != nil {
		fail("open_memory with a format: " + terr.Error())
	}
	if typed.Bounds() != bounds {
		fail("open_memory with an explicit format disagrees with open")
	}
	typed.Close()

	stl := filepath.Join(os.TempDir(), "cadaclysm-smoke-go.stl")
	roots := scene.Roots()
	if len(roots) == 0 {
		fail("the scene has no root nodes to save a mesh from")
	}
	if serr := roots[0].SaveMesh(stl, "stl"); serr != nil {
		fail(serr.Error())
	}
	info, serr := os.Stat(stl)
	if serr != nil {
		fail(serr.Error())
	}
	if info.Size() < 84 {
		fail("save_mesh wrote no triangles")
	}

	kernel(license)
}

// kernel is the smoke's second half: the plate with a hole and a pin, filleted, as STEP
// -- then read back through the reader. The kernel library keeps its own license state,
// so the same file is loaded into it too.
func kernel(license string) {
	if license != "" {
		if err := blacksmith.License(license); err != nil {
			fail("blacksmith license: " + err.Error())
		}
	}
	fmt.Printf("blacksmith %s built %s\n", blacksmith.Version(), blacksmith.BuildDate())
	fmt.Println("blacksmith license:", blacksmith.LicenseInfo())

	// Every profile is its own handle: the rectangle and the circle stay alive and are
	// closed too, not just the outline made from them.
	rect, err := blacksmith.Rect(80, 40)
	if err != nil {
		fail(err.Error())
	}
	defer rect.Close()
	hole, err := blacksmith.Circle(4)
	if err != nil {
		fail(err.Error())
	}
	defer hole.Close()
	outline, err := rect.WithHole(hole)
	if err != nil {
		fail(err.Error())
	}
	defer outline.Close()
	plate, err := blacksmith.XY().Extrude(outline, 6).Solid()
	if err != nil {
		fail(err.Error())
	}
	defer plate.Close()
	pin, err := blacksmith.FromSolid(plate).Faces(blacksmith.Max(blacksmith.AxisZ)).OnFace().Cylinder(5, 10).Solid()
	if err != nil {
		fail(err.Error())
	}
	defer pin.Close()
	part, err := plate.Join(pin, blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	defer part.Close()

	// The plate's own corners: vertical lines between planes.
	edges, err := part.Edges()
	if err != nil {
		fail(err.Error())
	}
	var corners []int
	for _, e := range edges {
		d, ok := e.Direction()
		if !ok || math.Abs(d[2]) <= 0.99 {
			continue
		}
		planes := true
		for _, f := range e.Faces {
			kind, kerr := part.FaceKind(f)
			if kerr != nil {
				fail(kerr.Error())
			}
			if kind != "plane" {
				planes = false
			}
		}
		if planes {
			corners = append(corners, e.Index)
		}
	}
	rounded, err := part.Fillet(corners, 1.0, blacksmith.FilletTolerance)
	if err != nil {
		fail(err.Error())
	}
	defer rounded.Close()
	faces, err := rounded.Faces()
	if err != nil {
		fail(err.Error())
	}
	watertight, err := rounded.IsWatertight(blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	fmt.Printf("faces=%d watertight=%v\n", faces, watertight)
	if !watertight {
		fail("the filleted part is not watertight")
	}
	// A plate has 6 faces, the hole adds 1 cylinder, the pin 2 (its wall and its top), and
	// each of the four corners rounded trades one edge for one face.
	if faces != 15 {
		fail(fmt.Sprintf("the filleted part has %d faces, not 15", faces))
	}

	// Colour: a gold plate joined with a blue pin -- the part is gold, the pin's top keeps
	// its blue.
	gold, err := plate.Coloured(0.8, 0.6, 0.4)
	if err != nil {
		fail(err.Error())
	}
	defer gold.Close()
	blue, err := pin.Coloured(0.2, 0.4, 1.0)
	if err != nil {
		fail(err.Error())
	}
	defer blue.Close()
	coloured, err := gold.Join(blue, blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	defer coloured.Close()
	top, err := coloured.SelectFace(blacksmith.Max(blacksmith.AxisZ))
	if err != nil {
		fail(err.Error())
	}
	partColour, ok, err := coloured.Colour()
	if err != nil || !ok {
		fail(fmt.Sprintf("the joined part has no colour (%v)", err))
	}
	topColour, ok, err := coloured.FaceColour(top)
	if err != nil || !ok {
		fail(fmt.Sprintf("the pin's top has no colour (%v)", err))
	}
	fmt.Printf("colour=%v pin top=%v\n", partColour, topColour)
	if partColour != [3]float64{0.8, 0.6, 0.4} || topColour != [3]float64{0.2, 0.4, 1.0} {
		fail("the colours did not carry through the join")
	}

	// A mesh view is tied to one filling of the solid's cache: meshing at another
	// tolerance and back again replaces that memory, and the first view must refuse to
	// read it rather than hand back a slice over freed memory.
	first, err := rounded.Mesh(0.05)
	if err != nil {
		fail(err.Error())
	}
	triangles0 := first.TriangleCount()
	if _, err := first.Positions(); err != nil {
		fail("a fresh mesh view refused to read: " + err.Error())
	}
	if _, err := rounded.Mesh(0.5); err != nil {
		fail(err.Error())
	}
	if _, err := rounded.Mesh(0.05); err != nil {
		fail(err.Error())
	}
	if _, err := first.Positions(); !errors.Is(err, blacksmith.ErrStaleView) {
		fail("a stale mesh view read freed memory after meshing at 0.05, 0.5, 0.05")
	}
	fmt.Printf("mesh at 0.05: %d triangles; the first view is stale after 0.05, 0.5, 0.05\n", triangles0)

	step := filepath.Join(os.TempDir(), "cadaclysm-smoke-go.stp")
	if err := rounded.Step(step, "", "mm"); err != nil {
		fail(err.Error())
	}
	back, err := cadaclysm.Open(step)
	if err != nil {
		fail("step read back: " + err.Error())
	}
	defer back.Close()
	b := back.Bounds()
	fmt.Printf("step read back: bounds max=(%g,%g,%g)\n", b.Max[0], b.Max[1], b.Max[2])
	// The plate is 80 x 40 x 6, Rect centring it on the origin, and the pin adds 10.
	if math.Abs(b.Max[0]-40) > 0.01 || math.Abs(b.Max[1]-20) > 0.01 || math.Abs(b.Max[2]-16) > 0.01 {
		fail("the STEP did not read back as the plate with its pin")
	}

	// ToScene is the same round trip in memory: the scene's bounds must match the solid's
	// own, and the scene is its own document -- closing the solid it came from leaves it
	// readable. (Open with a schema once stored a Go pointer inside the options struct it
	// handed to C, which cgo refuses at run time; this is the call that exercises it.)
	own, err := rounded.Bounds()
	if err != nil {
		fail(err.Error())
	}
	scene, err := rounded.ToScene("")
	if err != nil {
		fail("to_scene: " + err.Error())
	}
	defer scene.Close()
	sb := scene.Bounds()
	for i := 0; i < 3; i++ {
		if math.Abs(sb.Max[i]-own.Max[i]) > 0.01 || math.Abs(sb.Min[i]-own.Min[i]) > 0.01 {
			fail("to_scene's bounds disagree with the solid's")
		}
	}
	rounded.Close()
	if scene.Bounds() != sb {
		fail("closing the solid changed the scene made from it")
	}
	fmt.Printf("to_scene: bounds max=(%g,%g,%g), still readable after the solid is closed\n", sb.Max[0], sb.Max[1], sb.Max[2])
}

func fail(why string) {
	fmt.Fprintln(os.Stderr, why)
	os.Exit(1)
}
