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
	// Kinematics: a file with no mechanism carries no links or joints; mechanism.stp,
	// beside whatever sample this smoke was given, carries the fixed two-link one-joint
	// mechanism.
	if filepath.Base(path) == "cube.scad" && (len(scene.Links()) != 0 || len(scene.Joints()) != 0) {
		fail("the cube scene has links or joints")
	}
	absPath, aperr := filepath.Abs(path)
	if aperr != nil {
		fail(aperr.Error())
	}
	mechanismPath := filepath.Join(filepath.Dir(absPath), "mechanism.stp")
	mechanism, merr2 := cadaclysm.Open(mechanismPath)
	if merr2 != nil {
		fail(merr2.Error())
	}
	links := mechanism.Links()
	if len(links) != 2 || links[0].Name() != "base" || links[1].Name() != "arm" {
		fail("mechanism links are not [base, arm]")
	}
	for _, link := range links {
		nodes := link.Nodes()
		if len(nodes) != 1 || nodes[0].Name() != link.Name() {
			fail("link " + link.Name() + " does not name exactly one node of its own name")
		}
	}
	joints := mechanism.Joints()
	if len(joints) != 1 || joints[0].Name() != "hinge" {
		fail("mechanism does not carry exactly one joint named hinge")
	}
	joint := joints[0]
	start, end := joint.Start(), joint.End()
	// The file's order, (arm, base): a swap into (parent, child) would fail here.
	if start.Name() != "arm" || start.Index() != 1 || end.Name() != "base" || end.Index() != 0 {
		fail(fmt.Sprintf("joint hinge reads start=%s#%d end=%s#%d", start.Name(), start.Index(), end.Name(), end.Index()))
	}
	fmt.Printf("kinematics: links %d, joints %d, hinge %s->%s\n", len(links), len(joints), start.Name(), end.Name())
	mechanism.Close()
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
		if first.SurfaceEdgeBeziers().Count() != 0 {
			fail("the cube hands exact edges to the surface path")
		}
		if len(first.EdgeColours()) != 0 || len(first.SurfaceEdgeColours()) != 0 {
			fail("the unpainted cube has edge colours")
		}
	}
	// Edge colours: samples/edge-colours.stp sits beside the given sample and paints one
	// edge teal (0.1, 0.6, 0.55) on the body -- everything else, edge and surface-edge
	// alike, stays unstyled.
	absPath, absErr := filepath.Abs(path)
	if absErr != nil {
		fail(absErr.Error())
	}
	edgeColoursPath := filepath.Join(filepath.Dir(absPath), "edge-colours.stp")
	edgeColoursScene, ecErr := cadaclysm.Open(edgeColoursPath)
	if ecErr != nil {
		fail(ecErr.Error())
	}
	var edgeColoursBody *cadaclysm.Node
	for _, n := range edgeColoursScene.Walk() {
		if n.Edges().PolylineCount() > 0 {
			edgeColoursBody = n
			break
		}
	}
	if edgeColoursBody == nil {
		fail("edge colours: no node with edges")
	}
	type polylineColours struct {
		count   int
		colours [][]float32
	}
	for _, pc := range []polylineColours{
		{edgeColoursBody.Edges().PolylineCount(), edgeColoursBody.EdgeColours()},
		{edgeColoursBody.SurfaceEdges().PolylineCount(), edgeColoursBody.SurfaceEdgeColours()},
	} {
		if len(pc.colours) != pc.count {
			fail(fmt.Sprintf("edge colours: %d entries for %d polylines", len(pc.colours), pc.count))
		}
		styled := 0
		var styledColour []float32
		for _, c := range pc.colours {
			if c != nil {
				styled++
				styledColour = c
			}
		}
		if styled != 1 {
			fail(fmt.Sprintf("edge colours: %d styled entries, not exactly one", styled))
		}
		if math.Abs(float64(styledColour[0])-0.1) > 1e-6 || math.Abs(float64(styledColour[1])-0.6) > 1e-6 ||
			math.Abs(float64(styledColour[2])-0.55) > 1e-6 || math.Abs(float64(styledColour[3])-1.0) > 1e-6 {
			fail(fmt.Sprintf("edge colours: the styled entry reads (%g,%g,%g,%g), not (0.1,0.6,0.55,1.0)",
				styledColour[0], styledColour[1], styledColour[2], styledColour[3]))
		}
	}
	edgeColoursScene.Close()
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

	// A Rhino extrusion hands its exact edges to the surface path without meshing, in both
	// conventions: Unreal goes through the decorator that maps every getter into the caller's
	// space. The fixture is the repository's, not an SDK checkout's, so this runs where found.
	extrusions := filepath.Join(filepath.Dir(filepath.Dir(path)), "crates", "cadaclysm-acis", "tests", "fixtures", "rhino", "extrusion-objects.3dm")
	if _, err := os.Stat(extrusions); err == nil {
		for _, convention := range []cadaclysm.Convention{cadaclysm.Native, cadaclysm.Unreal} {
			surfaced, serr := cadaclysm.Open(extrusions, cadaclysm.WithConvention(convention))
			if serr != nil {
				fail(serr.Error())
			}
			found := 0
			for _, n := range surfaced.Walk() {
				if !n.CanMesh() || n.SurfaceEdges().PolylineCount() == 0 {
					continue
				}
				exact := n.SurfaceEdgeBeziers().Count()
				if exact == 0 || n.IsMeshed() {
					fail("an extrusion's exact edges are not free")
				}
				if exact != n.EdgeBeziers().Count() {
					fail("SurfaceEdgeBeziers is not EdgeBeziers' segments")
				}
				found++
			}
			if found == 0 {
				fail("extrusion-objects.3dm has no surfaced extrusion")
			}
			fmt.Printf("SurfaceEdgeBeziers (convention %d): %d extrusions, exact and unmeshed\n", convention, found)
			surfaced.Close()
		}
	}

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

	femReader(first, path)

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

	// The FEM surface mesh, both sides of the ABI: a B-rep body read back through the
	// reader, and the same solid through the kernel.
	femBrep(step, faces)
	femKernel(rounded, sheet, faces)

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

	// Scaled: every length times factor, exactly; a non-positive or non-finite factor is refused.
	box, err := blacksmith.Cuboid(1, 2, 3)
	if err != nil {
		fail(err.Error())
	}
	defer box.Close()
	big, err := box.Scaled(2)
	if err != nil {
		fail(err.Error())
	}
	defer big.Close()
	scaledBounds, err := big.Bounds()
	if err != nil {
		fail(err.Error())
	}
	if math.Abs(scaledBounds.Max[0]-scaledBounds.Min[0]-2) > 1e-9 || math.Abs(scaledBounds.Max[2]-scaledBounds.Min[2]-6) > 1e-9 {
		fail("scaled bounds")
	}
	if _, err := box.Scaled(0); err == nil || !strings.HasPrefix(err.Error(), "scaled:") {
		fail("scaled(0) not refused")
	}
	fmt.Println("blacksmith scaled: bounds tripled, non-positive factor refused")

	assembly()
}

