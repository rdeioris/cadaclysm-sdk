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
	"strings"

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
	shape, err := rounded.Manifold()
	if err != nil {
		fail(err.Error())
	}
	fmt.Printf("manifold: %+v\n", shape)
	if !shape.IsClosed || shape.Faces != faces {
		fail(fmt.Sprintf("the filleted part is not a closed manifold: %+v", shape))
	}
	// A plate has 6 faces, the hole adds 1 cylinder, the pin 2 (its wall and its top), and
	// each of the four corners rounded trades one edge for one face.
	if faces != 15 {
		fail(fmt.Sprintf("the filleted part has %d faces, not 15", faces))
	}

	// The sheet verbs: a face from a profile, a solid's face alone, faces dropped, a trim,
	// a rounded profile and a path along a curve.
	sheetVerbs(plate)

	// Frames: built, checked, and passed wherever twelve numbers go.
	frames()

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

	// A face: the outline as a sheet, which pushed out is the plate again.
	sheet, err := blacksmith.Face(outline, blacksmith.Frame{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1})
	if err != nil {
		fail(err.Error())
	}
	defer sheet.Close()
	pushed, err := sheet.ExtrudeFaces(6)
	if err != nil {
		fail(err.Error())
	}
	defer pushed.Close()
	sheetFaces, _ := sheet.Faces()
	pushedFaces, _ := pushed.Faces()
	plateFaces, _ := plate.Faces()
	pushedTight, _ := pushed.IsWatertight(blacksmith.DefaultTolerance)
	fmt.Printf("face: %d face, pushed out %d faces\n", sheetFaces, pushedFaces)
	if sheetFaces != 1 || pushedFaces != plateFaces || !pushedTight {
		fail("the outline's face did not push out to the plate")
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

	// No schema at all: the kernel writes against its built-in AP203, no ap203.exp needed.
	noSchemaText, err := rounded.StepText("", "mm")
	if err != nil {
		fail(err.Error())
	}
	if !strings.HasPrefix(noSchemaText, "ISO-10303-21;") {
		fail("StepText(\"\", ...) with no schema did not write valid STEP")
	}
	fmt.Println("StepText with no schema: ISO-10303-21; ok")

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

	// And back into the kernel: the read body's brep, shared with the scene rather than
	// copied, as a solid that outlives the scene it came from.
	var body *cadaclysm.Node
	for _, p := range back.Placements() {
		if brep, _ := p.Geometry().Brep(); brep != nil {
			read, err := brep.Manifold()
			brep.Close()
			if err != nil {
				fail(err.Error())
			}
			if !read.IsClosed || read.Faces != 15 {
				fail(fmt.Sprintf("the read body is not the closed manifold written: %+v", read))
			}
			if _, err := brep.Manifold(); err == nil {
				fail("a closed brep answered Manifold")
			}
			body = p.Geometry()
			break
		}
	}
	if body == nil {
		fail("no placement of the read-back STEP has a brep")
	}
	imported, err := blacksmith.FromNode(back, body, true)
	if err != nil {
		fail("from_node: " + err.Error())
	}
	defer imported.Close()
	back.Close()
	importedFaces, err := imported.Faces()
	if err != nil || importedFaces != faces {
		fail(fmt.Sprintf("from_node gave %d faces, not %d (%v)", importedFaces, faces, err))
	}
	opened, err := blacksmith.Open(step)
	if err != nil {
		fail("open: " + err.Error())
	}
	defer opened.Close()
	if n, _ := opened.Faces(); n != faces {
		fail(fmt.Sprintf("Open gave %d faces, not %d", n, faces))
	}
	fmt.Printf("from_node: %d faces after the scene closed; Open: the same\n", importedFaces)

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

// sheetVerbs checks Face, FaceSheet, DropFaces, Trim, Round and SweepPathAlong by their
// face counts, and that a trim with nothing on the kept side fails in the library's words.
func frames() {
	at, err := blacksmith.FrameAt([3]float64{}, [3]float64{0, -1, 0})
	if err != nil || at != blacksmith.FrameXZ([3]float64{}) {
		fail(fmt.Sprintf("FrameAt(-Y) = %v, %v", at, err))
	}
	if at, _ := blacksmith.FrameAt([3]float64{1, 2, 3}, [3]float64{0, 0, 5}); at != blacksmith.FrameXY([3]float64{1, 2, 3}) {
		fail(fmt.Sprintf("FrameAt(+Z) = %v", at))
	}
	if blacksmith.FrameXY([3]float64{}).Offset(5) != blacksmith.FrameXY([3]float64{0, 0, 5}) ||
		blacksmith.FrameYZ([3]float64{}) != blacksmith.YZ().Frame() {
		fail("FrameXY / Offset / FrameYZ disagree")
	}
	if _, err := blacksmith.NewFrame([3]float64{}, [3]float64{1, 0, 0}, [3]float64{0, 1, 0}, [3]float64{0, 0, -1}); err == nil ||
		!strings.Contains(err.Error(), "left-handed") {
		fail(fmt.Sprintf("a left-handed frame: %v", err))
	}
	rect, err := blacksmith.Rect(10, 4)
	if err != nil {
		fail(err.Error())
	}
	lid, err := blacksmith.Extrude(rect, blacksmith.FrameXY([3]float64{0, 0, 5}), 2)
	if err != nil {
		fail(err.Error())
	}
	wall, err := blacksmith.On(blacksmith.FrameXZ([3]float64{0, 3, 0})).Extrude(rect, 1).Solid()
	if err != nil {
		fail(err.Error())
	}
	b, _ := lid.Bounds()
	wb, _ := wall.Bounds()
	i, _ := lid.SelectFace(blacksmith.Max(blacksmith.AxisZ))
	raw, _ := lid.FaceFrame(i)
	top, err := blacksmith.FrameOf(raw)
	if err != nil || math.Abs(b.Min[2]-5) > 1e-6 || math.Abs(b.Max[2]-7) > 1e-6 || math.Abs(wb.Max[1]-3) > 1e-6 ||
		math.Abs(top.Origin()[2]-7) > 1e-6 || math.Abs(top.Z()[2]-1) > 1e-9 {
		fail(fmt.Sprintf("frames: lid %v, wall %v, top %v, %v", b, wb, top, err))
	}
	tilted, _ := blacksmith.FrameAt([3]float64{}, [3]float64{1, 1, 1})
	fmt.Printf("frames: %v: ok\n", tilted)
}

func sheetVerbs(plate *blacksmith.Solid) {
	must := func(s *blacksmith.Solid, err error) *blacksmith.Solid {
		if err != nil {
			fail("sheet verbs: " + err.Error())
		}
		return s
	}
	count := func(s *blacksmith.Solid) int {
		n, err := s.Faces()
		if err != nil {
			fail(err.Error())
		}
		return n
	}
	xy := blacksmith.Frame{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	square, err := blacksmith.Rect(20, 20)
	if err != nil {
		fail(err.Error())
	}
	circle, err := blacksmith.Circle(4)
	if err != nil {
		fail(err.Error())
	}
	sheet := must(blacksmith.Face(square, xy))
	peg := must(blacksmith.Extrude(circle, blacksmith.Frame{0, 0, -6, 1, 0, 0, 0, 1, 0, 0, 0, 1}, 12))
	holed := must(sheet.Trim(peg, "outside", blacksmith.DefaultTolerance))
	disc := must(sheet.Trim(peg, "inside", blacksmith.DefaultTolerance))
	top, err := plate.SelectFace(blacksmith.Max(blacksmith.AxisZ))
	if err != nil {
		fail(err.Error())
	}
	lid := must(plate.FaceSheet(top))
	walls := must(plate.DropFaces([]int{0, 1}))
	rounded, err := square.Round(2, nil, false)
	if err != nil {
		fail(err.Error())
	}
	slab := must(blacksmith.Extrude(rounded, xy, 1))
	wave, err := blacksmith.NewPath(0, 0).BezierTo([2]float64{20, 0}, [2]float64{20, 20}, [2]float64{40, 10}).EndOpen()
	if err != nil {
		fail(err.Error())
	}
	ring, err := blacksmith.Circle(1)
	if err != nil {
		fail(err.Error())
	}
	along := blacksmith.SweepPathAlong(wave, xy, 0.01, true)
	tube := must(blacksmith.Sweep(ring, blacksmith.Frame{0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0}, along))
	onPlane := must(blacksmith.XY().Face(square).Solid())
	watertight, err := tube.IsWatertight(blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	if count(sheet) != 1 || count(holed) < 1 || count(disc) < 1 || count(lid) != 1 || count(walls) != count(plate)-2 ||
		count(slab) != 10 || !watertight || count(onPlane) != 1 {
		fail(fmt.Sprintf("sheet verbs: sheet=%d holed=%d disc=%d lid=%d walls=%d slab=%d", count(sheet), count(holed),
			count(disc), count(lid), count(walls), count(slab)))
	}
	away := must(peg.Translate(100, 0, 0))
	if _, err := sheet.Trim(away, "inside", blacksmith.DefaultTolerance); err == nil ||
		!strings.Contains(err.Error(), "trim: nothing of the sheet lies inside the tool") {
		fail(fmt.Sprintf("a trim with nothing inside the tool: %v", err))
	}
	// Chain: an L's two sides, the second drawn back to front, joined -- open, two walls.
	sideA, err := blacksmith.NewPath(0, 0).LineTo(10, 0).EndOpen()
	if err != nil {
		fail(err.Error())
	}
	sideB, err := blacksmith.NewPath(10, 8).LineTo(10, 0).EndOpen()
	if err != nil {
		fail(err.Error())
	}
	ell, err := blacksmith.Chain([]*blacksmith.Profile{sideA, sideB}, 1e-6)
	if err != nil {
		fail("chain: " + err.Error())
	}
	ellWalls := must(blacksmith.ExtrudeOpen(ell, xy, 2))
	if count(ellWalls) != 2 {
		fail(fmt.Sprintf("chain: an L extruded open has %d walls, not 2", count(ellWalls)))
	}
	// Close: the open L's first side and a line back -- closed, a triangle's three walls.
	openL, err := blacksmith.NewPath(0, 0).LineTo(10, 0).LineTo(10, 8).EndOpen()
	if err != nil {
		fail(err.Error())
	}
	closedL, err := openL.CloseLoop()
	if err != nil {
		fail("close_loop: " + err.Error())
	}
	closedWalls := must(blacksmith.ExtrudeOpen(closedL, xy, 2))
	if count(closedWalls) != 3 {
		fail(fmt.Sprintf("close_loop: a closed L has %d walls, not 3", count(closedWalls)))
	}
	closedWalls.Close()
	closedL.Close()
	openL.Close()
	// Push-pull: a cube's top raised is one taller box, six faces, not a box and a prism.
	cube := must(blacksmith.Cuboid(10, 10, 10))
	cubeTop, err := cube.SelectFace(blacksmith.Max(blacksmith.AxisZ))
	if err != nil {
		fail(err.Error())
	}
	raised := must(cube.PushPull(cubeTop, 5, blacksmith.DefaultTolerance))
	if count(raised) != 6 {
		fail(fmt.Sprintf("push_pull: the raised cube has %d faces, not 6", count(raised)))
	}
	// Quick solids: a coiled wire and a pipe close; a cube split by a plane is two bodies.
	wireCircle, err := blacksmith.Circle(1)
	if err != nil {
		fail(err.Error())
	}
	wire, err := wireCircle.Translate(10, 0)
	if err != nil {
		fail(err.Error())
	}
	spring := must(blacksmith.Coil(wire, [6]float64{0, 0, 0, 0, 0, 1}, 4, 2))
	if ok, err := spring.IsWatertight(blacksmith.DefaultTolerance); err != nil || !ok {
		fail("coil: the spring leaks")
	}
	pipePath := blacksmith.NewSweepPath(0, 0, 0).LineTo([3]float64{0, 0, 10})
	pipe := must(blacksmith.Pipe(pipePath, 2, 0.5))
	if count(pipe) != 6 {
		fail(fmt.Sprintf("pipe: the tube has %d faces, not 6", count(pipe)))
	}
	halves, err := cube.SplitByPlane(blacksmith.Frame{2, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0}, blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	if len(halves) != 2 || count(halves[0]) != 6 {
		fail(fmt.Sprintf("split_by_plane: %d bodies, not 2", len(halves)))
	}
	for _, s := range append(halves, spring, pipe) {
		s.Close()
	}
	wire.Close()
	wireCircle.Close()
	pipePath.Close()
	raised.Close()
	cube.Close()
	ellWalls.Close()
	ell.Close()
	sideA.Close()
	sideB.Close()
	// From loops: a circle given before the square it lies in -- the square is the boundary.
	loopHole, err := blacksmith.Circle(4)
	if err != nil {
		fail(err.Error())
	}
	loopSquare, err := blacksmith.Rect(30, 30)
	if err != nil {
		fail(err.Error())
	}
	fromLoops, err := blacksmith.FromLoops([]*blacksmith.Profile{loopHole, loopSquare})
	if err != nil {
		fail("from_loops: " + err.Error())
	}
	holedSquare := must(blacksmith.Extrude(fromLoops, xy, 2))
	if count(holedSquare) != 8 {
		fail(fmt.Sprintf("from_loops: the holed square has %d faces, not 8", count(holedSquare)))
	}
	// Revolve in plane: a plate drawn beside the y axis turns into a tube of four walls.
	beside, err := blacksmith.Polygon([][2]float64{{5, 0}, {8, 0}, {8, 10}, {5, 10}})
	if err != nil {
		fail(err.Error())
	}
	turned := must(blacksmith.RevolveInPlane(beside, xy, [2]float64{0, 0}, [2]float64{0, 1}, 2*math.Pi))
	turnedWalls := must(blacksmith.RevolveOpenInPlane(beside, xy, [2]float64{0, 0}, [2]float64{0, 1}, math.Pi))
	if count(turned) != 4 || count(turnedWalls) != 4 {
		fail(fmt.Sprintf("revolve_in_plane: %d and %d faces, not 4", count(turned), count(turnedWalls)))
	}
	for _, s := range []*blacksmith.Solid{holedSquare, turned, turnedWalls} {
		s.Close()
	}
	for _, p := range []*blacksmith.Profile{loopHole, loopSquare, fromLoops, beside} {
		p.Close()
	}
	// A hexagon: six walls and two caps. A closed spline through a square's corners: one wall.
	hexagon, err := blacksmith.RegularPolygon([2]float64{0, 0}, 10, 6, 0)
	if err != nil {
		fail(err.Error())
	}
	loopSpline, err := blacksmith.Spline([][2]float64{{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, nil, true)
	if err != nil {
		fail(err.Error())
	}
	hexPrism := must(blacksmith.Extrude(hexagon, xy, 2))
	loopSolid := must(blacksmith.Extrude(loopSpline, xy, 2))
	if count(hexPrism) != 8 || count(loopSolid) != 3 {
		fail(fmt.Sprintf("shapes: %d and %d faces, not 8 and 3", count(hexPrism), count(loopSolid)))
	}
	hexPrism.Close()
	loopSolid.Close()
	hexagon.Close()
	loopSpline.Close()
	fmt.Printf("sheet verbs: face, trim (%d+%d), face_sheet, drop_faces, round (%d faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, spline: ok\n", count(holed), count(disc), count(slab))
	for _, s := range []*blacksmith.Solid{sheet, peg, holed, disc, lid, walls, slab, tube, onPlane, away} {
		s.Close()
	}
	for _, p := range []*blacksmith.Profile{square, circle, rounded, wave, ring} {
		p.Close()
	}
	along.Close()
}
