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
	"sort"
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
	// scene.Bounds64's max narrowed to float32 equals bounds's max: narrowing (round to
	// nearest) is monotonic, so this holds for any file, not only the small-coordinate cube.
	sceneBounds64 := scene.Bounds64()
	for i := 0; i < 3; i++ {
		if float32(sceneBounds64.Max[i]) != float32(bounds.Max[i]) {
			fail("scene Bounds64's max narrowed does not equal Bounds's max")
		}
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

	iges := false
	for _, f := range cadaclysm.Formats() {
		if f.Name == "IGES" && len(f.Extensions) == 2 && f.Extensions[0] == "iges" && f.Extensions[1] == "igs" {
			iges = true
		}
	}
	if !iges {
		fail("Formats() lacks IGES iges;igs")
	}
	for _, f := range cadaclysm.MeshFormats() {
		if f.Name == "stl" && f.Label != "STL (binary)" {
			fail("mesh format label is not the library's: " + f.Label)
		}
	}
	fmt.Printf("geometry diagnostics: %d\n", len(scene.GeometryDiagnostics()))
	scene.ForgetMeshes()
	rebuiltTriangles := 0
	for _, n := range scene.Walk() {
		if m, _ := n.Mesh(); m != nil {
			rebuiltTriangles += m.TriangleCount()
		}
	}
	if rebuiltTriangles != triangles {
		fail("ForgetMeshes did not rebuild")
	}

	if cadaclysm.LodLevels() != 3 {
		fail("LodLevels is not 3")
	}
	var first *cadaclysm.Node
	for _, n := range scene.Walk() {
		if n.CanMesh() {
			first = n
			break
		}
	}
	lod0, _ := first.MeshLod(0)
	full, _ := first.Mesh()
	if lod0 == nil || full == nil || lod0.TriangleCount() != full.TriangleCount() {
		fail("LOD 0 is not the mesh")
	}
	if first.LodError(0) != 0 {
		fail("LOD error at level 0 is not zero")
	}
	if past, _ := first.MeshLod(4); past != nil {
		fail("a level past LodLevels is not empty")
	}
	if strings.HasSuffix(path, "cube.scad") {
		lod1, _ := first.MeshLod(1)
		if lod1 == nil || lod1.TriangleCount() != 3 || first.EdgeBeziers().Count() != 12 || len(first.EdgeBeziers().Points) != 12*12 {
			fail("the cube's LOD 1 or Béziers are off")
		}
	}

	// f64 twins: mesh64, beziers64 and bounds64 mirror their f32 twins, narrowed exactly --
	// narrowing (round to nearest) is monotonic, so comparing narrowed values holds for any
	// file, not only this small-coordinate cube. See the task report for what this
	// comparison cannot see (the far-from-origin case Go has no unit test to carry).
	mesh64, m64err := first.Mesh64()
	if m64err != nil {
		fail(m64err.Error())
	}
	if mesh64 == nil || mesh64.TriangleCount() != full.TriangleCount() || len(mesh64.Positions) != len(full.Positions) ||
		len(mesh64.Indices) != len(full.Indices) {
		fail("mesh64's vertex/index counts do not equal mesh's")
	}
	if len(full.Positions) >= 3 &&
		(float32(mesh64.Positions[0]) != full.Positions[0] ||
			float32(mesh64.Positions[1]) != full.Positions[1] ||
			float32(mesh64.Positions[2]) != full.Positions[2]) {
		fail("mesh64's first position narrowed to float does not equal mesh's first position")
	}
	edgeBeziers32, edgeBeziers64 := first.EdgeBeziers(), first.EdgeBeziers64()
	if edgeBeziers64.Count() != edgeBeziers32.Count() || len(edgeBeziers64.Points) != len(edgeBeziers32.Points) {
		fail("edgeBeziers64's count/length does not equal edgeBeziers's")
	}
	if len(edgeBeziers32.Points) >= 3 && float32(edgeBeziers64.Points[0]) != edgeBeziers32.Points[0] {
		fail("edgeBeziers64's first point narrowed does not equal edgeBeziers's")
	}
	if first.CurveBeziers64().Count() != first.CurveBeziers().Count() {
		fail("curveBeziers64's count does not equal curveBeziers's")
	}
	if first.IsocurveBeziers64().Count() != first.IsocurveBeziers().Count() {
		fail("isocurveBeziers64's count does not equal isocurveBeziers's")
	}
	nodeBounds64, nodeBounds32 := first.Bounds64(), first.Bounds()
	for i := 0; i < 3; i++ {
		if float32(nodeBounds64.Max[i]) != float32(nodeBounds32.Max[i]) {
			fail("bounds64's max narrowed does not equal bounds's max")
		}
	}
	fmt.Printf("reader f64 twins: mesh64 %d triangles, edgeBeziers64 %d, bounds64 max (%g,%g,%g)\n",
		mesh64.TriangleCount(), edgeBeziers64.Count(), sceneBounds64.Max[0], sceneBounds64.Max[1], sceneBounds64.Max[2])
	fit, ok := first.Collision(0)
	if !ok || fit.Error != 0 || fit.HullVertexCount != 8 || fit.ShapeName() == "" {
		fail("the collision fit is off")
	}
	if hull := first.CollisionHull(0); hull.VertexCount() != 8 || hull.IndexCount() != 36 {
		fail("the collision hull is off")
	}

	meshlets, merr := cadaclysm.BuildMeshlets(full.Positions, full.Normals, full.Indices, 124, 64, 0)
	if merr != nil {
		fail(merr.Error())
	}
	if meshlets.Count() < 1 {
		fail("no meshlets")
	}
	one := meshlets.Meshlet(0)
	if len(one.Positions) != one.VertexCount*3 || len(one.Indices) != one.TriangleCount*3 || one.Level != 0 {
		fail("meshlet 0 is off")
	}
	if strings.HasSuffix(path, "cube.scad") && (meshlets.Count() != 1 || one.TriangleCount != 12 || one.VertexCount != 36) {
		fail("the cube's meshlets are off")
	}
	meshlets.Close()
	meshlets.Close()
	if _, err := cadaclysm.BuildMeshlets(full.Positions, nil, full.Indices, 0, 64, 0); err == nil {
		fail("a zero budget was accepted")
	}

	if est := first.TriangleEstimate(); est <= 0 && est != -1 {
		fail("triangle estimate is neither a count nor -1")
	}
	if strings.HasSuffix(path, "cube.scad") {
		proxy, _ := first.SurfaceProxyMesh(4)
		if first.TriangleEstimate() != 12 || first.SurfaceEdges().PolylineCount() != 0 || proxy != nil {
			fail("the cube has no surface products")
		}
		if _, hit := first.SurfacePick([3]float64{10, 10, 100}, [3]float64{10, 10, -100}); hit || !first.BoundsPlaced(nil).IsEmpty() {
			fail("the cube picks or bounds through surfaces")
		}
		if !first.BoundsPlaced64(nil).IsEmpty() {
			fail("the cube's boundsPlaced64 is not empty either")
		}
	}
	fresh, ferr := cadaclysm.Open(path)
	if ferr != nil {
		fail(ferr.Error())
	}
	var body *cadaclysm.Node
	for _, n := range fresh.Walk() {
		if n.CanMesh() {
			body = n
			break
		}
	}
	if body.IsMeshed() {
		fail("a fresh scene is already meshed")
	}
	if built := fresh.RealizeMeshes(false); built == 0 || !body.IsMeshed() {
		fail("RealizeMeshes(false) did not build")
	}
	fresh.Close()

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

	// SVG: the library's own camera, no viewer -- a scene and a node each write a
	// wireframe.
	svgText, serr := scene.SvgText(nil)
	if serr != nil {
		fail(serr.Error())
	}
	if !strings.HasPrefix(svgText, "<svg") || !strings.Contains(svgText, "<path") {
		fail("scene SVG text did not look like an SVG wireframe")
	}
	svgPath := filepath.Join(os.TempDir(), "cadaclysm-smoke-go.svg")
	if serr := scene.Svg(svgPath, nil); serr != nil {
		fail(serr.Error())
	}
	if svgInfo, serr := os.Stat(svgPath); serr != nil || svgInfo.Size() == 0 {
		fail("Scene.Svg wrote an empty file")
	}
	nodeSvgText, serr := first.SvgText(nil)
	if serr != nil {
		fail(serr.Error())
	}
	if !strings.HasPrefix(nodeSvgText, "<svg") || !strings.Contains(nodeSvgText, "<path") {
		fail("node SVG text did not look like an SVG wireframe")
	}
	badFov := cadaclysm.NewSvgOptions()
	badFov.Fov = 200
	if _, serr := scene.SvgText(&badFov); serr == nil {
		fail("scene svg: fov=200 was accepted")
	}
	fmt.Println("svg: scene and node text, file written, fov=200 refused")

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
	hits()
	edgeCurves()
	intersections()
	solidHits()
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

	// Edge colour: the plate's edges gold, edge 0 blue -- an edge's own colour wins over
	// the all-edges one, and a bare read-back tells "no colour" from "an error".
	plateEdgesGold, err := plate.EdgesColoured(0.8, 0.6, 0.4)
	if err != nil {
		fail(err.Error())
	}
	defer plateEdgesGold.Close()
	plateEdges, err := plateEdgesGold.EdgesColouredPicked([]int{0}, 0.2, 0.4, 1.0)
	if err != nil {
		fail(err.Error())
	}
	defer plateEdges.Close()
	edge0Colour, ok, err := plateEdges.EdgeColour(0)
	if err != nil || !ok {
		fail(fmt.Sprintf("edge 0 has no colour (%v)", err))
	}
	edge1Colour, ok, err := plateEdges.EdgeColour(1)
	if err != nil || !ok {
		fail(fmt.Sprintf("edge 1 has no colour (%v)", err))
	}
	fmt.Printf("edge0=%v edge1=%v\n", edge0Colour, edge1Colour)
	if edge0Colour != [3]float64{0.2, 0.4, 1.0} || edge1Colour != [3]float64{0.8, 0.6, 0.4} {
		fail("edge colours did not come back as picked/all-edges")
	}
	edgePolylineColours, err := plateEdges.EdgePolylineColours(0.05)
	if err != nil {
		fail(err.Error())
	}
	if len(edgePolylineColours) == 0 {
		fail("EdgePolylineColours was empty on a solid with edge paint")
	}
	rectProfile, err := blacksmith.Rect(10, 4)
	if err != nil {
		fail(err.Error())
	}
	defer rectProfile.Close()
	goldProfile, err := rectProfile.Coloured(0.8, 0.6, 0.4)
	if err != nil {
		fail(err.Error())
	}
	defer goldProfile.Close()
	profileColour, ok, err := goldProfile.Colour()
	if err != nil || !ok {
		fail(fmt.Sprintf("the coloured profile has no colour (%v)", err))
	}
	if profileColour != [3]float64{0.8, 0.6, 0.4} {
		fail("the profile did not keep its own colour")
	}
	if _, ok, _ := plate.EdgeColour(0); ok {
		fail("the original plate should not have gained an edge colour")
	}
	// An empty edge list colours no edge -- only a nil list colours every edge.
	noneColoured, err := plate.EdgesColouredPicked([]int{}, 0.8, 0.6, 0.4)
	if err != nil {
		fail(err.Error())
	}
	defer noneColoured.Close()
	if _, ok, _ := noneColoured.EdgeColour(0); ok {
		fail("an empty edge list coloured edge 0")
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

	// f64 twins on the kernel: mesh64 shares mesh's cache and bounds64 the same
	// tessellation, unnarrowed. rounded's cache is filled at 0.05 by the view test above.
	kMesh32, err := rounded.Mesh(0.05)
	if err != nil {
		fail(err.Error())
	}
	kPositions32, err := kMesh32.Positions()
	if err != nil {
		fail(err.Error())
	}
	kMesh64, err := rounded.Mesh64(0.05)
	if err != nil {
		fail(err.Error())
	}
	kPositions64, err := kMesh64.Positions()
	if err != nil {
		fail(err.Error())
	}
	if kMesh64.VertexCount() != kMesh32.VertexCount() || kMesh64.IndexCount() != kMesh32.IndexCount() {
		fail("blacksmith mesh64's vertex/index counts do not equal mesh's")
	}
	if len(kPositions32) >= 3 &&
		(float32(kPositions64[0]) != kPositions32[0] ||
			float32(kPositions64[1]) != kPositions32[1] ||
			float32(kPositions64[2]) != kPositions32[2]) {
		fail("blacksmith mesh64's first position narrowed to float does not equal mesh's first position")
	}
	kBounds32, err := rounded.BoundsAt(0.05)
	if err != nil {
		fail(err.Error())
	}
	kBounds64, err := rounded.BoundsAt64(0.05)
	if err != nil {
		fail(err.Error())
	}
	for i := 0; i < 3; i++ {
		if math.Abs(kBounds64.Min[i]-kBounds32.Min[i]) > 1e-6 || math.Abs(kBounds64.Max[i]-kBounds32.Max[i]) > 1e-6 {
			fail("blacksmith bounds64(0.05) does not equal bounds(0.05)")
		}
	}
	fmt.Printf("blacksmith f64 twins: mesh64 %d triangles, bounds64 max z %g\n", kMesh64.TriangleCount(), kBounds64.Max[2])

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

	// The OCCT .brep writer, and its reader.
	brep := filepath.Join(os.TempDir(), "cadaclysm-smoke-go.brep")
	if err := rounded.Brep(brep); err != nil {
		fail(err.Error())
	}
	if text, err := rounded.BrepText(); err != nil || !strings.HasPrefix(text, "DBRep_DrawableShape") {
		fail("the .brep text does not begin as one")
	}
	backBrep, err := cadaclysm.Open(brep)
	if err != nil {
		fail("brep read back: " + err.Error())
	}
	defer backBrep.Close()
	bb := backBrep.Bounds()
	fmt.Printf("brep read back: bounds max=(%g,%g,%g)\n", bb.Max[0], bb.Max[1], bb.Max[2])
	if math.Abs(bb.Max[0]-40) > 0.01 || math.Abs(bb.Max[1]-20) > 0.01 || math.Abs(bb.Max[2]-16) > 0.01 {
		fail("the .brep did not read back as the plate with its pin")
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

	// The same solid as SAT, written by the library itself, read back the same way.
	sat := filepath.Join(os.TempDir(), "cadaclysm-smoke-go.sat")
	if err := rounded.Sat(sat, "mm"); err != nil {
		fail(err.Error())
	}
	if text, err := rounded.SatText("mm"); err != nil || !strings.HasPrefix(text, "400 0 1 0") {
		fail("the SAT text does not open with the record version")
	}
	satBack, err := cadaclysm.Open(sat)
	if err != nil {
		fail("sat read back: " + err.Error())
	}
	defer satBack.Close()
	satBounds := satBack.Bounds()
	fmt.Printf("sat read back: bounds max=(%g,%g,%g)\n", satBounds.Max[0], satBounds.Max[1], satBounds.Max[2])
	if math.Abs(satBounds.Max[0]-40) > 0.01 || math.Abs(satBounds.Max[1]-20) > 0.01 || math.Abs(satBounds.Max[2]-16) > 0.01 {
		fail("the SAT did not read back as the plate with its pin")
	}

	// SVG over the kernel: the solid's own wireframe, no scene involved.
	solidSvgText, err := rounded.SvgText(nil)
	if err != nil {
		fail(err.Error())
	}
	if !strings.HasPrefix(solidSvgText, "<svg") || !strings.Contains(solidSvgText, "<path") {
		fail("solid SVG text did not look like an SVG wireframe")
	}
	solidSvgPath := filepath.Join(os.TempDir(), "cadaclysm-smoke-go-solid.svg")
	if err := rounded.Svg(solidSvgPath, nil); err != nil {
		fail(err.Error())
	}
	if svgInfo, serr := os.Stat(solidSvgPath); serr != nil || svgInfo.Size() == 0 {
		fail("Solid.Svg wrote an empty file")
	}
	badFov := blacksmith.NewSvgOptions()
	badFov.Fov = 200
	if _, err := rounded.SvgText(&badFov); err == nil {
		fail("blacksmith svg: fov=200 was accepted")
	}
	fmt.Println("blacksmith svg: solid text, file written, fov=200 refused")

	// A profile's own plane, top by default -- pinned against an explicit iso call, not
	// just checked non-empty, so a silently-iso default would fail this.
	profileSvgTop, err := outline.SvgText(nil)
	if err != nil {
		fail(err.Error())
	}
	if !strings.HasPrefix(profileSvgTop, "<svg") || !strings.Contains(profileSvgTop, "<path") {
		fail("profile SVG text did not look like an SVG wireframe")
	}
	profileSvgPath := filepath.Join(os.TempDir(), "cadaclysm-smoke-go-profile.svg")
	if err := outline.Svg(profileSvgPath, nil); err != nil {
		fail(err.Error())
	}
	if svgInfo, serr := os.Stat(profileSvgPath); serr != nil || svgInfo.Size() == 0 {
		fail("Profile.Svg wrote an empty file")
	}
	isoOptions := blacksmith.NewSvgOptions()
	profileSvgIso, err := outline.SvgText(&isoOptions)
	if err != nil {
		fail(err.Error())
	}
	if profileSvgTop == profileSvgIso {
		fail("Profile.SvgText did not default to the top view")
	}
	fmt.Println("blacksmith svg: profile text, file written, top default confirmed against iso")

	// The widened pair: a solid and a profile drawn together, one call, both group ids.
	mixed, err := blacksmith.WriteDrawingSvgText([]*blacksmith.Solid{rounded}, []*blacksmith.Profile{outline}, nil)
	if err != nil {
		fail(err.Error())
	}
	if !strings.Contains(mixed, "<path") || !strings.Contains(mixed, `id="solid-0"`) || !strings.Contains(mixed, `id="profile-0"`) {
		fail("the mixed drawing did not contain both group ids")
	}
	mixedSvgPath := filepath.Join(os.TempDir(), "cadaclysm-smoke-go-mixed.svg")
	if err := blacksmith.WriteDrawingSvg(mixedSvgPath, []*blacksmith.Solid{rounded}, []*blacksmith.Profile{outline}, nil); err != nil {
		fail(err.Error())
	}
	if svgInfo, serr := os.Stat(mixedSvgPath); serr != nil || svgInfo.Size() == 0 {
		fail("WriteDrawingSvg wrote an empty file")
	}
	fmt.Println("blacksmith svg: solid and profile drawn together, both group ids present")

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

// hits checks two radius-5 circles six apart cross at two points, (3, -4) and (3, 4). At
// (3, 4) the first circle's upper arc is at t 0.2952 and the moved one's at 0.7048; at
// (3, -4) the other way round -- which catches the two sides read swapped.
func hits() {
	left, err := blacksmith.Circle(5)
	if err != nil {
		fail(err.Error())
	}
	defer left.Close()
	circle, err := blacksmith.Circle(5)
	if err != nil {
		fail(err.Error())
	}
	defer circle.Close()
	right, err := circle.Translate(6, 0)
	if err != nil {
		fail(err.Error())
	}
	defer right.Close()
	crossing, err := left.Hits(right, 1e-6)
	if err != nil {
		fail(err.Error())
	}
	if len(crossing) != 2 {
		fail(fmt.Sprintf("hits: two circles hit %d times, not 2", len(crossing)))
	}
	ys := []float64{crossing[0].Start[1], crossing[1].Start[1]}
	sort.Float64s(ys)
	if math.Abs(ys[0]+4) > 1e-9 || math.Abs(ys[1]-4) > 1e-9 {
		fail(fmt.Sprintf("hits: y %v, not -4 and 4", ys))
	}
	for _, h := range crossing {
		ta, tb := 0.7048, 0.2952
		if h.Start[1] > 0 {
			ta, tb = tb, ta
		}
		if h.Run || h.Touch || h.AStart.LoopIndex != 0 || math.Abs(h.Start[0]-3) > 1e-9 ||
			math.Abs(h.AStart.T-ta) > 1e-3 || math.Abs(h.BStart.T-tb) > 1e-3 {
			fail(fmt.Sprintf("hits: %v is not a crossing at (3, +-4) at t %v on a and %v on b", h, ta, tb))
		}
	}
	fmt.Printf("hits: %v, %v\n", crossing[0], crossing[1])
	// Common: the same two circles share one lens, four arcs (each circle's own seam stays
	// a join) between two caps once extruded; moved apart they share nothing.
	lenses, err := left.Common(right, 1e-6)
	if err != nil {
		fail(err.Error())
	}
	if len(lenses) != 1 {
		fail(fmt.Sprintf("common: two circles share %d regions, not 1", len(lenses)))
	}
	defer lenses[0].Close()
	lensSolid, err := blacksmith.XY().Extrude(lenses[0], 1).Solid()
	if err != nil {
		fail(err.Error())
	}
	defer lensSolid.Close()
	lensFaces, _ := lensSolid.Faces()
	if lensFaces != 6 {
		fail(fmt.Sprintf("common: the lens extrudes to %d faces, not 6", lensFaces))
	}
	far, err := circle.Translate(100, 0)
	if err != nil {
		fail(err.Error())
	}
	defer far.Close()
	if none, err := left.Common(far, 1e-6); err != nil || len(none) != 0 {
		fail(fmt.Sprintf("common: circles 100 apart share %d regions (%v)", len(none), err))
	}
	if _, err := left.Common(right, 0); err == nil || !strings.Contains(err.Error(), "profile_common: tolerance must be positive and finite") {
		fail(fmt.Sprintf("common: a zero tolerance was accepted or refused in other words: %v", err))
	}
	fmt.Printf("common: one lens, %d faces extruded\n", lensFaces)
}

// edgeCurves: a cylinder's rims are circles of its radius about a cap centre in a unit
// frame, a whole turn each; a cuboid's edges are lines whose origin + x is the far end;
// an extruded closed spline keeps a nurbs edge with knots = poles + degree + 1.
func edgeCurves() {
	norm := func(v [3]float64) float64 { return math.Sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]) }
	sub := func(a, b [3]float64) [3]float64 { return [3]float64{a[0] - b[0], a[1] - b[1], a[2] - b[2]} }
	cyl, err := blacksmith.Cylinder(5, 3)
	if err != nil {
		fail(err.Error())
	}
	defer cyl.Close()
	edges, err := cyl.Edges()
	if err != nil {
		fail(err.Error())
	}
	var rims []*blacksmith.Curve
	for _, e := range edges {
		if e.Kind == "circle" {
			rims = append(rims, e.Curve)
		}
	}
	if len(rims) < 2 {
		fail("edge_curve: the cylinder has under two rims")
	}
	for _, c := range rims {
		if c == nil {
			fail("edge_curve: a rim has no curve")
		}
		unit := math.Abs(norm(c.X)-1) < 1e-9 && math.Abs(norm(c.Y)-1) < 1e-9 &&
			math.Abs(c.X[0]*c.Y[0]+c.X[1]*c.Y[1]+c.X[2]*c.Y[2]) < 1e-9
		centred := math.Abs(c.Origin[0]) < 1e-9 && math.Abs(c.Origin[1]) < 1e-9 &&
			math.Min(math.Abs(c.Origin[2]), math.Abs(c.Origin[2]-3)) < 1e-9
		if c.Kind != "circle" || math.Abs(c.Radius-5) > 1e-9 || !unit || !centred ||
			math.Abs(math.Abs(c.T1-c.T0)-2*math.Pi) > 1e-9 || c.Degree != 0 || len(c.Knots) != 0 || c.Weights != nil {
			fail(fmt.Sprintf("edge_curve: a rim reads %v", c))
		}
	}
	box, err := blacksmith.Cuboid(2, 4, 6)
	if err != nil {
		fail(err.Error())
	}
	defer box.Close()
	boxEdges, err := box.Edges()
	if err != nil {
		fail(err.Error())
	}
	for _, e := range boxEdges {
		c := e.Curve
		if c == nil || c.Kind != "line" || c.T0 != 0 || c.T1 != 1 {
			fail(fmt.Sprintf("edge_curve: a cuboid edge reads %v", c))
		}
		far := [3]float64{c.Origin[0] + c.X[0], c.Origin[1] + c.X[1], c.Origin[2] + c.X[2]}
		atOrigin, atFar := false, false
		for _, s := range e.Segments {
			for _, p := range s {
				atOrigin = atOrigin || norm(sub(p, c.Origin)) < 1e-9
				atFar = atFar || norm(sub(p, far)) < 1e-9
			}
		}
		if !atOrigin || !atFar {
			fail(fmt.Sprintf("edge_curve: a cuboid line's ends are not its own vertices: %v", c))
		}
	}
	square, err := blacksmith.Spline([][2]float64{{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, nil, true)
	if err != nil {
		fail(err.Error())
	}
	defer square.Close()
	loop, err := blacksmith.XY().Extrude(square, 2).Solid()
	if err != nil {
		fail(err.Error())
	}
	defer loop.Close()
	loopEdges, err := loop.Edges()
	if err != nil {
		fail(err.Error())
	}
	var splines []*blacksmith.Curve
	for _, e := range loopEdges {
		if e.Kind == "nurbs" {
			splines = append(splines, e.Curve)
		}
	}
	if len(splines) == 0 {
		fail("edge_curve: the extruded spline keeps no nurbs edge")
	}
	for _, c := range splines {
		if c == nil || c.Kind != "nurbs" || c.Degree != 3 || len(c.Knots) != len(c.Poles)+c.Degree+1 || c.Weights != nil {
			fail(fmt.Sprintf("edge_curve: the spline edge reads %v", c))
		}
	}
	fmt.Printf("edge_curve: %v; %v; %v\n", rims[0], boxEdges[0].Curve, splines[0])
}

// intersections: two equal pipes crossing at right angles meet on ellipse chains whose
// points lie on both pipes; apart, nothing; a zero tolerance refused in the kernel's words.
// Two coaxial pipes overlapping in height share a wall band: an overlap whose rings lie on it.
func intersections() {
	const tol = 1e-3
	offA := func(p [3]float64) float64 { return math.Abs(math.Hypot(p[0], p[1]) - 1) }
	offB := func(p [3]float64) float64 { return math.Abs(math.Hypot(p[0], p[2]-3) - 1) }
	pipeA, err := blacksmith.Cylinder(1, 6)
	if err != nil {
		fail(err.Error())
	}
	defer pipeA.Close()
	upright, err := blacksmith.Cylinder(1, 6)
	if err != nil {
		fail(err.Error())
	}
	defer upright.Close()
	pipeB, err := upright.Rotate([6]float64{0, 0, 3, 1, 0, 0}, math.Pi/2)
	if err != nil {
		fail(err.Error())
	}
	defer pipeB.Close()
	found, err := pipeA.Intersect(pipeB, tol)
	if err != nil {
		fail(err.Error())
	}
	if len(found.Chains) < 2 || len(found.Overlaps) != 0 {
		fail(fmt.Sprintf("intersect: the crossed pipes read %v", found))
	}
	facesA, _ := pipeA.Faces()
	facesB, _ := pipeB.Faces()
	ellipses := 0
	for _, c := range found.Chains {
		if c.FaceA < 0 || c.FaceA >= facesA || c.FaceB < 0 || c.FaceB >= facesB || len(c.Points) < 2 {
			fail(fmt.Sprintf("intersect: a chain reads %v", c))
		}
		for _, p := range c.Points {
			if offA(p) > 50*tol || offB(p) > 50*tol {
				fail(fmt.Sprintf("intersect: a chain leaves the pipes: %v", c))
			}
		}
		if c.Curve == nil {
			continue
		}
		if c.Curve.Kind != "ellipse" && c.Curve.Kind != "nurbs" {
			fail(fmt.Sprintf("intersect: a chain's curve reads %v", c.Curve))
		}
		if c.Curve.Kind != "ellipse" {
			continue
		}
		ellipses++
		t := (c.Curve.T0 + c.Curve.T1) / 2
		var q [3]float64
		for k := range q {
			q[k] = c.Curve.Origin[k] + c.Curve.X[k]*c.Curve.Radius*math.Cos(t) + c.Curve.Y[k]*c.Curve.Radius2*math.Sin(t)
		}
		if offA(q) > 50*tol || offB(q) > 50*tol {
			fail(fmt.Sprintf("intersect: the ellipse leaves the pipes at %v", c.Curve))
		}
	}
	if ellipses == 0 {
		fail("intersect: two equal pipes cross on ellipses")
	}
	far, err := pipeB.Translate(10, 0, 0)
	if err != nil {
		fail(err.Error())
	}
	defer far.Close()
	apart, err := pipeA.Intersect(far, 0.05)
	if err != nil {
		fail(err.Error())
	}
	if len(apart.Chains) != 0 || len(apart.Overlaps) != 0 {
		fail(fmt.Sprintf("intersect: pipes apart read %v", apart))
	}
	if _, err := pipeA.Intersect(pipeB, 0.0); err == nil || !strings.Contains(err.Error(), "intersect: tolerance must be positive and finite") {
		fail(fmt.Sprintf("intersect: a zero tolerance was accepted or refused in other words: %v", err))
	}
	lower, err := blacksmith.Cylinder(1, 4)
	if err != nil {
		fail(err.Error())
	}
	defer lower.Close()
	base, err := blacksmith.Cylinder(1, 4)
	if err != nil {
		fail(err.Error())
	}
	defer base.Close()
	upper, err := base.Translate(0, 0, 2)
	if err != nil {
		fail(err.Error())
	}
	defer upper.Close()
	shared, err := lower.Intersect(upper, tol)
	if err != nil {
		fail(err.Error())
	}
	if len(shared.Overlaps) < 1 || len(shared.Overlaps[0].Loops) < 1 {
		fail(fmt.Sprintf("intersect: the coaxial pipes read %v", shared))
	}
	for _, ring := range shared.Overlaps[0].Loops {
		if len(ring) < 3 {
			fail(fmt.Sprintf("intersect: an overlap ring is not a polygon: %v", shared.Overlaps[0]))
		}
		for _, p := range ring {
			if offA(p) > 50*tol || p[2] < 2-50*tol || p[2] > 4+50*tol {
				fail(fmt.Sprintf("intersect: an overlap ring leaves the shared band: %v", shared.Overlaps[0]))
			}
		}
	}
	fmt.Printf("intersect: %v (%d ellipses); %v\n", found, ellipses, shared.Overlaps[0])
}

// solidHits: a line through a cuboid pierces two faces and is cut into three pieces,
// outside/inside/outside, the middle one spanning the box and sweeping; a loop no hit cuts is
// one piece; an open sheet has no pieces; a zero tolerance refused in the kernel's words.
func solidHits() {
	check := func(err error) {
		if err != nil {
			fail(err.Error())
		}
	}
	xy := blacksmith.Frame{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	box, err := blacksmith.Cuboid(10, 20, 30)
	check(err)
	defer box.Close()
	line, err := blacksmith.NewPath(-20, 0).LineTo(20, 0).EndOpen()
	check(err)
	defer line.Close()
	found, err := box.Hits(line, xy, 0.05)
	check(err)
	if len(found.Hits) != 2 || len(found.Pieces) != 3 {
		fail(fmt.Sprintf("solid hits: a line through a cuboid reads %v", found))
	}
	for k, h := range found.Hits {
		x := []float64{-5, 5}[k]
		if h.Run || h.Touch || math.Abs(h.Start[0]-x) > 0.05 || h.AStart.Segment != 0 || h.AStart.Face != math.MaxUint32 ||
			h.BStart.Face == math.MaxUint32 || math.IsNaN(h.BStart.U) || math.IsInf(h.BStart.U, 0) || math.IsNaN(h.BStart.V) || math.IsInf(h.BStart.V, 0) {
			fail(fmt.Sprintf("solid hits: hit %d reads %v (%v, %v)", k, h, h.AStart, h.BStart))
		}
	}
	p := found.Pieces
	if p[0].Inside || !p[1].Inside || p[2].Inside {
		fail(fmt.Sprintf("solid hits: the pieces read %v", p))
	}
	if p[0].Start.T != 0 || p[2].End.T != 1 || p[0].End.T != p[1].Start.T || p[1].End.T != p[2].Start.T {
		fail(fmt.Sprintf("solid hits: the pieces do not run head to tail: %v", p))
	}
	middle, err := blacksmith.ExtrudeOpen(p[1].Profile, xy, 1)
	check(err)
	defer middle.Close()
	b, err := middle.Bounds()
	check(err)
	if math.Abs(b.Min[0]+5) > 0.05 || math.Abs(b.Max[0]-5) > 0.05 {
		fail(fmt.Sprintf("solid hits: the middle piece spans x %v .. %v, not the box", b.Min[0], b.Max[0]))
	}
	along := blacksmith.SweepPathAlong(p[1].Profile, xy, 0.05, true)
	check(along.Err())
	defer along.Close()
	for _, piece := range p {
		defer piece.Profile.Close()
	}
	circle, err := blacksmith.Circle(1)
	check(err)
	defer circle.Close()
	far, err := box.Hits(circle, blacksmith.Frame{100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}, 0.05)
	check(err)
	if len(far.Hits) != 0 || len(far.Pieces) != 1 || far.Pieces[0].Inside {
		fail(fmt.Sprintf("solid hits: a circle far off reads %v", far))
	}
	square, err := blacksmith.Rect(20, 20)
	check(err)
	defer square.Close()
	flat, err := blacksmith.Face(square, xy)
	check(err)
	defer flat.Close()
	upright, err := blacksmith.NewPath(0, -20).LineTo(0, 20).EndOpen()
	check(err)
	defer upright.Close()
	across, err := flat.Hits(upright, blacksmith.Frame{0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0}, 0.05)
	check(err)
	if len(across.Hits) < 1 || len(across.Pieces) != 0 {
		fail(fmt.Sprintf("solid hits: a line across a sheet reads %v", across))
	}
	if _, err := box.Hits(line, xy, 0.0); err == nil || err.Error() != "solid_profile_hits: tolerance must be positive and finite" {
		fail(fmt.Sprintf("solid hits: a zero tolerance reads %v", err))
	}
	fmt.Printf("solid hits: %v; %v\n", found, p[1])
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
	// Its top and a side pushed together: a 15 x 10 x 15 box, still six faces.
	cubeSide, err := cube.SelectFace(blacksmith.Max(blacksmith.AxisX))
	if err != nil {
		fail(err.Error())
	}
	grown := must(cube.PushPullFaces([]int{cubeTop, cubeSide}, 5, blacksmith.DefaultTolerance))
	if count(grown) != 6 {
		fail(fmt.Sprintf("push_pull: the cube grown two ways has %d faces, not 6", count(grown)))
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
	grown.Close()
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
	// A five-pointed star: ten walls and two caps.
	star, err := blacksmith.Star([2]float64{0, 0}, 10, 4, 5, 0)
	if err != nil {
		fail(err.Error())
	}
	starPrism := must(blacksmith.Extrude(star, xy, 2))
	if count(starPrism) != 12 {
		fail(fmt.Sprintf("star: %d faces, not 12", count(starPrism)))
	}
	// Text: an `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring with spline edges.
	word, err := blacksmith.Text("io", 10, "", "left", "baseline", 1, "ltr", nil)
	if err != nil {
		fail(err.Error())
	}
	textRing := must(blacksmith.Extrude(word[2], xy, 2))
	ringEdges, err := textRing.Edges()
	if err != nil {
		fail(err.Error())
	}
	spline := false
	for _, e := range ringEdges {
		if e.Kind == "nurbs" {
			spline = true
		}
	}
	if len(word) != 3 || !spline {
		fail(fmt.Sprintf("text: %d shapes, spline edges %v", len(word), spline))
	}
	if count(hexPrism) != 8 || count(loopSolid) != 3 {
		fail(fmt.Sprintf("shapes: %d and %d faces, not 8 and 3", count(hexPrism), count(loopSolid)))
	}
	hexPrism.Close()
	loopSolid.Close()
	hexagon.Close()
	loopSpline.Close()
	// A reflector: the parabola from rim to rim, closed and revolved -- watertight.
	dish, err := blacksmith.Parabola([2]float64{0, 0}, [2]float64{0, 1}, 20, 0, 50)
	if err != nil {
		fail(err.Error())
	}
	dishProfile, err := dish.LineTo(0, 31.25).LineTo(0, 0).End()
	if err != nil {
		fail(err.Error())
	}
	bowl := must(blacksmith.RevolveInPlane(dishProfile, xy, [2]float64{0, 0}, [2]float64{0, 1}, 2*math.Pi))
	if watertight, err := bowl.IsWatertight(blacksmith.DefaultTolerance); err != nil || !watertight {
		fail("parabola: the bowl leaks")
	}
	dishProfile.Close()
	bowl.Close()
	// The library reads a fixed count of weights: a wrong count is refused, not read past.
	corners := [][2]float64{{0, 0}, {10, 0}, {10, 10}, {0, 10}}
	control := [][2]float64{{5, 5}, {10, 0}}
	knots := []float64{0, 0, 0, 1, 1, 1}
	weighted, err := blacksmith.Spline(corners, 3, []float64{1, 2, 1, 1}, true)
	if err != nil {
		fail(err.Error())
	}
	weighted.Close()
	rational, err := blacksmith.NewPath(0, 0).NurbsTo(control, knots, 2, []float64{1, 0.5, 1}).EndOpen()
	if err != nil {
		fail(err.Error())
	}
	rational.Close()
	for _, weights := range [][]float64{{1, 1}, {}} {
		if _, err := blacksmith.Spline(corners, 3, weights, true); err == nil ||
			err.Error() != fmt.Sprintf("spline: %d weights for 4 points; give one per point", len(weights)) {
			fail(fmt.Sprintf("a wrong spline weight count: %v", err))
		}
		if _, err := blacksmith.NewPath(0, 0).NurbsTo(control, knots, 2, weights).EndOpen(); err == nil ||
			err.Error() != fmt.Sprintf("nurbs_to: %d weights for 3 control points (the current point and 2 given); give one per point", len(weights)) {
			fail(fmt.Sprintf("a wrong nurbs_to weight count: %v", err))
		}
	}
	fmt.Printf("sheet verbs: face, trim (%d+%d), face_sheet, drop_faces, round (%d faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, star, text, spline, parabola: ok\n", count(holed), count(disc), count(slab))
	for _, s := range []*blacksmith.Solid{sheet, peg, holed, disc, lid, walls, slab, tube, onPlane, away} {
		s.Close()
	}
	for _, p := range []*blacksmith.Profile{square, circle, rounded, wave, ring} {
		p.Close()
	}
	along.Close()
}