// assembly is Assembly, Solid.Named and Solid.Name, at parity with the Python reference's
// _shared_assembly() and the tests built on it.
func assembly() {
	asmBolt, err := blacksmith.Cylinder(1, 6)
	if err != nil {
		fail(err.Error())
	}
	asmBolt, err = asmBolt.Named("bolt")
	if err != nil {
		fail(err.Error())
	}
	defer asmBolt.Close()
	asmPlateRaw, err := blacksmith.Cuboid(20, 10, 2)
	if err != nil {
		fail(err.Error())
	}
	asmPlateNamed, err := asmPlateRaw.Named("plate")
	if err != nil {
		fail(err.Error())
	}
	asmPlateRaw.Close()
	asmPlate, err := asmPlateNamed.Coloured(1, 0.5, 0)
	if err != nil {
		fail(err.Error())
	}
	asmPlateNamed.Close()
	defer asmPlate.Close()

	bracket, err := blacksmith.NewAssembly("bracket")
	if err != nil {
		fail(err.Error())
	}
	defer bracket.Close()
	platePlacement, err := bracket.PlaceSolid(asmPlate, blacksmith.FrameXY([3]float64{}), "")
	if err != nil {
		fail(err.Error())
	}
	bolt1Placement, err := bracket.PlaceSolid(asmBolt, blacksmith.FrameXY([3]float64{5, 5, 2}), "")
	if err != nil {
		fail(err.Error())
	}
	bolt2Placement, err := bracket.PlaceSolid(asmBolt, blacksmith.FrameXY([3]float64{15, 5, 2}), "")
	if err != nil {
		fail(err.Error())
	}
	if platePlacement != "plate" || bolt1Placement != "bolt" || bolt2Placement != "bolt 2" {
		fail(fmt.Sprintf("assembly: bracket placements were %q, %q, %q, not plate/bolt/bolt 2",
			platePlacement, bolt1Placement, bolt2Placement))
	}

	asmFrame, err := blacksmith.NewAssembly("frame")
	if err != nil {
		fail(err.Error())
	}
	defer asmFrame.Close()
	leftPlacement, err := asmFrame.PlaceAssembly(bracket, blacksmith.FrameXY([3]float64{0, 0, 0}), "left")
	if err != nil {
		fail(err.Error())
	}
	// The mirrored-looking right placement is still right-handed: x=(0,1,0), y=(-1,0,0),
	// z=x×y=(0,0,1) — a 90-degree turn about z, not a mirror.
	rightPlacement, err := asmFrame.PlaceAssembly(bracket, blacksmith.Frame{100, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 1}, "right")
	if err != nil {
		fail(err.Error())
	}
	rootBoltPlacement, err := asmFrame.PlaceSolid(asmBolt, blacksmith.FrameXY([3]float64{50, 50, 0}), "")
	if err != nil {
		fail(err.Error())
	}
	if leftPlacement != "left" || rightPlacement != "right" || rootBoltPlacement != "bolt" {
		fail(fmt.Sprintf("assembly: frame placements were %q, %q, %q, not left/right/bolt",
			leftPlacement, rightPlacement, rootBoltPlacement))
	}

	frameStepText, err := asmFrame.StepText("", "mm")
	if err != nil {
		fail(err.Error())
	}
	manifoldCount := strings.Count(frameStepText, "=MANIFOLD_SOLID_BREP(")
	productCount := strings.Count(frameStepText, "=PRODUCT(")
	nauoCount := strings.Count(frameStepText, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(")
	if manifoldCount != 2 || productCount != 4 || nauoCount != 6 {
		fail(fmt.Sprintf("assembly: frame step_text has %d breps, %d products, %d NAUOs, not 2/4/6",
			manifoldCount, productCount, nauoCount))
	}
	if !strings.Contains(frameStepText, "'left'") || !strings.Contains(frameStepText, "'right'") || !strings.Contains(frameStepText, "'bolt 2'") {
		fail("assembly: frame step_text is missing 'left', 'right' or 'bolt 2'")
	}
	fmt.Printf("assembly: frame writes %d breps, %d products, %d NAUOs\n", manifoldCount, productCount, nauoCount)

	// Read-back, through the same reader door as Solid.ToScene -- structure only, at this
	// (pre-late-placement) text: one root "frame", two "bracket" containers each holding
	// plate/bolt/bolt, and one root-level "bolt". The world origins are Python's to check.
	readScene, err := cadaclysm.OpenMemory([]byte(frameStepText), "frame.stp")
	if err != nil {
		fail(err.Error())
	}
	roots := readScene.Roots()
	if len(roots) != 1 || roots[0].Name() != "frame" {
		fail("assembly: the read-back root is not one node named \"frame\"")
	}
	rootChildren := roots[0].Children()
	if len(rootChildren) != 3 {
		fail(fmt.Sprintf("assembly: the read-back root has %d children, not 3", len(rootChildren)))
	}
	var containers, rootBolts []*cadaclysm.Node
	for _, c := range rootChildren {
		switch c.Name() {
		case "bracket":
			containers = append(containers, c)
		case "bolt":
			rootBolts = append(rootBolts, c)
		}
	}
	if len(containers) != 2 || len(rootBolts) != 1 {
		fail("assembly: the read-back root does not have two bracket containers and one bolt")
	}
	for _, container := range containers {
		names := make([]string, 0, 3)
		for _, c := range container.Children() {
			names = append(names, c.Name())
		}
		sort.Strings(names)
		if len(names) != 3 || names[0] != "bolt" || names[1] != "bolt" || names[2] != "plate" {
			fail("assembly: a read-back bracket container does not hold plate, bolt, bolt")
		}
	}
	readScene.Close()
	fmt.Println("assembly: the read-back tree has one root, two bracket containers of plate+bolt+bolt, and one root bolt")

	// A late placement into bracket shows up wherever bracket is placed (left and right both).
	if _, err := bracket.PlaceSolid(asmBolt, blacksmith.FrameXY([3]float64{10, 8, 2}), ""); err != nil {
		fail(err.Error())
	}
	laterText, err := asmFrame.StepText("", "mm")
	if err != nil {
		fail(err.Error())
	}
	laterNauoCount := strings.Count(laterText, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(")
	if laterNauoCount != 7 {
		fail(fmt.Sprintf("assembly: a late placement gave %d NAUOs, not 7", laterNauoCount))
	}
	fmt.Println("assembly: a late placement into bracket shows up wherever it is placed")

	// A cycle, a duplicate placement name, a mirrored frame, and an assembly (or one
	// reachable from it) that places nothing are all refused.
	if _, err := bracket.PlaceAssembly(asmFrame, blacksmith.FrameXY([3]float64{}), ""); err == nil || !strings.Contains(err.Error(), "bracket → frame → bracket") {
		fail(fmt.Sprintf("assembly: a cycle (bracket -> frame -> bracket) was not refused right: %v", err))
	}
	if _, err := asmFrame.PlaceAssembly(bracket, blacksmith.FrameXY([3]float64{}), "left"); err == nil || !strings.Contains(err.Error(), "left") {
		fail(fmt.Sprintf("assembly: a duplicate placement name was not refused right: %v", err))
	}
	// A raw twelve-number frame, not the Frame type's own constructors, which refuse a
	// left-handed triple before Place is ever called -- the one way to drive a mirrored
	// frame into the ABI's own rigidity check.
	mirrored := blacksmith.Frame{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1}
	if _, err := asmFrame.PlaceAssembly(bracket, mirrored, ""); err == nil || !strings.Contains(err.Error(), "right-handed and orthonormal") {
		fail(fmt.Sprintf("assembly: a mirrored raw frame was not refused right: %v", err))
	}
	x, err := blacksmith.NewAssembly("x")
	if err != nil {
		fail(err.Error())
	}
	if _, err := x.StepText("", "mm"); err == nil {
		fail("assembly: an empty assembly wrote step text")
	}
	x.Close()
	outer, err := blacksmith.NewAssembly("outer")
	if err != nil {
		fail(err.Error())
	}
	hollow, err := blacksmith.NewAssembly("hollow")
	if err != nil {
		fail(err.Error())
	}
	if _, err := outer.PlaceAssembly(hollow, blacksmith.FrameXY([3]float64{}), ""); err != nil {
		fail(err.Error())
	}
	if _, err := outer.StepText("", "mm"); err == nil || !strings.Contains(err.Error(), "hollow") {
		fail(fmt.Sprintf("assembly: an assembly reachable from the root that places nothing was not refused right: %v", err))
	}
	outer.Close()
	hollow.Close()
	fmt.Println("assembly: a cycle, a duplicate name, a mirrored frame, and an empty assembly are all refused")

	// Solid.Named/Solid.Name: the name rides through a one-source operation (Place,
	// Coloured) and is dropped by a two-source one (Join) or a fresh primitive.
	if name, ok := asmBolt.Name(); !ok || name != "bolt" {
		fail(fmt.Sprintf("assembly: bolt.Name() is %q, %v, not \"bolt\", true", name, ok))
	}
	placedBolt, err := asmBolt.Place(blacksmith.FrameXY([3]float64{1, 2, 3}))
	if err != nil {
		fail(err.Error())
	}
	if name, ok := placedBolt.Name(); !ok || name != "bolt" {
		fail(fmt.Sprintf("assembly: bolt.Place(...).Name() is %q, %v, not \"bolt\", true", name, ok))
	}
	placedBolt.Close()
	colouredBolt, err := asmBolt.Coloured(1, 0, 0)
	if err != nil {
		fail(err.Error())
	}
	if name, ok := colouredBolt.Name(); !ok || name != "bolt" {
		fail(fmt.Sprintf("assembly: bolt.Coloured(...).Name() is %q, %v, not \"bolt\", true", name, ok))
	}
	colouredBolt.Close()
	cube, err := blacksmith.Cuboid(1, 1, 1)
	if err != nil {
		fail(err.Error())
	}
	joinedBolt, err := asmBolt.Join(cube, blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	if name, ok := joinedBolt.Name(); ok {
		fail(fmt.Sprintf("assembly: bolt.Join(...).Name() is %q, true, not \"\", false", name))
	}
	joinedBolt.Close()
	cube.Close()
	freshCube, err := blacksmith.Cuboid(1, 1, 1)
	if err != nil {
		fail(err.Error())
	}
	if name, ok := freshCube.Name(); ok {
		fail(fmt.Sprintf("assembly: a fresh cuboid's Name() is %q, true, not \"\", false", name))
	}
	freshCube.Close()
	fmt.Println("assembly: Named/Name ride through one-source operations and drop through two-source ones")
}

func fail(why string) {
	fmt.Fprintln(os.Stderr, why)
	os.Exit(1)
}

// femNone is the ABI's "no such thing" sentinel as the FEM accessors hand it over:
// CADACLYSM_NONE / CADACLYSM_BLACKSMITH_NONE, UINT32_MAX underneath. Neither package
// exports it (its `NONE` is documented absent for Go, missing nodes being nil), so the
// smoke names it here, once, for both halves.
const femNone = ^uint32(0)

// femReader is the FEM surface mesh through the reader binding, on a **mesh-only** body:
// cube.scad carries no brep, so the body falls back to the scene's own mesh -- one face,
// every node on it, no B-rep topology at all, and the scene's convention rather than the
// file's. Every check below says which wrong implementation it catches.
func femReader(node *cadaclysm.Node, path string) {
	mesh, err := node.FemMesh(0.5, 0, nil)
	if err != nil {
		fail("fem: " + err.Error())
	}
	defer mesh.Close()
	nodeCount := len(mesh.Nodes) / 3
	if len(mesh.Nodes)%3 != 0 || len(mesh.Triangles)%3 != 0 || nodeCount == 0 {
		fail(fmt.Sprintf("fem: the node and triangle arrays read %d and %d", len(mesh.Nodes), len(mesh.Triangles)))
	}
	// Catches Triangles lent over the node count (or Nodes over the triangle count): the
	// slices would be the wrong length and the indices would run past the nodes.
	if len(mesh.Triangles) != len(mesh.TriangleFace)*3 {
		fail("fem: TriangleFace is not one per triangle")
	}
	for _, index := range mesh.Triangles {
		if int(index) >= nodeCount {
			fail(fmt.Sprintf("fem: a triangle names node %d of %d", index, nodeCount))
		}
	}
	for _, face := range mesh.TriangleFace {
		if face >= mesh.FaceCount {
			fail(fmt.Sprintf("fem: a triangle lies on face %d of %d", face, mesh.FaceCount))
		}
	}
	// Catches NodeKind and NodeEntity lent from each other's pointer: a kind would then be a
	// face index and an entity a 0/1/2. Bounding each entity by the list its own kind names
	// is what tells the two apart -- the lengths cannot, both being one uint32 a node.
	if len(mesh.NodeKind) != nodeCount || len(mesh.NodeEntity) != nodeCount {
		fail("fem: NodeKind/NodeEntity are not one per node")
	}
	edges, err := mesh.Edges()
	if err != nil {
		fail("fem: " + err.Error())
	}
	vertices, err := mesh.Vertices()
	if err != nil {
		fail("fem: " + err.Error())
	}
	for k := 0; k < nodeCount; k++ {
		kind, entity := mesh.NodeKind[k], mesh.NodeEntity[k]
		var limit uint32
		switch kind {
		case 0:
			limit = uint32(len(vertices))
		case 1:
			limit = uint32(len(edges))
		case 2:
			limit = mesh.FaceCount
		}
		if kind > 2 || entity >= limit {
			fail(fmt.Sprintf("fem: node %d lies on kind %d entity %d, of %d", k, kind, entity, limit))
		}
	}
	if mesh.MinAngle <= 0 || mesh.MinAngle >= 90 || mesh.LongestEdge <= 0 ||
		int(mesh.WorstTriangle) >= len(mesh.Triangles)/3 {
		fail("fem: the quality figures read " + mesh.String())
	}
	open, err := mesh.OpenEdges()
	if err != nil {
		fail("fem: " + err.Error())
	}
	folded, err := mesh.FoldedEdges()
	if err != nil {
		fail("fem: " + err.Error())
	}
	for _, row := range append(append([][3]uint32(nil), open...), folded...) {
		if int(row[0]) >= nodeCount || int(row[1]) >= nodeCount || (row[2] != femNone && int(row[2]) >= len(edges)) {
			fail(fmt.Sprintf("fem: a census row reads %v, past this mesh", row))
		}
	}
	if strings.HasSuffix(path, "cube.scad") {
		// Catches FromMesh read off the neighbouring Watertight field -- which is true for
		// this body too, so only a body where the two differ separates them (femBrep).
		if !mesh.FromMesh || mesh.FaceCount != 1 || len(edges) != 0 || len(vertices) != 0 {
			fail("fem: the cube reads " + mesh.String() + ", not a mesh-only body of one face")
		}
		for _, kind := range mesh.NodeKind {
			if kind != 2 {
				fail("fem: a mesh body's nodes all lie on face 0")
			}
		}
		if !mesh.Watertight || len(open) != 0 || len(folded) != 0 {
			fail(fmt.Sprintf("fem: the closed cube reads %d cracks and %d folds", len(open), len(folded)))
		}
	}
	msh, err := mesh.MshText()
	if err != nil {
		fail("fem: " + err.Error())
	}
	if !strings.HasPrefix(msh, "$MeshFormat") || !strings.Contains(msh, "$Nodes") {
		fail("fem: MshText is not Gmsh 4.1 ASCII")
	}
	// The library's slot is borrowed on this side of the ABI, but C.GoString copies it out on
	// the way through, so a second ask does not free the first answer: both strings are this
	// program's own and both still read.
	again, err := mesh.MshText()
	if err != nil || len(again) != len(msh) {
		fail("fem: a second MshText disagrees with the first")
	}
	mshPath := filepath.Join(os.TempDir(), "cadaclysm-smoke-go.msh")
	if err := mesh.SaveMsh(mshPath); err != nil {
		fail("fem: " + err.Error())
	}
	if info, serr := os.Stat(mshPath); serr != nil || info.Size() < int64(len(msh)/2) {
		fail("fem: SaveMsh wrote less than MshText")
	}
	// The placement is carried through rather than dropped. **Go cannot make the mistake the
	// other wrappers guard against**: the reader's placement is a *[16]float64 and the
	// kernel's a *blacksmith.Frame ([12]float64), so handing one ABI the other's count does
	// not compile, where C#, Java and Python can only refuse it at run time. So this checks
	// the half a fixed-size type cannot: that the pointer reaches the library at all. A
	// column-major translation puts the origin in the last column.
	moved := [16]float64{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 100, 0, 0, 1}
	placed, err := node.FemMesh(0.5, 0, &moved)
	if err != nil {
		fail("fem placed: " + err.Error())
	}
	defer placed.Close()
	if len(placed.Nodes) != len(mesh.Nodes) {
		fail("fem: a placement changed the node count")
	}
	for i := 0; i < len(mesh.Nodes); i += 3 {
		if math.Abs(placed.Nodes[i]-(mesh.Nodes[i]+100)) > 1e-9 ||
			placed.Nodes[i+1] != mesh.Nodes[i+1] || placed.Nodes[i+2] != mesh.Nodes[i+2] {
			fail("fem: the placement did not move the nodes 100 along x")
		}
	}
	// **Neither tolerance nor maxSize is validated by this wrapper.** fem_mesh_of_mesh takes
	// no options at all, so on the mesh-only path the library reads neither field: all six
	// of these return a mesh. A wrapper that checked either itself would refuse six calls
	// the ABI accepts, and would pass every test shaped like Python's. (A B-rep body *does*
	// read the tolerance and refuses it; femBrep checks that half.)
	for _, o := range [][2]float64{
		{0, 0}, {-1, 0}, {math.NaN(), 0}, {0.5, -1}, {0.5, math.NaN()}, {0.5, math.Inf(1)},
	} {
		any, err := node.FemMesh(o[0], o[1], nil)
		if err != nil {
			fail(fmt.Sprintf("fem: tolerance %g maxSize %g was refused by the wrapper: %s", o[0], o[1], err))
		}
		if len(any.Nodes) != len(mesh.Nodes) {
			fail(fmt.Sprintf("fem: tolerance %g maxSize %g meshed %d nodes, not %d", o[0], o[1], len(any.Nodes)/3, nodeCount))
		}
		any.Close()
	}
	// A closed handle refuses every call that hands it to the library, and says so in this
	// package's own words. **The struct fields cannot refuse**: mesh.Nodes after a Close is
	// a slice over freed memory, and Go has no way to mark it so -- exactly what the package
	// doc says of the scene's own views, and why the doc comment says to hold the FemMesh.
	// Nothing below reads a field of `spent` for that reason.
	spent, err := node.FemMesh(0.5, 0, nil)
	if err != nil {
		fail("fem: " + err.Error())
	}
	spent.Close()
	if !spent.Closed() {
		fail("fem: a closed mesh does not say so")
	}
	spent.Close() // idempotent
	reads := []func() error{
		func() error { _, e := spent.Edges(); return e },
		func() error { _, e := spent.Vertices(); return e },
		func() error { _, e := spent.OpenEdges(); return e },
		func() error { _, e := spent.FoldedEdges(); return e },
		func() error { _, e := spent.MshText(); return e },
		func() error { return spent.SaveMsh(mshPath) },
	}
	if len(reads) != 6 {
		fail("fem: the closed-handle sweep is not all six calls that take the handle")
	}
	for i, read := range reads {
		err := read()
		if err == nil || !strings.Contains(err.Error(), "freed") {
			fail(fmt.Sprintf("fem: closed read %d answered anyway (%v)", i, err))
		}
		if _, ok := err.(*cadaclysm.CadaclysmError); !ok {
			fail(fmt.Sprintf("fem: closed read %d refused with %T, not a *CadaclysmError", i, err))
		}
	}
	fmt.Printf("fem (reader): %v, minAngle %.2f, longestEdge %.3f; a closed mesh refuses all six calls\n",
		mesh, mesh.MinAngle, mesh.LongestEdge)
	if strings.HasSuffix(path, "cube.scad") {
		femCensusWiring(filepath.Join(filepath.Dir(path), "open-sheet.scad"))
	}
}

// femCensusWiring pins **which count feeds which entry point**, which nothing else here does.
// Every other FEM check proves a row is extracted correctly; none proves OpenEdges reads
// open_edge_count rows through cadaclysm_fem_mesh_open_edge rather than the folded count or the
// folded call. samples/open-sheet.scad is the only body in this repository where both censuses
// are non-empty and of different lengths: the B-rep path computes no census unless the topology
// is closed (the documented "not asked" pair) and every closed body has none, while the mesh path
// always computes one -- so a polyhedron with a flap over one of its own directed edges is the way
// in. Six cracks, one fold, and the fold is not the first crack.
func femCensusWiring(sheet string) {
	scene, err := cadaclysm.Open(sheet)
	if err != nil {
		fail("fem census: " + err.Error())
	}
	defer scene.Close()
	var body *cadaclysm.Node
	for _, n := range scene.Walk() {
		if n.CanMesh() {
			body = n
			break
		}
	}
	if body == nil {
		fail("fem census: open-sheet.scad has no meshable node")
	}
	mesh, err := body.FemMesh(0.01, 0, nil)
	if err != nil {
		fail("fem census: " + err.Error())
	}
	defer mesh.Close()
	if len(mesh.Nodes) != 15 || len(mesh.Triangles) != 9 || !mesh.FromMesh || mesh.Watertight {
		fail(fmt.Sprintf("fem census: open-sheet.scad reads %v, not five open, folded, mesh-only nodes", mesh))
	}
	cracks, err := mesh.OpenEdges()
	if err != nil {
		fail("fem census: open edges: " + err.Error())
	}
	folds, err := mesh.FoldedEdges()
	if err != nil {
		fail("fem census: folded edges: " + err.Error())
	}
	// The counts are what separate the two lists: a swapped count reads 1 where 6 belongs, and a
	// swapped call cannot read row 1 of a one-row table at all.
	if len(cracks) != 6 || len(folds) != 1 {
		fail(fmt.Sprintf("fem census: %d cracks and %d folds, not 6 and 1", len(cracks), len(folds)))
	}
	// And the contents, which separates a wrapper that swapped both consistently.
	if folds[0] != [3]uint32{2, 0, femNone} {
		fail(fmt.Sprintf("fem census: the fold reads %v, not [2 0 NONE]", folds[0]))
	}
	if cracks[0][0] != 1 || cracks[0][1] != 2 {
		fail(fmt.Sprintf("fem census: the first crack reads %v, not [1 2 NONE]", cracks[0]))
	}
	fmt.Printf("fem census: open-sheet.scad reads %d cracks and %d fold at (%d,%d)\n",
		len(cracks), len(folds), folds[0][0], folds[0][1])
}

// femBrep is the reader's other half: a **B-rep** body, read back from the STEP this run
// wrote, carrying the topology the mesh-only body has none of -- edges with the body's own
// ids, vertices, and nodes on all three kinds of entity.
func femBrep(step string, faces int) {
	scene, err := cadaclysm.Open(step)
	if err != nil {
		fail("fem brep: " + err.Error())
	}
	defer scene.Close()
	var body *cadaclysm.Node
	for _, n := range scene.Walk() {
		if n.CanMesh() {
			body = n
			break
		}
	}
	if body == nil {
		fail("fem brep: the read-back STEP has nothing to mesh")
	}
	mesh, err := body.FemMesh(0.5, 0, nil)
	if err != nil {
		fail("fem brep: " + err.Error())
	}
	defer mesh.Close()
	// The other half of the FromMesh proof: false here where it was true for the cube, the
	// neighbouring Watertight being true for both bodies.
	if mesh.FromMesh || !mesh.Watertight || int(mesh.FaceCount) != faces {
		fail(fmt.Sprintf("fem: the read plate reads %v, not a closed B-rep of %d faces", mesh, faces))
	}
	edges, err := mesh.Edges()
	if err != nil {
		fail("fem brep: " + err.Error())
	}
	vertices, err := mesh.Vertices()
	if err != nil {
		fail("fem brep: " + err.Error())
	}
	if len(edges) == 0 || len(vertices) == 0 {
		fail("fem: a B-rep body carries edges and vertices")
	}
	kinds := map[uint32]bool{}
	for _, kind := range mesh.NodeKind {
		kinds[kind] = true
	}
	if len(kinds) != 3 || !kinds[0] || !kinds[1] || !kinds[2] {
		fail(fmt.Sprintf("fem: the plate's nodes lie on kinds %v, not 0, 1 and 2", kinds))
	}
	// ID is the body's own B-rep edge id, not this list's index: the list is a densely
	// renumbered subset ascending by id. Catches an ID filled from the loop counter -- which
	// a body whose ids happened to run 0, 1, 2 would hide, so both halves are checked.
	offIndex := false
	for i, e := range edges {
		if i > 0 && e.ID < edges[i-1].ID {
			fail(fmt.Sprintf("fem: the edge ids do not ascend at %d (%d after %d)", i, e.ID, edges[i-1].ID))
		}
		if int(e.ID) != i {
			offIndex = true
		}
	}
	if !offIndex {
		fail("fem: every edge id equals its own index -- ID is the index, not the body's id")
	}
	for _, e := range edges {
		if len(e.Runs) == 0 || e.Runs[0] != 0 || int(e.Runs[len(e.Runs)-1]) >= len(e.Nodes) {
			fail(fmt.Sprintf("fem: %v's runs do not start at 0 inside its chain", e))
		}
		for _, n := range e.Nodes {
			if int(n) >= len(mesh.Nodes)/3 {
				fail(fmt.Sprintf("fem: %v names a node past the mesh", e))
			}
		}
		// A closed body has no rim, so every edge has two real faces and neither is the
		// sentinel. (The open sheet in femKernel is where the sentinel shows.)
		if e.Faces[0] >= mesh.FaceCount || e.Faces[1] >= mesh.FaceCount {
			fail(fmt.Sprintf("fem: %v on a closed body bounds faces %d and %d of %d", e, e.Faces[0], e.Faces[1], mesh.FaceCount))
		}
		if e.Closed && len(e.Runs) > 1 {
			fail(fmt.Sprintf("fem: %v is one loop with a broken chain", e))
		}
		if e.Seam && e.Faces[0] != e.Faces[1] {
			fail(fmt.Sprintf("fem: %v is a seam whose two faces differ", e))
		}
		// The chain includes its end vertices, so the two ends name the nodes the chain
		// begins and finishes at -- which is what tells Ends from Faces, both being a pair
		// of uint32 that a swap would leave in range on a body of this shape.
		ends := map[uint32]bool{}
		for _, v := range e.Ends {
			if v != femNone {
				ends[vertices[v].Node] = true
			}
		}
		want := map[uint32]bool{e.Nodes[0]: true, e.Nodes[len(e.Nodes)-1]: true}
		if len(ends) != len(want) {
			fail(fmt.Sprintf("fem: %v ends at %v, not at its own chain's %v", e, ends, want))
		}
		for n := range want {
			if !ends[n] {
				fail(fmt.Sprintf("fem: %v does not end at its own vertices (%v vs %v)", e, ends, want))
			}
		}
	}
	positioned := false
	for _, v := range vertices {
		if v.HasPosition {
			positioned = true
		}
		if v.Node != femNone && int(v.Node) >= len(mesh.Nodes)/3 {
			fail(fmt.Sprintf("fem: %v is not a node of this mesh", v))
		}
	}
	if !positioned {
		fail("fem: no vertex of the plate has a position")
	}
	// A B-rep body *does* have geometry for a chordal tolerance to follow, so here the
	// tolerance is read and refused -- in the library's own words, which is what proves the
	// wrapper surfaces cadaclysm_last_error rather than a message of its own.
	if _, err := body.FemMesh(0, 0, nil); err == nil {
		fail("fem: a zero tolerance was accepted on a B-rep body")
	} else if !strings.Contains(err.Error(), "tolerance must be finite and > 0") {
		fail("fem: a zero tolerance was refused in the wrapper's words, not the library's: " + err.Error())
	}
	fmt.Printf("fem (read brep): %v, %d edges, %d vertices, edge 0 %v\n", mesh, len(edges), len(vertices), edges[0])
}

// femKernel is the kernel's own FEM mesh: the same solid through
// cadaclysm_blacksmith_fem_mesh, whose placement is twelve numbers and whose .msh text is
// owned rather than borrowed. sheet is an open one-faced body, the only shape here that
// shows the face sentinel and the "not asked" census trio.
func femKernel(rounded, sheet *blacksmith.Solid, faces int) {
	mesh, err := rounded.FemMesh(0.5, 0, nil)
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	defer mesh.Close()
	if mesh.FromMesh || !mesh.Watertight || int(mesh.FaceCount) != faces || len(mesh.Nodes) == 0 {
		fail("kernel fem: the filleted part reads " + mesh.String())
	}
	open, err := mesh.OpenEdges()
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	folded, err := mesh.FoldedEdges()
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	if len(open) != 0 || len(folded) != 0 {
		fail(fmt.Sprintf("kernel fem: a watertight solid reads %d cracks and %d folds", len(open), len(folded)))
	}
	// maxSize bounds the boundary segments and only *targets* the interior, so the figure a
	// solver caller checks is LongestEdge, not the ceiling it asked for. Catches a wrapper
	// that dropped maxSize on the floor: the mesh would not refine at all.
	fine, err := rounded.FemMesh(0.5, 3.0, nil)
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	defer fine.Close()
	// 1.05 and not 3.0 exactly: the ceiling is not a guarantee (1.03 x was measured on a
	// face whose parameters run unevenly), so a tighter pin here would assert something the
	// ABI deliberately does not promise.
	if fine.LongestEdge > 3.0*1.05 {
		fail(fmt.Sprintf("kernel fem: maxSize 3 came to longestEdge %g", fine.LongestEdge))
	}
	if len(fine.Nodes) <= len(mesh.Nodes) || fine.LongestEdge >= mesh.LongestEdge {
		fail(fmt.Sprintf("kernel fem: maxSize 3 gave %d nodes and longestEdge %g, no finer than %d/%g",
			len(fine.Nodes)/3, fine.LongestEdge, len(mesh.Nodes)/3, mesh.LongestEdge))
	}
	sheetMesh, err := sheet.FemMesh(0.5, 0, nil)
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	defer sheetMesh.Close()
	sheetOpen, err := sheetMesh.OpenEdges()
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	sheetFolded, err := sheetMesh.FoldedEdges()
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	// Watertight false with *both* censuses empty is "not asked", not "nothing found": a
	// sheet makes no claim to enclose anything. A caller reading only OpenEdges cannot tell
	// this from a sound body, which is why FoldedEdges is checked beside it.
	if sheetMesh.Watertight || len(sheetOpen) != 0 || len(sheetFolded) != 0 {
		fail("kernel fem: the sheet reads " + sheetMesh.String() + " rather than open with an unasked census")
	}
	// Catches face_b filled with 0 instead of the NONE sentinel: every rim edge of a
	// one-faced sheet bounds face 0 and nothing else, so a 0 there reads as a real second
	// face -- a coherent wrong answer no count or length can catch.
	rim, err := sheetMesh.Edges()
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	if sheetMesh.FaceCount != 1 || len(rim) == 0 {
		fail("kernel fem: the sheet reads " + sheetMesh.String() + ", not one face with a rim")
	}
	for _, e := range rim {
		if e.Faces[0] != 0 || e.Faces[1] != femNone {
			fail(fmt.Sprintf("kernel fem: the sheet's rim edge reads faces %d/%d", e.Faces[0], e.Faces[1]))
		}
	}
	kernelMsh, err := mesh.MshText()
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	if !strings.HasPrefix(kernelMsh, "$MeshFormat") {
		fail("kernel fem: MshText is not Gmsh 4.1 ASCII")
	}
	// Owned on this side, not borrowed: two asks give two independent texts, each released
	// by the wrapper with cadaclysm_blacksmith_string_free, and neither dies with the other
	// or with the handle.
	againMsh, err := mesh.MshText()
	if err != nil || len(againMsh) != len(kernelMsh) {
		fail("kernel fem: a second MshText disagrees with the first")
	}
	kernelMshPath := filepath.Join(os.TempDir(), "cadaclysm-smoke-go-kernel.msh")
	if err := mesh.SaveMsh(kernelMshPath); err != nil {
		fail("kernel fem: " + err.Error())
	}
	if info, serr := os.Stat(kernelMshPath); serr != nil || info.Size() < int64(len(kernelMsh)/2) {
		fail("kernel fem: SaveMsh wrote less than MshText")
	}
	// The kernel's placement is **twelve** numbers -- a blacksmith.Frame, origin then x, y,
	// z -- where the reader's is sixteen column-major. A Frame is a fixed-size type, so the
	// reader's sixteen cannot be passed here at all; what is checked instead is that the
	// frame reaches the library, its origin moving the whole mesh.
	moved := blacksmith.Frame{100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	placed, err := rounded.FemMesh(0.5, 0, &moved)
	if err != nil {
		fail("kernel fem placed: " + err.Error())
	}
	defer placed.Close()
	if len(placed.Nodes) != len(mesh.Nodes) {
		fail("kernel fem: a placement changed the node count")
	}
	for i := 0; i < len(mesh.Nodes); i += 3 {
		if math.Abs(placed.Nodes[i]-(mesh.Nodes[i]+100)) > 1e-9 ||
			placed.Nodes[i+1] != mesh.Nodes[i+1] || placed.Nodes[i+2] != mesh.Nodes[i+2] {
			fail("kernel fem: the frame did not move the nodes 100 along x")
		}
	}
	// Every solid has a B-rep behind it here, so the tolerance is always read: refused, in
	// the library's own words. Nothing in this wrapper validates it.
	if _, err := rounded.FemMesh(0, 0, nil); err == nil {
		fail("kernel fem: a zero tolerance was accepted")
	} else if !strings.Contains(err.Error(), "tolerance") {
		fail("kernel fem: a zero tolerance was refused without naming the tolerance: " + err.Error())
	}
	// A closed handle refuses every call that hands it to the library, wrapping ErrClosed as
	// every other closed kernel object does. The struct fields cannot refuse -- see
	// femReader, and the package doc.
	spent, err := rounded.FemMesh(0.5, 0, nil)
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	spent.Close()
	if !spent.Closed() {
		fail("kernel fem: a closed mesh does not say so")
	}
	spent.Close() // idempotent
	reads := []func() error{
		func() error { _, e := spent.Edges(); return e },
		func() error { _, e := spent.Vertices(); return e },
		func() error { _, e := spent.OpenEdges(); return e },
		func() error { _, e := spent.FoldedEdges(); return e },
		func() error { _, e := spent.MshText(); return e },
		func() error { return spent.SaveMsh(kernelMshPath) },
	}
	if len(reads) != 6 {
		fail("kernel fem: the closed-handle sweep is not all six calls that take the handle")
	}
	for i, read := range reads {
		if err := read(); !errors.Is(err, blacksmith.ErrClosed) {
			fail(fmt.Sprintf("kernel fem: closed read %d refused with %v, not ErrClosed", i, err))
		}
	}
	fmt.Printf("kernel fem: %v, maxSize 3 -> %d nodes, longestEdge %.3f; the sheet's rim reads 0/NONE; a closed mesh refuses all six calls\n",
		mesh, len(fine.Nodes)/3, fine.LongestEdge)
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
