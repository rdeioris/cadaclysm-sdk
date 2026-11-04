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
	"reflect"
	"runtime"
	"slices"
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
	if filepath.Base(path) == "cube.scad" && (len(scene.Links()) != 0 || len(scene.Joints()) != 0 || len(scene.States()) != 0) {
		fail("the cube scene has links, joints or states")
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

	// The pair facts: mechanism.stp's hinge is a revolute pair, both contact frames at
	// (0, 0, 100) with z axis (0, 0, 1), one freedom (rotation about z, ranged
	// [-1.5, 1.5]), and one state "open" setting the hinge to [0.5].
	pair := joint.Pair()
	if pair == nil {
		fail("joint hinge has no pair")
	}
	if pair.Kind != cadaclysm.PairRevolute || pair.HasTypeName || pair.HasPitch {
		fail("joint hinge's pair is not a bare revolute (kind, type name or pitch wrong)")
	}
	for _, frame := range [][16]float64{pair.FrameStart(), pair.FrameEnd()} {
		origin := [3]float64{frame[3], frame[7], frame[11]}
		zAxis := [3]float64{frame[2], frame[6], frame[10]}
		if math.Abs(origin[0]-0) > 1e-9 || math.Abs(origin[1]-0) > 1e-9 || math.Abs(origin[2]-100) > 1e-9 ||
			math.Abs(zAxis[0]-0) > 1e-9 || math.Abs(zAxis[1]-0) > 1e-9 || math.Abs(zAxis[2]-1) > 1e-9 {
			fail("a hinge contact frame is not origin (0,0,100) with z axis (0,0,1)")
		}
	}
	freedoms := pair.Freedoms()
	if len(freedoms) != 1 || freedoms[0].Motion != cadaclysm.MotionRotation || freedoms[0].Axis != cadaclysm.FreedomZ ||
		!freedoms[0].HasLower || !freedoms[0].HasUpper ||
		math.Abs(freedoms[0].Lower-(-1.5)) > 1e-9 || math.Abs(freedoms[0].Upper-1.5) > 1e-9 {
		fail("the hinge's freedom is not one rotation about z ranged [-1.5, 1.5]")
	}
	states := mechanism.States()
	if len(states) != 1 || states[0].Name != "open" || len(states[0].Values) != 1 ||
		states[0].Values[0].Joint.Index() != 0 || len(states[0].Values[0].Values) != 1 ||
		math.Abs(states[0].Values[0].Values[0]-0.5) > 1e-9 {
		fail("mechanism does not carry exactly one state 'open' setting hinge to [0.5]")
	}
	fmt.Printf("pair: %v, freedoms %d, states %d\n", pair.Kind, len(freedoms), len(states))

	// Posing: Scene.Base/Pose/PoseState and Pose, at parity with the Python reference's
	// six pose facts (mechanism.stp declares no base; base=links[0], arm=links[1]).
	baseLink, armLink := links[0], links[1]
	armNode := armLink.Nodes()[0]
	baseNode := baseLink.Nodes()[0]
	apply := func(m [16]float64, x, y, z float64) (float64, float64, float64) {
		return m[0]*x + m[4]*y + m[8]*z + m[12],
			m[1]*x + m[5]*y + m[9]*z + m[13],
			m[2]*x + m[6]*y + m[10]*z + m[14]
	}
	close3 := func(a, b float64) bool { return math.Abs(a-b) <= 1e-9 }
	if mechanism.Base() != nil {
		fail("mechanism.stp declares a base but declares none")
	}
	posedState, perr := mechanism.PoseState(states[0], nil)
	if perr != nil {
		fail(perr.Error())
	}
	if posedState.Ground.Index() != baseLink.Index() {
		fail("pose_state's ground is not the base link")
	}
	if len(posedState.Unsolved) != 0 || len(posedState.OutOfRange) != 0 {
		fail("pose_state reports unsolved or out-of-range joints")
	}
	const q = 0.5 // the arm is the joint's start, reached from its end: it turns by -q
	tipX, tipY, tipZ := apply(posedState.RawTransform(armNode), 10, 0, 0)
	if !close3(tipX, 10*math.Cos(q)) || !close3(tipY, -10*math.Sin(q)) || !close3(tipZ, 100) {
		fail("pose_state does not turn the arm by -0.5")
	}
	originX, originY, originZ := apply(posedState.RawTransform(armNode), 0, 0, 0)
	if !close3(originX, 0) || !close3(originY, 0) || !close3(originZ, 100) {
		fail("pose_state's arm origin is not (0, 0, 100)")
	}
	if posedState.RawTransform(baseNode) != baseNode.RawTransform() {
		fail("pose_state moves the ground link's own node")
	}

	pastRange, perr2 := mechanism.Pose([]cadaclysm.StateValue{{Joint: joint, Values: []float64{2.0}}}, nil)
	if perr2 != nil {
		fail(perr2.Error())
	}
	if len(pastRange.OutOfRange) != 1 || pastRange.OutOfRange[0].Joint.Index() != joint.Index() ||
		pastRange.OutOfRange[0].Freedom != 0 || !close3(pastRange.OutOfRange[0].Value, 2.0) {
		fail("pose does not report the out-of-range value")
	}
	pastTipX, pastTipY, pastTipZ := apply(pastRange.RawTransform(armNode), 10, 0, 0)
	if !close3(pastTipX, 10*math.Cos(2.0)) || !close3(pastTipY, -10*math.Sin(2.0)) || !close3(pastTipZ, 100) {
		fail("pose does not use the out-of-range value")
	}

	groundedOnArm, perr3 := mechanism.Pose([]cadaclysm.StateValue{{Joint: joint, Values: []float64{0.5}}}, armLink)
	if perr3 != nil {
		fail(perr3.Error())
	}
	if groundedOnArm.Ground.Index() != armLink.Index() {
		fail("pose does not hold the named ground")
	}
	if groundedOnArm.RawTransform(armNode) != armNode.RawTransform() {
		fail("pose does not leave the named ground at its rest transform")
	}

	fromStateValues, perr4 := mechanism.Pose(states[0].Values, nil)
	if perr4 != nil {
		fail(perr4.Error())
	}
	if fromStateValues.RawTransform(armNode) != posedState.RawTransform(armNode) {
		fail("pose(state.Values) does not match pose_state(state)")
	}
	rest, perr5 := mechanism.Pose(nil, nil)
	if perr5 != nil {
		fail(perr5.Error())
	}
	for _, node := range mechanism.Walk() {
		if rest.RawTransform(node) != node.RawTransform() {
			fail("pose([]) does not leave every node at its rest transform")
		}
	}

	if _, err := mechanism.Pose([]cadaclysm.StateValue{{Joint: joint, Values: []float64{1.0, 2.0}}}, nil); err == nil ||
		!strings.Contains(err.Error(), "takes 1 value(s)") {
		fail("a joint given the wrong number of values was not refused right")
	}
	fmt.Printf("pose: base=%v, ground=%s, out-of-range %d\n", mechanism.Base(), posedState.Ground.Name(), len(pastRange.OutOfRange))
	mechanism.Close()

	// Motion sequences: samples/mechanism-sequence.stp's two sequences, at parity with the
	// Python reference (plan 2026-10-05-motion-sequences-2).
	sequenceScene, sqerr := cadaclysm.Open(filepath.Join(filepath.Dir(absPath), "mechanism-sequence.stp"))
	if sqerr != nil {
		fail(sqerr.Error())
	}
	sequences := sequenceScene.Sequences()
	if len(sequences) != 2 || sequences[0].Name != "swing" || sequences[1].Name != "snap" {
		fail("sequences: the file does not carry swing then snap")
	}
	swing, snap := sequences[0], sequences[1]
	if !swing.Closed || swing.SecondsPerUnit == nil || *swing.SecondsPerUnit != 1.0 {
		fail("sequences: swing is not closed at 1 second per unit")
	}
	if snap.Closed || snap.SecondsPerUnit != nil {
		fail("sequences: snap is not open with no unit")
	}
	type seg struct {
		State, Interpolation string
		T                    float64
	}
	segsOf := func(s cadaclysm.Sequence) []seg {
		out := []seg{}
		for _, g := range s.Segments {
			out = append(out, seg{g.State.Name, g.Interpolation, g.T})
		}
		return out
	}
	if got, want := segsOf(swing), []seg{{"shut", "linear", 0}, {"open", "synchronous", 1}, {"wide", "linear", 2}}; !slices.Equal(got, want) {
		fail(fmt.Sprintf("sequences: swing's segments are %v", got))
	}
	if got, want := segsOf(snap), []seg{{"shut", "discontinuous", 0}, {"wide", "discontinuous", 0.5}}; !slices.Equal(got, want) {
		fail(fmt.Sprintf("sequences: snap's segments are %v", got))
	}
	if swing.Start() != 0 || swing.End() != 2 {
		fail("sequences: swing does not run 0 to 2")
	}
	for _, g := range swing.Segments {
		at, aterr := swing.Pose(g.T, nil)
		if aterr != nil {
			fail(aterr.Error())
		}
		want, werr := sequenceScene.PoseState(g.State, nil)
		if werr != nil {
			fail(werr.Error())
		}
		for _, node := range sequenceScene.Walk() {
			if at.RawTransform(node) != want.RawTransform(node) {
				fail(fmt.Sprintf("sequences: swing at %v does not match state %s", g.T, g.State.Name))
			}
		}
	}
	if _, nanerr := swing.Pose(math.NaN(), nil); nanerr == nil || !strings.Contains(nanerr.Error(), "the sequence parameter must be a finite number") {
		fail("sequences: pose(NaN) was not refused right")
	}
	sequenceScene.Close()
	fmt.Println("sequences: swing and snap read as the file records them, and swing poses at each keyframe")

	// IFC work schedules: samples/schedule.ifc, at parity with the Python reference
	// (plan 2026-10-06-ifc-4d-2). day is a day in seconds and t0 is 2026-03-02T08:00:00.
	const day = 86400.0
	const t0 = 1772438400.0
	scheduleScene, shErr := cadaclysm.Open(filepath.Join(filepath.Dir(absPath), "schedule.ifc"))
	if shErr != nil {
		fail(shErr.Error())
	}
	schedules := scheduleScene.Schedules()
	if len(schedules) != 1 {
		fail("schedules: the file does not carry exactly one schedule")
	}
	programme := schedules[0]
	if programme.Name != "Programme" || programme.Identification != "WS-1" || programme.Kind != "planned" || programme.KindName != "" ||
		programme.Start == nil || *programme.Start != t0 || programme.Finish != nil {
		fail("schedules: Programme is not planned WS-1 from T0 with no finish")
	}
	tasks := programme.Tasks()
	taskNames := []string{}
	byName := map[string]cadaclysm.Task{}
	for _, task := range tasks {
		taskNames = append(taskNames, task.Name)
		byName[task.Name] = task
	}
	if !slices.Equal(taskNames, []string{"Slab", "Structure", "Walls north", "Walls south", "Topping out", "Demolish shed", "Fit-out"}) {
		fail(fmt.Sprintf("schedules: the tasks are %v", taskNames))
	}
	if byName["Walls north"].Parent == nil || byName["Walls north"].Parent.Name != "Structure" ||
		byName["Walls south"].Parent == nil || byName["Walls south"].Parent.Name != "Structure" || byName["Slab"].Parent != nil {
		fail("schedules: the task parents are not Structure, Structure, none")
	}
	if byName["Slab"].Kind != "construction" || byName["Demolish shed"].Kind != "demolition" || byName["Topping out"].Kind != "notdefined" ||
		!byName["Topping out"].Milestone || byName["Slab"].Milestone {
		fail("schedules: the task kinds or milestones are off")
	}
	slab := byName["Slab"]
	if slab.Identification != "T1" || slab.Status != "COMPLETED" {
		fail("schedules: Slab is not T1, COMPLETED")
	}
	f64 := func(p *float64) string {
		if p == nil {
			return "none"
		}
		return fmt.Sprint(*p)
	}
	gotTimes := strings.Join([]string{f64(slab.Time.ScheduleStart), f64(slab.Time.ScheduleFinish), f64(slab.Time.Duration),
		f64(slab.Time.ActualStart), f64(slab.Time.ActualFinish)}, ",")
	wantTimes := strings.Join([]string{fmt.Sprint(t0), "none", fmt.Sprint(10 * day), fmt.Sprint(t0), fmt.Sprint(t0 + 8*day)}, ",")
	if gotTimes != wantTimes {
		fail("schedules: Slab's times are " + gotTimes)
	}
	if slab.Time.EarlyStart != nil || slab.Time.EarlyFinish != nil || slab.Time.LateStart != nil || slab.Time.LateFinish != nil {
		fail("schedules: Slab has early or late times")
	}
	nodeNames := func(nodes []*cadaclysm.Node) []string {
		out := []string{}
		for _, n := range nodes {
			out = append(out, n.Name())
		}
		sort.Strings(out)
		return out
	}
	if !slices.Equal(nodeNames(byName["Walls south"].Nodes()), []string{"Wall S1", "Wall S2"}) ||
		!slices.Equal(nodeNames(byName["Fit-out"].Nodes()), []string{"Desk", "Room"}) {
		fail("schedules: the task nodes are off")
	}
	type linkRow struct {
		from, to, kind, lag string
	}
	gotLinks := []linkRow{}
	for _, l := range programme.Links() {
		gotLinks = append(gotLinks, linkRow{l.From.Name, l.To.Name, l.Kind, f64(l.Lag)})
	}
	wantLinks := []linkRow{
		{"Slab", "Structure", "finish_start", "none"},
		{"Walls north", "Walls south", "start_start", fmt.Sprint(2 * day)},
		{"Walls south", "Topping out", "finish_start", "none"},
		{"Topping out", "Fit-out", "finish_start", "none"},
	}
	if !slices.Equal(gotLinks, wantLinks) {
		fail(fmt.Sprintf("schedules: the links are %v", gotLinks))
	}
	atStates := func(date float64, dates string) map[string]cadaclysm.ElementState {
		rows, aerr := programme.At(date, dates)
		if aerr != nil {
			fail("schedules: at: " + aerr.Error())
		}
		out := map[string]cadaclysm.ElementState{}
		for _, r := range rows {
			out[r.Node.Name()] = r
		}
		return out
	}
	early := atStates(t0+3*day, "scheduled")
	earlyNames := []string{}
	for name := range early {
		earlyNames = append(earlyNames, name)
	}
	sort.Strings(earlyNames)
	wantNames := []string{"Slab", "Wall N1", "Wall N2", "Wall S1", "Wall S2", "Shed", "Room", "Desk"}
	sort.Strings(wantNames)
	if !slices.Equal(earlyNames, wantNames) {
		fail(fmt.Sprintf("schedules: at(T0+3D) names %v", earlyNames))
	}
	if early["Slab"].Phase != "building" || math.Abs(early["Slab"].Progress-0.3) > 1e-9 ||
		early["Shed"].Phase != "demolishing" || early["Wall S1"].Phase != "unbuilt" {
		fail("schedules: at(T0+3D) phases are off")
	}
	late := atStates(t0+32*day, "actual")
	if late["Wall S1"].Phase != "building" || late["Wall S1"].Variance == nil || *late["Wall S1"].Variance != 5*day ||
		late["Slab"].Variance == nil || *late["Slab"].Variance != -2*day {
		fail("schedules: at(T0+32D, actual) variances are off")
	}
	if _, nanErr := programme.At(math.NaN(), "scheduled"); nanErr == nil || nanErr.Error() != "the date must be a finite number" {
		fail(fmt.Sprintf("schedules: at(NaN) was not refused right: %v", nanErr))
	}
	if _, badErr := programme.At(t0, "compare"); badErr == nil || badErr.Error() != "dates must be 'scheduled' or 'actual'" {
		fail(fmt.Sprintf("schedules: at(T0, compare) was not refused right: %v", badErr))
	}
	scheduleScene.Close()
	noSchedule, nsErr := cadaclysm.Open(filepath.Join(filepath.Dir(absPath), "cube.scad"))
	if nsErr != nil {
		fail(nsErr.Error())
	}
	if len(noSchedule.Schedules()) != 0 {
		fail("schedules: the cube has schedules")
	}
	noSchedule.Close()
	fmt.Println("schedules: Programme reads as the file records it, plays at both dates and refuses what it should")

	// pose([]) on the cube sample (no mechanism) fails with a message naming that, as the
	// Python reference's test_a_bad_pose_raises checks on the same file.
	cubePath := filepath.Join(filepath.Dir(absPath), "cube.scad")
	cubeScene, cerr := cadaclysm.Open(cubePath)
	if cerr != nil {
		fail(cerr.Error())
	}
	if _, err := cubeScene.Pose(nil, nil); err == nil || !strings.Contains(err.Error(), "no mechanism") {
		fail("pose([]) on a file without a mechanism was not refused right")
	}
	cubeScene.Close()

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
	if mesh64 == nil {
		fail("mesh64 is nil for a meshable node")
	}
	positions64, p64err := mesh64.Positions()
	indices64, i64err := mesh64.Indices()
	if p64err != nil || i64err != nil {
		fail("mesh64's arrays refused before any forget")
	}
	if mesh64.TriangleCount() != full.TriangleCount() || len(positions64) != len(full.Positions) ||
		len(indices64) != len(full.Indices) {
		fail("mesh64's vertex/index counts do not equal mesh's")
	}
	if len(full.Positions) >= 3 &&
		(float32(positions64[0]) != full.Positions[0] ||
			float32(positions64[1]) != full.Positions[1] ||
			float32(positions64[2]) != full.Positions[2]) {
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
	// ForgetMeshes frees the document's own mesh, which Mesh64 lends, so a Mesh64 made before
	// the forget answers ErrStaleView rather than a slice over freed memory. The float mesh
	// and the edge views are the scene's own caches and survive it, as the C ABI says they
	// do -- they must not be reported stale, nor must the node.
	{
		lent, _ := first.Mesh64()
		keptMesh, _ := first.Mesh()
		keptEdges := first.Edges()
		lentTriangles := lent.TriangleCount()
		early, err := lent.Copy()
		if err != nil {
			fail("a Mesh64 copy refused before any forget: " + err.Error())
		}
		scene.ForgetMeshes()
		if _, err := lent.Positions(); !errors.Is(err, cadaclysm.ErrStaleView) || !strings.Contains(err.Error(), "forgotten") {
			fail(fmt.Sprintf("a Mesh64 read after ForgetMeshes did not answer ErrStaleView: %v", err))
		}
		if _, err := lent.Copy(); !errors.Is(err, cadaclysm.ErrStaleView) {
			fail(fmt.Sprintf("a Mesh64 copied after ForgetMeshes did not answer ErrStaleView: %v", err))
		}
		if len(keptMesh.Positions) == 0 || len(keptEdges.Positions) == 0 || !first.CanMesh() {
			fail("ForgetMeshes staled the float mesh, an edge view or the node")
		}
		relent, _ := first.Mesh64()
		again, err := relent.Positions()
		if err != nil || relent.TriangleCount() != lentTriangles || len(again) != len(early.Positions) {
			fail("a Mesh64 asked for after ForgetMeshes does not read")
		}
		for i := range again {
			if again[i] != early.Positions[i] {
				fail("a Mesh64 asked for after ForgetMeshes reads other positions")
			}
		}
	}
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

	// CSS colour names in SvgOptions: a stroke of "red" packs to #ff0000, the same as the
	// hex form; a bogus name is refused.
	namedStroke := cadaclysm.NewSvgOptions()
	namedStroke.Stroke = "red"
	namedStrokeText, serr := scene.SvgText(&namedStroke)
	if serr != nil {
		fail(serr.Error())
	}
	if !strings.Contains(namedStrokeText, "#ff0000") {
		fail("scene svg: Stroke = \"red\" did not draw as #ff0000")
	}
	bogusStroke := cadaclysm.NewSvgOptions()
	bogusStroke.Stroke = "notacolour"
	if _, serr := scene.SvgText(&bogusStroke); serr == nil || !strings.Contains(serr.Error(), "a CSS colour name") {
		fail("scene svg: Stroke = \"notacolour\" was accepted")
	}
	fmt.Println("cadaclysm svg: Stroke by CSS colour name, bogus name refused")
	fmt.Println("svg: scene and node text, file written, fov=200 refused")

	kernel(license)
	silhouette(path)
	healthReader(path)
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
	machining()
	edgeCurves()
	intersections()
	collider()
	clash()
	sweptClash()
	assemblySweptClash()
	wallThickness()
	subd()
	sketch()
	solidHits()
	measure()
	rtree()
	interpolatorAndMerge()
	rtreeRays()
	healthKernel()
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

	// CSS colour names: RGB and the ...Text methods read "red" the same as (1, 0, 0), and
	// refuse a name the library's parser does not know.
	redRGB, err := blacksmith.RGB("red")
	if err != nil {
		fail(err.Error())
	}
	if redRGB != [3]float64{1, 0, 0} {
		fail(fmt.Sprintf("blacksmith.RGB(\"red\") is %v, not (1, 0, 0)", redRGB))
	}
	if _, err := blacksmith.RGB("notacolour"); err == nil || !strings.Contains(err.Error(), "a CSS colour name") {
		fail("blacksmith.RGB(\"notacolour\") was accepted")
	}
	redBox, err := plate.ColouredText("red")
	if err != nil {
		fail(err.Error())
	}
	defer redBox.Close()
	redBoxColour, ok, err := redBox.Colour()
	if err != nil || !ok || redBoxColour != [3]float64{1, 0, 0} {
		fail(fmt.Sprintf("Solid.ColouredText(\"red\") did not read back as (1, 0, 0): %v, %v, %v", redBoxColour, ok, err))
	}
	if _, err := plate.ColouredText("notacolour"); err == nil || !strings.Contains(err.Error(), "a CSS colour name") {
		fail("Solid.ColouredText(\"notacolour\") was accepted")
	}
	redFace, err := plate.ColouredFaceText(0, "lime")
	if err != nil {
		fail(err.Error())
	}
	defer redFace.Close()
	if c, ok, err := redFace.FaceColour(0); err != nil || !ok || c != [3]float64{0, 1, 0} {
		fail(fmt.Sprintf("Solid.ColouredFaceText(0, \"lime\") did not read back as (0, 1, 0): %v, %v, %v", c, ok, err))
	}
	redEdges, err := plate.EdgesColouredText("blue")
	if err != nil {
		fail(err.Error())
	}
	defer redEdges.Close()
	if c, ok, err := redEdges.EdgeColour(0); err != nil || !ok || c != [3]float64{0, 0, 1} {
		fail(fmt.Sprintf("Solid.EdgesColouredText(\"blue\") did not read back as (0, 0, 1): %v, %v, %v", c, ok, err))
	}
	redEdgesPicked, err := plate.EdgesColouredPickedText([]int{0}, "yellow")
	if err != nil {
		fail(err.Error())
	}
	defer redEdgesPicked.Close()
	if c, ok, err := redEdgesPicked.EdgeColour(0); err != nil || !ok || c != [3]float64{1, 1, 0} {
		fail(fmt.Sprintf("Solid.EdgesColouredPickedText([0], \"yellow\") did not read back as (1, 1, 0): %v, %v, %v", c, ok, err))
	}
	redProfile, err := rectProfile.ColouredText("red")
	if err != nil {
		fail(err.Error())
	}
	defer redProfile.Close()
	if c, ok, err := redProfile.Colour(); err != nil || !ok || c != [3]float64{1, 0, 0} {
		fail(fmt.Sprintf("Profile.ColouredText(\"red\") did not read back as (1, 0, 0): %v, %v, %v", c, ok, err))
	}
	fmt.Println("blacksmith colour: RGB and every ...Text method read CSS colour names, bogus names refused")

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

	// A mesh view owns a held tessellation of its own now: neither meshing the solid
	// again at another tolerance nor closing the solid frees the memory it reads.
	first, err := rounded.Mesh(0.05)
	if err != nil {
		fail(err.Error())
	}
	triangles0 := first.TriangleCount()
	kept := append([]float32(nil), mustPositions(first)...)
	if _, err := rounded.Mesh(0.5); err != nil {
		fail(err.Error())
	}
	if _, err := rounded.Mesh(0.01); err != nil {
		fail(err.Error())
	}
	afterRemesh, err := first.Positions()
	if err != nil || !slices.Equal(afterRemesh, kept) {
		fail("a held mesh view changed under a re-mesh at another tolerance")
	}
	runtime.KeepAlive(first)

	// A held view also outlives the solid it was cut from: a cuboid's mesh read after
	// Close must equal its earlier read.
	heldCuboid, err := blacksmith.Cuboid(3, 4, 5)
	if err != nil {
		fail(err.Error())
	}
	heldCuboidMesh, err := heldCuboid.Mesh(blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	heldCuboidKept := append([]float32(nil), mustPositions(heldCuboidMesh)...)
	heldCuboid.Close()
	afterClose, err := heldCuboidMesh.Positions()
	if err != nil || !slices.Equal(afterClose, heldCuboidKept) {
		fail("a held mesh view changed after the solid it was cut from was closed")
	}
	runtime.KeepAlive(heldCuboidMesh)
	fmt.Printf("mesh at 0.05: %d triangles; a held view survives re-mesh at 0.5, 0.01 and the solid's Close\n", triangles0)

	// f64 twins on the kernel: mesh64 shares mesh's cache and bounds64 the same
	// tessellation, unnarrowed.
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
			if err == nil {
				sewn, report, serr := brep.Sewed(nil, nil)
				if serr != nil {
					fail(serr.Error())
				}
				again, _ := brep.Manifold()
				if int(report.FreeBefore) != read.BoundaryEdges || again.BoundaryEdges != read.BoundaryEdges {
					fail(fmt.Sprintf("sewed reports %d free edges before, the brep has %d", report.FreeBefore, read.BoundaryEdges))
				}
				sewn.Close()
			}
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
	transforms()

	assembly()
	material()
	mechanism()
	gearRoundTrip()
	posedTests()
}

// material is Solid.WithMaterial and Solid.Styled with their readers, at parity with the
// Python reference's test_a_material_and_an_outside_style_ride_operations_and_reach_step.
func material() {
	cube, err := blacksmith.Cuboid(1, 1, 1)
	if err != nil {
		fail(err.Error())
	}
	defer cube.Close()
	if _, ok := cube.Material(); ok {
		fail("material: a fresh cuboid has a material")
	}
	made, err := cube.WithMaterial("Steel")
	if err != nil {
		fail(err.Error())
	}
	defer made.Close()
	steel, err := made.Styled("materials/steel.mtlx", "BrushedSteel")
	if err != nil {
		fail(err.Error())
	}
	defer steel.Close()
	m, _ := steel.Material()
	l, _ := steel.StyleLocation()
	i, _ := steel.StyleIdentification()
	if m != "Steel" || l != "materials/steel.mtlx" || i != "BrushedSteel" {
		fail(fmt.Sprintf("material: read back %q %q %q", m, l, i))
	}
	tool, err := cube.Translate(0.5, 0.5, 0.5)
	if err != nil {
		fail(err.Error())
	}
	defer tool.Close()
	cut, err := steel.Cut(tool, 0.05)
	if err != nil {
		fail(err.Error())
	}
	defer cut.Close()
	if m, _ := cut.Material(); m != "Steel" {
		fail(fmt.Sprintf("material: a cut is made of %q, not its target's Steel", m))
	}
	only, err := cube.Styled("", "BrushedSteel")
	if err != nil {
		fail(err.Error())
	}
	defer only.Close()
	if _, ok := only.StyleLocation(); ok {
		fail("material: an empty location was kept")
	}
	text, err := steel.StepText("", "mm")
	if err != nil {
		fail(err.Error())
	}
	if !strings.Contains(text, "MATERIAL_DESIGNATION('Steel'") || !strings.Contains(text, "EXTERNALLY_DEFINED_STYLE(IDENTIFIER('BrushedSteel')") {
		fail("material: STEP is missing the material or the style")
	}
	if _, err := cube.WithMaterial(" "); err == nil {
		fail("material: a blank material was accepted")
	}
	if _, err := cube.Styled("", ""); err == nil {
		fail("material: a style naming nothing was accepted")
	}
	fmt.Println("kernel material: read back, kept by a cut, written to STEP")
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

// geared builds Drives plan 4's round trip (Python's _geared): a pinion turning on "drive"
// meshes, by the gear pair "mesh" (radii 10 and 20, ratio -0.5, bevel 0.25, helical 0.125),
// with a wheel turning on "driven" about (30, 0); the wheel's part sits 5 off its axis, at
// (35, 0, 2). The two are different parts: AP242 refuses a pair between two placements of
// one.
func geared(mesh bool) *blacksmith.Assembly {
	must := func(err error) {
		if err != nil {
			fail(err.Error())
		}
	}
	solid := func(s *blacksmith.Solid, err error, name string) *blacksmith.Solid {
		must(err)
		named, err := s.Named(name)
		must(err)
		s.Close()
		return named
	}
	cube, cerr := blacksmith.Cuboid(40, 10, 2)
	plate := solid(cube, cerr, "plate")
	defer plate.Close()
	cyl, perr := blacksmith.Cylinder(1, 6)
	pin := solid(cyl, perr, "pin")
	defer pin.Close()
	cyl2, herr := blacksmith.Cylinder(2, 4)
	hub := solid(cyl2, herr, "hub")
	defer hub.Close()
	gears, err := blacksmith.NewAssembly("gears")
	must(err)
	_, err = gears.PlaceSolid(plate, blacksmith.FrameXY([3]float64{}), "frame")
	must(err)
	_, err = gears.PlaceSolid(pin, blacksmith.FrameXY([3]float64{0, 0, 2}), "pinion")
	must(err)
	_, err = gears.PlaceSolid(hub, blacksmith.FrameXY([3]float64{35, 0, 2}), "wheel")
	must(err)
	must(gears.Link("base", []string{"frame"}))
	must(gears.Link("driver", []string{"pinion"}))
	must(gears.Link("follower", []string{"wheel"}))
	must(gears.Joint("drive", "base", "driver"))
	must(gears.Joint("driven", "base", "follower"))
	must(gears.Joint("mesh", "driver", "follower"))
	must(gears.Pair("drive", "revolute", blacksmith.FrameXY([3]float64{0, 0, 2}), blacksmith.PairOptions{}))
	must(gears.Pair("driven", "revolute", blacksmith.FrameXY([3]float64{30, 0, 2}), blacksmith.PairOptions{}))
	if mesh {
		must(gears.PairWith("mesh", "gear", blacksmith.FrameXY([3]float64{0, 0, 2}), blacksmith.PairWithOptions{},
			[]float64{10, 20, -0.5, 0.25, 0.125}))
	}
	return gears
}

// gearRoundTrip is the Python reference's test_a_gear_pair_round_trips_and_poses_from_its_driver
// and test_pair_with_refuses_a_wrong_parameter_count.
func gearRoundTrip() {
	near := func(a, b float64) bool { return math.Abs(a-b) <= 1e-9 }
	gears := geared(true)
	defer gears.Close()
	scene, err := gears.ToScene("")
	if err != nil {
		fail(err.Error())
	}
	defer scene.Close()
	joints := map[string]*cadaclysm.Joint{}
	for _, j := range scene.Joints() {
		joints[j.Name()] = j
	}
	mesh := joints["mesh"].Pair()
	if mesh == nil || mesh.Kind != cadaclysm.PairOther || mesh.KindName() != "gear" {
		fail("gear: the mesh pair is not kind other / kind name gear")
	}
	want := []float64{10, 20, -0.5, 0.25, 0.125}
	got := mesh.Parameters()
	if len(got) != len(want) {
		fail(fmt.Sprintf("gear: parameters %v, not %v", got, want))
	}
	for i := range want {
		if !near(got[i], want[i]) {
			fail(fmt.Sprintf("gear: parameters %v, not %v", got, want))
		}
	}
	drive := joints["drive"].Pair()
	if drive.KindName() != "revolute" || len(drive.Parameters()) != 0 {
		fail("gear: the drive pair is not revolute with no parameters")
	}

	// the driver alone turns the wheel by ratio x 0.4 about (30, 0): nothing to report
	pose, err := scene.Pose([]cadaclysm.StateValue{{Joint: joints["drive"], Values: []float64{0.4}}}, nil)
	if err != nil {
		fail(err.Error())
	}
	if len(pose.Diagnostics) != 0 || len(pose.Unsolved) != 0 {
		fail(fmt.Sprintf("gear: a driver-only pose reports %v / %d unsolved", pose.Diagnostics, len(pose.Unsolved)))
	}
	wheel := scene.Links()[2].Nodes()[0]
	m := pose.Transform(wheel)
	if !near(m[3], 30+5*math.Cos(-0.2)) || !near(m[7], 5*math.Sin(-0.2)) || !near(m[11], 2) {
		fail(fmt.Sprintf("gear: the wheel's posed origin is (%v, %v, %v)", m[3], m[7], m[11]))
	}

	// both sides given, against the law: one diagnostic, in the kernel's words
	pose, err = scene.Pose([]cadaclysm.StateValue{
		{Joint: joints["drive"], Values: []float64{0.4}}, {Joint: joints["driven"], Values: []float64{0.4}}}, nil)
	if err != nil {
		fail(err.Error())
	}
	if len(pose.Diagnostics) != 1 || !strings.HasPrefix(pose.Diagnostics[0],
		"coupling 'mesh': both 'drive' and 'driven' are given and disagree by") {
		fail(fmt.Sprintf("gear: a disagreeing pose reports %q", pose.Diagnostics))
	}

	bare := geared(false)
	defer bare.Close()
	rerr := bare.PairWith("mesh", "gear", blacksmith.FrameXY([3]float64{}), blacksmith.PairWithOptions{}, []float64{10, 20})
	if rerr == nil || rerr.Error() != "pair: a gear takes 3 or 5 parameters, not 2" {
		fail(fmt.Sprintf("gear: a two-parameter gear was not refused exactly: %v", rerr))
	}
	if err := bare.PairWith("mesh", "gear", blacksmith.FrameXY([3]float64{}), blacksmith.PairWithOptions{},
		[]float64{10, 20, -0.5}); err != nil {
		fail("gear: the refused pair left the joint unusable: " + err.Error())
	}
	fmt.Println("gear: PairWith round-trips through Kind/KindName/Parameters, poses from its driver, reports a disagreement, refuses a wrong count")
}

// posedTests is the Python reference's test_posed_* (the to_scene half compared as STEP text),
// plus the gears' drive/driven refusal.
func posedTests() {
	must := func(err error) {
		if err != nil {
			fail(err.Error())
		}
	}
	noStamp := func(text string) string {
		var kept []string
		for _, l := range strings.Split(text, "\n") {
			if !strings.HasPrefix(l, "FILE_NAME(") {
				kept = append(kept, l)
			}
		}
		return strings.Join(kept, "\n")
	}
	stepOf := func(a *blacksmith.Assembly) string {
		text, err := a.StepText("", "mm")
		must(err)
		return noStamp(text)
	}
	named := func(s *blacksmith.Solid, err error, name string) *blacksmith.Solid {
		must(err)
		n, err := s.Named(name)
		must(err)
		s.Close()
		return n
	}
	str := func(s string) *string { return &s }

	// _posed_frame: two copies of a bracket whose bolt turns on 'turn', 'left' and 'right/rear'
	plateRaw, perr := blacksmith.Cuboid(20, 10, 2)
	plate := named(plateRaw, perr, "plate")
	defer plate.Close()
	boltRaw, berr := blacksmith.Cuboid(1, 1, 6)
	bolt := named(boltRaw, berr, "bolt")
	defer bolt.Close()
	bracket, err := blacksmith.NewAssembly("bracket")
	must(err)
	defer bracket.Close()
	_, err = bracket.PlaceSolid(plate, blacksmith.FrameXY([3]float64{}), "")
	must(err)
	_, err = bracket.PlaceSolid(bolt, blacksmith.FrameXY([3]float64{5, 5, 2}), "")
	must(err)
	must(bracket.Link("fixed", []string{"plate"}))
	must(bracket.Link("bolts", []string{"bolt"}))
	must(bracket.Joint("turn", "fixed", "bolts"))
	must(bracket.Pair("turn", "revolute", blacksmith.FrameXY([3]float64{10, 5, 2}), blacksmith.PairOptions{}))
	frame, err := blacksmith.NewAssembly("frame")
	must(err)
	defer frame.Close()
	_, err = frame.PlaceAssembly(bracket, blacksmith.FrameXY([3]float64{}), "left")
	must(err)
	_, err = frame.PlaceAssembly(bracket, blacksmith.FrameXY([3]float64{100, 0, 0}), "right/rear")
	must(err)
	frameBefore := stepOf(frame)

	_, err = frame.Posed([]blacksmith.StateRow{{Joint: "turn", Values: []float64{0.3}}}, blacksmith.PosedOptions{})
	const ambiguous = "posed: 'turn' names 2 joints: left/turn, right\\/rear/turn; give one by its path"
	if err == nil || err.Error() != ambiguous {
		fail(fmt.Sprintf("posed: the ambiguous name was not refused exactly: %v", err))
	}
	if _, isBuild := err.(*blacksmith.BuildError); !isBuild {
		fail(fmt.Sprintf("posed: the refusal is a %T, not a *BuildError", err))
	}
	posed, err := frame.Posed([]blacksmith.StateRow{{Joint: "right\\/rear/turn", Values: []float64{0.3}}}, blacksmith.PosedOptions{})
	must(err)
	defer posed.Close()
	if posed.Name() != "frame" {
		fail(fmt.Sprintf("posed: the posed assembly is named %q, not frame", posed.Name()))
	}
	if stepOf(posed) == frameBefore {
		fail("posed: a turned bolt left the STEP text unchanged")
	}
	zero, err := frame.Posed([]blacksmith.StateRow{{Joint: "right\\/rear/turn", Values: []float64{0.0}}}, blacksmith.PosedOptions{})
	must(err)
	defer zero.Close()
	if stepOf(zero) != frameBefore {
		fail("posed: a zero pose changed the STEP text")
	}
	if stepOf(frame) != frameBefore {
		fail("posed: posing changed the original")
	}
	none, err := frame.Posed(nil, blacksmith.PosedOptions{})
	must(err)
	defer none.Close()
	if stepOf(none) != frameBefore {
		fail("posed: no rows changed the STEP text")
	}

	// the arm: a state, a ground, the kernel's words
	armPlateRaw, aerr := blacksmith.Cuboid(40, 10, 2)
	armPlate := named(armPlateRaw, aerr, "plate")
	defer armPlate.Close()
	pinRaw, pinerr := blacksmith.Cylinder(1, 6)
	pin := named(pinRaw, pinerr, "pin")
	defer pin.Close()
	arm, err := blacksmith.NewAssembly("arm")
	must(err)
	defer arm.Close()
	_, err = arm.PlaceSolid(armPlate, blacksmith.FrameXY([3]float64{}), "base")
	must(err)
	_, err = arm.PlaceSolid(pin, blacksmith.FrameXY([3]float64{5, 5, 2}), "pin")
	must(err)
	must(arm.Link("ground", []string{"base"}))
	must(arm.Link("upper arm", []string{"pin"}))
	must(arm.Joint("shoulder", "ground", "upper arm"))
	lo, hi := -1.5, 1.5
	must(arm.Pair("shoulder", "revolute", blacksmith.FrameXY([3]float64{0, 0, 10}),
		blacksmith.PairOptions{Ranges: []blacksmith.Range{{Lower: &lo, Upper: &hi}}}))
	must(arm.State("reach", []blacksmith.StateRow{{Joint: "shoulder", Values: []float64{0.5}}}))
	must(arm.Base("ground"))
	armBefore := stepOf(arm)
	shoulder := func(v float64) []blacksmith.StateRow {
		return []blacksmith.StateRow{{Joint: "shoulder", Values: []float64{v}}}
	}
	posedStep := func(rows []blacksmith.StateRow, opts blacksmith.PosedOptions) string {
		p, err := arm.Posed(rows, opts)
		must(err)
		defer p.Close()
		return stepOf(p)
	}
	byState := posedStep(nil, blacksmith.PosedOptions{State: str("reach")})
	byRow := posedStep(shoulder(0.5), blacksmith.PosedOptions{})
	if byState != byRow {
		fail("posed: state 'reach' differs from shoulder = 0.5")
	}
	if byRow == armBefore {
		fail("posed: shoulder = 0.5 left the STEP text unchanged")
	}
	if posedStep(shoulder(0.5), blacksmith.PosedOptions{Ground: str("upper arm")}) == byRow {
		fail("posed: grounding 'upper arm' changed nothing")
	}
	_, err = arm.Posed(shoulder(2.0), blacksmith.PosedOptions{})
	if err == nil || err.Error() != "posed: value 0 of joint 'shoulder' is 2, outside its range" {
		fail(fmt.Sprintf("posed: an out-of-range value was not refused exactly: %v", err))
	}
	_, err = arm.Posed(nil, blacksmith.PosedOptions{State: str("fold")})
	if err == nil || err.Error() != "posed: assembly 'arm' has no state named 'fold'" {
		fail(fmt.Sprintf("posed: an unknown state was not refused exactly: %v", err))
	}
	if stepOf(arm) != armBefore {
		fail("posed: posing or a refusal changed the arm")
	}

	// the drives' gears: drive alone is fine; drive and driven that disagree are refused
	gears := geared(true)
	defer gears.Close()
	gearsBefore := stepOf(gears)
	g, err := gears.Posed([]blacksmith.StateRow{{Joint: "drive", Values: []float64{0.4}}}, blacksmith.PosedOptions{})
	must(err)
	defer g.Close()
	if g.Name() != "gears" {
		fail(fmt.Sprintf("posed: the posed gears are named %q", g.Name()))
	}
	_, err = gears.Posed([]blacksmith.StateRow{
		{Joint: "drive", Values: []float64{0.4}}, {Joint: "driven", Values: []float64{0.4}}}, blacksmith.PosedOptions{})
	if err == nil || !strings.HasPrefix(err.Error(),
		"posed: assembly 'gears': coupling 'mesh': both 'drive' and 'driven' are given and disagree by") {
		fail(fmt.Sprintf("posed: a disagreeing pair of drives was not refused: %v", err))
	}
	if stepOf(gears) != gearsBefore {
		fail("posed: posing or a refusal changed the gears")
	}
	fmt.Println("posed: Assembly.Posed poses by path, state and ground, refuses ambiguity, range, state and disagreeing drives in the kernel's words, and leaves the original unchanged")
}

// mechanism is Assembly.Link/Assembly.Joint, at parity with the Python reference's
// _mechanism() and its tests (test_a_mechanism_is_written_as_ap242_kinematic_topology,
// test_every_bad_link_or_joint_is_refused_and_changes_nothing).
func mechanism() {
	mechBoltRaw, err := blacksmith.Cylinder(1, 6)
	if err != nil {
		fail(err.Error())
	}
	mechBolt, err := mechBoltRaw.Named("bolt")
	if err != nil {
		fail(err.Error())
	}
	mechBoltRaw.Close()
	defer mechBolt.Close()
	mechPlateRaw, err := blacksmith.Cuboid(20, 10, 2)
	if err != nil {
		fail(err.Error())
	}
	mechPlate, err := mechPlateRaw.Named("plate") // uncoloured
	if err != nil {
		fail(err.Error())
	}
	mechPlateRaw.Close()
	defer mechPlate.Close()

	bracket, err := blacksmith.NewAssembly("bracket")
	if err != nil {
		fail(err.Error())
	}
	defer bracket.Close()
	if _, err := bracket.PlaceSolid(mechPlate, blacksmith.FrameXY([3]float64{}), ""); err != nil {
		fail(err.Error())
	}
	if _, err := bracket.PlaceSolid(mechBolt, blacksmith.FrameXY([3]float64{5, 5, 2}), ""); err != nil {
		fail(err.Error())
	}
	if _, err := bracket.PlaceSolid(mechBolt, blacksmith.FrameXY([3]float64{15, 5, 2}), ""); err != nil {
		fail(err.Error())
	}
	if err := bracket.Link("fixed", []string{"plate"}); err != nil {
		fail(err.Error())
	}
	if err := bracket.Link("bolts", []string{"bolt", "bolt 2"}); err != nil {
		fail(err.Error())
	}
	if err := bracket.Joint("screw", "fixed", "bolts"); err != nil {
		fail(err.Error())
	}

	arm, err := blacksmith.NewAssembly("arm")
	if err != nil {
		fail(err.Error())
	}
	defer arm.Close()
	if _, err := arm.PlaceSolid(mechPlate, blacksmith.FrameXY([3]float64{}), "base"); err != nil {
		fail(err.Error())
	}
	if _, err := arm.PlaceAssembly(bracket, blacksmith.FrameXY([3]float64{0, 0, 10}), "upper"); err != nil {
		fail(err.Error())
	}
	if _, err := arm.PlaceSolid(mechBolt, blacksmith.FrameXY([3]float64{5, 5, 2}), "pin"); err != nil {
		fail(err.Error())
	}
	if err := arm.Link("ground", []string{"base"}); err != nil {
		fail(err.Error())
	}
	if err := arm.Link("upper arm", []string{"upper", "pin"}); err != nil {
		fail(err.Error())
	}
	if err := arm.Joint("shoulder", "ground", "upper arm"); err != nil {
		fail(err.Error())
	}

	// Fact 1: the default schema (no explicit schema) carries the kinematic entities.
	armStepText, err := arm.StepText("", "mm")
	if err != nil {
		fail(err.Error())
	}
	if !strings.Contains(armStepText, "AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF") {
		fail("mechanism: arm.StepText() does not name AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF")
	}
	linkCount := strings.Count(armStepText, "=KINEMATIC_LINK(")
	rigidCount := strings.Count(armStepText, "=RIGID_LINK_REPRESENTATION(")
	cdklrCount := strings.Count(armStepText, "=CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION(")
	jointCount := strings.Count(armStepText, "=KINEMATIC_JOINT(")
	topoCount := strings.Count(armStepText, "=KINEMATIC_TOPOLOGY_STRUCTURE(")
	if linkCount != 4 || rigidCount != 6 || cdklrCount != 6 || jointCount != 2 || topoCount != 2 {
		fail(fmt.Sprintf("mechanism: arm.StepText() has %d links, %d rigid reps, %d context-dependent reps, %d joints, %d topologies, not 4/6/6/2/2",
			linkCount, rigidCount, cdklrCount, jointCount, topoCount))
	}
	fmt.Printf("mechanism: arm.StepText() writes %d links, %d rigid reps, %d context-dependent reps, %d joints, %d topologies\n",
		linkCount, rigidCount, cdklrCount, jointCount, topoCount)

	// Fact 2: an explicit schema without kinematic entities is refused.
	if _, err := arm.StepText("config_control_design", "mm"); err == nil || !strings.Contains(err.Error(), "no kinematic entities") {
		fail(fmt.Sprintf("mechanism: config_control_design was not refused right: %v", err))
	}
	fmt.Println("mechanism: an explicit schema without kinematic entities is refused")

	// Fact 3: each of the eleven refusals raises with exactly its message, and afterwards
	// the STEP text (with FILE_NAME( lines stripped) is unchanged.
	noStamp := func(text string) string {
		lines := strings.Split(text, "\n")
		kept := lines[:0]
		for _, l := range lines {
			if !strings.HasPrefix(l, "FILE_NAME(") {
				kept = append(kept, l)
			}
		}
		return strings.Join(kept, "\n")
	}
	before, err := arm.StepText("", "mm")
	if err != nil {
		fail(err.Error())
	}
	before = noStamp(before)
	refusals := []struct {
		Call    func() error
		Message string
	}{
		{func() error { return arm.Link("", []string{"base"}) }, "link: a name cannot be empty"},
		{func() error { return arm.Link("ground", []string{"base"}) }, "link: assembly 'arm' already has a link named 'ground'"},
		{func() error { return arm.Link("free", []string{}) }, "link: link 'free' names no placements"},
		{func() error { return arm.Link("free", []string{"base", "base"}) }, "link: link 'free' names placement 'base' twice"},
		{func() error { return arm.Link("free", []string{"bolt"}) }, "link: assembly 'arm' has no placement named 'bolt'"},
		{func() error { return arm.Link("free", []string{"pin"}) }, "link: placement 'pin' of assembly 'arm' is already in link 'upper arm'"},
		{func() error { return arm.Joint("", "ground", "upper arm") }, "joint: a name cannot be empty"},
		{func() error { return arm.Joint("shoulder", "upper arm", "ground") }, "joint: assembly 'arm' already has a joint named 'shoulder'"},
		{func() error { return arm.Joint("wrist", "ground", "hand") }, "joint: assembly 'arm' has no link named 'hand'"},
		{func() error { return arm.Joint("wrist", "ground", "ground") }, "joint: joint 'wrist' joins link 'ground' to itself"},
		{func() error { return arm.Joint("wrist", "ground", "upper arm") }, "joint: assembly 'arm' already joins 'ground' to 'upper arm'"},
	}
	for _, r := range refusals {
		err := r.Call()
		if err == nil {
			fail(fmt.Sprintf("mechanism: %q was accepted", r.Message))
		}
		if err.Error() != r.Message {
			fail(fmt.Sprintf("mechanism: got %q, not %q", err.Error(), r.Message))
		}
	}
	after, err := arm.StepText("", "mm")
	if err != nil {
		fail(err.Error())
	}
	if noStamp(after) != before {
		fail("mechanism: a refused link or joint changed the assembly")
	}
	fmt.Println("mechanism: all eleven bad links and joints are refused with their exact message, unchanged")

	// Fact 5: read-back through the reader, before fact 4 adds "back" -- arm.ToScene("")
	// carries the same links and joints back in, by name and node count, with no
	// kinematics diagnostic. (The Python reference checks this on a fresh _mechanism()
	// build, i.e. before the reverse-pair joint exists; done here in place, ahead of
	// fact 4, so it sees the same two joints.)
	mechScene, err := arm.ToScene("")
	if err != nil {
		fail(err.Error())
	}
	mechLinks := mechScene.Links()
	if len(mechLinks) != 4 {
		fail(fmt.Sprintf("mechanism: read-back has %d links, not 4", len(mechLinks)))
	}
	wantNames := []string{"fixed", "bolts", "ground", "upper arm"}
	wantNodes := []int{1, 2, 1, 2}
	for i, l := range mechLinks {
		if l.Name() != wantNames[i] {
			fail(fmt.Sprintf("mechanism: read-back link %d is %q, not %q", i, l.Name(), wantNames[i]))
		}
		if len(l.Nodes()) != wantNodes[i] {
			fail(fmt.Sprintf("mechanism: read-back link %q has %d nodes, not %d", l.Name(), len(l.Nodes()), wantNodes[i]))
		}
	}
	mechJoints := mechScene.Joints()
	if len(mechJoints) != 2 ||
		mechJoints[0].Name() != "screw" || mechJoints[0].Start().Index() != 0 || mechJoints[0].End().Index() != 1 ||
		mechJoints[1].Name() != "shoulder" || mechJoints[1].Start().Index() != 2 || mechJoints[1].End().Index() != 3 {
		fail("mechanism: read-back joints are not (screw, 0, 1) and (shoulder, 2, 3)")
	}
	for _, d := range mechScene.Diagnostics() {
		if strings.HasPrefix(d, "kinematics:") {
			fail("mechanism: read-back carries a kinematics: diagnostic")
		}
	}
	mechScene.Close()
	fmt.Println("mechanism: read-back through arm.ToScene() matches links, joints and diagnostics")

	// Pairs: Assembly.Pair/Assembly.State/Assembly.Base and the free PairFreedomCount, at
	// parity with the Python reference's _paired() fixture and its tests (spec
	// 2026-09-29). Built on bracket/arm before "back" is added below: a joint with no pair
	// refuses StepText(), so facts 1-6 and 9's diagnostics half need arm without it.
	near := func(a, b float64) bool { return math.Abs(a-b) <= 1e-9 }

	screwEndFrame := blacksmith.FrameXY([3]float64{4, 2, 3})
	if err := bracket.Pair("screw", "prismatic", blacksmith.FrameXY([3]float64{1, 2, 3}),
		blacksmith.PairOptions{EndFrame: &screwEndFrame}); err != nil {
		fail(err.Error())
	}
	shoulderLower, shoulderUpper := -1.5, 1.5
	if err := arm.Pair("shoulder", "revolute", blacksmith.FrameXY([3]float64{0, 0, 10}),
		blacksmith.PairOptions{Ranges: []blacksmith.Range{{Lower: &shoulderLower, Upper: &shoulderUpper}}}); err != nil {
		fail(err.Error())
	}
	if err := arm.State("reach", []blacksmith.StateRow{{Joint: "shoulder", Values: []float64{0.5}}}); err != nil {
		fail(err.Error())
	}
	if err := arm.Base("ground"); err != nil {
		fail(err.Error())
	}

	// Fact 1: the pair/state entity counts in the default schema.
	pairedStepText, err := arm.StepText("", "mm")
	if err != nil {
		fail(err.Error())
	}
	mechReprCount2 := strings.Count(pairedStepText, "=MECHANISM_REPRESENTATION(")
	pairRelCount := strings.Count(pairedStepText, "=PAIR_REPRESENTATION_RELATIONSHIP(")
	revoluteRangeCount := strings.Count(pairedStepText, "REVOLUTE_PAIR_WITH_RANGE")
	prismaticCount := strings.Count(pairedStepText, "PRISMATIC_PAIR")
	kinPropCount := strings.Count(pairedStepText, "=KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION(")
	mechStateCount := strings.Count(pairedStepText, "=MECHANISM_STATE_REPRESENTATION(")
	if mechReprCount2 != 2 || pairRelCount != 2 || revoluteRangeCount != 1 || prismaticCount != 1 ||
		kinPropCount != 1 || mechStateCount != 1 {
		fail(fmt.Sprintf("pairs: arm.StepText() has %d mechanism reps, %d pair rels, %d revolute-with-range, "+
			"%d prismatic, %d kinematic property reps, %d mechanism states, not 2/2/1/1/1/1",
			mechReprCount2, pairRelCount, revoluteRangeCount, prismaticCount, kinPropCount, mechStateCount))
	}
	fmt.Printf("pairs: arm.StepText() writes %d mechanism reps, %d pair rels, %d revolute-with-range, "+
		"%d prismatic, %d kinematic property reps, %d mechanism states\n",
		mechReprCount2, pairRelCount, revoluteRangeCount, prismaticCount, kinPropCount, mechStateCount)

	// Facts 2-6 and 9 (diagnostics half): read back through the reader.
	pairedScene, err := arm.ToScene("")
	if err != nil {
		fail(err.Error())
	}
	var shoulderJoint, screwJoint *cadaclysm.Joint
	for _, j := range pairedScene.Joints() {
		switch j.Name() {
		case "shoulder":
			shoulderJoint = j
		case "screw":
			screwJoint = j
		}
	}
	if shoulderJoint == nil || screwJoint == nil {
		fail("pairs: read-back is missing the shoulder or screw joint")
	}
	shoulderPair := shoulderJoint.Pair()
	if shoulderPair == nil {
		fail("pairs: shoulder has no pair")
	}
	if shoulderPair.Kind != cadaclysm.PairRevolute {
		fail("pairs: shoulder's pair is not revolute")
	}
	for _, frame := range [][16]float64{shoulderPair.FrameStart(), shoulderPair.FrameEnd()} {
		if !near(frame[3], 0) || !near(frame[7], 0) || !near(frame[11], 10) ||
			!near(frame[2], 0) || !near(frame[6], 0) || !near(frame[10], 1) {
			fail("pairs: shoulder's pair frames are not at (0,0,10) with z (0,0,1)")
		}
	}
	shoulderFreedoms := shoulderPair.Freedoms()
	if len(shoulderFreedoms) != 1 || shoulderFreedoms[0].Motion != cadaclysm.MotionRotation ||
		shoulderFreedoms[0].Axis != cadaclysm.FreedomZ ||
		!shoulderFreedoms[0].HasLower || !near(shoulderFreedoms[0].Lower, -1.5) ||
		!shoulderFreedoms[0].HasUpper || !near(shoulderFreedoms[0].Upper, 1.5) {
		fail("pairs: shoulder's pair is not one rotation-about-z freedom ranged [-1.5, 1.5]")
	}
	fmt.Println("pairs: shoulder's pair is revolute, one rotation-about-z freedom ranged [-1.5, 1.5]")

	screwPair := screwJoint.Pair()
	if screwPair == nil {
		fail("pairs: screw has no pair")
	}
	if screwPair.Kind != cadaclysm.PairPrismatic {
		fail("pairs: screw's pair is not prismatic")
	}
	for _, f := range screwPair.Freedoms() {
		if f.HasLower || f.HasUpper {
			fail("pairs: screw's pair has a ranged freedom")
		}
	}
	screwStart, screwEnd := screwPair.FrameStart(), screwPair.FrameEnd()
	if !near(screwStart[3], 1) || !near(screwStart[7], 2) || !near(screwStart[11], 13) ||
		!near(screwEnd[3], 4) || !near(screwEnd[7], 2) || !near(screwEnd[11], 13) {
		fail("pairs: screw's pair frames are not (1,2,13) to (4,2,13)")
	}
	fmt.Println("pairs: screw's pair is prismatic with no ranges, frames (1,2,13) to (4,2,13)")

	pairedBaseLink := pairedScene.Base()
	if pairedBaseLink == nil || pairedBaseLink.Name() != "ground" {
		fail("pairs: the scene's base is not 'ground'")
	}
	pairedStates := pairedScene.States()
	if len(pairedStates) != 1 || pairedStates[0].Name != "reach" {
		fail("pairs: the scene does not carry exactly one state named 'reach'")
	}
	reachRow := pairedStates[0].Values
	if len(reachRow) != 1 || reachRow[0].Joint.Name() != "shoulder" ||
		len(reachRow[0].Values) != 1 || !near(reachRow[0].Values[0], 0.5) {
		fail("pairs: state 'reach' is not exactly one row (shoulder, [0.5])")
	}
	fmt.Println("pairs: the scene's base is 'ground', with one state 'reach' of (shoulder, [0.5])")

	// Fact 5: pose_state(reach) carries the pin node to (5cos0.5-5sin0.5, 5sin0.5+5cos0.5, 2).
	reachPose, err := pairedScene.PoseState(pairedStates[0], nil)
	if err != nil {
		fail(err.Error())
	}
	var upperArmLink *cadaclysm.Link
	for _, l := range pairedScene.Links() {
		if l.Name() == "upper arm" {
			upperArmLink = l
		}
	}
	if upperArmLink == nil {
		fail("pairs: read-back is missing the 'upper arm' link")
	}
	var pinNode *cadaclysm.Node
	for _, nd := range upperArmLink.Nodes() {
		t := nd.Transform()
		if near(t[3], 5) && near(t[7], 5) && near(t[11], 2) {
			pinNode = nd
		}
	}
	if pinNode == nil {
		fail("pairs: 'upper arm' has no node at (5,5,2)")
	}
	posedPin := reachPose.Transform(pinNode)
	wantX := 5*math.Cos(0.5) - 5*math.Sin(0.5)
	wantY := 5*math.Sin(0.5) + 5*math.Cos(0.5)
	if !near(posedPin[3], wantX) || !near(posedPin[7], wantY) || !near(posedPin[11], 2) {
		fail("pairs: pose_state(reach) did not carry the pin node to the expected point")
	}
	fmt.Println("pairs: pose_state(reach) carries the pin node to the expected point")

	// Fact 6: pose([(screw, [3.0])]) leaves every 'bolts' node at rest; [5.0] moves by (2,0,0).
	pose3, err := pairedScene.Pose([]cadaclysm.StateValue{{Joint: screwJoint, Values: []float64{3.0}}}, nil)
	if err != nil {
		fail(err.Error())
	}
	pose5, err := pairedScene.Pose([]cadaclysm.StateValue{{Joint: screwJoint, Values: []float64{5.0}}}, nil)
	if err != nil {
		fail(err.Error())
	}
	var boltsLink *cadaclysm.Link
	for _, l := range pairedScene.Links() {
		if l.Name() == "bolts" {
			boltsLink = l
		}
	}
	if boltsLink == nil {
		fail("pairs: read-back is missing the 'bolts' link")
	}
	for _, node := range boltsLink.Nodes() {
		rest := node.Transform()
		at3 := pose3.Transform(node)
		at5 := pose5.Transform(node)
		if !near(at3[3], rest[3]) || !near(at3[7], rest[7]) || !near(at3[11], rest[11]) {
			fail("pairs: pose([(screw, [3.0])]) moved a 'bolts' node off rest")
		}
		if !near(at5[3], rest[3]+2.0) || !near(at5[7], rest[7]) || !near(at5[11], rest[11]) {
			fail("pairs: pose([(screw, [5.0])]) did not move a 'bolts' node by (2,0,0)")
		}
	}
	fmt.Println("pairs: pose([(screw, [3.0])]) rests, pose([(screw, [5.0])]) moves 'bolts' by (2,0,0)")

	// Fact 9 (diagnostics half): no diagnostic names kinematics.
	for _, d := range pairedScene.Diagnostics() {
		if strings.HasPrefix(d, "kinematics:") {
			fail("pairs: the paired scene carries a kinematics: diagnostic")
		}
	}
	pairedScene.Close()

	// Motion sequences, written: a state rest and a swing over rest and reach, read back.
	if err := arm.State("rest", []blacksmith.StateRow{{Joint: "shoulder", Values: []float64{0.0}}}); err != nil {
		fail(err.Error())
	}
	if err := arm.Sequence("swing", []blacksmith.SequenceSegment{{State: "rest", T: 0, Interpolation: "linear"}, {State: "reach", T: 1, Interpolation: "linear"}}, true); err != nil {
		fail(err.Error())
	}
	swingScene, err := arm.ToScene("")
	if err != nil {
		fail(err.Error())
	}
	written := swingScene.Sequences()
	if len(written) != 1 || written[0].Name != "swing" || !written[0].Closed || written[0].SecondsPerUnit == nil || *written[0].SecondsPerUnit != 1.0 {
		fail("sequences: the written swing did not read back closed at 1 second per unit")
	}
	if len(written[0].Segments) != 2 || written[0].Segments[0].State.Name != "rest" || written[0].Segments[0].T != 0 || written[0].Segments[0].Interpolation != "linear" ||
		written[0].Segments[1].State.Name != "reach" || written[0].Segments[1].T != 1 || written[0].Segments[1].Interpolation != "linear" {
		fail("sequences: the written swing's segments are not rest@0 then reach@1, linear")
	}
	swingScene.Close()
	if err := arm.Sequence("bad", []blacksmith.SequenceSegment{{State: "rest", T: 0, Interpolation: "linear"}, {State: "nowhere", T: 1, Interpolation: "linear"}}, false); err == nil ||
		err.Error() != "sequence: assembly 'arm' has no state named 'nowhere'" {
		fail(fmt.Sprintf("sequences: a sequence over an unknown state was not refused exactly: %v", err))
	}
	fmt.Println("sequences: Assembly.Sequence round-trips and refuses an unknown state exactly")

	// Fact 4 (mechanism's own): the reverse pair is a new joint.
	if err := arm.Joint("back", "upper arm", "ground"); err != nil {
		fail(err.Error())
	}
	fmt.Println("mechanism: the reverse pair (\"back\") is accepted as a new joint")

	// Fact 7: the eight bad pair/state/base calls are refused with exactly their message,
	// and fact 8's unpaired-joint refusal ("back" has no pair) stays byte-identical before
	// and after -- proof none of them mutated "back", or anything else StepText() would
	// notice, even though a wholly valid StepText() snapshot is unavailable while "back" has
	// no pair.
	pairedUnpairedMessage := func() string {
		if _, serr := arm.StepText("", "mm"); serr == nil {
			fail("pairs: arm.StepText() with an unpaired joint 'back' was accepted")
			return ""
		} else {
			return serr.Error()
		}
	}
	pairedBefore := pairedUnpairedMessage()
	negOne, posOne := -1.0, 1.0
	oneVal, negOneVal := 1.0, -1.0
	turnedFrame, ferr := blacksmith.FrameAtX([3]float64{0, 0, 0}, [3]float64{0, 0, 1}, [3]float64{0, 1, 0})
	if ferr != nil {
		fail(ferr.Error())
	}
	backEndFrame := blacksmith.FrameXY([3]float64{})
	pairRefusals := []struct {
		Call    func() error
		Message string
	}{
		{func() error {
			return arm.Pair("shoulder", "revolute", blacksmith.FrameXY([3]float64{0, 0, 10}), blacksmith.PairOptions{})
		}, "pair: joint 'shoulder' already has a pair"},
		{func() error { return arm.Pair("back", "orbital", blacksmith.FrameXY([3]float64{}), blacksmith.PairOptions{}) },
			"pair: 'orbital' is not a pair kind (revolute, prismatic, cylindrical, screw, gear, rack_and_pinion, spherical, " +
				"spherical_with_pin, planar, universal, homokinetic, fully_constrained, unconstrained)"},
		{func() error { return arm.Pair("back", "screw", blacksmith.FrameXY([3]float64{}), blacksmith.PairOptions{}) },
			"pair: a screw needs a non-zero pitch"},
		{func() error {
			return arm.Pair("back", "revolute", blacksmith.FrameXY([3]float64{}),
				blacksmith.PairOptions{Ranges: []blacksmith.Range{{Lower: &negOne, Upper: &posOne}, {Lower: &negOne, Upper: &posOne}}})
		}, "pair: 'revolute' has 1 freedoms, but 2 ranges were given"},
		{func() error {
			return arm.Pair("back", "revolute", blacksmith.FrameXY([3]float64{}),
				blacksmith.PairOptions{Ranges: []blacksmith.Range{{Lower: &oneVal, Upper: &negOneVal}}})
		}, "pair: range 0 of joint 'back' has lower >= upper"},
		{func() error {
			return arm.Pair("back", "prismatic", turnedFrame, blacksmith.PairOptions{EndFrame: &backEndFrame})
		}, "pair: joint 'back' is prismatic, but its end frame is turned 90° about -z, " +
			"which prismatic (does not turn) cannot make"},
		{func() error {
			return arm.State("overreach", []blacksmith.StateRow{{Joint: "shoulder", Values: []float64{5.0}}})
		}, "state: value 0 of joint 'shoulder' is outside its range"},
		{func() error { return arm.Base("upper arm") }, "base: assembly 'arm' already has base 'ground'"},
	}
	for _, r := range pairRefusals {
		rerr := r.Call()
		if rerr == nil {
			fail(fmt.Sprintf("pairs: %q was accepted", r.Message))
		}
		if rerr.Error() != r.Message {
			fail(fmt.Sprintf("pairs: got %q, not %q", rerr.Error(), r.Message))
		}
	}
	fmt.Println("pairs: all eight bad pair/state/base calls are refused with their exact message")

	// Fact 8: after "back" alone (added above), StepText() is refused with exactly this
	// message -- Fact 7 already computed it as the before/after snapshot; checked here
	// against the brief's exact text.
	const noPairMessage = "assembly_step: assembly 'arm': joint 'back' has no pair; a mechanism with pairs needs one on every joint (AP242)"
	if pairedBefore != noPairMessage {
		fail(fmt.Sprintf("pairs: StepText()'s unpaired-joint refusal is %q, not the expected text", pairedBefore))
	}
	pairedAfter := pairedUnpairedMessage()
	if pairedAfter != pairedBefore {
		fail("pairs: a refused pair/state/base call changed the unpaired-joint refusal")
	}
	fmt.Println("pairs: joint 'back' with no pair refuses StepText() with exactly its message, unchanged by any refusal above")

	// Fact 9 (freedom-count half): PairFreedomCount.
	if blacksmith.PairFreedomCount("spherical") != 3 || blacksmith.PairFreedomCount("revolute") != 1 ||
		blacksmith.PairFreedomCount("fully_constrained") != 0 || blacksmith.PairFreedomCount("not_a_kind") != 0 {
		fail("pairs: PairFreedomCount does not give 3/1/0/0 for spherical/revolute/fully_constrained/unknown")
	}
	fmt.Println("pairs: PairFreedomCount gives 3/1/0/0 for spherical/revolute/fully_constrained/an unknown name")

	// Fact 10 (controller ruling, added after review): a one-sided range survives the
	// round trip. Without has_lower/has_upper actually carried (an implementation that
	// always sends true for both would pass every other fact), joint "j"'s freedom would
	// come back with a lower limit it was never given.
	hinge, err := blacksmith.NewAssembly("hinge")
	if err != nil {
		fail(err.Error())
	}
	if _, err := hinge.PlaceSolid(mechPlate, blacksmith.FrameXY([3]float64{}), "base"); err != nil {
		fail(err.Error())
	}
	if _, err := hinge.PlaceSolid(mechBolt, blacksmith.FrameXY([3]float64{0, 0, 2}), "arm"); err != nil {
		fail(err.Error())
	}
	if err := hinge.Link("base", []string{"base"}); err != nil {
		fail(err.Error())
	}
	if err := hinge.Link("arm", []string{"arm"}); err != nil {
		fail(err.Error())
	}
	if err := hinge.Joint("j", "base", "arm"); err != nil {
		fail(err.Error())
	}
	hingeUpper := 1.0
	if err := hinge.Pair("j", "revolute", blacksmith.FrameXY([3]float64{}),
		blacksmith.PairOptions{Ranges: []blacksmith.Range{{Upper: &hingeUpper}}}); err != nil {
		fail(err.Error())
	}
	hingeScene, err := hinge.ToScene("")
	if err != nil {
		fail(err.Error())
	}
	var hingeJoint *cadaclysm.Joint
	for _, j := range hingeScene.Joints() {
		if j.Name() == "j" {
			hingeJoint = j
		}
	}
	if hingeJoint == nil {
		fail("pairs: hinge joint 'j' not found")
	}
	hingePair := hingeJoint.Pair()
	if hingePair == nil {
		fail("pairs: hinge joint 'j' has no pair")
	}
	hingeFreedoms := hingePair.Freedoms()
	if len(hingeFreedoms) != 1 || hingeFreedoms[0].HasLower || !hingeFreedoms[0].HasUpper || !near(hingeFreedoms[0].Upper, 1.0) {
		fail("pairs: hinge joint 'j' is not one freedom with no lower limit and upper exactly 1.0")
	}
	fmt.Println("pairs: a one-sided range (no lower, upper 1.0) survives the round trip")
	hingeScene.Close()
	hinge.Close()
}

// radiusOf is the distance of the k-th control point of a Béziers64's Points from c.
func radiusOf(points []float64, k int, c [3]float64) float64 {
	dx, dy, dz := points[k*3]-c[0], points[k*3+1]-c[1], points[k*3+2]-c[2]
	return math.Sqrt(dx*dx + dy*dy + dz*dz)
}

// silhouette is Solid.SilhouetteBeziers and Node.SilhouetteBeziers: the curves where a
// body's surfaces turn away from the eye. The kernel assertions are on values that pin the
// layout, not only on lengths: a stride-16 unpack that reads a weight as a coordinate, or
// a points slice shifted by one, still gives arrays of the right length. path is the
// sample the smoke was given; the reader's fixtures are the repository's, beside it.
func silhouette(path string) {
	// The error slot is thread-local and the binding's pin() unlocks after each call, so without
	// this the refusal and the later ask below are not guaranteed to share an OS thread.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	// Kernel. A radius-2 sphere's rim: the end points of every arc lie ON the sphere
	// (radius 2 within 1e-9), and the end weights are exactly 1 with the two interior ones
	// in (0, 1). The interior points and weights are not
	// bounded tighter: they move with how the rim is subdivided.
	sphere, err := blacksmith.Sphere(2)
	if err != nil {
		fail(err.Error())
	}
	defer sphere.Close()
	rim, err := sphere.SilhouetteBeziers(nil)
	if err != nil {
		fail("silhouette: " + err.Error())
	}
	if rim.Count() == 0 {
		fail("silhouette: a sphere gave no rim")
	}
	if len(rim.Points) != rim.Count()*4*3 || len(rim.Weights) != rim.Count()*4 {
		fail(fmt.Sprintf("silhouette: %d curves but %d point numbers and %d weights", rim.Count(), len(rim.Points), len(rim.Weights)))
	}
	origin := [3]float64{}
	for c := 0; c < rim.Count(); c++ {
		r0, r3 := radiusOf(rim.Points, c*4, origin), radiusOf(rim.Points, c*4+3, origin)
		if math.Abs(r0-2) > 1e-9 || math.Abs(r3-2) > 1e-9 {
			fail(fmt.Sprintf("silhouette: arc %d end points are at radius %v and %v, not 2", c, r0, r3))
		}
		w := rim.Weights[c*4 : c*4+4]
		if w[0] != 1 || w[3] != 1 || !(w[1] > 0 && w[1] < 1) || !(w[2] > 0 && w[2] < 1) {
			fail(fmt.Sprintf("silhouette: arc %d weights are %v, not 1, then two weights in (0, 1), then 1", c, w))
		}
	}
	fmt.Printf("silhouette: a radius-2 sphere gives %d arcs, ends at radius 2, end weights 1\n", rim.Count())

	// A cylinder seen from the side is straight rulings: polynomial, every weight exactly
	// 1 -- the path a sphere never exercises.
	cylinder, err := blacksmith.Cylinder(1, 3)
	if err != nil {
		fail(err.Error())
	}
	defer cylinder.Close()
	front := blacksmith.NewSvgOptions()
	front.View = blacksmith.SvgFront
	rulings, err := cylinder.SilhouetteBeziers(&front)
	if err != nil {
		fail("silhouette: " + err.Error())
	}
	if rulings.Count() == 0 {
		fail("silhouette: a cylinder gave no rulings")
	}
	for i, w := range rulings.Weights {
		if w != 1 {
			fail(fmt.Sprintf("silhouette: a cylinder's weight %d is %v, not 1", i, w))
		}
	}
	low, high := math.Inf(1), math.Inf(-1)
	for k := 0; k < rulings.Count()*4; k++ {
		x, y, z := rulings.Points[k*3], rulings.Points[k*3+1], rulings.Points[k*3+2]
		low, high = math.Min(low, z), math.Max(high, z)
		if math.Abs(math.Hypot(x, y)-1) > 1e-6 {
			fail("silhouette: a ruling's control point is off the cylinder's wall")
		}
		// The axis. hypot(x, y) and the z extent are both symmetric in x and y, so an unpack that
		// returned [y, x, z] passes both; |x| at the radius and |y| at zero tell the two apart (seen from
		// the front a ruling sits at x = +-radius, y = 0). Only the magnitude of x is asserted, not its
		// sign, and the number of rulings is not asserted.
		if math.Abs(math.Abs(x)-1) > 1e-6 {
			fail(fmt.Sprintf("silhouette: a ruling's control point has |x| = %v, not the radius 1", math.Abs(x)))
		}
		if math.Abs(y) > 1e-6 {
			fail(fmt.Sprintf("silhouette: a ruling's control point has |y| = %v, not 0", math.Abs(y)))
		}
	}
	// The rulings run cap to cap, so their z extent is the height: that pins z against x and y.
	if math.Abs(high-low-3) > 1e-6 {
		fail(fmt.Sprintf("silhouette: the rulings span z %v..%v, not a height of 3", low, high))
	}

	// An infinite tolerance is refused in the library's words; and the refusal left in the error slot must not
	// turn a later empty answer into an error. The cuboid is built BEFORE the refusal, not between it and the
	// ask: every call that builds, reads or writes geometry in the library runs under its `guard`, whose first
	// act is `clear_error` (blacksmith-capi lib.rs:117), so building one in between would wipe the refusal's
	// message. The order is build, refuse, ask. What this pins is narrower than it looks, though: the slot is
	// already clear when the silhouette's native call begins, because the wrapper first packs its options and
	// packing the default stroke "#000000" goes through `cadaclysm_blacksmith_parse_colour`, itself a `guard`
	// (lib.rs:200) that clears it (Go `buildSvgOptions` -> `parseSvgColour` -> `RGB` ->
	// `cadaclysm_blacksmith_parse_colour`). `cadaclysm_blacksmith_svg_options_init` is a bare struct fill and
	// does not clear. So the test pins that the wrapper must not read the slot BEFORE packing its options: a
	// read there fails it, while a read placed after packing and before the native call would pass. The
	// library's own clearing at the silhouette's entry is a library property, pinned for the reader's entry
	// point by `an_empty_answer_after_a_refusal_carries_no_stale_error`
	// (crates/cadaclysm-capi/tests/silhouette_abi.rs:401); this test covers the wrapper's half. Only
	// calls under `guard` clear: `cadaclysm_blacksmith_solid_free` and
	// `cadaclysm_blacksmith_silhouette_beziers_free` just drop a box and the error getter does not clear
	// either, so a free running between the refusal and the ask cannot wipe the slot.
	cuboid, err := blacksmith.Cuboid(10, 10, 10)
	if err != nil {
		fail(err.Error())
	}
	defer cuboid.Close()
	infinite := blacksmith.NewSvgOptions()
	infinite.Tolerance = math.Inf(1)
	if _, err := sphere.SilhouetteBeziers(&infinite); err == nil || !strings.Contains(err.Error(), "silhouette: ") {
		fail(fmt.Sprintf("silhouette: an infinite tolerance was not refused with \"silhouette: \": %v", err))
	}
	none, err := cuboid.SilhouetteBeziers(nil)
	if err != nil {
		fail("silhouette: an all-planar body was an error: " + err.Error())
	}
	if none.Count() != 0 || len(none.Points) != 0 || len(none.Weights) != 0 {
		fail("silhouette: an all-planar body gave a silhouette")
	}
	fmt.Println("silhouette: cylinder rulings all weight 1, infinite tolerance refused, a planar body is the empty answer")

	// Reader. The fixtures are the repository's, not an SDK checkout's, so this runs where found.
	fixtures := filepath.Join(filepath.Dir(filepath.Dir(mustAbs(path))), "crates", "cadaclysm-acis", "tests", "fixtures", "rhino")
	spherePath := filepath.Join(fixtures, "sphere.sat")
	boxPath := filepath.Join(fixtures, "box-chamfer-all.blacksmith.stp")
	if _, err := os.Stat(spherePath); err != nil {
		fmt.Println("silhouette (reader): skipped, no fixtures beside the sample:", spherePath)
		return
	}
	if _, err := os.Stat(boxPath); err != nil {
		fmt.Println("silhouette (reader): skipped, no fixtures beside the sample:", boxPath)
		return
	}
	// The body node above the lump holds no shape of its own; the first node with extent
	// is the part.
	partOf := func(scene *cadaclysm.Scene) *cadaclysm.Node {
		for _, node := range scene.Walk() {
			if b := node.Bounds64(); b.Min != b.Max {
				return node
			}
		}
		fail("silhouette (reader): no node with extent in the scene")
		return nil
	}
	readerScene, err := cadaclysm.Open(spherePath)
	if err != nil {
		fail(err.Error())
	}
	defer readerScene.Close()
	node := partOf(readerScene)
	// Asked the LARGER answer first: iso gives 236 curves against front's 174, so the
	// second call below refills the scene's one slot in place and overwrites the head of
	// what was kept, which is what makes a non-copying implementation fail loudly. The
	// reverse order can pass with a view. It was front first until the lattice's spacing
	// became a length in space (44efabc88): front gave 1248 against iso's 1210 then.
	isoView := cadaclysm.NewSvgOptions()
	isoView.View = cadaclysm.SvgIso
	first, err := node.SilhouetteBeziers(&isoView)
	if err != nil {
		fail("silhouette (reader): " + err.Error())
	}
	if first.Count() == 0 {
		fail("silhouette (reader): a sphere gave no rim")
	}
	if len(first.Points) != first.Count()*4*3 || len(first.Weights) != first.Count()*4 {
		fail("silhouette (reader): the arrays are not count*4*3 and count*4")
	}
	for _, w := range first.Weights {
		if math.IsNaN(w) || math.IsInf(w, 0) || w <= 0 {
			fail(fmt.Sprintf("silhouette (reader): a weight is %v, not finite and positive", w))
		}
	}
	// Every control point lies within the library's fit budget of the sphere, at the bounds radius
	// from the bounds centre. That is NOT because control points lie on the sphere: the silhouette
	// curve does, but a cubic's interior control points do not. It holds because the arcs are short
	// (half a unit on a radius of 10), and the budget is the tolerance the library fits the CURVE to,
	// not its control polygon. The margin is narrow: the curve itself uses nearly the whole budget
	// (3.42e-3 against 3.46e-3) since the lattice's spacing became a length in space (44efabc88);
	// before, a lattice ten times too fine left it at 1e-4. So this
	// catches a displaced or scaled result and a wildly mis-strided unpack. What it does with a slip
	// of the unpack was measured here as the worst radius DEVIATION of any control point from the
	// sphere's radius 10 (budget about 3.5e-3): a correct read deviates by 3.04e-3 on iso and 2.97e-3 on
	// front; a one-double wrap slip by 0.87 on iso and 8.8 on front, over the budget at either view;
	// a one-CONTROL-POINT slip by exactly the correct read's figure at either view, because it only
	// moves whole points. So this catches a one-double slip but can never catch a one-control-point
	// slip, which is why the chaining assertion below is the only one that does. This test asks iso,
	// because the ownership order below forces it. It also does NOT pin the eye or `up` (a silhouette
	// point is a point of the surface, so it is on the sphere from any view), the node choice (a wrong
	// node fails earlier, as a refusal or an empty answer), or the weights (all 1.0 on this fixture:
	// degree-1 chords). The bound is the library's own budget: it fits the silhouette to within
	// `extent * tolerance / width` (`world_tolerance`, capi svg.rs), the extent being the bounds'
	// diagonal. Measured on the iso view this test asks, the radius deviation is 3.04e-3 on a radius
	// of 10 (front: 2.97e-3). The budget is read off the options this call was given, not copied from
	// their defaults; the library's extent is the box of the body's sampled feature edges, falling
	// back to declared bounds only when there are none, and the node's bounds diagonal stands in for
	// it here, which can be looser than that box.
	b := node.Bounds64()
	centre := [3]float64{(b.Min[0] + b.Max[0]) / 2, (b.Min[1] + b.Max[1]) / 2, (b.Min[2] + b.Max[2]) / 2}
	radius := (b.Max[0] - b.Min[0]) / 2
	diagonal := math.Sqrt(math.Pow(b.Max[0]-b.Min[0], 2) + math.Pow(b.Max[1]-b.Min[1], 2) + math.Pow(b.Max[2]-b.Min[2], 2))
	budget := diagonal * (isoView.Tolerance / isoView.Width)
	worst := 0.0
	for k := 0; k < first.Count()*4; k++ {
		worst = math.Max(worst, math.Abs(radiusOf(first.Points, k, centre)-radius))
	}
	if radius <= 0 || worst > budget {
		fail(fmt.Sprintf("silhouette (reader): control points stray %v from the bounds centre's radius %v, past the budget %v", worst, radius, budget))
	}
	keepPoints := append([]float64(nil), first.Points...)
	keepWeights := append([]float64(nil), first.Weights...)
	// The next silhouette call on this scene refills the library's one slot in place.
	frontView := cadaclysm.NewSvgOptions()
	frontView.View = cadaclysm.SvgFront
	second, err := node.SilhouetteBeziers(&frontView)
	if err != nil {
		fail("silhouette (reader): " + err.Error())
	}
	if second.Count() == 0 {
		fail("silhouette (reader): the second view gave no rim")
	}
	if second.Count() > first.Count() {
		fail(fmt.Sprintf("silhouette (reader): the larger answer must come first (iso %d, front %d)", first.Count(), second.Count()))
	}
	if slices.Equal(second.Points, keepPoints) {
		fail("silhouette (reader): the two views gave the same silhouette, so this cannot tell a copy from a view")
	}
	if !slices.Equal(first.Points, keepPoints) {
		fail("silhouette (reader): the first answer's points changed when the second was asked")
	}
	if !slices.Equal(first.Weights, keepWeights) {
		fail("silhouette (reader): the first answer's weights changed when the second was asked")
	}
	// Chaining, the assertion that sees an offset slip; asked of the iso answer, whose
	// figures are quoted here (the front view chains much less). Count the consecutive
	// pairs whose last control point equals the next curve's first, to 1e-9 per coordinate
	// (x, y and z each, so a passing pair can be up to 1.73e-9 apart). The arcs come back in
	// RUNS, not as one ordered traversal, so "every arc ends where the next begins" is false
	// and this is a count with a margin, not an identity: measured on iso, 232 of the 235
	// consecutive pairs chain (98.7%, four runs); the front view chains 96 of 173 (55%), which
	// is why the eye matters and the bound is 80, not near 230. A read shifted by one double or
	// by one control point leaves none (0 of 235 each). Those are wrap-around slips, which
	// preserve the length and the count, so each denominator is the unshifted pair count (a
	// truncating slip loses a curve and drops it by one). The count varies with how the
	// sphere is tessellated; what makes a lower bound of 80 safe is not that it cannot
	// drift but that it sits about three times below the count measured here. It has drifted
	// once: the bound was 400 against 1206 of 1209 until the lattice's spacing became a length
	// in space (44efabc88) and the same four runs came back in arcs five times longer.
	// Its limit: a shift by a whole CURVE (12 doubles) is NOT caught, because it preserves the
	// chaining: 231 of 235 pairs still chain on iso, since every arc is replaced by its neighbour's
	// and the neighbours still join.
	if len(second.Points) != second.Count()*4*3 || len(second.Weights) != second.Count()*4 {
		fail("silhouette (reader): the front arrays are not count*4*3 and count*4")
	}
	for _, w := range second.Weights {
		if math.IsNaN(w) || math.IsInf(w, 0) || w <= 0 {
			fail(fmt.Sprintf("silhouette (reader): a front weight is %v, not finite and positive", w))
		}
	}
	chained := 0
	for c := 0; c+1 < first.Count(); c++ {
		last, next := c*12+9, (c+1)*12
		if math.Abs(first.Points[last]-first.Points[next]) <= 1e-9 &&
			math.Abs(first.Points[last+1]-first.Points[next+1]) <= 1e-9 &&
			math.Abs(first.Points[last+2]-first.Points[next+2]) <= 1e-9 {
			chained++
		}
	}
	if chained < 80 {
		fail(fmt.Sprintf("silhouette (reader): only %d of %d consecutive arcs chain (last control point = the next one's first), want at least 80", chained, first.Count()-1))
	}
	badTolerance := cadaclysm.NewSvgOptions()
	badTolerance.Tolerance = math.Inf(1)
	if _, err := node.SilhouetteBeziers(&badTolerance); err == nil || !strings.Contains(err.Error(), "silhouette: ") {
		fail(fmt.Sprintf("silhouette (reader): an infinite tolerance was not refused with \"silhouette: \": %v", err))
	}

	// A planar body: the empty answer, after a refusal has left its reason in the slot.
	boxScene, err := cadaclysm.Open(boxPath)
	if err != nil {
		fail(err.Error())
	}
	defer boxScene.Close()
	boxNode := partOf(boxScene)
	if _, err := boxNode.SilhouetteBeziers(&badTolerance); err == nil {
		fail("silhouette (reader): an infinite tolerance was accepted on the box")
	}
	boxAnswer, err := boxNode.SilhouetteBeziers(nil)
	if err != nil {
		fail("silhouette (reader): an all-planar body was an error: " + err.Error())
	}
	if boxAnswer.Count() != 0 || len(boxAnswer.Points) != 0 || len(boxAnswer.Weights) != 0 {
		fail("silhouette (reader): an all-planar body gave a silhouette")
	}
	fmt.Printf("silhouette (reader): sphere %d then %d curves (worst radius error %.3g of budget %.3g), first answer kept; infinite tolerance refused; planar box empty\n",
		first.Count(), second.Count(), worst, budget)
}

func mustAbs(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		fail(err.Error())
	}
	return abs
}

func fail(why string) {
	fmt.Fprintln(os.Stderr, why)
	os.Exit(1)
}

// mustPositions is Mesh.Positions with the error folded into fail, for a smoke check
// that just wants the slice.
func mustPositions(m *blacksmith.Mesh) []float32 {
	p, err := m.Positions()
	if err != nil {
		fail(err.Error())
	}
	return p
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
		crossings, err := mesh.Crossings()
		if err != nil {
			fail("fem: " + err.Error())
		}
		if !mesh.Watertight || len(open) != 0 || len(folded) != 0 || len(crossings) != 0 {
			fail(fmt.Sprintf("fem: the closed cube reads %d cracks, %d folds and %d crossings", len(open), len(folded), len(crossings)))
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
		func() error { _, e := spent.Crossings(); return e },
		func() error { _, e := spent.MshText(); return e },
		func() error { return spent.SaveMsh(mshPath) },
	}
	if len(reads) != 7 {
		fail("fem: the closed-handle sweep is not all seven calls that take the handle")
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
	fmt.Printf("fem (reader): %v, minAngle %.2f, longestEdge %.3f; a closed mesh refuses all seven calls\n",
		mesh, mesh.MinAngle, mesh.LongestEdge)
	if strings.HasSuffix(path, "cube.scad") {
		femCensusWiring(filepath.Join(filepath.Dir(path), "open-sheet.scad"))
		femCrossings(filepath.Join(filepath.Dir(path), "dented-box.stp"))
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

// femCrossings pins samples/dented-box.stp: a closed B-rep box whose top dips through its
// own floor, 296 pairs measured 2026-09-26 -- once through this reader, and once through
// the kernel's own open of the same file, which must agree with it.
func femCrossings(dentedBox string) {
	scene, err := cadaclysm.Open(dentedBox)
	if err != nil {
		fail("fem crossings: " + err.Error())
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
		fail("fem crossings: dented-box.stp has no meshable node")
	}
	mesh, err := body.FemMesh(0.01, 0, nil)
	if err != nil {
		fail("fem crossings: " + err.Error())
	}
	defer mesh.Close()
	if !mesh.Watertight || mesh.FromMesh {
		fail("fem crossings: dented-box.stp reads " + mesh.String() + ", not a watertight brep")
	}
	crossings, err := mesh.Crossings()
	if err != nil {
		fail("fem crossings: " + err.Error())
	}
	if len(crossings) != 296 {
		fail(fmt.Sprintf("fem crossings: dented-box.stp reads %d pairs, not 296", len(crossings)))
	}
	if crossings[0][0] >= crossings[0][1] {
		fail(fmt.Sprintf("fem crossings: the first pair reads %v, not a < b", crossings[0]))
	}
	kernelSolid, err := blacksmith.Open(dentedBox)
	if err != nil {
		fail("kernel fem crossings: " + err.Error())
	}
	defer kernelSolid.Close()
	kernelMesh, err := kernelSolid.FemMesh(0.01, 0, nil)
	if err != nil {
		fail("kernel fem crossings: " + err.Error())
	}
	defer kernelMesh.Close()
	kernelCrossings, err := kernelMesh.Crossings()
	if err != nil {
		fail("kernel fem crossings: " + err.Error())
	}
	if len(kernelCrossings) != 296 {
		fail(fmt.Sprintf("kernel fem crossings: dented-box.stp reads %d pairs, not 296", len(kernelCrossings)))
	}
	fmt.Printf("fem crossings: dented-box.stp reads %d pairs through the reader and %d through the kernel\n",
		len(crossings), len(kernelCrossings))
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
	crossings, err := mesh.Crossings()
	if err != nil {
		fail("kernel fem: " + err.Error())
	}
	if len(open) != 0 || len(folded) != 0 || len(crossings) != 0 {
		fail(fmt.Sprintf("kernel fem: a watertight solid reads %d cracks, %d folds and %d crossings", len(open), len(folded), len(crossings)))
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
		func() error { _, e := spent.Crossings(); return e },
		func() error { _, e := spent.MshText(); return e },
		func() error { return spent.SaveMsh(kernelMshPath) },
	}
	if len(reads) != 7 {
		fail("kernel fem: the closed-handle sweep is not all seven calls that take the handle")
	}
	for i, read := range reads {
		if err := read(); !errors.Is(err, blacksmith.ErrClosed) {
			fail(fmt.Sprintf("kernel fem: closed read %d refused with %v, not ErrClosed", i, err))
		}
	}
	fmt.Printf("kernel fem: %v, maxSize 3 -> %d nodes, longestEdge %.3f; the sheet's rim reads 0/NONE; a closed mesh refuses all seven calls\n",
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

// footprint is a profile's [x0, x1, y0, y1], read off the bounds of it extruded 1, at a
// fine tolerance.
func footprint(p *blacksmith.Profile) [4]float64 {
	solid, err := blacksmith.XY().Extrude(p, 1).Solid()
	if err != nil {
		fail(err.Error())
	}
	defer solid.Close()
	b, err := solid.BoundsAt(0.001)
	if err != nil {
		fail(err.Error())
	}
	return [4]float64{b.Min[0], b.Max[0], b.Min[1], b.Max[1]}
}

// near4 is whether every one of a's four numbers is within tolerance of b's.
func near4(a, b [4]float64, tolerance float64) bool {
	for i := range a {
		if math.Abs(a[i]-b[i]) > tolerance {
			return false
		}
	}
	return true
}

// pocketedBlock is a 40x30x10 block on z=0 with a 20x10 pocket 8 deep: four corners a 6 mm
// end mill misses.
func pocketedBlock() *blacksmith.Solid {
	block0, err := blacksmith.Cuboid(40, 30, 10)
	if err != nil {
		fail(err.Error())
	}
	defer block0.Close()
	block, err := block0.Translate(0, 0, 5)
	if err != nil {
		fail(err.Error())
	}
	defer block.Close()
	pocket0, err := blacksmith.Cuboid(20, 10, 8)
	if err != nil {
		fail(err.Error())
	}
	defer pocket0.Close()
	pocket, err := pocket0.Translate(0, 0, 6)
	if err != nil {
		fail(err.Error())
	}
	defer pocket.Close()
	out, err := block.Cut(pocket, blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	return out
}

// machining: the Python SDK's to_arcs, offset and section, then Tool, Stock and Job -- the
// fixtures of test_cadaclysm_blacksmith.py's "machining" block and Node's pocketedBlock on.
func machining() {
	rect2010, err := blacksmith.Rect(20, 10)
	if err != nil {
		fail(err.Error())
	}
	defer rect2010.Close()
	grown, err := rect2010.Offset(2, 0.01)
	if err != nil {
		fail(err.Error())
	}
	if len(grown) != 1 || !near4(footprint(grown[0]), [4]float64{-12, 12, -7, 7}, 1e-3) {
		fail(fmt.Sprintf("offset: grown by 2 is %d profile(s)", len(grown)))
	}
	grown[0].Close()
	shrunk, err := rect2010.Offset(-2, 0.01)
	if err != nil {
		fail(err.Error())
	}
	if len(shrunk) != 1 || !near4(footprint(shrunk[0]), [4]float64{-8, 8, -3, 3}, 1e-3) {
		fail("offset: shrunk by 2 is not one profile over [-8, 8, -3, 3]")
	}
	shrunk[0].Close()
	eaten, err := rect2010.Offset(-6, 0.01)
	if err != nil {
		fail(err.Error())
	}
	if len(eaten) != 0 {
		fail("offset: a shrink past half the width left something")
	}
	if _, err := rect2010.Offset(math.NaN(), 0.01); err == nil || err.Error() != "profile_offset: distance must be finite" {
		fail(fmt.Sprintf("offset: a NaN distance was accepted or refused in other words: %v", err))
	}
	fmt.Println("offset: grown to [-12, 12, -7, 7], shrunk to [-8, 8, -3, 3], eaten at -6, NaN refused")

	spline, err := blacksmith.Spline([][2]float64{{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, nil, true)
	if err != nil {
		fail(err.Error())
	}
	defer spline.Close()
	fitted, err := spline.ToArcs(0.01)
	if err != nil {
		fail(err.Error())
	}
	if !near4(footprint(fitted), footprint(spline), 0.011) {
		fail("to_arcs: the fit's footprint is not within 0.011 of the spline's")
	}
	fitted.Close()
	if _, err := spline.ToArcs(0); err == nil || err.Error() != "profile_to_arcs: tolerance must be positive and finite" {
		fail(fmt.Sprintf("to_arcs: a zero tolerance was accepted or refused in other words: %v", err))
	}
	fmt.Println("to_arcs: the fit bounds the spline within 0.011, zero tolerance refused")

	box2010, err := blacksmith.Cuboid(20, 10, 5)
	if err != nil {
		fail(err.Error())
	}
	defer box2010.Close()
	middle, err := box2010.Section(0, 0.05)
	if err != nil {
		fail(err.Error())
	}
	if len(middle) != 1 || !near4(footprint(middle[0]), [4]float64{-10, 10, -5, 5}, 1e-3) {
		fail("section: the box's middle is not one profile over [-10, 10, -5, 5]")
	}
	middle[0].Close()
	miss, err := box2010.Section(50, 0.05)
	if err != nil {
		fail(err.Error())
	}
	if len(miss) != 0 {
		fail("section: a plane missing the box cut something")
	}
	if _, err := box2010.Section(2.5, 0.05); err == nil ||
		err.Error() != "solid_section: a face lies in the plane -- section a little above or below it" {
		fail(fmt.Sprintf("section: a plane on the top face was accepted or refused in other words: %v", err))
	}
	fmt.Println("section: the box's middle, a miss above it, a face in the plane refused")

	// The pocketed block: a 6 mm end mill is too big for the pocket's four square corners.
	block := pocketedBlock()
	defer block.Close()
	endMill, err := blacksmith.ToolFlat(1, 6, 20, 800, 200, 12000, 3.0)
	if err != nil {
		fail(err.Error())
	}
	defer endMill.Close()
	blockStock, err := blacksmith.StockAround(block, 2)
	if err != nil {
		fail(err.Error())
	}
	job, err := blacksmith.NewJob(blockStock, 30, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
		blacksmith.JobDefaultName, blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
	if err != nil {
		fail(err.Error())
	}
	defer job.Close()
	report, err := job.Machine(block, endMill, nil, nil, nil, 0.3, nil)
	if err != nil {
		fail(err.Error())
	}
	if len(report.Items) != 4 {
		fail(fmt.Sprintf("machine: the pocketed block reports %d item(s), not 4:\n%s", len(report.Items), report.Text))
	}
	if report.String() != report.Text || len(strings.Split(report.Text, "\n")) != 4 {
		fail(fmt.Sprintf("machine: the report's text is not four lines:\n%s", report.Text))
	}
	for _, item := range report.Items {
		if item.Kind != "corner" || !(item.Size > 0) || len(item.Region) == 0 || item.Reason == "" {
			fail(fmt.Sprintf("machine: %v is not a corner with a location, a size and a region", item))
		}
		for _, r := range item.Region {
			r.Close()
		}
	}
	ops, err := job.Operations()
	if err != nil {
		fail(err.Error())
	}
	if len(ops) == 0 {
		fail("machine: the pocketed block's operations are missing")
	}
	for _, o := range ops {
		if o.Kind == "" || o.Tool != 1 || len(o.Params) == 0 {
			fail(fmt.Sprintf("machine: %v is missing a kind, a tool or params", o))
		}
	}
	fmt.Printf("machine: the pocketed block leaves four corners, %d operations (%v)\n", len(ops), report.Items[0])

	// A drill as the end mill is refused, and leaves the job as it was.
	drill5, err := blacksmith.ToolDrill(2, 5, 30, 150, 3000)
	if err != nil {
		fail(err.Error())
	}
	defer drill5.Close()
	freshStock, err := blacksmith.StockAround(block, 2)
	if err != nil {
		fail(err.Error())
	}
	fresh, err := blacksmith.NewJob(freshStock, 30, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
		blacksmith.JobDefaultName, blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
	if err != nil {
		fail(err.Error())
	}
	if _, err := fresh.Machine(block, drill5, nil, nil, nil, 0.3, nil); err == nil ||
		!strings.Contains(err.Error(), "end mill must not be a drill") {
		fail(fmt.Sprintf("machine: a drill as the end mill was accepted or refused in other words: %v", err))
	}
	freshOps, err := fresh.Operations()
	if err != nil {
		fail(err.Error())
	}
	if len(freshOps) != 0 {
		fail("machine: a refused call changed the job")
	}

	// A closed job refuses every later call.
	fresh.Close()
	fresh.Close() // idempotent
	if !fresh.Closed() {
		fail("job: closed but Closed() is false")
	}
	if _, err := fresh.Machine(block, endMill, nil, nil, nil, 0.3, nil); err == nil || !errors.Is(err, blacksmith.ErrClosed) {
		fail(fmt.Sprintf("job: machine() after Close() was accepted or the wrong error: %v", err))
	}
	if _, err := fresh.Operations(); err == nil || !errors.Is(err, blacksmith.ErrClosed) {
		fail(fmt.Sprintf("job: operations() after Close() was accepted or the wrong error: %v", err))
	}
	if _, err := fresh.Gcode(); err == nil || !errors.Is(err, blacksmith.ErrClosed) {
		fail(fmt.Sprintf("job: gcode() after Close() was accepted or the wrong error: %v", err))
	}
	fmt.Println("machine: a drill as the end mill refused, the job unchanged; a closed job refuses")

	// Rest machining: the Z range of each item (W2), a list of end mills (W1), an empty
	// list (W3) and a nil element (W4).
	for _, item := range report.Items {
		if math.Abs(item.Top-10) > 1e-6 || math.Abs(item.Bottom-2) > 1e-6 {
			fail(fmt.Sprintf("machine: item top/bottom are %v/%v, not 10/2", item.Top, item.Bottom))
		}
	}
	small, err := blacksmith.ToolFlat(2, 2.0, 20.0, 800.0, 200.0, 12000.0, 3.0)
	if err != nil {
		fail(err.Error())
	}
	defer small.Close()
	restStock, err := blacksmith.StockAround(block, 2)
	if err != nil {
		fail(err.Error())
	}
	restJob, err := blacksmith.NewJob(restStock, 30, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
		blacksmith.JobDefaultName, blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
	if err != nil {
		fail(err.Error())
	}
	defer restJob.Close()
	restReport, err := restJob.MachineWith(block, []*blacksmith.Tool{endMill, small}, nil, nil, nil, 0.3, nil)
	if err != nil {
		fail(err.Error())
	}
	if len(restReport.Items) != 4 {
		fail(fmt.Sprintf("machine_with: %d item(s), not 4:\n%s", len(restReport.Items), restReport.Text))
	}
	for _, item := range restReport.Items {
		if !strings.Contains(item.Reason, "T2 (2 mm)") {
			fail(fmt.Sprintf("machine_with: reason does not name T2 (2 mm): %s", item.Reason))
		}
		if math.Abs(item.Top-10) > 1e-6 || math.Abs(item.Bottom-2) > 1e-6 {
			fail(fmt.Sprintf("machine_with: item top/bottom are %v/%v, not 10/2", item.Top, item.Bottom))
		}
	}
	restOps, err := restJob.Operations()
	if err != nil {
		fail(err.Error())
	}
	pocketsWithT2 := 0
	for _, o := range restOps {
		if o.Kind == "pocket" && o.Tool == 2 {
			pocketsWithT2++
		}
	}
	if pocketsWithT2 == 0 {
		fail("machine_with: no pocket operation uses tool 2")
	}
	noMillStock, err := blacksmith.StockAround(block, 2)
	if err != nil {
		fail(err.Error())
	}
	noMillJob, err := blacksmith.NewJob(noMillStock, 30, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
		blacksmith.JobDefaultName, blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
	if err != nil {
		fail(err.Error())
	}
	defer noMillJob.Close()
	if _, err := noMillJob.MachineWith(block, nil, nil, nil, nil, 0.3, nil); err == nil ||
		!strings.Contains(err.Error(), "machine: at least one end mill is needed") {
		fail(fmt.Sprintf("machine_with: an empty list was accepted or refused in other words: %v", err))
	}
	if _, err := noMillJob.MachineWith(block, []*blacksmith.Tool{endMill, nil}, nil, nil, nil, 0.3, nil); err == nil ||
		!strings.Contains(err.Error(), "job_machine_with: null end mill 1") {
		fail(fmt.Sprintf("machine_with: a nil end mill was accepted or refused in other words: %v", err))
	}
	noMillOps, err := noMillJob.Operations()
	if err != nil {
		fail(err.Error())
	}
	if len(noMillOps) != 0 {
		fail("machine_with: a refused call changed the job")
	}
	fmt.Println("machine_with: two end mills leave four corners naming T2, z 10 down to 2; empty and nil lists refused")

	// The plate of spec 2026-09-28: machined cleanly by one end mill and one drill.
	plateOutline0, err := blacksmith.Rect(80, 50)
	if err != nil {
		fail(err.Error())
	}
	plateOutline, err := plateOutline0.Round(6, nil, false)
	plateOutline0.Close()
	if err != nil {
		fail(err.Error())
	}
	defer plateOutline.Close()
	platePart, err := blacksmith.XY().Extrude(plateOutline, 12).Solid()
	if err != nil {
		fail(err.Error())
	}
	pocketOutline0, err := blacksmith.Rect(40, 24)
	if err != nil {
		fail(err.Error())
	}
	pocketOutline1, err := pocketOutline0.Round(4, nil, false)
	pocketOutline0.Close()
	if err != nil {
		fail(err.Error())
	}
	pocketHole, err := blacksmith.Circle(5)
	if err != nil {
		fail(err.Error())
	}
	pocketOutline, err := pocketOutline1.WithHole(pocketHole)
	pocketOutline1.Close()
	pocketHole.Close()
	if err != nil {
		fail(err.Error())
	}
	pocketSolid, err := blacksmith.Extrude(pocketOutline, blacksmith.FrameXY([3]float64{0, 0, 7}), 5)
	pocketOutline.Close()
	if err != nil {
		fail(err.Error())
	}
	was := platePart
	platePart, err = was.Cut(pocketSolid, blacksmith.DefaultTolerance)
	was.Close()
	pocketSolid.Close()
	if err != nil {
		fail(err.Error())
	}
	for _, xy := range [][2]float64{{-32, -17}, {-32, 17}, {32, -17}, {32, 17}} {
		bore0, err := blacksmith.Cylinder(3, 12)
		if err != nil {
			fail(err.Error())
		}
		bore, err := bore0.Translate(xy[0], xy[1], 0)
		bore0.Close()
		if err != nil {
			fail(err.Error())
		}
		was := platePart
		platePart, err = was.Cut(bore, blacksmith.DefaultTolerance)
		was.Close()
		bore.Close()
		if err != nil {
			fail(err.Error())
		}
	}
	defer platePart.Close()

	plateDrill, err := blacksmith.ToolDrill(2, 6, 30, 150, 3000)
	if err != nil {
		fail(err.Error())
	}
	defer plateDrill.Close()
	plateStock, err := blacksmith.StockAround(platePart, 3)
	if err != nil {
		fail(err.Error())
	}
	plateJob, err := blacksmith.NewJob(plateStock, 25, 1.0, 0.01, "plate", blacksmith.JobDefaultSpindleDwell,
		blacksmith.JobDefaultResolution)
	if err != nil {
		fail(err.Error())
	}
	defer plateJob.Close()
	plateReport, err := plateJob.Machine(platePart, endMill, []*blacksmith.Tool{plateDrill}, nil, nil, 0.3, nil)
	if err != nil {
		fail(err.Error())
	}
	if len(plateReport.Items) != 0 || plateReport.Text != "nothing left uncut" {
		fail(fmt.Sprintf("plate: the report is not empty:\n%s", plateReport.Text))
	}
	plateOps, err := plateJob.Operations()
	if err != nil {
		fail(err.Error())
	}
	if len(plateOps) == 0 || plateOps[0].Kind != "face" {
		fail(fmt.Sprintf("plate: the operations do not start with face: %v", plateOps))
	}
	hasPocket := false
	for _, o := range plateOps {
		if o.Kind == "pocket" {
			hasPocket = true
		}
	}
	last := plateOps[len(plateOps)-1]
	if !hasPocket || last.Kind != "drill" {
		fail(fmt.Sprintf("plate: the operations are wrong: %v", plateOps))
	}
	if points := last.Params["points"]; points == nil || *points != 4 {
		fail(fmt.Sprintf("plate: the drill's params are %v", last))
	}
	if peck, ok := last.Params["peck"]; !ok || peck != nil {
		fail(fmt.Sprintf("plate: the drill's params are %v", last))
	}
	platePrograms, err := plateJob.Gcode()
	if err != nil {
		fail(err.Error())
	}
	if len(platePrograms) != 2 {
		fail(fmt.Sprintf("plate: gcode() gives %v", platePrograms))
	}
	for _, p := range platePrograms {
		if p.Tool < 1 || p.Name == "" || p.Text == "" {
			fail(fmt.Sprintf("plate: gcode() gives %v", platePrograms))
		}
	}
	folder := filepath.Join(os.TempDir(), fmt.Sprintf("cadaclysm-smoke-cam-go-%d", os.Getpid()))
	defer os.RemoveAll(folder)
	written, err := plateJob.WriteCamotics(filepath.Join(folder, "plate.camotics"))
	if err != nil {
		fail(err.Error())
	}
	if len(written) == 0 || !strings.HasSuffix(written[len(written)-1], "plate.camotics") {
		fail(fmt.Sprintf("plate: write_camotics wrote %v", written))
	}
	for _, w := range written {
		if _, statErr := os.Stat(w); statErr != nil {
			fail(fmt.Sprintf("plate: write_camotics wrote %s (missing): %v", w, statErr))
		}
	}
	// a stem that is all extension stays whole, as Python's Path.stem keeps it
	dotFolder := filepath.Join(os.TempDir(), fmt.Sprintf("cadaclysm-smoke-dot-go-%d", os.Getpid()))
	defer os.RemoveAll(dotFolder)
	dotWritten, err := plateJob.WriteCamotics(filepath.Join(dotFolder, ".camotics"))
	if err != nil {
		fail(err.Error())
	}
	if len(dotWritten) < 2 || !strings.HasPrefix(filepath.Base(dotWritten[0]), ".camotics-T1") {
		fail(fmt.Sprintf("write_camotics: the stem of \".camotics\" is not kept: %v", dotWritten))
	}
	fmt.Printf("plate: nothing left uncut, %d operations, %d programs, %d CAMotics files\n",
		len(plateOps), len(platePrograms), len(written))

	// The four verbs by hand -- the spec's own example -- and the refusals in the kernel's words.
	specOutline0, err := blacksmith.Rect(60, 40)
	if err != nil {
		fail(err.Error())
	}
	specOutline, err := specOutline0.Round(5, nil, false)
	specOutline0.Close()
	if err != nil {
		fail(err.Error())
	}
	defer specOutline.Close()
	specPart, err := blacksmith.XY().Extrude(specOutline, 20).Solid()
	if err != nil {
		fail(err.Error())
	}
	defer specPart.Close()
	end, err := blacksmith.ToolFlat(1, 6, 20, 800, 200, 12000, 3.0)
	if err != nil {
		fail(err.Error())
	}
	defer end.Close()
	specDrill, err := blacksmith.ToolDrill(2, 5, 30, 150, 3000)
	if err != nil {
		fail(err.Error())
	}
	defer specDrill.Close()
	specStock, err := blacksmith.StockAround(specPart, 2)
	if err != nil {
		fail(err.Error())
	}
	specJob, err := blacksmith.NewJob(specStock, 30, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
		blacksmith.JobDefaultName, blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
	if err != nil {
		fail(err.Error())
	}
	defer specJob.Close()
	if err := specJob.Face(end, 20, 3, 1); err != nil {
		fail(err.Error())
	}
	if err := specJob.Contour(end, specOutline, 20, 0, "outside", 2, true, false); err != nil {
		fail(err.Error())
	}
	levels, err := specPart.Section(15, 0.05)
	if err != nil {
		fail(err.Error())
	}
	if len(levels) == 0 {
		fail("job: section(15) is empty")
	}
	if err := specJob.Pocket(end, levels[0], 20, 10, 2.4, 2); err != nil {
		fail(err.Error())
	}
	for _, l := range levels {
		l.Close()
	}
	peck3 := 3.0
	if err := specJob.Drill(specDrill, [][2]float64{{10, 10}, {40, 10}}, 20, -1, &peck3); err != nil {
		fail(err.Error())
	}
	specPrograms, err := specJob.Gcode()
	if err != nil {
		fail(err.Error())
	}
	if len(specPrograms) != 2 || specPrograms[0].Tool != 1 || specPrograms[0].Name != "job-T1" ||
		specPrograms[1].Tool != 2 || specPrograms[1].Name != "job-T2" ||
		!strings.HasPrefix(specPrograms[0].Text, "(cadaclysm: job-T1, T1 flat D6)\n") ||
		!strings.HasPrefix(specPrograms[1].Text, "(cadaclysm: job-T2, T2 drill D5)\n") {
		fail(fmt.Sprintf("job: the spec example's programs are %v", specPrograms))
	}
	specOps, err := specJob.Operations()
	if err != nil {
		fail(err.Error())
	}
	kinds := make([]string, len(specOps))
	for i, o := range specOps {
		kinds[i] = o.Kind
	}
	if strings.Join(kinds, ",") != "face,contour,pocket,drill" {
		fail(fmt.Sprintf("job: the operations are %v", kinds))
	}
	dOp := specOps[3]
	if p := dOp.Params["peck"]; p == nil || *p != 3 {
		fail(fmt.Sprintf("job: the drill's params are %v", dOp))
	}
	if p := dOp.Params["points"]; p == nil || *p != 2 {
		fail(fmt.Sprintf("job: the drill's params are %v", dOp))
	}

	stockE, err := blacksmith.StockBox([3]float64{-15, -10, 0}, [3]float64{15, 10, 10})
	if err != nil {
		fail(err.Error())
	}
	defer stockE.Close()
	squareProfile, err := blacksmith.Rect(20, 10)
	if err != nil {
		fail(err.Error())
	}
	defer squareProfile.Close()

	prefixRefusals := []struct {
		text string
		call func() error
	}{
		{"tool: number must be at least 1", func() error {
			_, err := blacksmith.ToolFlat(0, 6, 20, 800, 200, 12000, 3.0)
			return err
		}},
		{"tool: ramp angle must be in (0, 90] degrees", func() error {
			_, err := blacksmith.ToolBall(1, 6, 20, 800, 200, 12000, 91)
			return err
		}},
		{"stock: min must be below max on every axis, all finite", func() error {
			_, err := blacksmith.StockBox([3]float64{0, 0, 0}, [3]float64{0, 10, 10})
			return err
		}},
		{"job: safe z must be above the stock's top", func() error {
			_, err := blacksmith.NewJob(stockE, 5, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
				blacksmith.JobDefaultName, blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
			return err
		}},
		{"job: clearance must be positive and finite", func() error {
			_, err := blacksmith.NewJob(stockE, 30, 0, blacksmith.JobDefaultTolerance,
				blacksmith.JobDefaultName, blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
			return err
		}},
		{"job: a name must be non-empty and without brackets", func() error {
			_, err := blacksmith.NewJob(stockE, 30, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
				"a/b", blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
			return err
		}},
		{"job: a name must be non-empty and without brackets", func() error {
			_, err := blacksmith.NewJob(stockE, 30, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
				"a\x00b", blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
			return err
		}},
	}
	for _, r := range prefixRefusals {
		if err := r.call(); err == nil || !strings.HasPrefix(err.Error(), r.text) {
			fail(fmt.Sprintf("cam: %q was accepted or refused in other words: %v", r.text, err))
		}
	}

	emptyJob, err := blacksmith.NewJob(stockE, 30, blacksmith.JobDefaultClearance, blacksmith.JobDefaultTolerance,
		blacksmith.JobDefaultName, blacksmith.JobDefaultSpindleDwell, blacksmith.JobDefaultResolution)
	if err != nil {
		fail(err.Error())
	}
	defer emptyJob.Close()
	exactRefusals := []struct {
		text string
		call func() error
	}{
		{"contour: a drill only drills", func() error {
			return emptyJob.Contour(specDrill, squareProfile, 10, 5, "outside", 1.0, true, false)
		}},
		{"drill: drilling needs a drill", func() error {
			return emptyJob.Drill(end, [][2]float64{{0, 0}}, 10, 5, nil)
		}},
		{"drill: there are no points", func() error {
			return emptyJob.Drill(specDrill, nil, 10, 5, nil)
		}},
		{"pocket: stepover must be at most the tool's radius for a pocket", func() error {
			return emptyJob.Pocket(end, squareProfile, 10, 5, 4, 1)
		}},
		{"face: z must be finite and not above the stock's top", func() error {
			return emptyJob.Face(end, 11, 3, 1)
		}},
	}
	for _, r := range exactRefusals {
		if err := r.call(); err == nil || err.Error() != r.text {
			fail(fmt.Sprintf("cam: %q was accepted or refused in other words: %v", r.text, err))
		}
	}
	if err := emptyJob.Contour(end, squareProfile, 10, 5, "left", 1.0, true, false); err == nil ||
		err.Error() != "side must be 'outside', 'inside' or 'on'" {
		fail(fmt.Sprintf("contour: side \"left\" was accepted or the wrong error: %v", err))
	} else if _, isBuild := err.(*blacksmith.BuildError); !isBuild {
		fail(fmt.Sprintf("contour: the bad-side refusal is a %T, not a *BuildError", err))
	}
	// a NUL in a CAMotics stem is refused in the kernel's words, before the library
	if _, err := emptyJob.WriteCamotics(filepath.Join(os.TempDir(), "cadaclysm-nul", "a\x00b.camotics")); err == nil ||
		err.Error() != "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |" {
		fail(fmt.Sprintf("write_camotics: a NUL stem was accepted or refused in other words: %v", err))
	}
	emptyGcode, err := emptyJob.Gcode()
	if err != nil {
		fail(err.Error())
	}
	if len(emptyGcode) != 0 {
		fail("cam: a refused operation changed the job")
	}
	fmt.Println("job: face, contour, pocket and drill by hand give two programs; every refusal in the kernel's words")
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

// collider: two cuboids overlapping by 2 along x, plus one far away -> one hit (0, 1),
// depth 2, Solid() non-null.
func collider() {
	xy0 := blacksmith.Frame{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	partA, err := blacksmith.Cuboid(4, 4, 4)
	if err != nil {
		fail(err.Error())
	}
	defer partA.Close()
	cubB, err := blacksmith.Cuboid(4, 4, 4)
	if err != nil {
		fail(err.Error())
	}
	defer cubB.Close()
	partB, err := cubB.Translate(2, 0, 0)
	if err != nil {
		fail(err.Error())
	}
	defer partB.Close()
	cubC, err := blacksmith.Cuboid(4, 4, 4)
	if err != nil {
		fail(err.Error())
	}
	defer cubC.Close()
	partC, err := cubC.Translate(100, 0, 0)
	if err != nil {
		fail(err.Error())
	}
	defer partC.Close()
	boxA, err := partA.BoundsBox()
	if err != nil {
		fail(err.Error())
	}
	boxB, err := partB.BoundsBox()
	if err != nil {
		fail(err.Error())
	}
	if !boxA.Overlaps(boxB) {
		fail("collider: the two overlapping cuboids' bounds boxes do not overlap")
	}
	col, err := blacksmith.NewCollider([]*blacksmith.Solid{partA, partB, partC}, blacksmith.DefaultTolerance, nil, nil)
	if err != nil {
		fail(err.Error())
	}
	defer col.Close()
	groupCount, err := col.GroupCount()
	if err != nil {
		fail(err.Error())
	}
	if groupCount != 3 {
		fail(fmt.Sprintf("collider: the group count is not one per part: %d", groupCount))
	}
	hits, err := col.Check([]blacksmith.Frame{xy0, xy0, xy0}, 0, 0)
	if err != nil {
		fail(err.Error())
	}
	if len(hits) != 1 {
		fail(fmt.Sprintf("collider: found other than one hit: %v", hits))
	}
	hit := hits[0]
	if hit.A != 0 || hit.B != 1 {
		fail(fmt.Sprintf("collider: the hit does not name parts 0 and 1: %v", hit))
	}
	if !hit.Overlap || hit.Kind != "overlap" || hit.Text != "" {
		fail(fmt.Sprintf("collider: the hit is not a clean overlap: %v", hit))
	}
	if math.Abs(hit.Depth-2.0) > 1e-9 {
		fail(fmt.Sprintf("collider: the hit's depth is not exactly 2: %v", hit))
	}
	overlapSolid, err := hit.Solid()
	if err != nil {
		fail(err.Error())
	}
	defer overlapSolid.Close()
	faces, err := overlapSolid.Faces()
	if err != nil {
		fail(err.Error())
	}
	if faces == 0 {
		fail("collider: the hit's rebuilt solid has no faces")
	}
	stats, err := col.Stats()
	if err != nil {
		fail(err.Error())
	}
	if stats.Considered != 3 {
		fail(fmt.Sprintf("collider: the stats do not consider all three pairs: %v", stats))
	}
	if _, err := blacksmith.NewCollider([]*blacksmith.Solid{partA, partB, partC}, blacksmith.DefaultTolerance, []uint32{0, 1}, nil); err == nil ||
		!strings.Contains(err.Error(), "groups must have one entry per solid") {
		fail(fmt.Sprintf("collider: a short groups list was accepted or refused in other words: %v", err))
	}
	fmt.Printf("collider: %d hit(s), depth %g, %v\n", len(hits), hit.Depth, stats)
}

// clash: Python's test_clash_*, trimmed to what proves the marshalling (clash plan 3), plus
// the edge row: every field read, every refusal's prefix, the handle kept alive past the
// collider and past the other rows.
func clash() {
	must := func(err error) {
		if err != nil {
			fail("clash: " + err.Error())
		}
	}
	check := func(ok bool, why string) {
		if !ok {
			fail("clash: " + why)
		}
	}
	refused := func(err error, prefix string) {
		var be *blacksmith.BuildError
		if err == nil || !errors.As(err, &be) || !strings.HasPrefix(err.Error(), prefix) {
			fail(fmt.Sprintf("clash: expected a *BuildError starting %q, got %v", prefix, err))
		}
	}
	solid := func(s *blacksmith.Solid, err error) *blacksmith.Solid {
		must(err)
		return s
	}
	collider := func(solids ...*blacksmith.Solid) *blacksmith.Collider {
		c, err := blacksmith.NewCollider(solids, 1e-3, nil, nil)
		must(err)
		return c
	}
	at := func(x, y, z float64) blacksmith.Frame {
		return blacksmith.Frame{x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	}
	o := at(0, 0, 0)

	// 1. Balls too close: every field.
	ballA := solid(blacksmith.Sphere(1))
	defer ballA.Close()
	ballB := solid(blacksmith.Sphere(1))
	defer ballB.Close()
	balls := collider(ballA, ballB)
	rows, err := balls.Clash([]blacksmith.Frame{o, at(2.5, 0, 0)}, 1, 0, 0)
	must(err)
	check(len(rows) == 1, fmt.Sprintf("balls: %d rows, not 1: %v", len(rows), rows))
	r := rows[0]
	check(r.A == 0 && r.B == 1 && r.Kind == "too_close", fmt.Sprintf("balls: %v", r))
	check(math.Abs(r.Distance-0.5) <= 1e-3, fmt.Sprintf("balls' distance %g", r.Distance))
	check(r.KindA == "face" && r.KindB == "face", fmt.Sprintf("balls' kinds %q, %q", r.KindA, r.KindB))
	check(r.IndexA != nil && r.IndexB != nil, fmt.Sprintf("balls' indices unset: %+v", r))
	check(r.EdgeA == nil && r.EdgeB == nil, fmt.Sprintf("balls' edges set: %+v", r))
	check(math.Abs(r.OnA[0]-1) <= 2e-3 && math.Abs(r.OnB[0]-1.5) <= 2e-3, fmt.Sprintf("balls' points %v, %v", r.OnA, r.OnB))
	check(r.Text == "" && r.Depth == 0, fmt.Sprintf("balls' text %q, depth %g", r.Text, r.Depth))
	_ = r.Refined
	check(r.String() == `Clash(a=0, b=1, kind="too_close", distance=`+fmt.Sprintf("%.9g", r.Distance)+")", r.String())
	rows, err = balls.Clash([]blacksmith.Frame{o, at(2.5, 0, 0)}, 0.25, 0, 0)
	must(err)
	check(len(rows) == 0, fmt.Sprintf("balls at clearance 0.25: %v", rows))
	balls.Close()

	// 2. Boxes face to face: touching, no shared volume, the shared face as an overlap.
	boxA := solid(blacksmith.Cuboid(2, 2, 2))
	defer boxA.Close()
	boxB := solid(blacksmith.Cuboid(2, 2, 2))
	defer boxB.Close()
	boxes := collider(boxA, boxB)
	rows, err = boxes.Clash([]blacksmith.Frame{o, at(2, 0, 0)}, 0, 0, 0)
	must(err)
	boxes.Close()
	check(len(rows) == 1 && rows[0].Kind == "touching" && rows[0].Distance <= 1e-3, fmt.Sprintf("face to face: %v", rows))
	_, err = rows[0].Solid()
	refused(err, "clashes_solid: pair (0, 1) is not penetrating")
	x, err := rows[0].Intersect()
	must(err)
	check(len(x.Overlaps) == 1 && len(x.Overlaps[0].Loops) > 0, fmt.Sprintf("face to face: %v", x))
	ring := x.Overlaps[0].Loops[0]
	area := 0.0
	for i, p := range ring {
		q := ring[(i+1)%len(ring)]
		check(math.Abs(p[0]-1) <= 1e-3, fmt.Sprintf("face to face: a ring point %v off x = 1", p))
		area += p[1]*q[2] - q[1]*p[2]
	}
	check(math.Abs(math.Abs(area)/2-4) <= 1e-6, fmt.Sprintf("face to face: the shared face's area %g", math.Abs(area)/2))

	// 3. Boxes interpenetrating: depth, features none, the rebuild after the collider is
	// closed and the other rows dropped.
	boxes = collider(boxA, boxB)
	rows, err = boxes.Clash([]blacksmith.Frame{o, at(1.75, 0, 0)}, 0, 0, 0)
	must(err)
	boxes.Close()
	check(len(rows) == 1, fmt.Sprintf("interpenetrating: %v", rows))
	kept := rows[0]
	rows = nil
	runtime.GC()
	runtime.GC()
	check(kept.Kind == "penetrating" && math.Abs(kept.Depth-0.25) < 1e-9 && kept.Distance == 0,
		fmt.Sprintf("interpenetrating: %+v", kept))
	check(kept.KindA == "none" && kept.IndexA == nil && kept.EdgeA == nil, fmt.Sprintf("interpenetrating a: %+v", kept))
	check(kept.KindB == "none" && kept.IndexB == nil && kept.EdgeB == nil, fmt.Sprintf("interpenetrating b: %+v", kept))
	shared, err := kept.Solid()
	must(err)
	defer shared.Close()
	mass, err := shared.Mass(0)
	must(err)
	check(math.Abs(mass.Volume-1) < 1e-6, fmt.Sprintf("interpenetrating: the shared volume %g", mass.Volume))
	_, err = kept.Intersect()
	must(err)

	// 4. One-shot: two sets, one set, one set with allowed.
	a0 := solid(blacksmith.Sphere(1))
	defer a0.Close()
	a1 := solid(solid(blacksmith.Sphere(1)).Translate(2.05, 0, 0))
	defer a1.Close()
	b0 := solid(solid(blacksmith.Sphere(1)).Translate(0, 2.5, 0))
	defer b0.Close()
	b1 := solid(solid(blacksmith.Sphere(1)).Translate(10, 0, 0))
	defer b1.Close()
	two, err := blacksmith.Clashes([]*blacksmith.Solid{a0, a1}, []*blacksmith.Solid{b0, b1}, 1, 1e-3, nil)
	must(err)
	check(len(two) == 1 && two[0].A == 0 && two[0].B == 0 && two[0].Kind == "too_close", fmt.Sprintf("two sets: %v", two))
	check(math.Abs(two[0].Distance-0.5) <= 1e-3, fmt.Sprintf("two sets' distance %g", two[0].Distance))
	one, err := blacksmith.Clashes([]*blacksmith.Solid{a0, a1}, nil, 1, 1e-3, nil)
	must(err)
	check(len(one) == 1 && one[0].A == 0 && one[0].B == 1, fmt.Sprintf("one set: %v", one))
	none, err := blacksmith.Clashes([]*blacksmith.Solid{a0, a1}, nil, 1, 1e-3, []uint32{0, 1})
	must(err)
	check(len(none) == 0, fmt.Sprintf("one set, (0, 1) allowed: %v", none))
	// A box's edge against a ball's face, 0.1 apart: the two sides' features differ.
	d := 1.1 / math.Sqrt2
	ball := solid(solid(blacksmith.Sphere(1)).Translate(1+d, 1+d, 0))
	defer ball.Close()
	mixed, err := blacksmith.Clashes([]*blacksmith.Solid{boxA}, []*blacksmith.Solid{ball}, 0.5, 1e-3, nil)
	must(err)
	check(len(mixed) == 1 && mixed[0].Kind == "too_close" && math.Abs(mixed[0].Distance-0.1) <= 1e-3, fmt.Sprintf("box to ball: %v", mixed))
	check(mixed[0].KindA == "edge" && mixed[0].EdgeA != nil && mixed[0].IndexA != nil, fmt.Sprintf("box to ball a: %+v", mixed[0]))
	check(mixed[0].KindB == "face" && mixed[0].EdgeB == nil && mixed[0].IndexB != nil, fmt.Sprintf("box to ball b: %+v", mixed[0]))

	// 5. Refusals, by prefix.
	boxes = collider(boxA, boxB)
	_, err = boxes.Clash([]blacksmith.Frame{o, at(1.75, 0, 0)}, -1, 0, 0)
	refused(err, "collider_clash: clearance -1")
	_, err = boxes.Clash([]blacksmith.Frame{o}, 0, 0, 0)
	refused(err, "collider_clash: 1 frames for 2 groups")
	_, err = boxes.Clash([]blacksmith.Frame{o, at(1.75, 0, 0)}, 0, 2, 2)
	refused(err, "collider_clash: share (2, 2)")
	boxes.Close()
	_, err = boxes.Clash([]blacksmith.Frame{o, at(1.75, 0, 0)}, 0, 0, 0)
	check(errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("a closed collider clashed: %v", err))
	pair := []*blacksmith.Solid{boxA, boxB}
	_, err = blacksmith.Clashes(pair, nil, -1, blacksmith.DefaultTolerance, nil)
	refused(err, "clash: clearance -1")
	_, err = blacksmith.Clashes(pair, nil, 0, blacksmith.DefaultTolerance, []uint32{5, 0})
	refused(err, "clash: allowed pair (5, 0) names a part out of range")
	_, err = blacksmith.Clashes(pair, nil, 0, blacksmith.DefaultTolerance, []uint32{0, 1, 2})
	refused(err, "clash: allowed is 3 numbers, not pairs")
	_, err = blacksmith.Clashes(pair, []*blacksmith.Solid{}, 0, blacksmith.DefaultTolerance, nil)
	refused(err, "clash: an empty set")

	// 6. The edge row: b turned so its edge crosses a's edge on x = 1, y = 1, 0.1 apart.
	c := math.Sqrt(0.5)
	s := 0.1 * c
	turned := blacksmith.Frame{2 + s, 2 + s, 0, c, -c, 0, 0.5, 0.5, c, -0.5, -0.5, c}
	boxes = collider(boxA, boxB)
	rows, err = boxes.Clash([]blacksmith.Frame{o, turned}, 0.5, 0, 0)
	must(err)
	boxes.Close()
	check(len(rows) == 1 && rows[0].Kind == "too_close", fmt.Sprintf("edge row: %v", rows))
	e := rows[0]
	check(math.Abs(e.Distance-0.1) <= 1e-3, fmt.Sprintf("edge row's distance %g", e.Distance))
	check(nearV(e.OnA, [3]float64{1, 1, 0}, 2e-3), fmt.Sprintf("edge row's on_a %v", e.OnA))
	check(e.KindA == "edge" && e.KindB == "edge", fmt.Sprintf("edge row's kinds %q, %q", e.KindA, e.KindB))
	edgesA, err := boxA.Edges()
	must(err)
	edgesB, err := boxB.Edges()
	must(err)
	check(e.EdgeA != nil && int(*e.EdgeA) < len(edgesA), fmt.Sprintf("edge row's edge_a %v", e.EdgeA))
	for _, seg := range edgesA[*e.EdgeA].Segments {
		for _, p := range seg {
			check(math.Abs(p[0]-1) <= 2e-3 && math.Abs(p[1]-1) <= 2e-3, fmt.Sprintf("edge row: edge_a's point %v is off x = 1, y = 1", p))
		}
	}
	check(e.EdgeB != nil && int(*e.EdgeB) < len(edgesB), fmt.Sprintf("edge row's edge_b %v of %d", e.EdgeB, len(edgesB)))

	fmt.Printf("clash: balls %g, touching, depth %g, edge row %d/%d of %d\n", r.Distance, kept.Depth, *e.EdgeA, *e.EdgeB, len(edgesA))
}

// sweptClash: Python's test_swept_clash_*, trimmed to what proves the marshalling (swept clash
// plan 2b): every field read, interval order, First a working Clash after the collider is
// closed, every refusal's prefix. A 2-cube moving along x from -5 to 5 through a 2-cube at the
// origin meets it at t = 0.3 and leaves at 0.7, at a relative speed of 10 a segment.
func sweptClash() {
	must := func(err error) {
		if err != nil {
			fail("swept clash: " + err.Error())
		}
	}
	check := func(ok bool, why string) {
		if !ok {
			fail("swept clash: " + why)
		}
	}
	refused := func(err error, prefix string) {
		var be *blacksmith.BuildError
		if err == nil || !errors.As(err, &be) || !strings.HasPrefix(err.Error(), prefix) {
			fail(fmt.Sprintf("swept clash: expected a *BuildError starting %q, got %v", prefix, err))
		}
	}
	const tol, res, steps = 1e-3, 1e-3, 100000
	cube := func() *blacksmith.Solid {
		s, err := blacksmith.Cuboid(2, 2, 2)
		must(err)
		return s
	}
	collider := func(solids ...*blacksmith.Solid) *blacksmith.Collider {
		c, err := blacksmith.NewCollider(solids, tol, nil, nil)
		must(err)
		return c
	}
	at := func(x, y float64) blacksmith.Frame {
		return blacksmith.Frame{x, y, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	}
	through := [][]blacksmith.Frame{{at(-5, 0), at(0, 0)}, {at(5, 0), at(0, 0)}}
	near := func(got, want, within float64) bool { return math.Abs(got-want) <= within }

	a := cube()
	defer a.Close()
	b := cube()
	defer b.Close()

	// 1. A cube through a cube: every field; First rebuilds the contact after the collider is
	// closed and the rows' other handle is gone.
	boxes := collider(a, b)
	rows, err := boxes.SweptClash(through, 0, res, steps, 0, 0)
	must(err)
	boxes.Close()
	runtime.GC()
	runtime.GC()
	check(len(rows) == 1, fmt.Sprintf("through: %d rows, not 1: %v", len(rows), rows))
	r := rows[0]
	check(r.A == 0 && r.B == 1, fmt.Sprintf("through: %v", r))
	check(near(r.FirstTime, 0.3, tol/10+1e-9), fmt.Sprintf("through: first time %.12g", r.FirstTime))
	check(len(r.Intervals) == 1, fmt.Sprintf("through: intervals %v", r.Intervals))
	check(r.Intervals[0][0] == r.FirstTime && near(r.Intervals[0][1], 0.7, res+tol/10),
		fmt.Sprintf("through: interval %v, first time %.12g", r.Intervals[0], r.FirstTime))
	check(r.First.A == 0 && r.First.B == 1 && r.First.Kind == "touching", fmt.Sprintf("through: first %v", r.First))
	check(r.String() == fmt.Sprintf("SweptClash(a=0, b=1, first_time=%.9g, kind=\"touching\", intervals=%v)", r.FirstTime, r.Intervals), r.String())
	_, err = r.First.Solid()
	refused(err, "clashes_solid: pair (0, 1) is not penetrating")
	x, err := r.First.Intersect()
	must(err)
	check(len(x.Overlaps) == 1, fmt.Sprintf("through: %d overlap regions", len(x.Overlaps)))
	for _, loop := range x.Overlaps[0].Loops {
		for _, p := range loop {
			check(near(p[0], -1, 2*tol), fmt.Sprintf("through: an overlap point %v off x = -1", p))
		}
	}

	// 2. There and back: two intervals, in order.
	boxes = collider(a, b)
	rows, err = boxes.SweptClash(append(through, []blacksmith.Frame{at(-5, 0), at(0, 0)}), 0, res, steps, 0, 0)
	must(err)
	check(len(rows) == 1 && len(rows[0].Intervals) == 2, fmt.Sprintf("there and back: %v", rows))
	for i, want := range [][2]float64{{0.3, 0.7}, {1.3, 1.7}} {
		got := rows[0].Intervals[i]
		check(near(got[0], want[0], tol/10+1e-9) && near(got[1], want[1], res+tol/10),
			fmt.Sprintf("there and back: interval %d %v, not %v", i, got, want))
	}

	// 3. A miss, seen only within the clearance.
	passing := [][]blacksmith.Frame{{at(-5, 2.5), at(0, 0)}, {at(5, 2.5), at(0, 0)}}
	rows, err = boxes.SweptClash(passing, 0.4, res, steps, 0, 0)
	must(err)
	check(len(rows) == 0, fmt.Sprintf("a miss at clearance 0.4: %v", rows))
	rows, err = boxes.SweptClash(passing, 0.6, res, steps, 0, 0)
	must(err)
	check(len(rows) == 1 && len(rows[0].Intervals) == 1, fmt.Sprintf("a miss at clearance 0.6: %v", rows))
	check(rows[0].First.Kind == "too_close" && rows[0].First.Distance >= 0.5-tol && rows[0].First.Distance <= 0.6,
		fmt.Sprintf("a miss at clearance 0.6: first %v", rows[0].First))

	// 4. Starting inside: the overlap rebuilt at time 0.
	rows, err = boxes.SweptClash([][]blacksmith.Frame{{at(1.75, 0), at(0, 0)}, {at(5, 0), at(0, 0)}}, 0, res, steps, 0, 0)
	must(err)
	boxes.Close()
	check(len(rows) == 1 && rows[0].FirstTime == 0 && rows[0].First.Kind == "penetrating", fmt.Sprintf("inside: %v", rows))
	shared, err := rows[0].First.Solid()
	must(err)
	defer shared.Close()
	mass, err := shared.Mass(0)
	must(err)
	check(near(mass.Volume, 1, 1e-6), fmt.Sprintf("inside: the shared volume %g", mass.Volume))

	// 5. One-shot: set a still at the origin and at y = 20, set b carried along x through them;
	// the collider over all four agrees. Then one set, and one set with (0, 1) allowed.
	a0, a1 := cube(), cube()
	defer a0.Close()
	defer a1.Close()
	moved, err := a1.Translate(0, 20, 0)
	must(err)
	defer moved.Close()
	b0, b1 := cube(), cube()
	defer b0.Close()
	defer b1.Close()
	still := [][]blacksmith.Frame{{at(0, 0), at(0, 0)}, {at(0, 0), at(0, 0)}}
	moving := [][]blacksmith.Frame{{at(-5, 0), at(-5, 20)}, {at(5, 0), at(5, 20)}}
	two, err := blacksmith.SweptClashes([]*blacksmith.Solid{a0, moved}, still, []*blacksmith.Solid{b0, b1}, moving, 0, tol, res, steps, nil)
	must(err)
	check(len(two) == 2 && two[0].A == 0 && two[0].B == 0 && two[1].A == 1 && two[1].B == 1, fmt.Sprintf("two sets: %v", two))
	check(two[0].First.A == 0 && two[0].First.B == 0 && two[1].First.A == 1 && two[1].First.B == 1,
		fmt.Sprintf("two sets' firsts: %v, %v", two[0].First, two[1].First))
	all := collider(a0, moved, b0, b1)
	var joined [][]blacksmith.Frame
	for k := range still {
		joined = append(joined, append(append([]blacksmith.Frame{}, still[k]...), moving[k]...))
	}
	via, err := all.SweptClash(joined, 0, res, steps, 0, 0)
	must(err)
	all.Close()
	check(len(via) == len(two), fmt.Sprintf("the collider: %v, the one-shot: %v", via, two))
	for i := range via {
		check(via[i].A == two[i].A && via[i].B-2 == two[i].B && via[i].FirstTime == two[i].FirstTime &&
			reflect.DeepEqual(via[i].Intervals, two[i].Intervals), fmt.Sprintf("the collider's %v, the one-shot's %v", via[i], two[i]))
	}
	crossing := [][]blacksmith.Frame{{at(0, 0), at(-5, 0)}, {at(0, 0), at(5, 0)}}
	one, err := blacksmith.SweptClashes([]*blacksmith.Solid{a0, b0}, crossing, nil, nil, 0, tol, res, steps, nil)
	must(err)
	check(len(one) == 1 && one[0].A == 0 && one[0].B == 1, fmt.Sprintf("one set: %v", one))
	none, err := blacksmith.SweptClashes([]*blacksmith.Solid{a0, b0}, crossing, nil, nil, 0, tol, res, steps, []uint32{0, 1})
	must(err)
	check(len(none) == 0, fmt.Sprintf("one set, (0, 1) allowed: %v", none))

	// 6. Refusals, by prefix.
	boxes = collider(a, b)
	_, err = boxes.SweptClash(through[:1], 0, res, steps, 0, 0)
	refused(err, "collider_swept_clash: 1 poses, at least 2 are needed")
	_, err = boxes.SweptClash([][]blacksmith.Frame{{at(0, 0)}, {at(0, 0)}}, 0, res, steps, 0, 0)
	refused(err, "collider_swept_clash: 1 frames for 2 groups")
	_, err = boxes.SweptClash([][]blacksmith.Frame{{at(0, 0), at(0, 0)}, {at(0, 0)}}, 0, res, steps, 0, 0)
	refused(err, "collider_swept_clash: 1 frames for 2 groups")
	_, err = boxes.SweptClash(through, 0, 0, steps, 0, 0)
	refused(err, "collider_swept_clash: resolution 0")
	_, err = boxes.SweptClash(through, 0, res, 0, 0, 0)
	refused(err, "collider_swept_clash: max_steps must be at least 1")
	_, err = boxes.SweptClash(through, -1, res, steps, 0, 0)
	refused(err, "collider_swept_clash: clearance -1")
	_, err = boxes.SweptClash(through, 0, res, steps, 2, 2)
	refused(err, "collider_swept_clash: share (2, 2)")
	boxes.Close()
	_, err = boxes.SweptClash(through, 0, res, steps, 0, 0)
	check(errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("a closed collider swept: %v", err))
	pair := []*blacksmith.Solid{a, b}
	single := [][]blacksmith.Frame{{at(0, 0)}, {at(0, 0)}}
	_, err = blacksmith.SweptClashes([]*blacksmith.Solid{a}, single, []*blacksmith.Solid{b}, nil, 0, tol, res, steps, nil)
	refused(err, "swept_clash: others and other_poses go together")
	_, err = blacksmith.SweptClashes([]*blacksmith.Solid{a}, single, nil, single, 0, tol, res, steps, nil)
	refused(err, "swept_clash: others and other_poses go together")
	_, err = blacksmith.SweptClashes([]*blacksmith.Solid{a}, single, []*blacksmith.Solid{b}, single[:1], 0, tol, res, steps, nil)
	refused(err, "swept_clash: 2 poses for set a, 1 for set b")
	_, err = blacksmith.SweptClashes([]*blacksmith.Solid{a}, single, []*blacksmith.Solid{b},
		[][]blacksmith.Frame{{at(0, 0)}, {at(0, 0), at(0, 0)}}, 0, tol, res, steps, nil)
	refused(err, "swept_clash: pose 1 of set b has 2 frames for 1 parts")
	_, err = blacksmith.SweptClashes([]*blacksmith.Solid{a}, single, []*blacksmith.Solid{}, [][]blacksmith.Frame{{}, {}}, 0, tol, res, steps, nil)
	refused(err, "swept_clash: an empty set")
	_, err = blacksmith.SweptClashes(pair, through, nil, nil, 0, tol, res, steps, []uint32{5, 0})
	refused(err, "swept_clash: allowed pair (5, 0) names a part out of range")
	_, err = blacksmith.SweptClashes(pair, through, nil, nil, 0, tol, res, steps, []uint32{0, 1, 2})
	refused(err, "swept_clash: allowed is 3 numbers, not pairs")
	_, err = blacksmith.SweptClashes(pair, through, nil, nil, 0, tol, res, 0, nil)
	refused(err, "swept_clash: max_steps must be at least 1")
	_, err = blacksmith.SweptClashes(pair, through[:1], nil, nil, 0, tol, res, steps, nil)
	refused(err, "swept_clash: 1 poses, at least 2 are needed")

	fmt.Printf("swept clash: first time %.6g, interval %v, %d rows two-set\n", r.FirstTime, r.Intervals[0], len(two))
}

// assemblySweptClash: Python's test_assembly_parts_* and test_assembly_swept_clash_*,
// trimmed to the marshalling (swept clash plan 3c), on the same rig: a `base` plate on link
// `ground`; an `arm`, cuboid(3, 0.2, 0.2) from the hinge out along x, on link `arm`, turning
// on `hinge` (revolute about z through the origin); a `carriage` far out on `slide`
// (cylindrical, two values); and two cubes in no link: `chord` below the hinge, which the
// chord between the arm's end poses crosses and its arc never does, and `circle` on the arm's
// circle at 90 degrees.
func assemblySweptClash() {
	must := func(err error) {
		if err != nil {
			fail("assembly swept clash: " + err.Error())
		}
	}
	check := func(ok bool, why string) {
		if !ok {
			fail("assembly swept clash: " + why)
		}
	}
	refused := func(err error, want string, prefix bool) {
		var be *blacksmith.BuildError
		if err == nil || !errors.As(err, &be) || (prefix && !strings.HasPrefix(err.Error(), want)) || (!prefix && err.Error() != want) {
			fail(fmt.Sprintf("assembly swept clash: expected a *BuildError %q, got %v", want, err))
		}
	}
	const tol = 1e-3
	const res, steps = 1e-3, 100000
	at := func(x, y, z float64) blacksmith.Frame {
		return blacksmith.Frame{x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	}
	cuboid := func(x, y, z float64) *blacksmith.Solid {
		s, err := blacksmith.Cuboid(x, y, z)
		must(err)
		return s
	}
	place := func(a *blacksmith.Assembly, s *blacksmith.Solid, f blacksmith.Frame, name string) {
		_, err := a.PlaceSolid(s, f, name)
		must(err)
	}
	hand := func() *blacksmith.Assembly {
		// a `tip` cube on link `body`, and a `nub` well above it on `nubs`, turning on `turn`
		h, err := blacksmith.NewAssembly("hand")
		must(err)
		place(h, cuboid(0.4, 0.4, 0.4), at(0, 0, 0), "tip")
		place(h, cuboid(0.2, 0.2, 0.2), at(0, 0, 2), "nub")
		must(h.Link("body", []string{"tip"}))
		must(h.Link("nubs", []string{"nub"}))
		must(h.Joint("turn", "body", "nubs"))
		must(h.Pair("turn", "revolute", at(0, 0, 0), blacksmith.PairOptions{}))
		return h
	}
	rig := func(h *blacksmith.Assembly) *blacksmith.Assembly {
		r, err := blacksmith.NewAssembly("rig")
		must(err)
		place(r, cuboid(1, 1, 0.4), at(0, 0, -1), "base")
		arm := "arm"
		if h == nil {
			place(r, cuboid(3, 0.2, 0.2), at(1.5, 0, 0), "arm")
		} else {
			_, err = r.PlaceAssembly(h, at(1.5, 0, 0), "hand")
			must(err)
			arm = "hand"
		}
		place(r, cuboid(0.4, 0.4, 0.4), at(0, -1.2, 0), "chord")
		place(r, cuboid(0.4, 0.4, 0.4), at(0, 1.5, 0), "circle")
		place(r, cuboid(0.4, 0.4, 0.4), at(20, 0, 0), "carriage")
		must(r.Link("ground", []string{"base"}))
		must(r.Link("arm", []string{arm}))
		must(r.Link("carriage", []string{"carriage"}))
		for _, j := range [][3]string{{"hinge", "arm", "revolute"}, {"slide", "carriage", "cylindrical"}} {
			must(r.Joint(j[0], "ground", j[1]))
			must(r.Pair(j[0], j[2], at(0, 0, 0), blacksmith.PairOptions{}))
		}
		must(r.Base("ground"))
		return r
	}
	row := func(joint string, values ...float64) blacksmith.StateRow {
		return blacksmith.StateRow{Joint: joint, Values: values}
	}
	// the hinge at 0, 90 and 180 degrees, the carriage sliding 0, 0.5, 1 unturned
	swing := [][]blacksmith.StateRow{
		{row("hinge", 0), row("slide", 0, 0)},
		{row("hinge", math.Pi/2), row("slide", 0.5, 0)},
		{row("hinge", math.Pi), row("slide", 1, 0)},
	}
	// the time the arm's leading face (y = 0.1 in its own frame) is gap from the circle
	// cube's corner (0.2, 1.3), the first point it meets, in the first segment
	circleTime := func(gap float64) float64 {
		r, phi := math.Hypot(1.3, 0.2), math.Atan2(0.2, 1.3)
		return (math.Acos((0.1+gap)/r) - phi) / (math.Pi / 2)
	}
	sweep := func(a *blacksmith.Assembly, keys [][]blacksmith.StateRow) ([]blacksmith.SweptClash, error) {
		return a.SweptClash(keys, 0, tol, res, steps, nil, "", false)
	}

	// 1. Parts: depth first, escaped; an empty assembly lists none.
	sub, err := blacksmith.NewAssembly("pair")
	must(err)
	place(sub, cuboid(1, 1, 1), at(0, 0, 0), "x")
	place(sub, cuboid(1, 1, 1), at(2, 0, 0), "y")
	top, err := blacksmith.NewAssembly("top")
	must(err)
	place(top, cuboid(1, 1, 1), at(0, 5, 0), "p")
	_, err = top.PlaceAssembly(sub, at(0, 0, 0), "a/b")
	must(err)
	place(top, cuboid(1, 1, 1), at(0, 9, 0), "q")
	names, err := top.Parts()
	must(err)
	check(slices.Equal(names, []string{"p", "a\\/b/x", "a\\/b/y", "q"}), fmt.Sprintf("parts: %q", names))
	empty, err := blacksmith.NewAssembly("empty")
	must(err)
	names, err = empty.Parts()
	must(err)
	check(len(names) == 0, fmt.Sprintf("an empty assembly's parts: %q", names))

	// 2. The arc, not the chord: one row, (arm, circle) by Parts' names, first in the window.
	r := rig(nil)
	names, err = r.Parts()
	must(err)
	check(slices.Equal(names, []string{"base", "arm", "chord", "circle", "carriage"}), fmt.Sprintf("the rig's parts: %q", names))
	rows, err := sweep(r, swing)
	must(err)
	check(len(rows) == 1 && names[rows[0].A] == "arm" && names[rows[0].B] == "circle", fmt.Sprintf("the arc: %v", rows))
	within, meets := circleTime(tol), circleTime(0)
	check(within-1e-9 <= rows[0].FirstTime && rows[0].FirstTime <= meets+1e-9,
		fmt.Sprintf("the arc: first time %.12g, not in [%.12g, %.12g]", rows[0].FirstTime, within, meets))
	check(rows[0].First.A == rows[0].A && rows[0].First.B == rows[0].B, fmt.Sprintf("the arc: first %v", rows[0].First))
	arcFirst := rows[0].FirstTime

	// 3. First at the posed frames: the arm starts at 1.5 rad, already through the circle
	// cube; the overlap lies inside the arm's box turned 1.5 about z.
	rows, err = sweep(r, [][]blacksmith.StateRow{{row("hinge", 1.5), row("slide", 0, 0)}, {row("hinge", math.Pi), row("slide", 0, 0)}})
	must(err)
	check(len(rows) == 1 && rows[0].A == 1 && rows[0].B == 3 && rows[0].FirstTime == 0, fmt.Sprintf("posed frames: %v", rows))
	overlap, err := rows[0].First.Solid()
	must(err)
	got, err := overlap.BoundsBoxAt(tol)
	must(err)
	arm := cuboid(3, 0.2, 0.2)
	armAt, err := arm.Translate(1.5, 0, 0)
	must(err)
	rest, err := armAt.BoundsBoxAt(tol)
	must(err)
	co, si := math.Cos(1.5), math.Sin(1.5)
	want, err := rest.Moved(blacksmith.Frame{0, 0, 0, co, si, 0, -si, co, 0, 0, 0, 1})
	must(err)
	for k := 0; k < 3; k++ {
		check(want.Lo[k]-1e-6 <= got.Lo[k] && got.Hi[k] <= want.Hi[k]+1e-6, fmt.Sprintf("posed frames: overlap %v outside %v", got, want))
	}
	check(got.Lo[1] >= 1.3-4*tol && got.Hi[1] <= 1.7+4*tol && got.Hi[0] > got.Lo[0], fmt.Sprintf("posed frames: overlap %v", got))

	// 4. Joined: a pin on the arm's link inside a bore on the ground link, the hinge joining
	// them, tested only when asked, and then not when the pair is allowed.
	pinned, err := blacksmith.NewAssembly("pinned")
	must(err)
	place(pinned, cuboid(0.6, 0.6, 0.6), at(0, 0, 0), "bore")
	place(pinned, cuboid(0.2, 0.2, 0.2), at(0, 0, 0), "pin")
	must(pinned.Link("ground", []string{"bore"}))
	must(pinned.Link("arm", []string{"pin"}))
	must(pinned.Joint("hinge", "ground", "arm"))
	must(pinned.Pair("hinge", "revolute", at(0, 0, 0), blacksmith.PairOptions{}))
	keys := [][]blacksmith.StateRow{{row("hinge", 0)}, {row("hinge", 1)}}
	rows, err = sweep(pinned, keys)
	must(err)
	check(len(rows) == 0, fmt.Sprintf("joined, not asked: %v", rows))
	rows, err = pinned.SweptClash(keys, 0, tol, res, steps, nil, "", true)
	must(err)
	check(len(rows) == 1 && rows[0].A == 0 && rows[0].B == 1 && rows[0].FirstTime == 0, fmt.Sprintf("joined: %v", rows))
	rows, err = pinned.SweptClash(keys, 0, tol, res, steps, []uint32{0, 1}, "", true)
	must(err)
	check(len(rows) == 0, fmt.Sprintf("joined, (0, 1) allowed: %v", rows))

	// 5. A sub-assembly rides its placement's link.
	withHand := rig(hand())
	names, err = withHand.Parts()
	must(err)
	check(slices.Equal(names, []string{"base", "hand/tip", "hand/nub", "chord", "circle", "carriage"}), fmt.Sprintf("the hand rig's parts: %q", names))
	rows, err = sweep(withHand, swing)
	must(err)
	check(len(rows) == 1 && names[rows[0].A] == "hand/tip" && names[rows[0].B] == "circle", fmt.Sprintf("the hand: %v", rows))

	// 6. Refusals by their exact words: the wrapper's own, before C is called, then the
	// kernel's, passed on.
	two := [][]blacksmith.StateRow{{row("hinge", 0)}, {row("hinge", 1)}}
	_, err = sweep(withHand, [][]blacksmith.StateRow{{row("hinge", 0), row("slide", 0, 0)}, {row("hinge", 1), row("slide", 0, 0)}, {row("hinge", 2)}})
	refused(err, "swept_clash: joint 'slide' is in keyframe 0 and not in keyframe 2", false)
	_, err = sweep(withHand, [][]blacksmith.StateRow{{row("hinge", 0)}, {row("hinge", 1), row("slide", 0, 0)}})
	refused(err, "swept_clash: joint 'slide' is in keyframe 1 and not in keyframe 0", false)
	_, err = sweep(withHand, [][]blacksmith.StateRow{{row("hinge", 0)}, {row("hinge", 1), row("hinge", 2)}})
	refused(err, "swept_clash: joint 'hinge' is given twice", false)
	_, err = sweep(withHand, [][]blacksmith.StateRow{{row("slide", 0, 0)}, {row("slide", 1)}})
	refused(err, "swept_clash: joint 'slide' has 2 values in keyframe 0 and 1 in keyframe 1", false)
	_, err = withHand.SweptClash(two, 0, tol, res, steps, []uint32{0, 1, 2}, "", false)
	refused(err, "swept_clash: allowed is 3 numbers, not pairs", false)
	_, err = sweep(withHand, [][]blacksmith.StateRow{{row("hand/turn", 0)}, {row("hand/turn", 1)}})
	refused(err, "swept_clash: joint 'hand/turn' is in a sub-assembly; a sweep moves this assembly's own joints", false)
	_, err = sweep(withHand, [][]blacksmith.StateRow{{row("elbow", 0)}, {row("elbow", 1)}})
	refused(err, "swept_clash: no joint named 'elbow' in assembly 'rig' or under it", false)
	_, err = sweep(withHand, [][]blacksmith.StateRow{{row("hinge", 0, 0)}, {row("hinge", 1, 1)}})
	refused(err, "swept_clash: joint 'hinge' takes 1 values, but 2 were given", false)
	_, err = sweep(withHand, two[:1])
	refused(err, "swept_clash: 1 poses, at least 2 are needed", false)
	_, err = withHand.SweptClash(two, 0, tol, 0, steps, nil, "", false)
	refused(err, "swept_clash: resolution 0", true)
	_, err = withHand.SweptClash(two, 0, tol, res, 0, nil, "", false)
	refused(err, "swept_clash: max_steps must be at least 1", false)
	_, err = withHand.SweptClash(two, 0, tol, res, steps, []uint32{9, 0}, "", false)
	refused(err, "swept_clash: allowed pair (9, 0) names a part out of range", false)
	_, err = withHand.SweptClash(two, 0, tol, res, steps, nil, "wheel", false)
	refused(err, "swept_clash: assembly 'rig' has no link named 'wheel'", false)

	// a closed assembly
	empty.Close()
	_, err = empty.Parts()
	check(errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("a closed assembly's parts: %v", err))
	_, err = sweep(empty, two)
	check(errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("a closed assembly swept: %v", err))

	fmt.Printf("assembly swept clash: first time %.6g, %d parts with the hand\n", arcFirst, len(names))
}

// wallThickness: Python's test_thickness_* and test_mesh_thickness_*, trimmed to what proves
// the marshalling (wall thickness plan 2b): every field read, the none mappings, every
// refusal's prefix, the gauge's lifetime.
func wallThickness() {
	must := func(err error) {
		if err != nil {
			fail("thickness: " + err.Error())
		}
	}
	check := func(ok bool, why string) {
		if !ok {
			fail("thickness: " + why)
		}
	}
	refused := func(err error, prefix string) {
		var be *blacksmith.BuildError
		if err == nil || !errors.As(err, &be) || !strings.HasPrefix(err.Error(), prefix) {
			fail(fmt.Sprintf("thickness: expected a *BuildError starting %q, got %v", prefix, err))
		}
	}
	solid := func(s *blacksmith.Solid, err error) *blacksmith.Solid {
		must(err)
		return s
	}
	profile := func(p *blacksmith.Profile, err error) *blacksmith.Profile {
		must(err)
		return p
	}
	gaugeOf := func(tolerance float64, solids ...*blacksmith.Solid) *blacksmith.ThicknessGauge {
		g, err := blacksmith.NewThicknessGauge(solids, tolerance)
		must(err)
		return g
	}
	xy := blacksmith.FrameXY([3]float64{})
	near := func(a, b, tolerance float64) bool { return math.Abs(a-b) <= tolerance }
	count := func(g *blacksmith.ThicknessGauge) int {
		n, err := g.Len()
		must(err)
		return n
	}
	// faceHolding is the face of body whose reading at p lies at p.
	faceHolding := func(g *blacksmith.ThicknessGauge, s *blacksmith.Solid, body uint32, p [3]float64) uint32 {
		faces, err := s.Faces()
		must(err)
		for f := 0; f < faces; f++ {
			r, err := g.ThicknessAt(body, uint32(f), p, 100, 0.5)
			must(err)
			if r != nil && nearV(r.Point, p, 1e-9) {
				return uint32(f)
			}
		}
		fail(fmt.Sprintf("thickness: no face holds %v", p))
		return 0
	}

	// 1. A plate reads 2 at every cap vertex.
	plate := solid(blacksmith.Cuboid(10, 10, 2))
	defer plate.Close()
	g := gaugeOf(0.01, plate)
	defer g.Close()
	tol, err := g.Tolerance()
	must(err)
	check(count(g) == 1 && tol == 0.01, fmt.Sprintf("gauge: %d bodies, tolerance %g", count(g), tol))
	rows, err := g.Thickness(10, 0.5)
	must(err)
	mesh, err := g.Mesh(0)
	must(err)
	caps := 0
	for _, r := range rows {
		check(r.Body == 0 && r.Vertex != nil, fmt.Sprintf("a mesh row without a vertex or off body 0: %v", r))
		check(mesh.Positions[*r.Vertex] == r.Point, fmt.Sprintf("row's point is not mesh vertex %d: %v", *r.Vertex, r))
		if near(math.Abs(r.Point[2]), 1, 1e-9) && near(r.Opposite[2]+r.Point[2], 0, 1e-9) {
			caps++
			check(near(r.Thickness, 2, 1e-9) && near(r.ExactThickness, 2, 1e-9), fmt.Sprintf("cap thickness: %v", r))
			check(near(r.ExactOpposite[2]+r.Point[2], 0, 1e-9), fmt.Sprintf("cap exact opposite: %v", r))
			check(!r.Knife && r.OppositeBody == 0, fmt.Sprintf("cap knife or opposite body: %v", r))
		}
	}
	check(caps >= 8, fmt.Sprintf("only %d cap rows of %d", caps, len(rows)))
	// below the wall nothing reads
	none1, err := g.Thickness(1, 0)
	must(err)
	check(len(none1) == 0, fmt.Sprintf("maximum 1 read %d rows", len(none1)))
	deflt, err := g.Thickness(10, 0)
	must(err)
	check(len(deflt) == len(rows), fmt.Sprintf("sharp angle 0 read %d rows, 0.5 read %d", len(deflt), len(rows)))
	check(strings.HasPrefix(rows[0].String(), "Thickness(body=0, vertex="), rows[0].String())
	check(g.String() == "ThicknessGauge(bodies=1, tolerance=0.01)", g.String())

	// 2. The mesh is a copy that matches the readings.
	m := mesh
	check(len(m.Faces) == len(m.Triangles) && len(m.Triangles) >= 12, fmt.Sprintf("mesh: %d faces, %d triangles", len(m.Faces), len(m.Triangles)))
	check(len(m.Normals) == len(m.Positions) && len(m.Positions) > 0, fmt.Sprintf("mesh: %d normals, %d positions", len(m.Normals), len(m.Positions)))
	plateFaces, err := plate.Faces()
	must(err)
	for _, f := range m.Faces {
		check(int(f) < plateFaces, fmt.Sprintf("mesh face %d of %d", f, plateFaces))
	}
	for _, t := range m.Triangles {
		for _, k := range t {
			check(int(k) < len(m.Positions), fmt.Sprintf("mesh triangle %v past %d vertices", t, len(m.Positions)))
		}
	}
	for _, n := range m.Normals {
		check(near(math.Sqrt(n[0]*n[0]+n[1]*n[1]+n[2]*n[2]), 1, 1e-9), fmt.Sprintf("normal %v is not unit", n))
	}
	all, err := g.Thickness(100, 0.5)
	must(err)
	check(len(all) == len(m.Positions), fmt.Sprintf("%d rows for %d vertices", len(all), len(m.Positions)))
	for _, r := range all {
		found := false
		for t, tri := range m.Triangles {
			if tri[0] == *r.Vertex || tri[1] == *r.Vertex || tri[2] == *r.Vertex {
				check(m.Faces[t] == r.Face, fmt.Sprintf("row's face %d, triangle %d's face %d", r.Face, t, m.Faces[t]))
				found = true
				break
			}
		}
		check(found, fmt.Sprintf("no triangle holds vertex %d", *r.Vertex))
	}
	_, err = g.Mesh(1)
	check(err != nil && err.Error() == "thickness_gauge_mesh: no body 1 -- there are 1", fmt.Sprintf("mesh(1): %v", err))
	check(strings.HasPrefix(m.String(), "ThicknessMesh(vertices="), m.String())

	// 3. A reading at a point has no vertex.
	probe := [3]float64{1, 2, 1}
	top := faceHolding(g, plate, 0, probe)
	r, err := g.ThicknessAt(0, top, probe, 100, 0.5)
	must(err)
	check(r != nil && r.Vertex == nil, fmt.Sprintf("a reading at a point: %v", r))
	check(r.Body == 0 && r.Face == top && r.OppositeBody == 0 && r.Point == probe, fmt.Sprintf("at-point identity: %v", r))
	check(near(r.Thickness, 2, 1e-9) && near(r.ExactThickness, 2, 1e-9), fmt.Sprintf("at-point thickness: %v", r))
	check(near(r.Opposite[2], -1, 1e-9) && near(r.ExactOpposite[2], -1, 1e-9), fmt.Sprintf("at-point opposite: %v %v", r.Opposite, r.ExactOpposite))
	check(r.Sphere != nil && near(*r.Sphere, 2, 0.02), fmt.Sprintf("at-point sphere: %v", r.Sphere))
	thin, err := g.ThicknessAt(0, top, probe, 1, 0.5)
	must(err)
	check(thin == nil, fmt.Sprintf("a wall past the maximum read %v", thin))
	plain, err := g.ThicknessAt(0, top, probe, 100, 0)
	must(err)
	check(plain != nil && plain.Thickness == r.Thickness, "the sharp angle changed the plate's reading")

	// 4. A face's thickness, and none where nothing is found.
	f, err := g.ThicknessAtFace(0, top, nil, 100)
	must(err)
	check(f != nil && near(f.Thickness, 2, 1e-9) && f.Uniform && near(f.Min, 2, 1e-9) && near(f.Max, 2, 1e-9), fmt.Sprintf("face: %v", f))
	above := [3]float64{1, 2, 5}
	a, err := g.ThicknessAtFace(0, top, &above, 100)
	must(err)
	check(a != nil && near(a.Thickness, 2, 1e-9) && a.Min == a.Max && a.Uniform, fmt.Sprintf("face at: %v", a))
	check(strings.HasPrefix(a.String(), "FaceThickness(thickness=2"), a.String())
	f, err = g.ThicknessAtFace(0, top, nil, 1)
	must(err)
	check(f == nil, fmt.Sprintf("a face under the maximum read %v", f))
	off := [3]float64{50, 2, 5}
	f, err = g.ThicknessAtFace(0, top, &off, 100)
	must(err)
	check(f == nil, fmt.Sprintf("an at off the face read %v", f))
	s, err := plate.ThicknessAtFace(top, nil, 100, blacksmith.DefaultTolerance)
	must(err)
	check(s != nil && near(s.Thickness, 2, 1e-9) && s.Uniform, fmt.Sprintf("solid face: %v", s))
	s, err = plate.ThicknessAtFace(top, &above, 100, 0.05)
	must(err)
	check(s != nil && near(s.Thickness, 2, 1e-9), fmt.Sprintf("solid face at: %v", s))
	s, err = plate.ThicknessAtFace(top, nil, 1, blacksmith.DefaultTolerance)
	must(err)
	check(s == nil, fmt.Sprintf("a solid face under the maximum read %v", s))

	// 5. A ball past the maximum is nil; the wall's own rule still reads.
	wedge := solid(blacksmith.Extrude(profile(blacksmith.Polygon([][2]float64{{0, 0}, {10, 0}, {0, 10}})), xy, 20))
	defer wedge.Close()
	wg := gaugeOf(0.01, wedge)
	defer wg.Close()
	wp := [3]float64{5, 0, 10}
	wf := faceHolding(wg, wedge, 0, wp)
	wide, err := wg.ThicknessAt(0, wf, wp, 100, 0.5)
	must(err)
	check(wide != nil && wide.Sphere != nil && near(*wide.Sphere, 2*5/(1+math.Sqrt2), 0.01), fmt.Sprintf("wedge ball: %v", wide))
	narrow, err := wg.ThicknessAt(0, wf, wp, 4, 0.5)
	must(err)
	check(narrow != nil && near(narrow.Thickness, 5/math.Sqrt2, 1e-9) && narrow.Sphere == nil, fmt.Sprintf("wedge past the maximum: %v", narrow))

	// 6. Two bodies read each other, and the one-shot agrees.
	slab := solid(blacksmith.Extrude(profile(blacksmith.Polygon([][2]float64{{0, 0}, {10, 0}, {10, 3}, {0, 1}})), xy, 4))
	defer slab.Close()
	ring := profile(profile(blacksmith.Circle(5)).WithHole(profile(blacksmith.Circle(4))))
	tube := solid(blacksmith.Extrude(ring, xy, 10))
	defer tube.Close()
	tg := gaugeOf(0.01, slab, tube)
	check(count(tg) == 2, "two bodies")
	via, err := tg.Thickness(100, 0.5)
	must(err)
	tg.Close()
	one, err := blacksmith.Thicknesses([]*blacksmith.Solid{slab, tube}, 100, 0.5, 0.01)
	must(err)
	check(len(one) == len(via), fmt.Sprintf("one-shot read %d rows, gauge %d", len(one), len(via)))
	slabReadsTube, tubeReadsSlab := false, false
	for i := range one {
		a, b := one[i], via[i]
		check(a.Body == b.Body && *a.Vertex == *b.Vertex && a.Face == b.Face && a.Thickness == b.Thickness &&
			a.OppositeBody == b.OppositeBody, fmt.Sprintf("row %d: %v vs %v", i, a, b))
		slabReadsTube = slabReadsTube || (a.Body == 0 && a.OppositeBody == 1)
		tubeReadsSlab = tubeReadsSlab || (a.Body == 1 && a.OppositeBody == 0)
	}
	check(slabReadsTube && tubeReadsSlab, "the two bodies do not read each other")
	empty, err := blacksmith.Thicknesses([]*blacksmith.Solid{slab}, 0.001, 0, 0.01)
	must(err)
	check(len(empty) == 0, "a slab read under 0.001")
	coarse, err := blacksmith.Thicknesses([]*blacksmith.Solid{slab}, 100, 0, 0.05)
	must(err)
	check(len(coarse) > 0, "a coarse slab read nothing")
	none0, err := blacksmith.Thicknesses(nil, 10, 0, 0.01)
	must(err)
	check(len(none0) == 0, "no solids read rows")

	// 7. Two triangles one apart read one across.
	lower := blacksmith.ThicknessInputMesh{
		Positions: [][3]float64{{0, 0, 0}, {0, 1, 0}, {1, 0, 0}}, Triangles: [][3]uint32{{0, 1, 2}}}
	upper := blacksmith.ThicknessInputMesh{
		Positions: [][3]float64{{0, 0, 1}, {1, 0, 1}, {0, 1, 1}}, Triangles: [][3]uint32{{0, 1, 2}}}
	meshes := []blacksmith.ThicknessInputMesh{lower, upper}
	mrows, err := blacksmith.MeshThicknesses(meshes, 10, 0.5)
	must(err)
	check(len(mrows) == 6, fmt.Sprintf("%d mesh rows", len(mrows)))
	for i, r := range mrows {
		check(near(r.Thickness, 1, 1e-12) && !r.Knife, fmt.Sprintf("mesh row %v", r))
		check(r.OppositeMesh == 1-r.Mesh && r.OppositeTriangle == 0, fmt.Sprintf("mesh row's opposite: %v", r))
		check(r.Point == meshes[r.Mesh].Positions[r.Vertex], fmt.Sprintf("mesh row's point %v", r.Point))
		check(near(r.Opposite[2], 1-r.Point[2], 1e-12) && r.Opposite[0] == r.Point[0] && r.Opposite[1] == r.Point[1],
			fmt.Sprintf("mesh row's opposite point %v", r.Opposite))
		check(int(r.Mesh) == i/3 && int(r.Vertex) == i%3, fmt.Sprintf("mesh row %d is (%d, %d)", i, r.Mesh, r.Vertex))
	}
	check(strings.HasPrefix(mrows[0].String(), "MeshThickness(mesh=0, vertex=0, thickness=1"), mrows[0].String())
	mrows, err = blacksmith.MeshThicknesses(meshes, 0.5, 0.5)
	must(err)
	check(len(mrows) == 0, "a mesh pair under the gap read rows")
	mrows, err = blacksmith.MeshThicknesses(nil, 1, 0)
	must(err)
	check(len(mrows) == 0, "no meshes read rows")

	// 8. Every refusal carries the call's prefix.
	_, err = blacksmith.NewThicknessGauge([]*blacksmith.Solid{plate}, 0)
	refused(err, "thickness_gauge_new: the tolerance must be positive and finite")
	rg := gaugeOf(0.01, plate)
	_, err = rg.Thickness(0, 0)
	refused(err, "thickness_gauge_measure: the maximum must be positive and finite")
	_, err = rg.Thickness(10, -0.1)
	refused(err, "thickness_gauge_measure: the sharp angle must be zero or positive and finite")
	_, err = rg.ThicknessAt(3, 0, [3]float64{1, 2, 1}, 10, 0)
	refused(err, "thickness_gauge_at: no body 3 -- there are 1")
	_, err = rg.ThicknessAt(0, 99, [3]float64{1, 2, 1}, 10, 0)
	refused(err, "thickness_gauge_at: no face 99 -- the solid has 6 (0 to 5)")
	_, err = rg.ThicknessAt(0, 0, [3]float64{1, math.NaN(), 1}, 10, 0)
	refused(err, "thickness_gauge_at: the point must be finite")
	_, err = rg.ThicknessAtFace(2, 0, nil, 10)
	refused(err, "thickness_gauge_face: no body 2 -- there are 1")
	_, err = rg.ThicknessAtFace(0, 99, nil, 10)
	refused(err, "thickness_gauge_face: no face 99 -- the solid has 6 (0 to 5)")
	inf := [3]float64{math.Inf(1), 0, 1}
	_, err = rg.ThicknessAtFace(0, 0, &inf, 10)
	refused(err, "thickness_gauge_face: the point must be finite")
	_, err = rg.ThicknessAtFace(0, 0, nil, 0)
	refused(err, "thickness_gauge_face: the maximum must be positive and finite")
	rg.Close()
	rg.Close() // twice is a no-op
	check(rg.Closed(), "a closed gauge reads open")
	for name, err := range map[string]error{
		"Len":       func() error { _, err := rg.Len(); return err }(),
		"Tolerance": func() error { _, err := rg.Tolerance(); return err }(),
		"Thickness": func() error { _, err := rg.Thickness(10, 0); return err }(),
		"ThicknessAt": func() error {
			_, err := rg.ThicknessAt(0, 0, [3]float64{1, 2, 1}, 10, 0)
			return err
		}(),
		"ThicknessAtFace": func() error { _, err := rg.ThicknessAtFace(0, 0, nil, 10); return err }(),
		"Mesh":            func() error { _, err := rg.Mesh(0); return err }(),
	} {
		check(errors.Is(err, blacksmith.ErrClosed) && strings.HasPrefix(err.Error(), "thickness_gauge: closed"),
			fmt.Sprintf("a closed gauge's %s: %v", name, err))
	}
	check(rg.String() == "ThicknessGauge(closed)", rg.String())
	// the conveniences refuse with the gauge call's own prefix
	_, err = blacksmith.Thicknesses([]*blacksmith.Solid{plate}, -1, 0, 0.01)
	refused(err, "thickness_gauge_measure: the maximum must be positive and finite")
	_, err = blacksmith.Thicknesses([]*blacksmith.Solid{plate}, 10, 0, math.NaN())
	refused(err, "thickness_gauge_new: the tolerance must be positive and finite")
	_, err = plate.ThicknessAtFace(99, nil, 10, 0.01)
	refused(err, "thickness_gauge_face: no face 99")
	// mesh_thickness: the kernel's refusals
	_, err = blacksmith.MeshThicknesses(meshes, 0, 0)
	refused(err, "mesh_thickness: the maximum must be positive and finite")
	_, err = blacksmith.MeshThicknesses(meshes, 10, -0.5)
	refused(err, "mesh_thickness: the sharp angle must be zero or positive and finite")
	_, err = blacksmith.MeshThicknesses([]blacksmith.ThicknessInputMesh{{
		Positions: [][3]float64{{0, 0, 0}, {1, 0, 0}}, Triangles: [][3]uint32{{0, 1, 2}}}}, 10, 0)
	refused(err, "mesh_thickness: a triangle names a position past the mesh")
	_, err = blacksmith.MeshThicknesses([]blacksmith.ThicknessInputMesh{{
		Positions: [][3]float64{{0, 0, 0}, {1, math.NaN(), 0}, {0, 1, 0}}, Triangles: [][3]uint32{{0, 1, 2}}}}, 10, 0)
	refused(err, "mesh_thickness: a mesh position is not finite")

	// The gauge keeps its own reference: it answers after its solid is closed, and a mesh
	// outlives its gauge.
	kept := solid(blacksmith.Cuboid(10, 10, 2))
	kg := gaugeOf(0.01, kept)
	kept.Close()
	krows, err := kg.Thickness(10, 0)
	must(err)
	check(len(krows) > 0, "a gauge of a closed solid read nothing")
	km, err := kg.Mesh(0)
	must(err)
	kg.Close()
	check(len(km.Positions) == len(krows), fmt.Sprintf("a mesh past its gauge: %d positions for %d rows", len(km.Positions), len(krows)))
	closed := solid(blacksmith.Cuboid(1, 1, 1))
	closed.Close()
	_, err = blacksmith.NewThicknessGauge([]*blacksmith.Solid{closed}, 0.01)
	check(errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("a gauge of a closed solid: %v", err))

	fmt.Printf("thickness: plate %g at %d cap rows of %d, wedge ball %g, %d mesh rows\n", rows[0].Thickness, caps, len(rows), *wide.Sphere, 6)
}

// rtree: Python's test_rtree_*, trimmed to what proves the marshalling (rtree plan 3): every
// field read, every refusal's prefix, list length and order, and the handle's lifetime.
func rtree() {
	must := func(err error) {
		if err != nil {
			fail("rtree: " + err.Error())
		}
	}
	check := func(ok bool, why string) {
		if !ok {
			fail("rtree: " + why)
		}
	}
	refused := func(err error, prefix string, parts ...string) {
		if err == nil || !strings.HasPrefix(err.Error(), prefix) {
			fail(fmt.Sprintf("rtree: expected a refusal starting %q, got %v", prefix, err))
		}
		for _, p := range parts {
			if !strings.Contains(err.Error(), p) {
				fail(fmt.Sprintf("rtree: the refusal %q does not contain %q", err.Error(), p))
			}
		}
	}
	tree := func(t *blacksmith.RTree, err error) *blacksmith.RTree {
		must(err)
		return t
	}
	box := func(x0, y0, z0, x1, y1, z1 float64) blacksmith.Box {
		return blacksmith.Box{Lo: [3]float64{x0, y0, z0}, Hi: [3]float64{x1, y1, z1}}
	}
	pairsSorted := func(ps []blacksmith.RTreePair) bool {
		for i := 1; i < len(ps); i++ {
			p, q := ps[i-1], ps[i]
			if p.A > q.A || (p.A == q.A && p.B > q.B) {
				return false
			}
		}
		return true
	}
	dist := func(a, b [3]float64) float64 {
		return math.Sqrt((a[0]-b[0])*(a[0]-b[0]) + (a[1]-b[1])*(a[1]-b[1]) + (a[2]-b[2])*(a[2]-b[2]))
	}
	byDistance := func(hay [][3]float64, q [3]float64) []int {
		order := make([]int, len(hay))
		for i := range order {
			order[i] = i
		}
		sort.SliceStable(order, func(x, y int) bool { return dist(hay[order[x]], q) < dist(hay[order[y]], q) })
		return order
	}

	// 1. the grid, packed and inserted one at a time
	var cells []blacksmith.RTreeEntry
	var corner []uint32
	for i := 0; i < 10; i++ {
		for j := 0; j < 10; j++ {
			for k := 0; k < 10; k++ {
				id := uint32(100*i + 10*j + k)
				cells = append(cells, blacksmith.RTreeEntry{ID: id, Box: box(float64(i), float64(j), float64(k), float64(i+1), float64(j+1), float64(k+1))})
				if i <= 2 && j <= 2 && k <= 2 {
					corner = append(corner, id)
				}
			}
		}
	}
	packed := tree(blacksmith.RTreeFromBoxes(cells))
	defer packed.Close()
	grown := tree(blacksmith.NewRTree())
	defer grown.Close()
	for n := len(cells) - 1; n >= 0; n-- {
		must(grown.Insert(cells[n].ID, cells[n].Box))
	}
	var answers [][]blacksmith.RTreePair
	for _, t := range []*blacksmith.RTree{packed, grown} {
		name := "RTreeFromBoxes"
		if t == grown {
			name = "Insert"
		}
		size, err := t.Len()
		must(err)
		check(size == 1000, fmt.Sprintf("%s: size %d", name, size))
		b, err := t.Bounds()
		must(err)
		check(b != nil && *b == box(0, 0, 0, 10, 10, 10), fmt.Sprintf("%s: bounds %v", name, b))
		found, err := t.Search(box(0, 0, 0, 2, 2, 2))
		must(err)
		check(slices.Equal(found, corner), fmt.Sprintf("%s: search found %v", name, found))
		near, err := t.Nearest([3]float64{-1, -1, -1}, 1)
		must(err)
		check(len(near) == 1 && near[0].ID == 0 && math.Abs(near[0].Distance-math.Sqrt(3)) <= 1e-12, fmt.Sprintf("%s: nearest %v", name, near))
		at, err := t.Within([3]float64{0, 0, 0}, 0)
		must(err)
		check(slices.Equal(at, []blacksmith.RTreeHit{{ID: 0, Distance: 0}}), fmt.Sprintf("%s: within 0 %v", name, at))
		four, err := t.Within([3]float64{-1, -1, -1}, 2.5)
		must(err)
		var fourIDs []uint32
		for _, h := range four {
			fourIDs = append(fourIDs, h.ID)
		}
		check(slices.Equal(fourIDs, []uint32{0, 1, 10, 100}), fmt.Sprintf("%s: within 2.5 %v", name, four))
		pairs, err := t.SelfOverlaps(0)
		must(err)
		ordered := pairsSorted(pairs)
		for _, p := range pairs {
			ordered = ordered && p.A < p.B
		}
		check(len(pairs) == (28*28*28-1000)/2 && ordered, fmt.Sprintf("%s: self overlaps %d, or a pair out of order", name, len(pairs)))
		half, err := t.SelfOverlaps(0.5)
		must(err)
		check(slices.Equal(half, pairs), fmt.Sprintf("%s: unit gaps paired at slack 0.5", name))
		answers = append(answers, pairs)
	}
	check(slices.Equal(answers[0], answers[1]), "the packed and the grown trees disagree")

	// 2. two trees, and the same tree twice
	one := tree(blacksmith.RTreeFromBoxes([]blacksmith.RTreeEntry{{ID: 7, Box: box(4.5, 4.5, 4.5, 5.5, 5.5, 5.5)}}))
	defer one.Close()
	cross, err := packed.Overlaps(one, 0)
	must(err)
	var want, back []blacksmith.RTreePair
	for _, a := range []uint32{444, 445, 454, 455, 544, 545, 554, 555} {
		want = append(want, blacksmith.RTreePair{A: a, B: 7})
		back = append(back, blacksmith.RTreePair{A: 7, B: a})
	}
	check(slices.Equal(cross, want), fmt.Sprintf("overlaps: %v", cross))
	other, err := one.Overlaps(packed, 0)
	must(err)
	check(slices.Equal(other, back), fmt.Sprintf("overlaps the other way round: %v", other))
	twice, err := packed.Overlaps(packed, 0)
	must(err)
	check(len(twice) == 1000+2*10476 && pairsSorted(twice), fmt.Sprintf("overlaps: the grid with itself gave %d", len(twice)))

	// 3. points, insert and remove
	pts := tree(blacksmith.RTreeFromPoints([][3]float64{{0, 0, 0}, {5, 0, 0}, {1, 0, 0}, {0, 3, 0}}))
	defer pts.Close()
	ids, err := pts.Search(box(-0.1, -0.1, -0.1, 1.1, 0.1, 0.1))
	must(err)
	check(slices.Equal(ids, []uint32{0, 2}), fmt.Sprintf("from points: ids are not the indices: %v", ids))
	two, err := pts.Nearest([3]float64{4, 0, 0}, 2)
	must(err)
	check(slices.Equal(two, []blacksmith.RTreeHit{{ID: 1, Distance: 1}, {ID: 2, Distance: 3}}), fmt.Sprintf("from points: nearest %v", two))
	{
		t := tree(blacksmith.NewRTree())
		cell := box(3, 3, 3, 4, 4, 4)
		must(t.Insert(7, cell))
		must(t.Insert(7, cell))
		found, err := t.Search(cell)
		must(err)
		check(slices.Equal(found, []uint32{7, 7}), "insert: one (id, box) twice is two entries")
		for n, w := range []bool{true, true, false} {
			gone, err := t.Remove(7, cell)
			must(err)
			check(gone == w, fmt.Sprintf("remove %d: %v, not %v", n, gone, w))
		}
		must(t.Insert(7, cell))
		gone, err := t.Remove(8, cell)
		must(err)
		check(!gone, "remove: another id took the entry out")
		gone, err = t.Remove(7, box(3, 3, 3, 4, 4, 4.5))
		must(err)
		check(!gone, "remove: another box took the entry out")
		point := [3]float64{1, 2, 3}
		must(t.InsertPoint(9, point))
		size, err := t.Len()
		must(err)
		b, err := t.Bounds()
		must(err)
		check(size == 2 && b != nil && *b == blacksmith.Box{Lo: point, Hi: [3]float64{4, 4, 4}}, fmt.Sprintf("insert: a point, bounds %v", b))
		gonePoint, err := t.RemovePoint(9, point)
		must(err)
		goneBox, err := t.Remove(7, cell)
		must(err)
		check(gonePoint && goneBox, "remove: the point or the box stayed")
		size, err = t.Len()
		must(err)
		b, err = t.Bounds()
		must(err)
		check(size == 0 && b == nil, fmt.Sprintf("remove: emptied, the tree still has bounds %v", b))
		big := uint32(math.MaxUint32)
		must(t.InsertPoint(big, point))
		found, err = t.Search(box(0, 0, 0, 5, 5, 5))
		must(err)
		check(slices.Equal(found, []uint32{big}), fmt.Sprintf("insert: the largest id did not come back whole: %v", found))
		gone, err = t.RemovePoint(big, point)
		must(err)
		check(gone, "remove: the largest id stayed")
		t.Close()
	}

	// 4. point neighbours against brute force
	state := uint64(5)
	next := func() float64 {
		state = state*6364136223846793005 + 1442695040888963407
		return float64(state>>11) / float64(uint64(1)<<53)
	}
	var hay, needles [][3]float64
	for i := 0; i < 30; i++ {
		hay = append(hay, [3]float64{10 * next(), 10 * next(), 10 * next()})
	}
	for i := 0; i < 5; i++ {
		needles = append(needles, [3]float64{10 * next(), 10 * next(), 10 * next()})
	}
	closest, err := blacksmith.ClosestPoints(hay, needles, 3.0)
	must(err)
	knn, err := blacksmith.KNeighbors(hay, needles, 4)
	must(err)
	check(len(closest) == 5 && len(knn) == 5, "closest points / k neighbors: not one answer per needle")
	someClose, allClose := false, true
	for n, q := range needles {
		order := byDistance(hay, q)
		var inLimit []int
		for _, i := range order {
			if dist(hay[i], q) <= 3.0 {
				inLimit = append(inLimit, i)
			}
		}
		check(slices.Equal(closest[n], inLimit), fmt.Sprintf("closest points: needle %d gave %v, not %v", n, closest[n], inLimit))
		check(slices.Equal(knn[n], order[:4]), fmt.Sprintf("k neighbors: needle %d gave %v, not %v", n, knn[n], order[:4]))
		someClose = someClose || len(inLimit) > 0
		allClose = allClose && len(inLimit) == len(hay)
	}
	check(someClose && !allClose, "closest points: the limit chose nothing or everything")
	all, err := blacksmith.KNeighbors(hay, needles[:2], 500)
	must(err)
	check(len(all) == 2 && slices.Equal(all[1], byDistance(hay, needles[1])), "k neighbors: k over the hay count is not every point")
	none, err := blacksmith.KNeighbors(nil, needles[:2], 3)
	must(err)
	check(len(none) == 2 && len(none[0]) == 0 && len(none[1]) == 0, fmt.Sprintf("k neighbors: an empty hay found %v", none))

	// 5. refusals, by the call's name
	nan, inf := math.NaN(), math.Inf(1)
	{
		t := tree(blacksmith.NewRTree())
		refused(t.Insert(1, box(0, 0, 0, nan, 1, 1)), "rtree_insert: ", "is not a box")
		refused(t.Insert(1, box(1, 0, 0, 0, 1, 1)), "rtree_insert: ", "is not a box")
		refused(t.InsertPoint(1, [3]float64{inf, 0, 0}), "rtree_insert_point: ", "is not finite")
		size, err := t.Len()
		must(err)
		check(size == 0, "insert: a refused insert changed the tree")
		_, err = t.Remove(1, box(1, 0, 0, 0, 1, 1))
		refused(err, "rtree_remove: ")
		gone, err := t.Remove(1, box(0, 0, 0, 1, 1, 1))
		must(err)
		check(!gone, "remove: absent right after a refusal read true")
		_, err = t.Search(box(0, 0, 0, nan, 1, 1))
		refused(err, "rtree_search: ")
		_, err = t.Within([3]float64{nan, 0, 0}, 1)
		refused(err, "rtree_within: ", "is not finite")
		_, err = t.Nearest([3]float64{nan, 0, 0}, 1)
		refused(err, "rtree_nearest: ", "is not finite")
		_, err = t.Within([3]float64{0, 0, 0}, -1)
		check(err != nil && err.Error() == "rtree_within: radius -1 is not a distance", fmt.Sprintf("within: radius -1 gave %v", err))
		_, err = t.SelfOverlaps(nan)
		check(err != nil && err.Error() == "rtree_self_overlaps: slack NaN is not a distance", fmt.Sprintf("self overlaps: slack NaN gave %v", err))
		_, err = t.Overlaps(t, -0.5)
		refused(err, "rtree_overlaps: ")
		_, err = t.Nearest([3]float64{0, 0, 0}, 1_000_001)
		check(err != nil && err.Error() == "rtree_nearest: k 1000001 is not at most 1000000", fmt.Sprintf("nearest: k 1000001 gave %v", err))
		var be *blacksmith.BuildError
		check(errors.As(err, &be), fmt.Sprintf("nearest: the refusal is not a *BuildError: %T", err))
		t.Close()
	}
	_, err = blacksmith.RTreeFromBoxes([]blacksmith.RTreeEntry{{ID: 1, Box: box(0, 0, 0, 1, 1, 1)}, {ID: 2, Box: box(2, 0, 0, 1, 1, 1)}})
	refused(err, "rtree_from_boxes: entry 1")
	_, err = blacksmith.RTreeFromPoints([][3]float64{{0, 0, 0}, {0, nan, 0}})
	check(err != nil && err.Error() == "rtree_from_points: point 1 is not finite", fmt.Sprintf("from points: a NaN point 1 gave %v", err))
	origin := [][3]float64{{0, 0, 0}}
	_, err = blacksmith.ClosestPoints(origin, origin, -1)
	check(err != nil && err.Error() == "closest_points: limit -1 is not a distance", fmt.Sprintf("closest points: limit -1 gave %v", err))
	_, err = blacksmith.ClosestPoints([][3]float64{{0, 0, 0}, {nan, 0, 0}}, [][3]float64{{inf, 0, 0}}, -1)
	check(err != nil && err.Error() == "closest_points: limit -1 is not a distance", fmt.Sprintf("closest points: the limit is not checked first: %v", err))
	_, err = blacksmith.ClosestPoints(origin, [][3]float64{{nan, 0, 0}}, 1)
	check(err != nil && err.Error() == "closest_points: needle point 0 is not finite", fmt.Sprintf("closest points: a NaN needle gave %v", err))
	_, err = blacksmith.ClosestPoints([][3]float64{{0, 0, 0}, {0, 0, nan}}, [][3]float64{{nan, 0, 0}}, 1)
	check(err != nil && err.Error() == "closest_points: hay point 1 is not finite", fmt.Sprintf("closest points: the hay is not checked before the needles: %v", err))
	_, err = blacksmith.KNeighbors([][3]float64{{0, 0, 0}, {inf, 0, 0}}, origin, 1_000_001)
	check(err != nil && err.Error() == "k_neighbors: hay point 1 is not finite", fmt.Sprintf("k neighbors: an infinite hay point before a bad k gave %v", err))
	_, err = blacksmith.KNeighbors(origin, origin, 1_000_001)
	check(err != nil && err.Error() == "k_neighbors: k 1000001 is not at most 1000000", fmt.Sprintf("k neighbors: k 1000001 gave %v", err))

	// 6. lifetime: an empty tree answers nothing; a closed one refuses
	empty := tree(blacksmith.NewRTree())
	size, err := empty.Len()
	must(err)
	b, err := empty.Bounds()
	must(err)
	check(size == 0 && b == nil, fmt.Sprintf("an empty tree: size %d, bounds %v", size, b))
	s, err := empty.Search(box(0, 0, 0, 1, 1, 1))
	must(err)
	w, err := empty.Within([3]float64{0, 0, 0}, 10)
	must(err)
	nr, err := empty.Nearest([3]float64{0, 0, 0}, 3)
	must(err)
	so, err := empty.SelfOverlaps(0)
	must(err)
	ov, err := empty.Overlaps(packed, 0)
	must(err)
	check(len(s) == 0 && len(w) == 0 && len(nr) == 0 && len(so) == 0 && len(ov) == 0, "an empty tree answered something")
	check(!empty.Closed(), "a live tree reads closed")
	empty.Close()
	empty.Close()
	check(empty.Closed(), "a closed tree reads live")
	closedCalls := map[string]error{}
	_, closedCalls["Len"] = empty.Len()
	_, closedCalls["Bounds"] = empty.Bounds()
	closedCalls["Insert"] = empty.Insert(1, box(0, 0, 0, 1, 1, 1))
	closedCalls["InsertPoint"] = empty.InsertPoint(1, [3]float64{0, 0, 0})
	_, closedCalls["Remove"] = empty.Remove(1, box(0, 0, 0, 1, 1, 1))
	_, closedCalls["RemovePoint"] = empty.RemovePoint(1, [3]float64{0, 0, 0})
	_, closedCalls["Search"] = empty.Search(box(0, 0, 0, 1, 1, 1))
	_, closedCalls["Within"] = empty.Within([3]float64{0, 0, 0}, 1)
	_, closedCalls["Nearest"] = empty.Nearest([3]float64{0, 0, 0}, 1)
	_, closedCalls["SelfOverlaps"] = empty.SelfOverlaps(0)
	_, closedCalls["Overlaps"] = empty.Overlaps(packed, 0)
	_, closedCalls["Overlaps(other)"] = packed.Overlaps(empty, 0)
	var nilTree *blacksmith.RTree
	_, closedCalls["nil Len"] = nilTree.Len()
	for name, err := range closedCalls {
		check(err != nil && err.Error() == "rtree: closed" && errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("%s: a closed tree gave %v", name, err))
	}
	fmt.Printf("rtree: grid of 1000, %d self pairs, points, neighbours, refusals and lifetime all read back\n", len(answers[0]))
}

// interpolatorAndMerge: Python's test_interpolator_*, test_circumscribed_polygon_touches_its_circle,
// test_merge_* and test_a_merged_body_is_refused_*, trimmed to what proves the marshalling
// (interpolator / merge wrappers plan): every field read, every refusal's prefix, list length
// and order, and the handle's lifetime. Join takes no progress callback here, so neither does
// Merge, and the phases are not read.
func interpolatorAndMerge() {
	must := func(err error) {
		if err != nil {
			fail("interpolator/merge: " + err.Error())
		}
	}
	check := func(ok bool, why string) {
		if !ok {
			fail("interpolator/merge: " + why)
		}
	}
	refused := func(err error, prefix string) {
		if err == nil || !strings.HasPrefix(err.Error(), prefix) {
			fail(fmt.Sprintf("interpolator/merge: expected a refusal starting %q, got %v", prefix, err))
		}
		var be *blacksmith.BuildError
		if !errors.As(err, &be) {
			fail(fmt.Sprintf("interpolator/merge: %q is not a *BuildError", err.Error()))
		}
	}
	near := func(a, b, tol float64) bool { return math.Abs(a-b) <= tol }
	one := func(v []float64, err error) float64 {
		must(err)
		check(len(v) == 1, fmt.Sprintf("a dimension-1 answer of %d numbers", len(v)))
		return v[0]
	}
	all := func(v, w []float64, tol float64) bool {
		if len(v) != len(w) {
			return false
		}
		for k := range v {
			if !near(v[k], w[k], tol) {
				return false
			}
		}
		return true
	}
	modes := []blacksmith.InterpolatorMode{blacksmith.InterpolateNearest, blacksmith.InterpolateLinear,
		blacksmith.InterpolateCosine, blacksmith.InterpolateCubic, blacksmith.InterpolateCatmullRom}

	// 1. the squares, open and cyclic
	squares := []float64{0, 1, 4, 9, 16}
	sq, err := blacksmith.NewInterpolator(squares, false)
	must(err)
	n, err := sq.Len()
	must(err)
	d, err := sq.Dimension()
	must(err)
	cyc, err := sq.Cyclic()
	must(err)
	check(n == 5 && d == 1 && !cyc, fmt.Sprintf("squares: %d samples of %d, cyclic %v", n, d, cyc))
	for _, m := range modes {
		for k, y := range squares {
			check(near(one(sq.At(float64(k), m)), y, 1e-12), fmt.Sprintf("squares: mode %d at %d", m, k))
		}
		check(near(one(sq.At(-2, m)), 0, 1e-12) && near(one(sq.At(7, m)), 16, 1e-12), fmt.Sprintf("squares: mode %d not clamped", m))
	}
	check(one(sq.Nearest(1.5)) == 4 && one(sq.Nearest(1.49)) == 1, "squares: nearest")
	check(near(one(sq.Linear(1.5)), 2.5, 1e-12), "squares: linear(1.5)")
	check(near(one(sq.Cosine(1.5)), 2.5, 1e-12), "squares: cosine(1.5)")
	check(near(one(sq.Cosine(1.25)), 1+3*(1-math.Cos(math.Pi/4))/2, 1e-12), "squares: cosine(1.25)")
	check(near(one(sq.Cubic(1.5)), 2.0, 1e-12), "squares: cubic(1.5)")
	check(near(one(sq.CatmullRom(1.5)), 2.25, 1e-12), "squares: catmull_rom(1.5)")
	check(one(sq.At(1.5, blacksmith.InterpolateLinear)) == one(sq.Linear(1.5)), "squares: At Linear is not Linear")
	ring, err := blacksmith.NewInterpolator(squares, true)
	must(err)
	cyc, err = ring.Cyclic()
	must(err)
	check(cyc, "ring: not cyclic")
	check(near(one(ring.CatmullRom(5)), one(ring.CatmullRom(0)), 1e-12), "ring: catmull_rom(5) is not catmull_rom(0)")
	check(near(one(ring.Linear(-0.5)), 8.0, 1e-12), "ring: linear(-0.5)")
	ring.Close()

	// 2. points, and Sample a loop of At
	var helix [][]float64
	for k := 0; k < 9; k++ {
		helix = append(helix, []float64{math.Cos(0.7 * float64(k)), math.Sin(0.7 * float64(k)), 0.3 * float64(k)})
	}
	hx, err := blacksmith.NewInterpolatorRows(helix, false)
	must(err)
	defer hx.Close()
	n, err = hx.Len()
	must(err)
	d, err = hx.Dimension()
	must(err)
	check(n == 9 && d == 3, fmt.Sprintf("helix: %d samples of %d", n, d))
	at2, err := hx.At(2, blacksmith.InterpolateLinear)
	must(err)
	check(all(at2, helix[2], 1e-12), fmt.Sprintf("helix: at(2) %v", at2))
	cr, err := hx.CatmullRom(2.5)
	must(err)
	check(len(cr) == 3, fmt.Sprintf("helix: catmull_rom(2.5) %v", cr))
	var ts []float64
	for k := 0; k < 50; k++ {
		ts = append(ts, -1.0+10.0*float64(k)/49)
	}
	for _, m := range modes {
		got, err := hx.Sample(ts, m)
		must(err)
		check(len(got) == len(ts), fmt.Sprintf("helix: sample gave %d values for %d", len(got), len(ts)))
		for k, t := range ts {
			want, err := hx.At(t, m)
			must(err)
			check(slices.Equal(got[k], want), fmt.Sprintf("helix: mode %d sample %d is %v, at %v", m, k, got[k], want))
		}
	}
	none, err := hx.Sample(nil, blacksmith.InterpolateLinear)
	must(err)
	check(len(none) == 0, "helix: sample of nothing")
	square, err := blacksmith.NewInterpolatorRows([][]float64{{0, 0}, {1, 0}, {1, 1}, {0, 1}}, true)
	must(err)
	half, err := square.Linear(-0.5)
	must(err)
	check(all(half, []float64{0, 0.5}, 1e-12), fmt.Sprintf("square: linear(-0.5) %v", half))
	two, err := square.Sample([]float64{0.5, 1.5}, blacksmith.InterpolateLinear)
	must(err)
	check(len(two) == 2 && all(two[0], []float64{0.5, 0}, 1e-12) && all(two[1], []float64{1, 0.5}, 1e-12), fmt.Sprintf("square: sample %v", two))
	square.Close()

	// 3. refusals and the lifetime
	_, err = blacksmith.NewInterpolator(nil, false)
	refused(err, "interpolator_new: no samples")
	_, err = blacksmith.NewInterpolatorRows(nil, false)
	refused(err, "interpolator_new: no samples")
	_, err = blacksmith.NewInterpolator([]float64{0, 1, math.NaN()}, false)
	refused(err, "interpolator_new: sample 2 is not finite")
	_, err = blacksmith.NewInterpolatorRows([][]float64{{0, 1}, {2, 3, 4}}, false)
	refused(err, "interpolator: samples differ in length")
	_, err = sq.Linear(math.NaN())
	refused(err, "interpolator_at: t NaN is not finite")
	_, err = sq.At(1, blacksmith.InterpolatorMode(7))
	refused(err, "interpolator_at: mode 7 is not a mode")
	_, err = sq.Sample([]float64{0, math.Inf(1)}, blacksmith.InterpolateLinear)
	refused(err, "interpolator_sample: t 1 (inf) is not finite")
	check(sq.String() == "Interpolator(5 samples of 1)", sq.String())
	sq.Close()
	sq.Close()
	check(sq.Closed() && sq.String() == "Interpolator(closed)", "closed: "+sq.String())
	closedCalls := map[string]error{}
	_, closedCalls["Len"] = sq.Len()
	_, closedCalls["Dimension"] = sq.Dimension()
	_, closedCalls["Cyclic"] = sq.Cyclic()
	_, closedCalls["Linear"] = sq.Linear(1)
	_, closedCalls["Sample"] = sq.Sample([]float64{1}, blacksmith.InterpolateLinear)
	var nilInterp *blacksmith.Interpolator
	_, closedCalls["nil Len"] = nilInterp.Len()
	for name, err := range closedCalls {
		check(err != nil && err.Error() == "interpolator: closed" && errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("%s: a closed interpolator gave %v", name, err))
	}

	// 4. the circumscribed polygon
	centre, r, sides := [2]float64{2, -1}, 5.0, 6
	hex, err := blacksmith.CircumscribedPolygon(centre, r, sides, 0.3)
	must(err)
	defer hex.Close()
	length, err := hex.Length(0)
	must(err)
	perimeter := 2 * float64(sides) * r * math.Tan(math.Pi/float64(sides))
	check(math.Abs(length.Length-perimeter) <= 1e-9*perimeter, fmt.Sprintf("circumscribed: length %v, not %v", length.Length, perimeter))
	// Twelve equal steps round the outline from its first corner: corners and side midpoints
	// alternately.
	steps, err := hex.DivideByCount(uint32(2*sides), 0)
	must(err)
	check(len(steps) >= 2*sides, fmt.Sprintf("circumscribed: %d steps", len(steps)))
	for k := 0; k < 2*sides; k++ {
		p := steps[k].Point
		want := r
		if k%2 == 0 {
			want = r / math.Cos(math.Pi/float64(sides))
		}
		got := math.Hypot(p[0]-centre[0], p[1]-centre[1])
		check(math.Abs(got-want) <= 1e-6*want, fmt.Sprintf("circumscribed: step %d at %v from the centre, not %v", k, got, want))
	}
	first := steps[0].Point
	check(near(math.Atan2(first[1]-centre[1], first[0]-centre[0]), 0.3, 1e-9), fmt.Sprintf("circumscribed: first corner at %v", first))
	_, err = blacksmith.CircumscribedPolygon([2]float64{0, 0}, 10, 2, 0)
	refused(err, "profile_circumscribed_polygon: a polygon has at least 3 sides, not 2")
	_, err = blacksmith.CircumscribedPolygon([2]float64{0, 0}, 10, -1, 0)
	refused(err, "profile_circumscribed_polygon: sides is out of range: -1")
	_, err = blacksmith.CircumscribedPolygon([2]float64{0, 0}, 10, 1<<32, 0)
	refused(err, "profile_circumscribed_polygon: sides is out of range: 4294967296")

	// 5. two cubes at a corner
	const tol = 1e-6
	a, err := blacksmith.Cuboid(1, 1, 1)
	must(err)
	defer a.Close()
	b, err := a.Translate(0.5, 0.5, 0.5)
	must(err)
	defer b.Close()
	m, err := a.Merge(b, tol)
	must(err)
	defer m.Close()
	faces, err := m.Faces()
	must(err)
	check(faces == 18, fmt.Sprintf("merge: %d faces", faces))
	regions, err := m.Regions()
	must(err)
	check(len(regions) == 4, fmt.Sprintf("merge: %d regions", len(regions)))
	total := 0
	covered := map[uint32]bool{}
	for i, reg := range regions {
		check(reg.Index == uint32(i), fmt.Sprintf("merge: region %d has index %d", i, reg.Index))
		check(reg.Finite == (i > 0), fmt.Sprintf("merge: region %d finite %v", i, reg.Finite))
		check(reg.Shells == 1, fmt.Sprintf("merge: region %d has %d shells", i, reg.Shells))
		for k, s := range reg.Sides {
			check(s.Sense == 1 || s.Sense == -1, fmt.Sprintf("merge: region %d side %d sense %d", i, k, s.Sense))
			if k > 0 {
				p := reg.Sides[k-1]
				check(p.Face < s.Face || (p.Face == s.Face && p.Sense < s.Sense), fmt.Sprintf("merge: region %d sides out of order at %d", i, k))
			}
			if i > 0 {
				covered[s.Face] = true
			}
		}
		total += len(reg.Sides)
	}
	check(total == 2*faces, fmt.Sprintf("merge: %d sides, not each face's two", total))
	check(len(covered) == faces, fmt.Sprintf("merge: the cells cover %d faces of %d", len(covered), faces))
	for f := 0; f < faces; f++ {
		check(covered[uint32(f)], fmt.Sprintf("merge: face %d bounds no cell", f))
	}
	volumes := map[int]float64{}
	for i := 1; i < len(regions); i++ {
		cell, err := m.RegionSolid(i)
		must(err)
		mass, err := cell.Mass(0)
		must(err)
		volumes[i] = mass.Volume
		cell.Close()
	}
	sorted := []float64{volumes[1], volumes[2], volumes[3]}
	sort.Float64s(sorted)
	check(near(sorted[0], 0.125, 1e-6) && near(sorted[1], 0.875, 1e-6) && near(sorted[2], 0.875, 1e-6), fmt.Sprintf("merge: cell volumes %v", sorted))
	small := 0
	for i, v := range volumes {
		if near(v, 0.125, 1e-6) {
			small = i
		}
	}
	overlap := regions[small]
	allBehind := len(overlap.Sides) == 6
	for _, s := range overlap.Sides {
		allBehind = allBehind && s.Sense == -1
	}
	check(allBehind, fmt.Sprintf("merge: the overlap's sides %v", overlap.Sides))
	check(all(overlap.Box.Lo[:], []float64{0, 0, 0}, 1e-6) && all(overlap.Box.Hi[:], []float64{0.5, 0.5, 0.5}, 1e-6), fmt.Sprintf("merge: the overlap's box %v", overlap.Box))
	again, err := m.Regions()
	must(err)
	same := len(again) == len(regions)
	for i := 0; same && i < len(again); i++ {
		p, q := again[i], regions[i]
		same = p.Index == q.Index && p.Finite == q.Finite && p.Box == q.Box && p.Shells == q.Shells && slices.Equal(p.Sides, q.Sides)
	}
	check(same, "merge: Regions twice disagree")

	// 6. a ball merged into the box
	ball, err := blacksmith.Sphere(0.3)
	must(err)
	defer ball.Close()
	bm, err := a.Merge(ball, tol)
	must(err)
	defer bm.Close()
	bregions, err := bm.Regions()
	must(err)
	check(len(bregions) == 3, fmt.Sprintf("ball in a box: %d regions", len(bregions)))
	bv := 4.0 / 3.0 * math.Pi * 0.3 * 0.3 * 0.3
	bvol := map[int]float64{}
	for i := 1; i < 3; i++ {
		cell, err := bm.RegionSolid(i)
		must(err)
		mass, err := cell.Mass(0)
		must(err)
		bvol[i] = mass.Volume
		cell.Close()
	}
	boxCell := 1
	if bvol[2] > bvol[1] {
		boxCell = 2
	}
	check(near(bvol[boxCell], 1-bv, 1e-6) && near(bvol[3-boxCell], bv, 1e-6), fmt.Sprintf("ball in a box: volumes %v", bvol))
	check(bregions[boxCell].Shells == 2 && bregions[3-boxCell].Shells == 1, fmt.Sprintf("ball in a box: shells %d, %d", bregions[boxCell].Shells, bregions[3-boxCell].Shells))

	// 7. the merged body refused by the manifold verbs, its cells not
	_, err = m.Join(a, tol)
	refused(err, "join: the join needs a manifold solid, and this one has edges of three or more faces")
	_, err = m.Mass(0)
	refused(err, "mass_properties: the mass needs a manifold solid")
	_, err = m.RegionSolid(0)
	refused(err, "region_solid: region 0 is the infinite region")
	_, err = m.RegionSolid(4)
	refused(err, "region_solid: region 4 is not below 4")
	_, err = m.RegionSolid(-1)
	refused(err, "region_solid: region is out of range: -1")
	_, err = m.RegionSolid(1 << 32)
	refused(err, "region_solid: region is out of range: 4294967296")
	_, err = a.Merge(a, 0)
	refused(err, "merge: tolerance must be positive and finite")
	cell, err := m.RegionSolid(1)
	must(err)
	defer cell.Close()
	joined, err := cell.Join(a, tol)
	must(err)
	defer joined.Close()
	jf, err := joined.Faces()
	must(err)
	check(jf > 0, "merge: a cell joined to the cube has no faces")
	plain, err := a.Regions()
	must(err)
	check(len(plain) == 2, fmt.Sprintf("cube: %d regions", len(plain)))
	for _, s := range plain[0].Sides {
		check(s.Sense == 1, "cube: an outside side behind its face")
	}
	for _, s := range plain[1].Sides {
		check(s.Sense == -1, "cube: an inside side in front of its face")
	}
	check(len(plain[0].Sides) == 6 && len(plain[1].Sides) == 6, "cube: not six sides a region")
	var closedSolid *blacksmith.Solid
	_, err = closedSolid.Regions()
	check(err != nil && errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("regions: a nil solid gave %v", err))
	_, err = a.Merge(closedSolid, tol)
	check(err != nil && errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("merge: a nil other gave %v", err))
	fmt.Printf("interpolator/merge: squares, helix, refusals; hexagon of %g; %d + %d regions, cells %v\n", length.Length, len(regions), len(bregions), sorted)
}

// rtreeRays: rays, triangle trees and a solid's face tree, Python's tests trimmed (rtree plan 6).
func rtreeRays() {
	check := func(ok bool, why string) {
		if !ok {
			fail("rtree: " + why)
		}
	}
	tree := func(t *blacksmith.RTree, err error) *blacksmith.RTree {
		if err != nil {
			fail("rtree: " + err.Error())
		}
		return t
	}
	ray := func(t *blacksmith.RTree, o, d [3]float64, maxT float64) []blacksmith.RTreeHit {
		hits, err := t.Ray(o, d, maxT)
		if err != nil {
			fail("rtree ray: " + err.Error())
		}
		return hits
	}
	said := func(err error) string {
		if err == nil {
			return "(no error)"
		}
		return err.Error()
	}
	box := func(x0, y0, z0, x1, y1, z1 float64) blacksmith.Box {
		return blacksmith.Box{Lo: [3]float64{x0, y0, z0}, Hi: [3]float64{x1, y1, z1}}
	}
	inf := math.Inf(1)
	var row []blacksmith.RTreeEntry
	var all []blacksmith.RTreeHit
	for i := 0; i < 10; i++ {
		row = append(row, blacksmith.RTreeEntry{ID: uint32(i), Box: box(float64(i), 0, 0, float64(i+1), 1, 1)})
		all = append(all, blacksmith.RTreeHit{ID: uint32(i), Distance: float64(i + 1)})
	}
	rowTree := tree(blacksmith.RTreeFromBoxes(row))
	defer rowTree.Close()
	along := ray(rowTree, [3]float64{-1, 0.5, 0.5}, [3]float64{1, 0, 0}, inf)
	check(slices.Equal(along, all), fmt.Sprintf("ray: the row gave %v", along))
	scaled := ray(rowTree, [3]float64{-1, 0.5, 0.5}, [3]float64{2, 0, 0}, 1)
	check(slices.Equal(scaled, []blacksmith.RTreeHit{{ID: 0, Distance: 0.5}, {ID: 1, Distance: 1}}), fmt.Sprintf("ray: t is not in units of the direction: %v", scaled))
	cut := ray(rowTree, [3]float64{-1, 0.5, 0.5}, [3]float64{1, 0, 0}, 3)
	check(slices.Equal(cut, []blacksmith.RTreeHit{{ID: 0, Distance: 1}, {ID: 1, Distance: 2}, {ID: 2, Distance: 3}}), fmt.Sprintf("ray: max_t 3 gave %v", cut))
	inside := ray(rowTree, [3]float64{2.5, 0.5, 0.5}, [3]float64{1, 0, 0}, 1)
	check(slices.Equal(inside, []blacksmith.RTreeHit{{ID: 2, Distance: 0}, {ID: 3, Distance: 0.5}}), fmt.Sprintf("ray: from inside gave %v", inside))
	back := ray(rowTree, [3]float64{11, 0.5, 0.5}, [3]float64{-1, 0, 0}, 2)
	check(slices.Equal(back, []blacksmith.RTreeHit{{ID: 9, Distance: 1}, {ID: 8, Distance: 2}}), fmt.Sprintf("ray: backwards gave %v", back))
	check(len(ray(rowTree, [3]float64{-1, 1, 0.5}, [3]float64{1, 0, 0}, inf)) == 10, "ray: grazing the top face missed")
	check(len(ray(rowTree, [3]float64{-1, 1 + 1e-12, 0.5}, [3]float64{1, 0, 0}, inf)) == 0, "ray: a ray above the row met it")
	_, err := rowTree.Ray([3]float64{}, [3]float64{}, inf)
	check(said(err) == "rtree_ray: direction (0, 0, 0) is not a direction", "ray: a zero direction gave "+said(err))
	_, err = rowTree.Ray([3]float64{}, [3]float64{1, 0, 0}, -1)
	check(said(err) == "rtree_ray: max_t -1 is not a distance", "ray: max_t -1 gave "+said(err))
	_, err = rowTree.Ray([3]float64{}, [3]float64{1, 0, 0}, math.NaN())
	check(said(err) == "rtree_ray: max_t NaN is not a distance", "ray: max_t NaN gave "+said(err))
	_, err = rowTree.Ray([3]float64{math.NaN(), 0, 0}, [3]float64{1, 0, 0}, inf)
	check(said(err) == "rtree_ray: origin (NaN, 0, 0) is not finite", "ray: a NaN origin gave "+said(err))

	positions := [][3]float64{{0, 0, 0}, {2, 0, 0}, {0, 3, 0}, {math.NaN(), 0, 0}, {5, 1, 4}}
	tris := tree(blacksmith.RTreeFromTriangles(positions, [][3]uint32{{0, 1, 2}, {1, 4, 1}}))
	defer tris.Close()
	n, err := tris.Len()
	b, err2 := tris.Bounds()
	check(err == nil && err2 == nil && n == 2 && b != nil && *b == box(0, 0, 0, 5, 3, 4), fmt.Sprintf("from triangles: count %d, bounds %v", n, b))
	first, _ := tris.Search(box(1, 1, 0, 1, 1, 0))
	second, _ := tris.Search(box(4, 0.5, 2, 4, 0.5, 2))
	check(slices.Equal(first, []uint32{0}) && slices.Equal(second, []uint32{1}), "from triangles: ids are not the triangle indices")
	through := ray(tris, [3]float64{-1, 0.5, 0}, [3]float64{1, 0, 0}, inf)
	check(slices.Equal(through, []blacksmith.RTreeHit{{ID: 0, Distance: 1}, {ID: 1, Distance: 3}}), fmt.Sprintf("from triangles: a ray gave %v", through))
	none := tree(blacksmith.RTreeFromTriangles(nil, nil))
	n, _ = none.Len()
	check(n == 0, "from triangles: none gave entries")
	none.Close()
	four := make([][3]float64, 4)
	_, err = blacksmith.RTreeFromTriangles(four, [][3]uint32{{0, 1, 2}, {0, 4, 1}})
	check(said(err) == "rtree_from_triangles: triangle 1 names point 4 of 4", "from triangles: an index past the points gave "+said(err))
	_, err = blacksmith.RTreeFromTriangles([][3]float64{{0, 0, 0}, {0, inf, 0}}, [][3]uint32{{0, 1, 0}})
	check(said(err) == "rtree_from_triangles: triangle 0 point 1 is not finite", "from triangles: an infinite corner gave "+said(err))

	cuboid, err := blacksmith.Cuboid(3, 4, 5)
	if err != nil {
		fail("face tree: " + err.Error())
	}
	defer cuboid.Close()
	faces := tree(cuboid.FaceTree())
	defer faces.Close()
	grow := 5 * 1e-3
	n, _ = faces.Len()
	fb, _ := faces.Bounds()
	check(n == 6 && fb != nil && nearV(fb.Lo, [3]float64{-1.5 - grow, -2 - grow, -2.5 - grow}, 1e-9) && nearV(fb.Hi, [3]float64{1.5 + grow, 2 + grow, 2.5 + grow}, 1e-9),
		fmt.Sprintf("face tree: count %d, bounds %v", n, fb))
	corner, _ := faces.Search(box(1.4, 1.9, 2.4, 1.6, 2.1, 2.6))
	check(len(corner) == 3, fmt.Sprintf("face tree: a corner is %v", corner))
	shot := ray(faces, [3]float64{10, 0, 0}, [3]float64{-1, 0, 0}, inf)
	check(len(shot) == 2 && math.Abs(shot[0].Distance-(8.5-grow)) <= 1e-9 && math.Abs(shot[1].Distance-(11.5-grow)) <= 1e-9, fmt.Sprintf("face tree: a ray gave %v", shot))
	frame, err := cuboid.FaceFrame(int(shot[0].ID))
	check(err == nil && nearV([3]float64{frame[9], frame[10], frame[11]}, [3]float64{1, 0, 0}, 1e-9), "face tree: the first face met is not the +x face")

	gone := tree(blacksmith.NewRTree())
	gone.Close()
	_, err = gone.Ray([3]float64{}, [3]float64{}, -1)
	check(err != nil && err.Error() == "rtree: closed" && errors.Is(err, blacksmith.ErrClosed), "ray: a closed tree gave "+said(err))
	closedSolid, _ := blacksmith.Cuboid(1, 1, 1)
	closedSolid.Close()
	_, err = closedSolid.FaceTree()
	check(err != nil && errors.Is(err, blacksmith.ErrClosed), "face tree: a closed solid gave "+said(err))
	fmt.Println("rtree: rays, triangle trees and a cuboid's face tree all read back")
}

func nearV(a, b [3]float64, tolerance float64) bool {
	return math.Abs(a[0]-b[0]) <= tolerance && math.Abs(a[1]-b[1]) <= tolerance && math.Abs(a[2]-b[2]) <= tolerance
}

// measure: the oriented box, edge and profile length, containment (one-shot and the
// Classifier handle) and closest points, each field read and each refusal in the library's
// words. The kernel's correctness is the C ABI suite's; this proves the marshalling.
func measure() {
	must := func(err error) {
		if err != nil {
			fail("measure: " + err.Error())
		}
	}
	check := func(ok bool, why string) {
		if !ok {
			fail("measure: " + why)
		}
	}
	refused := func(err error, prefix string, parts ...string) {
		if err == nil || !strings.HasPrefix(err.Error(), prefix) {
			fail(fmt.Sprintf("measure: expected a refusal starting %q, got %v", prefix, err))
		}
		for _, p := range parts {
			if !strings.Contains(err.Error(), p) {
				fail(fmt.Sprintf("measure: the refusal %q does not contain %q", err.Error(), p))
			}
		}
	}
	solid := func(s *blacksmith.Solid, err error) *blacksmith.Solid {
		must(err)
		return s
	}

	// Group 1: the oriented box of a cuboid turned 30 degrees.
	turned := solid(solid(blacksmith.Cuboid(2, 3, 4)).Rotate([6]float64{0, 0, 0, 0, 0, 1}, math.Pi/6))
	defer turned.Close()
	box, err := turned.OrientedBox(1e-9)
	must(err)
	half := box.Half
	sort.Float64s(half[:])
	for i, w := range [3]float64{1, 1.5, 2} {
		check(half[i] >= w-1e-9 && half[i] <= w+1e-3, fmt.Sprintf("half %v is not about (1, 1.5, 2)", box.Half))
	}
	for _, c := range box.Centre {
		check(math.Abs(c) < 1e-3, fmt.Sprintf("centre %v is not the origin", box.Centre))
	}
	for i := 0; i < 3; i++ {
		for j := 0; j < 3; j++ {
			dot := box.Axes[i][0]*box.Axes[j][0] + box.Axes[i][1]*box.Axes[j][1] + box.Axes[i][2]*box.Axes[j][2]
			want := 0.0
			if i == j {
				want = 1
			}
			check(math.Abs(dot-want) < 1e-9, fmt.Sprintf("axes %d.%d = %g, not %g", i, j, dot, want))
		}
	}

	// Group 2: the default accuracy, and the refusals.
	cyl := solid(blacksmith.Cylinder(1, 2))
	defer cyl.Close()
	ref, err := cyl.OrientedBox(1e-5)
	must(err)
	for _, a := range []float64{0, -1} {
		got, err := cyl.OrientedBox(a)
		must(err)
		check(got == ref, fmt.Sprintf("accuracy %g gave %v, not the default's %v", a, got, ref))
	}
	for _, h := range ref.Half {
		check(math.Abs(h-(1+3.125e-5*math.Sqrt(12))) < 1e-12, fmt.Sprintf("cylinder half %v", ref.Half))
	}
	_, err = cyl.OrientedBox(math.NaN())
	refused(err, "oriented_box: ", "is not an accuracy")
	bar := solid(blacksmith.Cuboid(1, 2, 3))
	defer bar.Close()
	sheet := solid(bar.FaceSheet(0))
	defer sheet.Close()
	_, err = sheet.OrientedBox(0)
	refused(err, "oriented_box: ")

	// Group 3: edge length.
	can := solid(blacksmith.Cylinder(2.5, 4))
	defer can.Close()
	edges, err := can.Edges()
	must(err)
	circles := 0
	for _, e := range edges {
		if e.Curve == nil || e.Curve.Kind != "circle" {
			continue
		}
		circles++
		l, err := can.EdgeLength(e.Index, 1e-9)
		must(err)
		check(math.Abs(l.Length-5*math.Pi) <= math.Max(l.Error, 1e-9) && l.Error >= 0 && l.Error <= 1e-6*l.Length, fmt.Sprintf("circle edge %d is %g long, error %g", e.Index, l.Length, l.Error))
		check(l.AccuracyMet && !l.FromPolyline, fmt.Sprintf("circle edge %d: %+v", e.Index, l))
	}
	check(circles > 0, "the cylinder has no circle edge")
	cube := solid(blacksmith.Cuboid(1, 1, 1))
	defer cube.Close()
	cubeEdges, err := cube.Edges()
	must(err)
	_, err = cube.EdgeLength(len(cubeEdges), 0)
	refused(err, "edge_length: ")

	// Group 4: profile length.
	slot, err := blacksmith.Slot([2]float64{0, 0}, 8, 1)
	must(err)
	defer slot.Close()
	pl, err := slot.Length(1e-9)
	must(err)
	check(math.Abs(pl.Length-(12+2*math.Pi)) <= math.Max(pl.Error, 1e-9) && pl.Error >= 0 && pl.Error <= 1e-6*pl.Length && pl.AccuracyMet,
		fmt.Sprintf("the slot is %+v, not 12 + 2 pi", pl))
	_, err = slot.Length(math.NaN())
	refused(err, "profile_length: ")

	// Group 4b: arc length.
	closeTo := func(a, b [3]float64, tol float64) bool {
		return math.Abs(a[0]-b[0]) <= tol && math.Abs(a[1]-b[1]) <= tol && math.Abs(a[2]-b[2]) <= tol
	}
	dist := func(a, b [3]float64) float64 {
		return math.Sqrt((a[0]-b[0])*(a[0]-b[0]) + (a[1]-b[1])*(a[1]-b[1]) + (a[2]-b[2])*(a[2]-b[2]))
	}
	rims := 0
	for _, e := range edges {
		if e.Curve == nil || e.Curve.Kind != "circle" {
			continue
		}
		rims++
		c := e.Curve
		start, err := can.EdgePointAtLength(e.Index, 0, 0)
		must(err)
		check(start.Parameter == c.T0, fmt.Sprintf("rim %d starts at parameter %g, not %g", e.Index, start.Parameter, c.T0))
		quarter, err := can.EdgePointAtLength(e.Index, 2.5*math.Pi/2, 0)
		must(err)
		check(math.Abs(quarter.Parameter-(c.T0+math.Pi/2)) <= 1e-9, fmt.Sprintf("rim %d quarter parameter %g", e.Index, quarter.Parameter))
		check(math.Abs(dist(quarter.Point, c.Origin)-2.5) <= 1e-9, fmt.Sprintf("rim %d quarter point %v", e.Index, quarter.Point))
		check(math.Abs(dist(quarter.Tangent, [3]float64{})-1) <= 1e-12, fmt.Sprintf("rim %d tangent %v", e.Index, quarter.Tangent))
		check(quarter.Segment == nil && !quarter.FromPolyline && quarter.Error >= 0 && !math.IsInf(quarter.Error, 0) && !math.IsNaN(quarter.Error),
			fmt.Sprintf("rim %d quarter: %+v", e.Index, quarter))
		byCount, err := can.EdgeDivideByCount(e.Index, 4, 0)
		must(err)
		check(len(byCount) == 4, fmt.Sprintf("rim %d divides into %d, not 4", e.Index, len(byCount)))
		for k := range byCount {
			next := byCount[(k+1)%len(byCount)]
			check(math.Abs(dist(byCount[k].Point, next.Point)-2.5*math.Sqrt2) <= 1e-9, fmt.Sprintf("rim %d chord %d", e.Index, k))
		}
		check(closeTo(byCount[0].Point, start.Point, 1e-12), fmt.Sprintf("rim %d first sample %v, not %v", e.Index, byCount[0].Point, start.Point))
		byLength, err := can.EdgeDivideByLength(e.Index, 2.5*math.Pi/2, 0)
		must(err)
		check(len(byLength) == 4, fmt.Sprintf("rim %d divides by length into %d, not 4", e.Index, len(byLength)))
	}
	check(rims >= 2, fmt.Sprintf("the cylinder has %d circle edges", rims))

	// An open edge: a cuboid's line of length 4.
	cub := solid(blacksmith.Cuboid(2, 3, 4))
	defer cub.Close()
	cubEdges, err := cub.Edges()
	must(err)
	openAt := -1
	for i, e := range cubEdges {
		if e.Curve == nil || e.Curve.Kind != "line" {
			continue
		}
		if l, err := cub.EdgeLength(e.Index, 0); err == nil && math.Abs(l.Length-4) <= 1e-9 {
			openAt = i
			break
		}
	}
	check(openAt >= 0, "the cuboid has no line edge of length 4")
	open := cubEdges[openAt]
	five, err := cub.EdgeDivideByCount(open.Index, 4, 0)
	must(err)
	check(len(five) == 5, fmt.Sprintf("an open edge divides into %d, not 5", len(five)))
	for k, a := range five {
		check(math.Abs(dist(a.Point, five[0].Point)-float64(k)) <= 1e-9, fmt.Sprintf("open sample %d at %g", k, dist(a.Point, five[0].Point)))
	}
	check(five[0].Parameter == open.Curve.T0 && five[4].Parameter == open.Curve.T1, fmt.Sprintf("open ends %g, %g", five[0].Parameter, five[4].Parameter))
	three, err := cub.EdgeDivideByLength(open.Index, 1.5, 0)
	must(err)
	check(len(three) == 3, fmt.Sprintf("an open edge divides by 1.5 into %d, not 3", len(three)))
	for k, a := range three {
		check(math.Abs(dist(a.Point, three[0].Point)-1.5*float64(k)) <= 1e-9, fmt.Sprintf("open step sample %d at %g", k, dist(a.Point, three[0].Point)))
	}

	// The slot.
	mid, err := slot.PointAtLength(6+math.Pi/2, 0)
	must(err)
	check(closeTo(mid.Point, [3]float64{4, 0, 0}, 1e-9) && mid.Segment != nil && *mid.Segment == 1, fmt.Sprintf("the slot at 6 + pi/2: %+v", mid))
	eight, err := slot.DivideByCount(8, 0)
	must(err)
	check(len(eight) == 8, fmt.Sprintf("the slot divides into %d, not 8", len(eight)))
	for _, a := range eight {
		check(a.Segment != nil && *a.Segment <= 4, fmt.Sprintf("slot sample segment %v", a.Segment))
	}
	seven, err := slot.DivideByLength(3, 0)
	must(err)
	check(len(seven) == int(math.Floor((12+2*math.Pi)/3))+1, fmt.Sprintf("the slot divides by 3 into %d", len(seven)))
	for k, a := range seven {
		want, err := slot.PointAtLength(3*float64(k), 0)
		must(err)
		check(closeTo(a.Point, want.Point, 1e-12) && a.Segment != nil && want.Segment != nil && *a.Segment == *want.Segment,
			fmt.Sprintf("slot sample %d: %+v, not %+v", k, a, want))
	}
	check(dist(seven[len(seven)-1].Point, seven[0].Point) > 0.1, "the slot's last sample repeats its first")

	// Refusals.
	_, err = can.EdgePointAtLength(edges[0].Index, -1, 0)
	refused(err, "edge_point_at_length: ")
	_, err = can.EdgePointAtLength(edges[0].Index, 100, 0)
	refused(err, "edge_point_at_length: ")
	_, err = cube.EdgePointAtLength(len(cubeEdges), 1, 0)
	refused(err, "edge_point_at_length: ")
	_, err = can.EdgeDivideByCount(edges[0].Index, 0, 0)
	refused(err, "edge_divide_by_count: ", "not at least 1")
	_, err = can.EdgeDivideByCount(edges[0].Index, 1_000_001, 0)
	refused(err, "edge_divide_by_count: ", "not at most 1000000")
	_, err = can.EdgeDivideByLength(edges[0].Index, 0, 0)
	refused(err, "edge_divide_by_length: ")
	_, err = slot.PointAtLength(-1, 0)
	refused(err, "profile_point_at_length: ")
	_, err = slot.DivideByCount(0, 0)
	refused(err, "profile_divide_by_count: ")
	_, err = slot.DivideByLength(-1, 0)
	refused(err, "profile_divide_by_length: ")
	_, err = can.EdgePointAtLength(edges[0].Index, 1, math.NaN())
	refused(err, "edge_point_at_length: ", "is not an accuracy")

	// The default accuracy: 0 and -1 are the same as the library's own.
	base, err := slot.PointAtLength(5, 0)
	must(err)
	neg, err := slot.PointAtLength(5, -1)
	must(err)
	check(base.Segment != nil && neg.Segment != nil && *base.Segment == *neg.Segment, "accuracy -1 changed the segment")
	base.Segment, neg.Segment = nil, nil
	check(base == neg, fmt.Sprintf("accuracy -1 gave %+v, not %+v", neg, base))

	// Group 5: containment, one-shot and the classifier.
	where := func(s *blacksmith.Solid, p [3]float64) string {
		w, err := s.Contains(p, 0.05)
		must(err)
		return w
	}
	slab := solid(blacksmith.Cuboid(2, 3, 4))
	defer slab.Close()
	check(where(slab, [3]float64{0, 0, 0}) == "inside", "the centre of a cuboid is not inside")
	check(where(slab, [3]float64{5, 0, 0}) == "outside", "a point far off a cuboid is not outside")
	check(where(slab, [3]float64{0, 0, 2}) == "on", "a point on a cuboid face is not on")
	slabClass, err := slab.Classifier(0.05)
	must(err)
	defer slabClass.Close()
	for _, p := range [][3]float64{{0, 0, 0}, {0.99, 0, 0}, {1, 0, 0}, {1.2, 0, 0}, {0, 1.6, 0}, {0, 0, -2}} {
		got, err := slabClass.Contains(p)
		must(err)
		check(got == where(slab, p), fmt.Sprintf("the classifier says %s at %v, the one-shot %s", got, p, where(slab, p)))
	}
	ball := solid(blacksmith.Sphere(1.5))
	defer ball.Close()
	ballClass, err := ball.Classifier(1e-3)
	must(err)
	defer ballClass.Close()
	for i, x := range []float64{-2, -1.4, -0.5, 0, 0.5, 1.4, 2} {
		want := "inside"
		if i == 0 || i == 6 {
			want = "outside"
		}
		got, err := ballClass.Contains([3]float64{x, 0, 0})
		must(err)
		check(got == want, fmt.Sprintf("the sphere at x=%g is %s, not %s", x, got, want))
	}
	for _, p := range [][3]float64{{1.5, 0, 0}, {0, 0, -1.5}} {
		got, err := ballClass.Contains(p)
		must(err)
		check(got == "on", fmt.Sprintf("the sphere at %v is %s, not on", p, got))
	}

	// Group 6: the classifier outlives its solid.
	orphanSolid := solid(blacksmith.Sphere(1))
	orphan, err := orphanSolid.Classifier(1e-3)
	must(err)
	defer orphan.Close()
	orphanSolid.Close()
	runtime.GC()
	for _, c := range []struct {
		p    [3]float64
		want string
	}{{[3]float64{0, 0, 0}, "inside"}, {[3]float64{2, 0, 0}, "outside"}, {[3]float64{1, 0, 0}, "on"}} {
		got, err := orphan.Contains(c.p)
		must(err)
		check(got == c.want, fmt.Sprintf("after its solid closed, the classifier says %s at %v, not %s", got, c.p, c.want))
	}

	// Group 7: containment errors.
	_, err = slab.Contains([3]float64{math.NaN(), 0, 0}, 0.05)
	refused(err, "contains: ", "not finite")
	_, err = slabClass.Contains([3]float64{math.NaN(), 0, 0})
	refused(err, "classifier_contains: ", "not finite")
	_, err = slab.Contains([3]float64{}, 0)
	refused(err, "contains: ", "positive and finite")
	_, err = slab.Classifier(0)
	refused(err, "classifier_new: ", "positive and finite")
	spent, err := slab.Classifier(0.05)
	must(err)
	spent.Close()
	spent.Close()
	check(spent.Closed(), "a closed classifier is not Closed")
	_, err = spent.Contains([3]float64{})
	check(errors.Is(err, blacksmith.ErrClosed) && strings.HasPrefix(err.Error(), "classifier: "),
		fmt.Sprintf("a closed classifier answered %v", err))

	// Group 8: closest of two spheres.
	s1 := solid(blacksmith.Sphere(1))
	defer s1.Close()
	s2 := solid(solid(blacksmith.Sphere(1)).Translate(5, 0, 0))
	defer s2.Close()
	near, err := s1.Closest(s2, 1e-3)
	must(err)
	check(math.Abs(near.Distance-3) < 6e-9 && near.Refined, fmt.Sprintf("two spheres: %+v", near))
	check(near.KindA == "face" && near.KindB == "face" && near.EdgeA == nil && near.EdgeB == nil,
		fmt.Sprintf("two spheres' features: %+v", near))
	vecNear := func(a, b [3]float64, tol float64) bool {
		return math.Abs(a[0]-b[0]) < tol && math.Abs(a[1]-b[1]) < tol && math.Abs(a[2]-b[2]) < tol
	}
	check(vecNear(near.OnA, [3]float64{1, 0, 0}, 1e-6) && vecNear(near.OnB, [3]float64{4, 0, 0}, 1e-6),
		fmt.Sprintf("two spheres' points: %v, %v", near.OnA, near.OnB))
	swapped, err := s2.Closest(s1, 1e-3)
	must(err)
	check(vecNear(swapped.OnA, near.OnB, 1e-9) && vecNear(swapped.OnB, near.OnA, 1e-9) &&
		math.Abs(swapped.Distance-near.Distance) < 1e-12, fmt.Sprintf("swapped: %+v", swapped))

	// Group 9: closest names a filletable edge.
	ballOff := solid(solid(blacksmith.Sphere(1)).Translate(3, 0, 4))
	defer ballOff.Close()
	hit, err := slab.Closest(ballOff, 1e-3)
	must(err)
	check(math.Abs(hit.Distance-(2*math.Sqrt2-1)) < 2e-3, fmt.Sprintf("box to sphere distance %g", hit.Distance))
	check(hit.KindA == "edge" && hit.EdgeA != nil && hit.KindB == "face" && hit.EdgeB == nil, fmt.Sprintf("box to sphere: %+v", hit))
	rounded := solid(slab.Fillet([]int{int(*hit.EdgeA)}, 0.2, blacksmith.FilletTolerance))
	defer rounded.Close()
	before, err := slab.Faces()
	must(err)
	after, err := rounded.Faces()
	must(err)
	check(after == before+1, fmt.Sprintf("filleting the named edge went from %d faces to %d", before, after))

	// Group 10: closest refusals. (Progress: Join takes none in Go, so neither does Closest.)
	_, err = s1.Closest(s2, 0)
	refused(err, "closest: ")

	fmt.Printf("measure: box half %v, circle edges %d, slot %g, sphere gap %g\n", ref.Half, circles, pl.Length, near.Distance)
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
	// A rectangle drawn above a sphere cores it: the ball with a square hole, then the core.
	ball, err := blacksmith.Sphere(10)
	if err != nil {
		fail(err.Error())
	}
	coreSquare, err := blacksmith.Rect(6, 6)
	if err != nil {
		fail(err.Error())
	}
	cored, err := ball.SplitByProfile(coreSquare, blacksmith.Frame{0, 0, 40, 1, 0, 0, 0, 1, 0, 0, 0, 1}, blacksmith.DefaultTolerance)
	if err != nil {
		fail(err.Error())
	}
	if len(cored) != 2 {
		fail(fmt.Sprintf("split_by_profile: %d bodies, not 2", len(cored)))
	}
	volume := func(s *blacksmith.Solid) float64 {
		m, err := s.Mass(0)
		if err != nil {
			fail(err.Error())
		}
		return m.Volume
	}
	whole, outside, inside := volume(ball), volume(cored[0]), volume(cored[1])
	if !(inside > 0 && inside < outside) || math.Abs(outside+inside-whole) > 0.01*whole {
		fail(fmt.Sprintf("split_by_profile: %g + %g is not the ball's %g", outside, inside, whole))
	}
	for _, s := range append(cored, ball) {
		s.Close()
	}
	coreSquare.Close()
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
	// A count the C call's uint32_t cannot hold is refused before it, never wrapped into a
	// shape of its own (2^32 + 6 would be a hexagon).
	for _, n := range []int{-1, 1<<32 + 6} {
		if _, err := blacksmith.RegularPolygon([2]float64{0, 0}, 10, n, 0); err == nil || err.Error() != fmt.Sprintf("profile_regular_polygon: sides is out of range: %d", n) {
			fail(fmt.Sprintf("regular polygon of %d sides: %v", n, err))
		}
		if _, err := blacksmith.Star([2]float64{0, 0}, 10, 4, n, 0); err == nil || err.Error() != fmt.Sprintf("profile_star: points is out of range: %d", n) {
			fail(fmt.Sprintf("star of %d points: %v", n, err))
		}
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

// subdMust folds an error into fail, for a smoke check that just wants the value.
func subdMust[T any](v T, err error) T {
	if err != nil {
		fail("subd: " + err.Error())
	}
	return v
}

// subdNear: two point lists the same length, equal to within tolerance in every coordinate.
func subdNear(a, b [][3]float64, tolerance float64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		for k := 0; k < 3; k++ {
			if math.Abs(a[i][k]-b[i][k]) > tolerance {
				return false
			}
		}
	}
	return true
}

func subdCheck(ok bool, what string) {
	if !ok {
		fail("subd: " + what)
	}
}

// subdRefused requires err to be a refusal whose text satisfies ok.
func subdRefused(err error, what string, ok func(string) bool) {
	if err == nil {
		fail("subd: " + what + " was accepted")
	}
	var be *blacksmith.BuildError
	if !errors.As(err, &be) || !ok(be.Message) {
		fail(fmt.Sprintf("subd: %s was refused in other words: %v", what, err))
	}
}

func subdContains(sub string) func(string) bool {
	return func(s string) bool { return strings.Contains(s, sub) }
}

func subdCuboid() *blacksmith.Subd {
	return subdMust(blacksmith.SubdCuboid([3]float64{2, 2, 2}, [3]uint32{1, 1, 1}))
}

func subdEdges(a, b []blacksmith.SubdEdge) bool { return slices.Equal(a, b) }

// subd ports Python's test_subd_* cage facts one for one.
func subd() {
	// Fact 1: a cuboid's parts, copies, from_parts the inverse.
	cube := subdCuboid()
	defer cube.Close()
	positions := subdMust(cube.Positions())
	faces := subdMust(cube.Faces())
	subdCheck(len(positions) == 8 && len(faces) == 6, "a cuboid is not 8 vertices and 6 faces")
	for _, f := range faces {
		subdCheck(len(f) == 4, "a cuboid face is not a quad")
	}
	creases := subdMust(cube.Creases())
	pins := subdMust(cube.Pins())
	sym := subdMust(cube.Symmetry())
	sel := subdMust(cube.Selection())
	subdCheck(len(creases) == 0 && len(pins) == 0 && sym == nil && sel == nil, "a fresh cuboid has creases, pins, symmetry or a selection")
	saved := positions[0]
	savedFace := append([]uint32(nil), faces[0]...)
	positions[0][0] += 99
	faces[0][0] += 99
	again := subdMust(cube.Positions())
	againFaces := subdMust(cube.Faces())
	subdCheck(again[0] == saved && slices.Equal(againFaces[0], savedFace), "writing to a read-back changed the next read")
	positions[0] = saved
	faces[0][0] -= 99
	rebuilt := subdMust(blacksmith.SubdFromParts(positions, faces, nil, nil, nil))
	defer rebuilt.Close()
	rp := subdMust(rebuilt.Positions())
	rf := subdMust(rebuilt.Faces())
	subdCheck(slices.Equal(rp, positions) && len(rf) == len(faces), "from_parts did not give equal positions and faces")
	for i := range rf {
		subdCheck(slices.Equal(rf[i], faces[i]), "from_parts did not give equal faces")
	}

	// Fact 2: extrude.
	raised := subdMust(cube.Extrude([]uint32{1}, 1))
	defer raised.Close()
	rpos := subdMust(raised.Positions())
	rsel := subdMust(raised.Selection())
	subdCheck(len(rpos) == 12 && rsel != nil && rsel.Kind == blacksmith.SubdFaces && slices.Equal(rsel.IDs, []uint32{1}),
		"extrude([1], 1) is not 12 vertices selecting face 1")
	subdCheck(len(subdMust(cube.Positions())) == 8, "extrude changed its input")

	// Fact 3: crease and pin.
	edge01 := []blacksmith.SubdEdge{{0, 1}}
	creased := subdMust(cube.Crease(edge01, true))
	defer creased.Close()
	csel := subdMust(creased.Selection())
	subdCheck(csel != nil && csel.Kind == blacksmith.SubdEdges && subdEdges(csel.Edges, edge01), "crease did not select its edge")
	pinned := subdMust(creased.Pin([]uint32{6}, true))
	defer pinned.Close()
	subdCheck(subdEdges(subdMust(pinned.Creases()), edge01) && slices.Equal(subdMust(pinned.Pins()), []uint32{6}),
		"crease then pin did not keep both")
	psel := subdMust(pinned.Selection())
	subdCheck(psel != nil && psel.Kind == blacksmith.SubdVertices && slices.Equal(psel.IDs, []uint32{6}), "pin did not select its vertex")
	both := subdMust(blacksmith.SubdFromParts(positions, faces, edge01, []uint32{6}, nil))
	defer both.Close()
	subdCheck(subdEdges(subdMust(both.Creases()), edge01) && slices.Equal(subdMust(both.Pins()), []uint32{6}),
		"from_parts lost its creases or pins")
	uncreased := subdMust(pinned.Crease(edge01, false))
	defer uncreased.Close()
	unpinned := subdMust(uncreased.Pin([]uint32{6}, false))
	defer unpinned.Close()
	subdCheck(len(subdMust(unpinned.Creases())) == 0 && len(subdMust(unpinned.Pins())) == 0, "on=false did not empty creases and pins")

	// Fact 4: mirror.
	halves := subdMust(blacksmith.SubdCuboid([3]float64{2, 2, 2}, [3]uint32{2, 1, 1}))
	defer halves.Close()
	whole := len(subdMust(halves.Positions()))
	half := subdMust(halves.MirrorOn(blacksmith.SubdX))
	defer half.Close()
	hs := subdMust(half.Symmetry())
	subdCheck(hs != nil && hs.Axis == blacksmith.SubdX && hs.Tolerance > 0, "mirror_on(X) has no X symmetry with a tolerance")
	subdCheck(subdMust(half.Selection()) == nil, "mirror_on selected something")
	hpos, hfaces := subdMust(half.Positions()), subdMust(half.Faces())
	subdCheck(len(hpos) < whole, "the mirrored half is not smaller than the whole")
	loaded := subdMust(blacksmith.SubdFromParts(hpos, hfaces, nil, nil, hs))
	defer loaded.Close()
	ls := subdMust(loaded.Symmetry())
	subdCheck(slices.Equal(subdMust(loaded.Positions()), hpos) && ls != nil && *ls == *hs, "from_parts did not keep a half's positions and symmetry")
	fullCage := subdMust(half.Full())
	defer fullCage.Close()
	subdCheck(len(subdMust(fullCage.Positions())) == whole, "full() is not as big as the whole")
	off := subdMust(half.MirrorOff())
	defer off.Close()
	subdCheck(subdMust(off.Symmetry()) == nil, "mirror_off still has symmetry")

	// Fact 5: edge loops.
	grid := subdMust(blacksmith.SubdCuboid([3]float64{2, 2, 2}, [3]uint32{2, 2, 2}))
	defer grid.Close()
	gf := subdMust(grid.Faces())
	a, b := gf[0][0], gf[0][1]
	loop := subdMust(grid.EdgeLoop(blacksmith.SubdEdge{a, b}))
	subdCheck(len(loop) >= 4 && loop[0] == blacksmith.SubdEdge{min(a, b), max(a, b)}, "edge_loop is not >= 4 edges led by the picked edge")
	diag := subdMust(cube.EdgeLoop(blacksmith.SubdEdge{faces[0][0], faces[0][2]}))
	subdCheck(len(diag) == 0, "edge_loop of a diagonal is not empty")
	subdCheck(len(subdMust(cube.EdgeLoop(blacksmith.SubdEdge{0, 99}))) == 0, "edge_loop((0, 99)) is not empty")

	// Fact 6: transform.
	rot := []float64{0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	all := blacksmith.SubdOfVertices(0, 1, 2, 3, 4, 5, 6, 7)
	turned := subdMust(cube.Transform(all, rot))
	defer turned.Close()
	tp := subdMust(turned.Positions())
	for i, p := range positions {
		want := [3]float64{-p[1], p[0], p[2]}
		for k := 0; k < 3; k++ {
			subdCheck(math.Abs(tp[i][k]-want[k]) <= 1e-12, "the rotation did not map (x, y, z) to (-y, x, z)")
		}
	}
	one := subdMust(cube.Transform(blacksmith.SubdOfVertices(0), rot))
	defer one.Close()
	op := subdMust(one.Positions())
	for i := range positions {
		if i == 0 {
			subdCheck(op[0] != positions[0], "vertex 0 did not move")
		} else {
			subdCheck(op[i] == positions[i], "a vertex other than 0 moved")
		}
	}
	slide := []float64{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 0, 1}
	slid := subdMust(cube.Transform(blacksmith.SubdOfEdges(blacksmith.SubdEdge{0, 1}), slide))
	defer slid.Close()
	sp := subdMust(slid.Positions())
	subdCheck(sp[0][0] == positions[0][0]+3, "the slide did not add exactly 3 to vertex 0's x")
	ssel := subdMust(slid.Selection())
	subdCheck(ssel != nil && ssel.Kind == blacksmith.SubdEdges && subdEdges(ssel.Edges, edge01), "the slide did not select its edge")
	_, err := cube.Transform(all, []float64{1, 2, 3})
	subdRefused(err, "a matrix of 3 numbers", subdContains("matrix"))

	// Fact 7: inset and insert_loop.
	inset := subdMust(cube.Inset([]uint32{1}, 0.25, false))
	defer inset.Close()
	subdCheck(len(subdMust(inset.Faces())) == 10, "inset([1], 0.25) is not 10 faces")
	cut := subdMust(cube.InsertLoop(blacksmith.SubdEdge{0, 1}, 0.5))
	defer cut.Close()
	cutSel := subdMust(cut.Selection())
	subdCheck(len(subdMust(cut.Positions())) == 12 && cutSel != nil && cutSel.Kind == blacksmith.SubdEdges, "insert_loop is not 12 vertices with an edge selection")
	_, err = cube.InsertLoop(blacksmith.SubdEdge{0, 1}, 1.5)
	subdRefused(err, "insert_loop at 1.5", func(s string) bool { return strings.HasPrefix(s, "bad selection: ") })

	// subdivide: whole, one face, a bad face.
	kiln := subdMust(blacksmith.SubdCuboid([3]float64{2, 2, 2}, [3]uint32{2, 2, 2}))
	defer kiln.Close()
	subWhole := subdMust(kiln.Subdivide(nil))
	defer subWhole.Close()
	subdCheck(len(subdMust(subWhole.Faces())) == 96, "subdivide(nil) is not 96 faces")
	subOne := subdMust(kiln.Subdivide([]uint32{1}))
	defer subOne.Close()
	subdCheck(len(subdMust(subOne.Faces())) == 27, "subdivide([1]) is not 27 faces")
	subSel := subdMust(subOne.Selection())
	subdCheck(subSel != nil && subSel.Kind == blacksmith.SubdFaces && len(subSel.IDs) == 4, "subdivide([1]) does not select 4 faces")
	_, err = kiln.Subdivide([]uint32{999})
	subdRefused(err, "subdivide of face 999", subdContains("subdivide: face 999 is not in the cage"))

	// Fact 8: the smooth mesh, copied.
	var survivor *blacksmith.SubdMesh
	func() {
		mortal := subdCuboid()
		defer mortal.Close()
		survivor = subdMust(mortal.SmoothMesh(2))
	}()
	runtime.GC()
	mesh := subdMust(cube.SmoothMesh(2))
	n := len(mesh.Positions)
	subdCheck(n > 8 && len(mesh.Normals) == n, "smooth_mesh(2) is not n > 8 positions and n normals")
	for _, v := range mesh.Normals {
		subdCheck(math.Abs(math.Sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2])-1) <= 1e-9, "a normal is not unit")
	}
	subdCheck(len(mesh.Indices)%3 == 0 && len(mesh.TriangleFace) == len(mesh.Indices)/3, "triangle_face is not one entry a triangle")
	for _, i := range mesh.Indices {
		subdCheck(int(i) < n, "an index is out of range")
	}
	for _, f := range mesh.TriangleFace {
		subdCheck(f < 6, "a triangle_face is not a face of the cage")
	}
	subdCheck(len(subdMust(cube.SmoothMesh(1)).Positions) < n, "smooth_mesh(1) is not smaller than smooth_mesh(2)")
	subdCheck(slices.Equal(subdMust(cube.SmoothMesh(2)).Positions, mesh.Positions), "a second smooth_mesh(2) differs")
	_, err = cube.SmoothMesh(7)
	subdRefused(err, "smooth_mesh(7)", subdContains("levels"))
	// Another cage of the same topology meshes from kept weights: the same mesh to within
	// rounding (its points may differ in the last bits), its triangles exactly. The weights
	// are kept per OS thread and the goroutine may change threads, so either mesh may be the
	// direct one: the bounds are cadaclysm-subd's own, 1e-12 of the cube's diagonal for a
	// point and 1e-9 for a normal.
	subdCheck(subdNear(survivor.Positions, mesh.Positions, 1e-12*math.Sqrt(12)) && slices.Equal(survivor.Indices, mesh.Indices) &&
		subdNear(survivor.Normals, mesh.Normals, 1e-9) && slices.Equal(survivor.TriangleFace, mesh.TriangleFace),
		"a mesh read after its cage closed is not whole")

	// Fact 9: pick.
	fine := subdMust(cube.SmoothMesh(3))
	target, best := fine.Positions[0], math.Inf(1)
	for _, p := range fine.Positions {
		d := math.Hypot(math.Hypot(p[0]-positions[6][0], p[1]-positions[6][1]), p[2]-positions[6][2])
		if d < best {
			best, target = d, p
		}
	}
	pv := subdMust(cube.Pick(target, blacksmith.SubdVertices))
	subdCheck(pv != nil && pv.Kind == blacksmith.SubdVertices && slices.Equal(pv.IDs, []uint32{6}), "picking near vertex 6 for a vertex is not 6")
	pe := subdMust(cube.Pick(target, blacksmith.SubdEdges))
	subdCheck(pe != nil && len(pe.Edges) == 1 && (pe.Edges[0][0] == 6 || pe.Edges[0][1] == 6), "picking near vertex 6 for an edge is not an edge of 6")
	pf := subdMust(cube.Pick(target, blacksmith.SubdFaces))
	subdCheck(pf != nil && len(pf.IDs) == 1 && pf.IDs[0] < 6, "picking for a face is not a face")
	far := subdMust(cube.Pick([3]float64{100, 100, 100}, blacksmith.SubdVertices))
	subdCheck(far == nil, "a far point picked something")
	_, err = cube.Pick([3]float64{math.NaN(), 0, 0}, blacksmith.SubdVertices)
	subdRefused(err, "a NaN pick", func(s string) bool { return s == "bad selection: pick: point is not finite" })
	// The refusal must not leave a stale error that reads a far point as a refusal.
	subdCheck(subdMust(cube.Pick([3]float64{100, 100, 100}, blacksmith.SubdVertices)) == nil, "a far point after a refusal is not nothing near")

	// Fact 10: to_solid.
	solid, report, err := cube.ToSolid(blacksmith.SubdSolidOptions{})
	if err != nil {
		fail("subd: " + err.Error())
	}
	defer solid.Close()
	subdCheck(report.Regular == 0 && report.Refined == 24 && report.Levels >= 2 && report.Steps >= 1 &&
		report.Deviation <= 1e-4 && report.G1AngleDeg <= 0.1, fmt.Sprintf("the cuboid's report is off: %+v", report))
	m := subdMust(solid.Manifold())
	subdCheck(m.IsClosed, "the cuboid's solid is not closed")
	subdCheck(subdMust(solid.Mass(0)).Volume > 0, "the cuboid's solid has no volume")
	solid2, _, err := cube.ToSolid(blacksmith.SubdSolidOptions{Tolerance: 1e-4, G1Angle: 0.1, MaxLevels: 6})
	if err != nil {
		fail("subd: " + err.Error())
	}
	solid2.Close()

	// Fact 11: a cylinder with sharp rims has a tangent break.
	sharp := subdMust(blacksmith.SubdCylinder(1, 2, 8, 1, false))
	defer sharp.Close()
	_, _, err = sharp.ToSolid(blacksmith.SubdSolidOptions{})
	subdRefused(err, "an uncreased cylinder's solid", func(s string) bool {
		return strings.HasPrefix(s, "subd:") && strings.Contains(s, "tangent break")
	})

	// Fact 12: creased rims, with every other value the default.
	can := subdMust(blacksmith.SubdCylinder(1, 2, 8, 1, true))
	defer can.Close()
	canSolid, canReport, err := can.ToSolid(blacksmith.SubdSolidOptions{})
	if err != nil {
		fail("subd: " + err.Error())
	}
	canSolid.Close()
	subdCheck(canReport.Deviation <= 1e-4 && canReport.G1AngleDeg <= 0.1, fmt.Sprintf("the default cylinder's report is off: %+v", canReport))

	// Fact 13: primitives and their refusals.
	for name, build := range map[string]func() (*blacksmith.Subd, error){
		"cylinder": func() (*blacksmith.Subd, error) { return blacksmith.SubdCylinder(1, 2, 8, 2, true) },
		"sphere":   func() (*blacksmith.Subd, error) { return blacksmith.SubdSphere(1, 2) },
		"torus":    func() (*blacksmith.Subd, error) { return blacksmith.SubdTorus(3, 1, 12, 8) },
	} {
		p := subdMust(build())
		subdCheck(len(subdMust(p.Faces())) > 0, name+" has no faces")
		p.Close()
	}
	_, err = blacksmith.SubdCuboid([3]float64{2, 2, 2}, [3]uint32{0, 1, 1})
	subdRefused(err, "a cuboid of 0 segments", func(s string) bool { return s == "bad selection: cuboid: segments >= 1" })
	_, err = blacksmith.SubdSphere(1, 2000)
	subdRefused(err, "a sphere of 2000 segments", subdContains("1024"))

	// Fact 14: from_parts refusals.
	_, err = blacksmith.SubdFromParts(positions, faces, []blacksmith.SubdEdge{{0, 6}}, nil, nil)
	subdRefused(err, "a crease that is not an edge", func(s string) bool { return strings.HasPrefix(s, "bad selection: ") })
	_, err = blacksmith.SubdFromParts(nil, faces, nil, nil, nil)
	subdRefused(err, "zero positions", subdContains("vertex_count"))

	// Fact 15: the pipeline, and its STEP text.
	rise := subdMust(cube.Extrude([]uint32{1}, 0.5))
	defer rise.Close()
	cutIn := subdMust(rise.Inset([]uint32{1}, 0.25, false))
	defer cutIn.Close()
	pipe, pipeReport, err := cutIn.ToSolid(blacksmith.SubdSolidOptions{})
	if err != nil {
		fail("subd: " + err.Error())
	}
	defer pipe.Close()
	subdCheck(subdMust(pipe.Manifold()).IsClosed && pipeReport.Deviation <= 1e-4, "the pipeline's solid is not closed within tolerance")
	text := subdMust(pipe.StepText("", "mm"))
	subdCheck(strings.HasPrefix(text, "ISO-10303-21;") && strings.Contains(text, "ADVANCED_FACE"), "the pipeline's STEP text is not STEP with advanced faces")
	scene, err := cadaclysm.OpenMemory([]byte(text), "subd.stp")
	if err != nil {
		fail("subd: " + err.Error())
	}
	meshed := 0
	for _, node := range scene.Nodes() {
		if node.CanMesh() {
			meshed++
		}
	}
	scene.Close()
	subdCheck(meshed == 1, fmt.Sprintf("the STEP the cage wrote is %d meshable nodes, not one", meshed))

	// Fact 16: close, twice, and use after close.
	gone := subdCuboid()
	gone.Close()
	gone.Close()
	subdCheck(gone.Closed(), "a closed cage is not Closed")
	closedRefused := func(what string, err error) {
		if !errors.Is(err, blacksmith.ErrClosed) {
			fail(fmt.Sprintf("subd: %s on a closed cage is not ErrClosed: %v", what, err))
		}
	}
	_, err = gone.Positions()
	closedRefused("Positions", err)
	_, err = gone.Extrude([]uint32{1}, 1)
	closedRefused("Extrude", err)
	_, err = gone.SmoothMesh(2)
	closedRefused("SmoothMesh", err)
	_, err = gone.Pick([3]float64{}, blacksmith.SubdVertices)
	closedRefused("Pick", err)
	_, _, err = gone.ToSolid(blacksmith.SubdSolidOptions{})
	closedRefused("ToSolid", err)
	_, err = gone.EdgeLoop(blacksmith.SubdEdge{0, 1})
	closedRefused("EdgeLoop", err)

	fmt.Printf("subd: cuboid %d vertices, smooth mesh %d vertices, to_solid %d refined patches (deviation %g)\n",
		len(positions), n, report.Refined, report.Deviation)
}

// ---- Sketch: the 2D constraint sketcher ------------------------------------------------------

// skMust folds an error into fail, for a sketch check that just wants the value.
func skMust[T any](v T, err error) T {
	if err != nil {
		fail("sketch: " + err.Error())
	}
	return v
}

// skOK folds a bare error into fail.
func skOK(err error) {
	if err != nil {
		fail("sketch: " + err.Error())
	}
}

func skCheck(ok bool, what string) {
	if !ok {
		fail("sketch: " + what)
	}
}

// skRefused requires err to be a *BuildError whose text satisfies ok, and returns it.
func skRefused(err error, what string, ok func(string) bool) *blacksmith.BuildError {
	if err == nil {
		fail("sketch: " + what + " was accepted")
	}
	var be *blacksmith.BuildError
	if !errors.As(err, &be) || !ok(be.Message) {
		fail(fmt.Sprintf("sketch: %s was refused in other words: %v", what, err))
	}
	return be
}

func skPrefix(prefix string) func(string) bool {
	return func(s string) bool { return strings.HasPrefix(s, prefix) }
}

func skNear(a, b, tolerance float64) bool { return math.Abs(a-b) <= tolerance }

func skSorted(ids []uint32) []uint32 {
	out := slices.Clone(ids)
	slices.Sort(out)
	return out
}

// skRect is a sketch holding the 40 x 30 rectangle every fact starts from.
func skRect() (*blacksmith.Sketch, [4]uint32, [4]uint32) {
	s := skMust(blacksmith.NewSketch())
	corners, sides, err := s.AddRect([2]float64{0, 0}, [2]float64{40, 30})
	skOK(err)
	return s, corners, sides
}

// sketch ports Python's test_a_sketch_* facts (S1-S8), S10, S11, S12 and every constraint method.
func sketch() {
	// S1: a plate dimensioned, solved and extruded.
	{
		s, corners, sides := skRect()
		skMust(s.Fix(corners[0]))
		width := skMust(s.Length(sides[0], 60, true))
		skMust(s.Length(sides[1], 30, true))
		hole := skMust(s.AddCircle(skMust(s.AddPoint(30, 15)), 5))
		skMust(s.RadiusOf(hole, 5, true))
		report := skMust(s.Solve())
		skCheck(report.Converged() && report.Status == "converged" && report.IDs != nil && len(report.IDs) == 0,
			fmt.Sprintf("the plate solved as %+v", report))
		p := skMust(s.Point(corners[1]))
		skCheck(skNear(p[0], 60, 1e-9) && skNear(p[1], 0, 1e-9), fmt.Sprintf("corner 1 is at %v, not (60, 0)", p))
		skCheck(skMust(s.ConstraintKind(width)) == "length", "the width is not a length")
		v := skMust(s.ConstraintValue(width))
		skCheck(v != nil && *v == 60, "the width's value is not 60")
		dof := skMust(s.Diagnose())
		skCheck(dof.Free == 2 && dof.State == "under", fmt.Sprintf("the plate diagnosed as %+v", dof))
		profiles := skMust(s.Profiles(1e-9))
		skCheck(len(profiles) == 1, fmt.Sprintf("the plate has %d profiles, not 1", len(profiles)))
		body := skMust(blacksmith.Extrude(profiles[0], blacksmith.FrameXY([3]float64{}), 10))
		skCheck(skMust(body.Mass(0)).Volume > 0, "the extruded plate has no volume")
		body.Close()
		profiles[0].Close()
		s.Close()
	}

	// S2: a conflict is refused with the ids it clashes with; a closed sketch refuses.
	{
		s, corners, sides := skRect()
		skMust(s.Fix(corners[0]))
		skMust(s.Length(sides[0], 40, true))
		skMust(s.Length(sides[1], 30, true))
		_, err := s.Distance(corners[0], corners[2], 10, true)
		be := skRefused(err, "a diagonal over the dimensioned rectangle", skPrefix("sketch_constrain: over-constrained"))
		skCheck(slices.Equal(be.IDs, []uint32{0, 1, 5, 6}), fmt.Sprintf("the conflict names %v, not [0 1 5 6]", be.IDs))
		skCheck(len(skMust(s.Constraints())) == 7, "the refused constraint was kept")
		_, err = s.RemoveEntity(corners[0])
		be = skRefused(err, "removing a corner in use", skPrefix("sketch_remove_entity: point"))
		skCheck(slices.Equal(skSorted(be.IDs), skSorted([]uint32{sides[0], sides[3]})),
			fmt.Sprintf("the in-use refusal names %v, not the sides holding it", be.IDs))
		_, err = s.Kind(9999)
		be = skRefused(err, "kind(9999)", subdContains("sketch_kind"))
		skCheck(len(be.IDs) == 0, fmt.Sprintf("kind(9999) carries the ids %v", be.IDs))
		s.Close()
		s.Close() // twice is a no-op
		skCheck(s.Closed(), "a closed sketch is not Closed")
		_, err = s.Solve()
		skCheck(errors.Is(err, blacksmith.ErrClosed) && err.Error() == "sketch: closed",
			fmt.Sprintf("solve on a closed sketch gave %v", err))
		_, err = s.AddPoint(0, 0)
		skCheck(errors.Is(err, blacksmith.ErrClosed), "add_point on a closed sketch is not ErrClosed")
		other := skMust(blacksmith.NewSketch())
		_, err = other.Reference(s, 0)
		skCheck(errors.Is(err, blacksmith.ErrClosed), "a reference into a closed sketch is not ErrClosed")
		other.Close()
	}

	// S3: drag moves the point it holds, and the rectangle follows.
	{
		s, corners, _ := skRect()
		r := skMust(s.Drag(map[uint32][2]float64{corners[0]: {5, 5}}))
		skCheck(r.Converged() && len(r.IDs) == 0, fmt.Sprintf("the drag gave %+v", r))
		p := skMust(s.Point(corners[0]))
		skCheck(skNear(p[0], 5, 1e-9) && skNear(p[1], 5, 1e-9), fmt.Sprintf("the dragged corner is at %v", p))
		skCheck(skNear(skMust(s.Point(corners[1]))[1], 5, 1e-9), "the side does not stay level")
		s.Close()
	}

	// S4: a reference follows its source.
	{
		plate, corners, sides := skRect()
		boss := skMust(blacksmith.NewSketch())
		skMust(plate.Fix(corners[0]))
		width := skMust(plate.Length(sides[0], 40, true))
		skMust(plate.Length(sides[1], 30, true))
		edge := skMust(boss.Reference(plate, sides[1])) // the right side, x = 40
		skCheck(boss.IsReference(edge) && boss.IsConstruction(edge), "the reference is not a construction reference")
		o := skMust(boss.AddPoint(130, 15))
		hole := skMust(boss.AddCircle(o, 12))
		skMust(boss.RadiusOf(hole, 12, true))
		skMust(boss.PointLineDistance(o, edge, 100, true, "auto"))
		skCheck(skNear(skMust(boss.Point(o))[0], 140, 1e-9), "the boss is not 100 from the plate's edge")
		bossProfiles := skMust(boss.Profiles(1e-9))
		skCheck(len(bossProfiles) == 1, "the reference is part of a profile")
		bossProfiles[0].Close()
		skCheck(skMust(plate.SetValue(width, 60)).Converged(), "the plate's new width did not converge")
		r := skMust(boss.UpdateReference(edge, plate))
		skCheck(r.Converged() && len(r.IDs) == 0, fmt.Sprintf("update_reference gave %+v", r))
		skCheck(skNear(skMust(boss.Point(o))[0], 160, 1e-9), "the boss does not follow the plate")
		_, err := boss.UpdateReference(o, plate)
		be := skRefused(err, "updating a point that is no reference", skPrefix("sketch_update_reference: entity"))
		skCheck(len(be.IDs) == 0, fmt.Sprintf("the update refusal carries %v", be.IDs))
		_, err = boss.Reference(boss, o)
		skRefused(err, "a sketch referencing itself", subdContains("cannot reference itself"))
		boss.Close()
		plate.Close()
	}

	// S5: from a profile, with its joint tangents.
	{
		slot := skMust(blacksmith.Slot([2]float64{0, 0}, 60, 8))
		s := skMust(blacksmith.SketchFromProfile(slot, true, 1e-9))
		tangents := 0
		for _, c := range skMust(s.Constraints()) {
			if skMust(s.ConstraintKind(c)) == "tangent" {
				tangents++
				skCheck(s.IsJointTangent(c), fmt.Sprintf("tangent %d is not a joint tangent", c))
			}
		}
		skCheck(tangents == 4, fmt.Sprintf("the slot has %d tangents, not 4", tangents))
		skCheck(skMust(s.Diagnose()).Free == 4, "the slot's sketch is not 4 free")
		s.Close()
		slot.Close()
	}

	// S6: it reads back what it holds; S10 (b): the ambiguous readers refuse an unknown id.
	{
		s := skMust(blacksmith.NewSketch())
		a, b := skMust(s.AddPoint(0, 0)), skMust(s.AddPoint(10, 0))
		line := skMust(s.AddLine(a, b))
		skCheck(skMust(s.Kind(a)) == "point" && skMust(s.Kind(line)) == "line", "the kinds read back wrong")
		skCheck(slices.Equal(skMust(s.Entities()), skSorted([]uint32{a, b, line})), "entities() is not [a b line]")
		skCheck(slices.Equal(skMust(s.Ends(line)), []uint32{a, b}), "the line's ends are not [a b]")
		c := skMust(s.AddCircle(skMust(s.AddPoint(0, 20)), 3))
		skCheck(skMust(s.Kind(c)) == "circle" && skMust(s.Radius(c)) == 3 && skMust(s.Kind(skMust(s.Centre(c)))) == "point",
			"the circle reads back wrong")
		skOK(s.SetRadius(c, 4))
		skCheck(skMust(s.Radius(c)) == 4, "set_radius did not take")
		skOK(s.SetPoint(b, 12, 0))
		skCheck(skMust(s.Point(b)) == [2]float64{12, 0}, "set_point did not take")
		skOK(s.SetConstruction(c, true))
		skCheck(s.IsConstruction(c) && !s.IsReference(c), "construction reads back wrong")
		h := skMust(s.Horizontal(a, b))
		skCheck(skMust(s.ConstraintKind(h)) == "horizontal" && slices.Equal(skMust(s.ConstraintRefs(h)), []uint32{a, b}),
			"the horizontal reads back wrong")
		skCheck(skMust(s.ConstraintValue(h)) == nil && !skMust(s.ConstraintDriving(h)), "a horizontal has a value or drives")
		skCheck(skMust(s.ConstraintSense(h)) == "auto", "a horizontal's sense is not auto")
		d := skMust(s.Distance(a, b, 15, false))
		dv := skMust(s.ConstraintValue(d))
		skCheck(dv != nil && *dv == 15 && !skMust(s.ConstraintDriving(d)), "the reporting distance reads back wrong")
		skCheck(skNear(skMust(s.Measure(d)), 12, 1e-12), "the distance does not measure 12")
		r := skMust(s.SetDriving(d, true)) // a dimension made driving takes what it measures
		dv = skMust(s.ConstraintValue(d))
		skCheck(r.Converged() && skMust(s.ConstraintDriving(d)) && dv != nil && *dv == 12, "set_driving did not take the measure")
		r = skMust(s.SetValue(d, 20))
		skCheck(r.Converged() && skNear(skMust(s.Measure(d)), 20, 1e-9), "set_value did not move the points")
		r = skMust(s.Drag(map[uint32][2]float64{b: {25, 5}}))
		skCheck(slices.Contains([]string{"converged", "conflicting", "diverged"}, r.Status) && r.IDs != nil,
			fmt.Sprintf("the drag gave %+v", r))
		// S10 (b)
		_, err := s.ConstraintValue(999)
		be := skRefused(err, "constraint_value(999)", subdContains("sketch_constraint_value"))
		skCheck(len(be.IDs) == 0, "constraint_value(999) carries ids")
		_, err = s.ConstraintDriving(999)
		skRefused(err, "constraint_driving(999)", subdContains("sketch_constraint_driving"))
		skCheck(slices.Equal(skMust(s.Constraints()), skSorted([]uint32{h, d})), "constraints() is not [h d]")
		skOK(s.Remove(h))
		skCheck(slices.Equal(skMust(s.Constraints()), []uint32{d}), "remove(h) left more than [d]")
		skCheck(slices.Equal(skMust(s.RemoveEntity(line)), []uint32{d}), "remove_entity(line) did not take the distance")
		skCheck(!slices.Contains(skMust(s.Entities()), a) && len(skMust(s.Constraints())) == 0,
			"the line's ends or constraints survived it")
		bez := skMust(s.AddBezier(skMust(s.AddPoint(0, 0)), [2]float64{1, 1}, [2]float64{2, 1}, [2]float64{3, 0}))
		skCheck(skMust(s.Kind(bez)) == "free_curve" && len(skMust(s.Ends(bez))) == 4, "the Bezier reads back wrong")
		chains := skMust(s.OpenChains(1e-9))
		skCheck(len(chains) == 1, fmt.Sprintf("%d open chains, not 1", len(chains)))
		chains[0].Close()
		_, err = s.Kind(9999)
		skRefused(err, "kind(9999)", subdContains("sketch_kind"))
		_, err = s.Tangent(bez, c, "sideways")
		skRefused(err, "a sideways sense", func(m string) bool {
			return strings.HasPrefix(m, "tangent: sense must be one of ") && strings.HasSuffix(m, ", not 'sideways'") &&
				strings.Contains(m, "'auto'") && strings.Contains(m, "'positive'") && strings.Contains(m, "'negative'")
		})
		s.Close()
	}

	// S7: tangent_at_end reads its end back.
	{
		s := skMust(blacksmith.NewSketch())
		a, b := skMust(s.AddPoint(0, 0)), skMust(s.AddPoint(4, 0))
		line := skMust(s.AddLine(a, b))
		bez := skMust(s.AddBezier(b, [2]float64{5, 0}, [2]float64{6, 1}, [2]float64{7, 1}))
		skCheck(skMust(s.ConstraintEnd(skMust(s.TangentAtEnd(bez, line, "end")))) == "end", "tangent_at_end(end) reads back wrong")
		skCheck(skMust(s.ConstraintEnd(skMust(s.TangentAtEnd(bez, line, "start")))) == "start", "tangent_at_end(start) reads back wrong")
		skCheck(skMust(s.ConstraintEnd(skMust(s.Length(line, 4, true)))) == "start", "a length has an end")
		_, err := s.ConstraintEnd(999)
		skRefused(err, "constraint_end(999)", subdContains("sketch_constraint_end: no constraint 999"))
		_, err = s.TangentAtEnd(bez, line, "middle")
		skRefused(err, "a middle end", subdContains("tangent_at_end: end must be one of 'start', 'end', not 'middle'"))
		s.Close()
	}

	// S8: nurbs checks its weights; a point must be finite.
	{
		s := skMust(blacksmith.NewSketch())
		start := skMust(s.AddPoint(0, 0))
		points := [][2]float64{{1, 2}, {3, 2}, {4, 0}}
		knots := []float64{0, 0, 0, 0.5, 1, 1, 1}
		_, err := s.AddNurbs(start, points, knots, 2, []float64{1, 1, 1})
		skRefused(err, "three weights for four points", func(m string) bool {
			return m == "sketch_add_nurbs: 3 weights for 4 control points (the start and 3 given); give one per point"
		})
		curve := skMust(s.AddNurbs(start, points, knots, 2, []float64{1, 0.5, 0.5, 1}))
		ends := skMust(s.Ends(curve))
		skCheck(skMust(s.Kind(curve)) == "free_curve" && len(ends) == 4 && ends[0] == start, "the NURBS reads back wrong")
		s.Close()
		s = skMust(blacksmith.NewSketch())
		_, err = s.AddPoint(math.NaN(), 0)
		skRefused(err, "a NaN point", skPrefix("sketch_add_point: the coordinates must be finite"))
		_, err = s.AddPoint(0, math.Inf(1))
		skRefused(err, "an infinite point", subdContains("sketch_add_point"))
		skCheck(len(skMust(s.Entities())) == 0, "a refused point was kept")
		s.Close()
	}

	// S10 (a): the sense of a signed distance puts the point on its own side of the line.
	for _, sense := range []string{"positive", "negative"} {
		want := 3.0
		if sense == "negative" {
			want = -3.0
		}
		s := skMust(blacksmith.NewSketch())
		la, lb := skMust(s.AddPoint(0, 0)), skMust(s.AddPoint(10, 0))
		ln := skMust(s.AddLine(la, lb))
		skMust(s.Fix(la))
		skMust(s.Fix(lb))
		pt := skMust(s.AddPoint(5, 1))
		dc := skMust(s.PointLineDistance(pt, ln, 3, true, sense))
		skCheck(skMust(s.ConstraintSense(dc)) == sense, "the "+sense+" sense reads back as "+skMust(s.ConstraintSense(dc)))
		skCheck(skMust(s.Solve()).Converged(), "the "+sense+" distance did not converge")
		p := skMust(s.Point(pt))
		skCheck(skNear(p[1], want, 1e-6), fmt.Sprintf("the %s sense put the point at %v", sense, p))
		s.Close()
	}

	// S11: a redundant constraint is listed as redundant, not conflicting, whole and per part.
	{
		s, corners, sides := skRect()
		skMust(s.Fix(corners[0]))
		skMust(s.Length(sides[0], 40, true))
		skMust(s.Length(sides[1], 30, true))
		h := skMust(s.Horizontal(corners[3], corners[2]))
		skCheck(h == 7, fmt.Sprintf("the redundant horizontal is %d, not 7", h))
		dof := skMust(s.Diagnose())
		skCheck(dof.Free == 0 && dof.State == "full", fmt.Sprintf("the rectangle diagnosed as %+v", dof))
		skCheck(slices.Equal(dof.Redundant, []uint32{7}) && dof.Conflicting != nil && len(dof.Conflicting) == 0,
			fmt.Sprintf("redundant %v, conflicting %v; want [7], []", dof.Redundant, dof.Conflicting))
		skCheck(len(dof.Parts) == 1, fmt.Sprintf("%d parts, not 1", len(dof.Parts)))
		part := dof.Parts[0]
		skCheck(part.Free == 0 && part.State == "full", fmt.Sprintf("the part diagnosed as %+v", part))
		skCheck(slices.Equal(part.Redundant, []uint32{7}) && part.Conflicting != nil && len(part.Conflicting) == 0,
			fmt.Sprintf("the part's redundant %v, conflicting %v; want [7], []", part.Redundant, part.Conflicting))
		skCheck(slices.Equal(part.Constraints, []uint32{0, 1, 2, 3, 5, 6, 7}),
			fmt.Sprintf("the part holds %v, not [0 1 2 3 5 6 7]", part.Constraints))
		s.Close()
	}

	// S12: an edit the solve cannot reach is refused, naming the constraints it pulls on,
	// and the sketch is left as it was.
	{
		s := skMust(blacksmith.NewSketch())
		a, b, c := skMust(s.AddPoint(0, 0)), skMust(s.AddPoint(1, 0)), skMust(s.AddPoint(0, 1))
		skMust(s.Distance(a, b, 1, true))
		skMust(s.Distance(b, c, 1, true))
		d3 := skMust(s.Distance(a, c, 1, true))
		_, err := s.SetValue(d3, 10)
		be := skRefused(err, "a triangle's side of 10 beside two of 1", skPrefix("sketch_set_value: the solve did not converge"))
		skCheck(slices.Equal(be.IDs, []uint32{2, 0, 1}), fmt.Sprintf("the diverged edit names %v, not [2 0 1]", be.IDs))
		r := skMust(s.Solve())
		skCheck(r.Converged(), fmt.Sprintf("the sketch after the refused edit solved as %+v", r))
		s.Close()
	}

	// Every constraint method, each on a fresh sketch where nothing is refused: its kind,
	// its refs in the order given, a dimension's value, and the geometry it leaves (so a
	// kind sent under another kind's code is caught even though it reads back as sent).
	{
		type fixture struct {
			s                                       *blacksmith.Sketch
			a, b, l1, c, d, l2, e, c1, f, c2, g, bz uint32
		}
		fresh := func() fixture {
			var x fixture
			x.s = skMust(blacksmith.NewSketch())
			x.a, x.b = skMust(x.s.AddPoint(0, 0)), skMust(x.s.AddPoint(10, 0))
			x.l1 = skMust(x.s.AddLine(x.a, x.b))
			x.c, x.d = skMust(x.s.AddPoint(0, 5)), skMust(x.s.AddPoint(10, 6))
			x.l2 = skMust(x.s.AddLine(x.c, x.d))
			x.e = skMust(x.s.AddPoint(30, 0))
			x.c1 = skMust(x.s.AddCircle(x.e, 5))
			x.f = skMust(x.s.AddPoint(30, 20))
			x.c2 = skMust(x.s.AddCircle(x.f, 3))
			x.g = skMust(x.s.AddPoint(50, 0))
			x.bz = skMust(x.s.AddBezier(x.g, [2]float64{51, 1}, [2]float64{52, 1}, [2]float64{53, 0}))
			return x
		}
		// The geometry the rows check, read back from the sketch.
		near := func(u, v float64) bool { return math.Abs(u-v) <= 1e-6 }
		pt := func(x fixture, id uint32) [2]float64 { return skMust(x.s.Point(id)) }
		sub := func(u, v [2]float64) [2]float64 { return [2]float64{u[0] - v[0], u[1] - v[1]} }
		cross := func(u, v [2]float64) float64 { return u[0]*v[1] - u[1]*v[0] }
		dot := func(u, v [2]float64) float64 { return u[0]*v[0] + u[1]*v[1] }
		norm := func(u [2]float64) float64 { return math.Hypot(u[0], u[1]) }
		gap := func(x fixture, p, q uint32) float64 { return norm(sub(pt(x, q), pt(x, p))) }
		dir := func(x fixture, line uint32) [2]float64 {
			ends := skMust(x.s.Ends(line))
			return sub(pt(x, ends[1]), pt(x, ends[0]))
		}
		offLine := func(x fixture, p [2]float64, line uint32) float64 { // distance from p to line
			ends := skMust(x.s.Ends(line))
			u := dir(x, line)
			return math.Abs(cross(u, sub(p, pt(x, ends[0])))) / norm(u)
		}
		sine := func(u, v [2]float64) float64 { return cross(u, v) / (norm(u) * norm(v)) }
		cosine := func(u, v [2]float64) float64 { return dot(u, v) / (norm(u) * norm(v)) }
		r := func(x fixture, circle uint32) float64 { return skMust(x.s.Radius(circle)) }
		type ids = []uint32
		for _, row := range []struct {
			kind  string
			value float64 // 0: no value (a geometric kind)
			call  func(x fixture) (uint32, error)
			refs  func(x fixture) ids
			holds func(x fixture) bool
		}{
			{"coincident", 0, func(x fixture) (uint32, error) { return x.s.Coincident(x.a, x.c) },
				func(x fixture) ids { return ids{x.a, x.c} },
				func(x fixture) bool { return gap(x, x.a, x.c) <= 1e-6 }},
			{"point_on_line", 0, func(x fixture) (uint32, error) { return x.s.PointOnLine(x.c, x.l1) },
				func(x fixture) ids { return ids{x.c, x.l1} },
				func(x fixture) bool { return near(offLine(x, pt(x, x.c), x.l1), 0) }},
			{"point_on_circle", 0, func(x fixture) (uint32, error) { return x.s.PointOnCircle(x.a, x.c1) },
				func(x fixture) ids { return ids{x.a, x.c1} },
				func(x fixture) bool { return near(gap(x, x.a, x.e), r(x, x.c1)) }},
			{"horizontal", 0, func(x fixture) (uint32, error) { return x.s.Horizontal(x.c, x.d) },
				func(x fixture) ids { return ids{x.c, x.d} },
				func(x fixture) bool { return near(pt(x, x.c)[1], pt(x, x.d)[1]) && gap(x, x.c, x.d) > 1 }},
			{"vertical", 0, func(x fixture) (uint32, error) { return x.s.Vertical(x.a, x.c) },
				func(x fixture) ids { return ids{x.a, x.c} },
				func(x fixture) bool { return near(pt(x, x.a)[0], pt(x, x.c)[0]) && gap(x, x.a, x.c) > 1 }},
			{"parallel", 0, func(x fixture) (uint32, error) { return x.s.Parallel(x.l1, x.l2) },
				func(x fixture) ids { return ids{x.l1, x.l2} },
				func(x fixture) bool { return near(sine(dir(x, x.l1), dir(x, x.l2)), 0) }},
			{"perpendicular", 0, func(x fixture) (uint32, error) { return x.s.Perpendicular(x.l1, x.l2) },
				func(x fixture) ids { return ids{x.l1, x.l2} },
				func(x fixture) bool { return near(cosine(dir(x, x.l1), dir(x, x.l2)), 0) }},
			{"collinear", 0, func(x fixture) (uint32, error) { return x.s.Collinear(x.l1, x.l2) },
				func(x fixture) ids { return ids{x.l1, x.l2} },
				func(x fixture) bool {
					return near(offLine(x, pt(x, x.c), x.l1), 0) && near(offLine(x, pt(x, x.d), x.l1), 0)
				}},
			{"tangent", 0, func(x fixture) (uint32, error) { return x.s.Tangent(x.l2, x.c1, "auto") },
				func(x fixture) ids { return ids{x.l2, x.c1} },
				func(x fixture) bool { return near(offLine(x, pt(x, x.e), x.l2), r(x, x.c1)) }},
			{"tangent_at_end", 0, func(x fixture) (uint32, error) { return x.s.TangentAtEnd(x.bz, x.l1, "end") },
				func(x fixture) ids { return ids{x.bz, x.l1} },
				func(x fixture) bool {
					poles := skMust(x.s.Ends(x.bz))
					return near(sine(sub(pt(x, poles[3]), pt(x, poles[2])), dir(x, x.l1)), 0)
				}},
			{"concentric", 0, func(x fixture) (uint32, error) { return x.s.Concentric(x.c1, x.c2) },
				func(x fixture) ids { return ids{x.c1, x.c2} },
				func(x fixture) bool { return gap(x, x.e, x.f) <= 1e-6 }},
			{"equal_length", 0, func(x fixture) (uint32, error) { return x.s.EqualLength(x.l1, x.l2) },
				func(x fixture) ids { return ids{x.l1, x.l2} },
				func(x fixture) bool { return near(norm(dir(x, x.l1)), norm(dir(x, x.l2))) }},
			{"equal_radius", 0, func(x fixture) (uint32, error) { return x.s.EqualRadius(x.c1, x.c2) },
				func(x fixture) ids { return ids{x.c1, x.c2} },
				func(x fixture) bool { return near(r(x, x.c1), r(x, x.c2)) }},
			{"midpoint", 0, func(x fixture) (uint32, error) { return x.s.Midpoint(x.c, x.l1) },
				func(x fixture) ids { return ids{x.c, x.l1} },
				func(x fixture) bool {
					a, b, c := pt(x, x.a), pt(x, x.b), pt(x, x.c)
					return near(c[0], (a[0]+b[0])/2) && near(c[1], (a[1]+b[1])/2)
				}},
			{"symmetric", 0, func(x fixture) (uint32, error) { return x.s.Symmetric(x.c, x.d, x.l1) },
				func(x fixture) ids { return ids{x.c, x.d, x.l1} },
				func(x fixture) bool {
					c, d := pt(x, x.c), pt(x, x.d)
					mid := [2]float64{(c[0] + d[0]) / 2, (c[1] + d[1]) / 2}
					return near(offLine(x, mid, x.l1), 0) && near(cosine(sub(d, c), dir(x, x.l1)), 0)
				}},
			{"fix", 0, func(x fixture) (uint32, error) { return x.s.Fix(x.a) },
				func(x fixture) ids { return ids{x.a} },
				func(x fixture) bool {
					skMust(x.s.Drag(map[uint32][2]float64{x.a: {3, 3}}))
					return norm(pt(x, x.a)) <= 1e-9
				}},
			{"distance", 12, func(x fixture) (uint32, error) { return x.s.Distance(x.a, x.d, 12, true) },
				func(x fixture) ids { return ids{x.a, x.d} },
				func(x fixture) bool { return near(gap(x, x.a, x.d), 12) }},
			{"point_line_distance", 4, func(x fixture) (uint32, error) { return x.s.PointLineDistance(x.c, x.l1, 4, true, "auto") },
				func(x fixture) ids { return ids{x.c, x.l1} },
				func(x fixture) bool { return near(offLine(x, pt(x, x.c), x.l1), 4) }},
			{"line_distance", 4, func(x fixture) (uint32, error) { return x.s.LineDistance(x.l1, x.l2, 4, true, "auto") },
				func(x fixture) ids { return ids{x.l1, x.l2} },
				func(x fixture) bool { return near(offLine(x, pt(x, x.c), x.l1), 4) }}, // from b's start
			{"circle_line_distance", 7, func(x fixture) (uint32, error) { return x.s.CircleLineDistance(x.c1, x.l1, 7, true, "auto") },
				func(x fixture) ids { return ids{x.c1, x.l1} },
				func(x fixture) bool { return near(offLine(x, pt(x, x.e), x.l1)-r(x, x.c1), 7) }},
			{"circle_distance", 9, func(x fixture) (uint32, error) { return x.s.CircleDistance(x.c1, x.c2, 9, true) },
				func(x fixture) ids { return ids{x.c1, x.c2} },
				func(x fixture) bool { return near(gap(x, x.e, x.f)-r(x, x.c1)-r(x, x.c2), 9) }},
			{"horizontal_distance", 8, func(x fixture) (uint32, error) { return x.s.HorizontalDistance(x.a, x.d, 8, true) },
				func(x fixture) ids { return ids{x.a, x.d} },
				func(x fixture) bool { return near(math.Abs(pt(x, x.d)[0]-pt(x, x.a)[0]), 8) }},
			{"vertical_distance", 4, func(x fixture) (uint32, error) { return x.s.VerticalDistance(x.a, x.d, 4, true) },
				func(x fixture) ids { return ids{x.a, x.d} },
				func(x fixture) bool { return near(math.Abs(pt(x, x.d)[1]-pt(x, x.a)[1]), 4) }},
			{"length", 12, func(x fixture) (uint32, error) { return x.s.Length(x.l1, 12, true) },
				func(x fixture) ids { return ids{x.l1} },
				func(x fixture) bool { return near(norm(dir(x, x.l1)), 12) }},
			{"angle", 0.5, func(x fixture) (uint32, error) { return x.s.Angle(x.l1, x.l2, 0.5, true) },
				func(x fixture) ids { return ids{x.l1, x.l2} },
				func(x fixture) bool {
					u, v := dir(x, x.l1), dir(x, x.l2)
					return near(math.Abs(math.Atan2(cross(u, v), dot(u, v))), 0.5)
				}},
			{"radius", 6, func(x fixture) (uint32, error) { return x.s.RadiusOf(x.c1, 6, true) },
				func(x fixture) ids { return ids{x.c1} },
				func(x fixture) bool { return near(r(x, x.c1), 6) }},
			{"diameter", 8, func(x fixture) (uint32, error) { return x.s.Diameter(x.c1, 8, true) },
				func(x fixture) ids { return ids{x.c1} },
				func(x fixture) bool { return near(r(x, x.c1), 4) }},
		} {
			x := fresh()
			id, err := row.call(x)
			if err != nil {
				fail(fmt.Sprintf("sketch: every method: %s was refused: %v", row.kind, err))
			}
			got := skMust(x.s.ConstraintKind(id))
			skCheck(got == row.kind, fmt.Sprintf("every method: the %s reads back as %s", row.kind, got))
			held := skMust(x.s.ConstraintRefs(id))
			skCheck(slices.Equal(held, row.refs(x)), fmt.Sprintf("every method: the %s holds %v, not %v", row.kind, held, row.refs(x)))
			v := skMust(x.s.ConstraintValue(id))
			if row.value == 0 {
				skCheck(v == nil, fmt.Sprintf("every method: the %s has a value", row.kind))
			} else {
				skCheck(v != nil && *v == row.value, fmt.Sprintf("every method: the %s's value is not %v", row.kind, row.value))
			}
			skCheck(row.holds(x), fmt.Sprintf("every method: the %s does not hold in the geometry", row.kind))
			x.s.Close()
		}
		x := fresh()
		h, i, j := skMust(x.s.AddPoint(70, 0)), skMust(x.s.AddPoint(75, 0)), skMust(x.s.AddPoint(70, 5))
		arc := skMust(x.s.AddArc(h, i, j))
		skCheck(skMust(x.s.Kind(arc)) == "arc" && skMust(x.s.Centre(arc)) == h &&
			slices.Equal(skMust(x.s.Ends(arc)), []uint32{i, j}), "every method: add_arc reads back wrong")
		k := skMust(x.s.AddPoint(90, 0))
		conic := skMust(x.s.AddConic(k, [2]float64{91, 1}, [2]float64{92, 0}, 0.7))
		ends := skMust(x.s.Ends(conic))
		skCheck(skMust(x.s.Kind(conic)) == "free_curve" && len(ends) == 3 && ends[0] == k,
			"every method: add_conic reads back wrong")
		x.s.Close()
	}

	fmt.Println("sketch: plate, conflict, drag, reference, profile, read-back, ends, nurbs, senses, redundancy, divergence and every method all hold")
}

// healRel is whether a is b to rel, relatively.
func healRel(a, b, rel float64) bool { return math.Abs(a-b) <= rel*math.Abs(b) }

// healCheck fails the smoke with what, prefixed, unless ok.
func healCheck(ok bool, what string) {
	if !ok {
		fail("health: " + what)
	}
}

func healMust[T any](v T, err error) T {
	if err != nil {
		fail("health: " + err.Error())
	}
	return v
}

func healOf(v float64) *float64 { return &v }

// healthKernel checks Solid.Health, Solid.Healed and Solid.EdgeTolerance on Python's own
// figures (test_health_* and test_healed_* in test_cadaclysm_blacksmith.py): a closed cuboid,
// the cuboid without a face, a thin plate, a tiny body, the healed cuboid, every kind toggled
// off, and a closed solid.
func healthKernel() {
	// 1. a closed cuboid: nothing free or small, no cracks unless asked for, and the figures
	// that scale with the extent
	box := healMust(blacksmith.Cuboid(10, 10, 10))
	defer box.Close()
	r := healMust(box.Health(nil, false))
	healCheck(len(r.FreeEdges) == 0 && len(r.Wires) == 0 && len(r.Small) == 0, "the closed cuboid has free edges, wires or small features")
	healCheck(r.Cracks == nil, "the cuboid's report has cracks without asking for the mesh")
	healCheck(healRel(r.Extent, 10*math.Sqrt(3), 1e-12), fmt.Sprintf("the cuboid's extent is %v", r.Extent))
	healCheck(healRel(r.Rounding, 1e-7*r.Extent, 1e-12), fmt.Sprintf("the cuboid's rounding is %v", r.Rounding))
	healCheck(healRel(r.Tolerance, 1e-4*r.Extent, 1e-12), fmt.Sprintf("the cuboid's tolerance is %v", r.Tolerance))
	healCheck(r.LooseEdges == 0 && r.WorstLoose == 0 && r.SewPairs == 0 && r.SewRefused == 0 && r.SewWorstGap == 0,
		fmt.Sprintf("the cuboid has loose or sewing figures: %+v", r))
	meshed := healMust(box.Health(nil, true))
	c := meshed.Cracks
	healCheck(c != nil && c.Watertight && c.Open == 0 && c.Folded == 0 && c.Crossings == 0 && len(c.Edges) == 0,
		fmt.Sprintf("the meshed cuboid's cracks are %+v", c))
	healCheck(healMust(box.Health(healOf(0.5), false)).Tolerance == 0.5, "health(0.5) did not judge at 0.5")
	healCheck(healMust(box.Health(healOf(-1), false)).Tolerance == r.Tolerance, "health(-1) did not take the default")

	// 2. the cuboid without face 0: one closed rim of four edges, each partnered across the hole
	hole := healMust(box.DropFaces([]int{0}))
	defer hole.Close()
	r = healMust(hole.Health(nil, false))
	healCheck(len(r.FreeEdges) == 4 && len(r.Wires) == 1, fmt.Sprintf("the rim is %d edges in %d wires", len(r.FreeEdges), len(r.Wires)))
	w := r.Wires[0]
	healCheck(w.First == 0 && w.Count == 4 && w.Closed && healRel(w.Length, 40, 1e-9), fmt.Sprintf("the rim's wire is %+v", w))
	want := [][4]uint32{{4, 3, 1, 2}, {16, 2, 4, 3}, {11, 1, 2, 0}, {15, 0, 3, 1}}
	for i, e := range r.FreeEdges {
		healCheck(e.Edge != nil && e.Partner != nil, fmt.Sprintf("rim edge %d has no edge or no partner", i))
		got := [4]uint32{e.Trim, *e.Edge, e.Face, uint32(*e.Partner)}
		healCheck(got == want[i], fmt.Sprintf("rim edge %d is (trim, edge, face, partner) %v, not %v", i, got, want[i]))
		healCheck(e.Wire == 0 && e.SharedEnds == 0, fmt.Sprintf("rim edge %d is on wire %d sharing %d ends", i, e.Wire, e.SharedEnds))
		healCheck(healRel(e.Length, 10, 1e-9) && healRel(e.Gap, 10, 1e-9), fmt.Sprintf("rim edge %d is %v long, %v away", i, e.Length, e.Gap))
		healCheck(*r.FreeEdges[*e.Partner].Partner == i, fmt.Sprintf("rim edge %d's partner is not partnered back", i))
	}
	healCheck(healRel(r.WorstGap, 10, 1e-9), fmt.Sprintf("the rim's worst gap is %v", r.WorstGap))
	healCheck(reflect.DeepEqual(r.WireEdges(0), r.FreeEdges), "wire 0's edges are not the rim")
	c = healMust(hole.Health(nil, true)).Cracks
	healCheck(c != nil && !c.Watertight && c.Open == 0 && c.Folded == 0 && c.Crossings == 0 && len(c.Edges) == 0,
		fmt.Sprintf("the meshed rim's cracks are %+v", c))
	healCheck(r.SewPairs == 0 && r.SewRefused == 0 && r.SewWorstGap == 0 && r.LooseEdges == 0, "the rim has something to sew")

	// 3. a thin plate at 0.01: its four thickness edges, then its four side faces
	plate := healMust(blacksmith.Cuboid(10, 10, 0.001))
	defer plate.Close()
	r = healMust(plate.Health(healOf(0.01), false))
	healCheck(len(r.Small) == 8, fmt.Sprintf("the plate has %d small features", len(r.Small)))
	for i, s := range r.Small {
		if i < 4 {
			healCheck(s.Kind == "short_edge" && s.Index == uint32(8+i) && healRel(s.Size, 0.001, 1e-9), fmt.Sprintf("plate small %d is %+v", i, s))
		} else {
			healCheck(s.Kind == "sliver_face" && s.Index == uint32(i-2) && healRel(s.Size, 0.0009999, 1e-3), fmt.Sprintf("plate small %d is %+v", i, s))
		}
	}

	// 4. a tiny body at 0.01: twelve short edges, six tiny faces, the tiny body
	tiny := healMust(blacksmith.Cuboid(0.0005, 0.0005, 0.0005))
	defer tiny.Close()
	r = healMust(tiny.Health(healOf(0.01), false))
	kinds := map[string][]blacksmith.SmallFeature{}
	for _, s := range r.Small {
		kinds[s.Kind] = append(kinds[s.Kind], s)
	}
	healCheck(len(kinds) == 3 && len(kinds["short_edge"]) == 12 && len(kinds["tiny_face"]) == 6 && len(kinds["tiny_body"]) == 1,
		fmt.Sprintf("the tiny body's small features are %+v", r.Small))
	for i, s := range kinds["tiny_face"] {
		healCheck(s.Index == uint32(i) && healRel(s.Size, 2.5e-7, 1e-9), fmt.Sprintf("tiny face %d is %+v", i, s))
	}
	b := kinds["tiny_body"][0]
	healCheck(b.Index == 0 && healRel(b.Size, 0.0005*math.Sqrt(3), 1e-9), fmt.Sprintf("the tiny body is %+v", b))

	// 5. the healed cuboid: itself, as a new solid
	healed, hr := healMust2(box.Healed(nil, true, true, true))
	defer healed.Close()
	healCheck(healed != box && !healed.Closed(), "healed is not a new solid")
	healCheck(len(hr.Fixes) == 0 && len(hr.Refused) == 0 && !hr.Guarded, fmt.Sprintf("the cuboid healed something: %+v", hr))
	healCheck(hr.SmallBefore == 0 && hr.SmallAfter == 0 && hr.FreeBefore == 0 && hr.FreeAfter == 0, fmt.Sprintf("the cuboid's before/after: %+v", hr))
	healCheck(hr.ClosedBefore && hr.ClosedAfter && hr.NonmanifoldBefore == 0 && hr.NonmanifoldAfter == 0, fmt.Sprintf("the cuboid's closed/non-manifold: %+v", hr))
	healCheck(healRel(hr.Tolerance, healMust(box.Health(nil, false)).Tolerance, 1e-12) && hr.Moved == 0, fmt.Sprintf("the cuboid healed at %v, moving %v", hr.Tolerance, hr.Moved))
	healCheck(healMust(healed.Faces()) == 6 && healRel(healMust(healed.Mass(0)).Volume, 1000, 1e-9), "the healed cuboid is not the cuboid")
	again, ar := healMust2(box.Healed(healOf(0.5), true, true, true))
	again.Close()
	healCheck(ar.Tolerance == 0.5, "healed(0.5) did not heal at 0.5")
	for e := uint32(0); e < 12; e++ {
		t := healMust(healed.EdgeTolerance(e))
		healCheck(t != nil && *t == 0, fmt.Sprintf("edge %d of the healed cuboid has tolerance %v", e, t))
	}
	healCheck(healMust(healed.EdgeTolerance(0xFFFFFFF0)) == nil, "an edge no trim names has a tolerance")

	// 6. the plate with every kind switched off: each small feature refused as toggled
	off, or := healMust2(plate.Healed(healOf(0.01), false, false, false))
	off.Close()
	healCheck(len(or.Fixes) == 0 && or.SmallBefore == 8 && or.SmallAfter == 8, fmt.Sprintf("the toggled plate: %+v", or))
	healCheck(len(or.Refused) == 8, fmt.Sprintf("the toggled plate refused %d", len(or.Refused)))
	for i, f := range or.Refused {
		want := blacksmith.HealRefusal{Kind: "short_edge", Index: uint32(8 + i), Why: "toggled"}
		if i >= 4 {
			want = blacksmith.HealRefusal{Kind: "sliver_face", Index: uint32(i - 2), Why: "toggled"}
		}
		healCheck(f == want, fmt.Sprintf("toggled refusal %d is %+v, not %+v", i, f, want))
	}
	on, onr := healMust2(plate.Healed(healOf(0.01), true, true, true))
	on.Close()
	healCheck(onr.SmallBefore == 8, fmt.Sprintf("the plate healed with %d small before", onr.SmallBefore))
	for _, f := range onr.Refused {
		healCheck(f.Why != "toggled", "a kind switched on was refused as toggled")
		healCheck(!onr.Guarded || f.Why == "body_guard", "a guarded refusal is not body_guard")
	}

	// 6b. a pinhole: a sheet trimmed round a radius-0.05 peg holds a small hole at 0.2 (loop 1),
	// which healing drops with holes on and refuses as toggled with holes off -- the one kind
	// the cuboids above never reach, so the holes switch is seen to reach the library
	xy := blacksmith.Frame{0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}
	square := healMust(blacksmith.Rect(20, 20))
	defer square.Close()
	pin := healMust(blacksmith.Circle(0.05))
	defer pin.Close()
	sheet := healMust(blacksmith.Face(square, xy))
	defer sheet.Close()
	peg := healMust(blacksmith.Extrude(pin, blacksmith.Frame{0, 0, -6, 1, 0, 0, 0, 1, 0, 0, 0, 1}, 12))
	defer peg.Close()
	pinholed := healMust(sheet.Trim(peg, "outside", blacksmith.DefaultTolerance))
	defer pinholed.Close()
	holes := 0
	for _, s := range healMust(pinholed.Health(healOf(0.2), false)).Small {
		if s.Kind == "small_hole" {
			healCheck(s.Index == 1, fmt.Sprintf("the pinhole is loop %d", s.Index))
			holes++
		}
	}
	healCheck(holes == 1, fmt.Sprintf("the pinholed sheet has %d small holes at 0.2", holes))
	filled, fr := healMust2(pinholed.Healed(healOf(0.2), true, true, true))
	filled.Close()
	dropped := false
	for _, f := range fr.Fixes {
		dropped = dropped || f.Kind == "small_hole"
	}
	healCheck(dropped && fr.SmallAfter == 0, fmt.Sprintf("healing with holes on did not drop the pinhole: %+v", fr))
	kept, kr := healMust2(pinholed.Healed(healOf(0.2), true, true, false))
	kept.Close()
	toggled := false
	for _, f := range kr.Refused {
		toggled = toggled || (f.Kind == "small_hole" && f.Why == "toggled")
	}
	healCheck(toggled, fmt.Sprintf("healing with holes off did not refuse the pinhole as toggled: %+v", kr))

	// 7. a closed solid refuses all three
	closed := healMust(blacksmith.Cuboid(1, 1, 1))
	closed.Close()
	_, err := closed.Health(nil, false)
	healCheck(errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("health on a closed solid: %v", err))
	_, _, err = closed.Healed(nil, true, true, true)
	healCheck(errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("healed on a closed solid: %v", err))
	_, err = closed.EdgeTolerance(0)
	healCheck(errors.Is(err, blacksmith.ErrClosed), fmt.Sprintf("edge_tolerance on a closed solid: %v", err))

	fmt.Println("health (kernel): cuboid, rim, plate, tiny body, healed cuboid, toggled plate, pinhole and a closed solid all hold")
}

func healMust2[A, B any](a A, b B, err error) (A, B) {
	if err != nil {
		fail("health: " + err.Error())
	}
	return a, b
}

// healthReader checks Brep.Health, Brep.Healed and Brep.EdgeTolerance on st203-bapl.stp's
// second body, on Python's figures (test_brep_health_* and test_brep_healed_* in
// test_cadaclysm.py). The sample is the repository's (scripts/link-samples.py), beside the
// smoke's own sample's folder, so this runs where found.
func healthReader(path string) {
	sample := filepath.Join(filepath.Dir(filepath.Dir(mustAbs(path))), "st203-bapl.stp")
	if _, err := os.Stat(sample); err != nil {
		fmt.Println("health (reader): skipped, no sample:", sample)
		return
	}
	scene, err := cadaclysm.Open(sample)
	if err != nil {
		fail(err.Error())
	}
	defer scene.Close()
	var breps []*cadaclysm.Brep
	for _, n := range scene.Nodes() {
		if b := healMust(n.Brep()); b != nil {
			breps = append(breps, b)
		}
	}
	healCheck(len(breps) > 1, fmt.Sprintf("st203-bapl.stp has %d breps", len(breps)))
	body := breps[1] // the 188-free-edge body; body 0 takes minutes to diagnose

	// 8. the health report
	r := healMust(body.Health(nil, false))
	healCheck(len(r.FreeEdges) == 188 && len(r.Wires) == 45, fmt.Sprintf("st203 body 1 has %d free edges in %d wires", len(r.FreeEdges), len(r.Wires)))
	sum := 0
	for _, w := range r.Wires {
		sum += w.Count
	}
	healCheck(sum == 188, fmt.Sprintf("the wires' counts sum to %d", sum))
	for i := range r.Wires {
		for _, e := range r.WireEdges(i) {
			healCheck(e.Wire == i, fmt.Sprintf("an edge of wire %d says it is on wire %d", i, e.Wire))
		}
	}
	healCheck(reflect.DeepEqual(r.WireEdges(0), r.FreeEdges[:r.Wires[0].Count]), "wire 0's edges are not the first rows")
	first := r.FreeEdges[0]
	healCheck(first.Edge != nil && first.Partner != nil, "free edge 0 has no edge or no partner")
	got := [6]uint32{first.Trim, *first.Edge, first.Face, uint32(first.Wire), uint32(*first.Partner), uint32(first.SharedEnds)}
	healCheck(got == [6]uint32{0, 41363, 0, 0, 67, 0}, fmt.Sprintf("free edge 0 is %v", got))
	healCheck(healRel(first.Gap, 95.01496054, 1e-6), fmt.Sprintf("free edge 0's gap is %v", first.Gap))
	for _, e := range r.FreeEdges {
		healCheck(e.Partner != nil || math.IsInf(e.Gap, 1), "a free edge without a partner has a finite gap")
	}
	healCheck(healRel(r.Extent, 253.66439715552204, 1e-12), fmt.Sprintf("the extent is %v", r.Extent))
	healCheck(r.LooseEdges == 0 && r.Cracks == nil, "st203 body 1 has loose edges or unasked cracks")
	sewn, sew, err := body.Sewed(nil, nil)
	if err != nil {
		fail(err.Error())
	}
	sewn.Close()
	healCheck(r.SewRefused == 4 && r.SewRefused == int(sew.Refused) && r.SewPairs == int(sew.Pairs),
		fmt.Sprintf("health's sewing (%d, %d) is not sewed's (%d, %d)", r.SewPairs, r.SewRefused, sew.Pairs, sew.Refused))
	healCheck(healMust(body.Health(healOf(math.NaN()), false)).Tolerance == r.Tolerance, "health(NaN) did not take the default")
	c := healMust(body.Health(nil, true)).Cracks
	healCheck(c != nil && !c.Watertight && c.Open == 0 && c.Folded == 0 && c.Crossings == 166 && len(c.Edges) == 0,
		fmt.Sprintf("the meshed report's cracks are %+v", c))
	wide := healMust(body.Health(healOf(5), false))
	healCheck(len(wide.Small) == 96, fmt.Sprintf("%d small at 5", len(wide.Small)))
	var short *cadaclysm.SmallFeature
	for i := range wide.Small {
		if wide.Small[i].Kind == "short_edge" {
			short = &wide.Small[i]
			break
		}
	}
	healCheck(short != nil && short.Index == 41550 && healRel(short.Size, 3.1622776616321775, 1e-9), fmt.Sprintf("the first short edge is %+v", short))

	// 9. healed at 5
	healed, hr := healMust2(body.Healed(healOf(5), true, true, true))
	healCheck(hr.Tolerance == 5 && hr.SmallBefore == 96, fmt.Sprintf("healed at %v from %d small", hr.Tolerance, hr.SmallBefore))
	healCheck(len(hr.Fixes) == 28 && hr.SmallAfter == 8 && hr.FreeBefore == 188 && hr.FreeAfter == 88,
		fmt.Sprintf("healed: %d fixes, small after %d, free %d -> %d", len(hr.Fixes), hr.SmallAfter, hr.FreeBefore, hr.FreeAfter))
	healCheck(len(hr.Refused) == 8, fmt.Sprintf("healed refused %d", len(hr.Refused)))
	for _, f := range hr.Refused {
		healCheck(f.Kind == "sliver_face" && f.Why == "uneven", fmt.Sprintf("a refusal is %+v", f))
	}
	healCheck(!hr.ClosedBefore && !hr.ClosedAfter && hr.NonmanifoldBefore == 0 && hr.NonmanifoldAfter == 0, fmt.Sprintf("closed/non-manifold: %+v", hr))
	most := 0.0
	for _, f := range hr.Fixes {
		most = math.Max(most, f.Moved)
	}
	healCheck(healRel(hr.Moved, 1.581138831332503, 1e-9) && healRel(most, 1.8248105306211464, 1e-9), fmt.Sprintf("moved %v, the largest fix %v", hr.Moved, most))
	healCheck(len(healMust(healed.Health(healOf(5), false)).Small) == hr.SmallAfter, "small after is not the result's health")
	healCheck(len(healMust(body.Health(healOf(5), false)).Small) == 96, "the input was not left as it was")
	t := healMust(body.EdgeTolerance(41550))
	healCheck(t != nil && *t == 0, fmt.Sprintf("the input's edge 41550 has tolerance %v", t))
	healCheck(healMust(healed.EdgeTolerance(41550)) == nil, "the merged edge 41550 has a tolerance")
	t = healMust(healed.EdgeTolerance(41363))
	healCheck(t != nil && *t == 0, fmt.Sprintf("the healed edge 41363 has tolerance %v", t))
	healCheck(healMust(healed.EdgeTolerance(0xFFFFFFF0)) == nil, "an edge no trim names has a tolerance")
	healed.Close()

	// every kind switched off: nothing healed, every small feature refused as toggled
	off, or := healMust2(body.Healed(healOf(5), false, false, false))
	off.Close()
	healCheck(len(or.Fixes) == 0 && len(or.Refused) == 96 && or.FreeAfter == or.FreeBefore, fmt.Sprintf("all off: %d fixes, %d refused", len(or.Fixes), len(or.Refused)))
	per := map[string]int{}
	for _, f := range or.Refused {
		healCheck(f.Why == "toggled" && f.Figure == 0, fmt.Sprintf("an all-off refusal is %+v", f))
		per[f.Kind]++
	}
	healCheck(len(per) == 3 && per["short_edge"] == 64 && per["sliver_face"] == 26 && per["tiny_face"] == 6, fmt.Sprintf("all off, per kind: %v", per))
	// one kind switched on: the others refused as toggled
	edges, er := healMust2(body.Healed(healOf(5), true, false, false))
	edges.Close()
	for _, f := range er.Refused {
		healCheck(f.Kind == "short_edge" || f.Why == "toggled", fmt.Sprintf("edges only refused %+v", f))
	}
	for _, f := range er.Fixes {
		healCheck(f.Kind == "short_edge" || f.Kind == "collapsed_edge", fmt.Sprintf("edges only fixed %+v", f))
	}

	for _, b := range breps {
		b.Close()
	}
	_, _, err = body.Healed(nil, true, true, true)
	healCheck(err != nil && strings.Contains(err.Error(), "released"), fmt.Sprintf("healed on a released brep: %v", err))
	_, err = body.Health(nil, false)
	healCheck(err != nil && strings.Contains(err.Error(), "released"), fmt.Sprintf("health on a released brep: %v", err))
	_, err = body.EdgeTolerance(0)
	healCheck(err != nil && strings.Contains(err.Error(), "released"), fmt.Sprintf("edge_tolerance on a released brep: %v", err))
	fmt.Println("health (reader): st203-bapl.stp body 1's health, healed at 5, toggled kinds and a released brep all hold")
}

// ---- transforms ----------------------------------------------------------------------
//
// Transform, Quaternion, Solid.Transform / ConvertToNurbs / InexactTrims, on Python's own
// figures (test_a_transform_is_sixteen_numbers_row_major_and_composes_right_to_left through
// test_a_solid_converts_to_nurbs_at_each_level in test_cadaclysm_blacksmith.py). The profile
// verbs (Python's test_a_profile_turns_scales_mirrors_and_maps) are in
// blacksmith/transform_test.go, where the profile's own polylines can be read.

func tfMust[T any](v T, err error) T {
	if err != nil {
		fail("transforms: " + err.Error())
	}
	return v
}

func tfCheck(ok bool, what string) {
	if !ok {
		fail("transforms: " + what)
	}
}

// tfRefused fails unless err is a *BuildError whose message starts with prefix.
func tfRefused(err error, prefix, what string) {
	var be *blacksmith.BuildError
	if err == nil || !errors.As(err, &be) || !strings.HasPrefix(be.Message, prefix) {
		fail(fmt.Sprintf("transforms: %s: expected a *BuildError starting %q, got %v", what, prefix, err))
	}
}

func tfNear3(a, b [3]float64, tolerance float64) bool {
	for i := range a {
		if !(math.Abs(a[i]-b[i]) <= tolerance) {
			return false
		}
	}
	return true
}

func tfNear4(a, b [4]float64, tolerance float64) bool {
	for i := range a {
		if !(math.Abs(a[i]-b[i]) <= tolerance) {
			return false
		}
	}
	return true
}

// tfDet is the determinant of a map's linear part.
func tfDet(t blacksmith.Transform) float64 {
	r := t.Rows()
	return r[0]*(r[5]*r[10]-r[6]*r[9]) - r[1]*(r[4]*r[10]-r[6]*r[8]) + r[2]*(r[4]*r[9]-r[5]*r[8])
}

func transforms() {
	transformRows()
	transformConstructors()
	transformToldAndSplit()
	transformQuaternions()
	transformQuaternionsFarFromUnit()
	transformSolids()
	transformKeepsColoursAndName()
	transformNurbsLevels()
	fmt.Println("transforms: rows, constructors, splits, quaternions, solids, colours and levels hold")
}

var tfOrigin = [3]float64{0, 0, 0}

// 1. Rows and composition.
func transformRows() {
	t := tfMust(blacksmith.TransformTranslation([3]float64{1, 2, 3}))
	tfCheck(t.Rows() == [16]float64{1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1}, fmt.Sprintf("translation's rows are %v", t.Rows()))
	s := tfMust(blacksmith.TransformScale(tfOrigin, 2))
	ts := tfMust(t.Compose(s))
	st := tfMust(s.Compose(t))
	tfCheck(tfNear3(ts.Point([3]float64{1, 1, 1}), [3]float64{3, 4, 5}, 1e-12), fmt.Sprintf("(t after s) of (1,1,1) is %v", ts.Point([3]float64{1, 1, 1})))
	tfCheck(tfNear3(st.Point([3]float64{1, 1, 1}), [3]float64{4, 6, 8}, 1e-12), fmt.Sprintf("(s after t) of (1,1,1) is %v", st.Point([3]float64{1, 1, 1})))
	back := tfMust(tfMust(ts.Inverse()).Compose(ts))
	tfCheck(tfNear3(back.Point([3]float64{3, -4, 5}), [3]float64{3, -4, 5}, 1e-12), "inverse after the map moves (3,-4,5)")
	rows := t.Rows()
	tfCheck(tfMust(blacksmith.TransformFromRows(rows[:])) == t, "from_rows(t.rows) != t")
	tfCheck(tfMust(blacksmith.NewTransform()) == blacksmith.TransformIdentity(), "Transform() != identity()")
	tfCheck(blacksmith.Transform{} == blacksmith.TransformIdentity(), "the zero Transform is not the identity")
	tfCheck(tfMust(blacksmith.TransformFromMatrix([4][4]float64{{1, 0, 0, 1}, {0, 1, 0, 2}, {0, 0, 1, 3}, {0, 0, 0, 1}})) == t, "four rows of four != t")
	_, err := blacksmith.NewTransform(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1)
	tfRefused(err, "Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)", "a bad bottom row")
	_, err = blacksmith.TransformFromRows(make([]float64, 15))
	tfRefused(err, "Transform: a matrix is 16 numbers, got 15", "15 numbers")
	nan := rows
	nan[5] = math.NaN()
	_, err = blacksmith.TransformFromRows(nan[:])
	tfRefused(err, "Transform: not finite", "a NaN")
	flat := tfMust(blacksmith.TransformScaleXYZ(blacksmith.FrameXY(tfOrigin), 1, 1, 0))
	_, err = flat.Inverse()
	tfRefused(err, "transform_inverse: the map is singular", "a singular inverse")
}

// 2. Constructors, closed forms.
func transformConstructors() {
	fxy := blacksmith.FrameXY(tfOrigin)
	f123 := blacksmith.FrameXY([3]float64{1, 2, 3})
	for _, c := range []struct {
		what string
		t    blacksmith.Transform
		p    [3]float64
		want [3]float64
	}{
		{"rotation", tfMust(blacksmith.TransformRotation([3]float64{1, 0, 0}, [3]float64{0, 0, 1}, math.Pi/2)), [3]float64{2, 0, 0}, [3]float64{1, 1, 0}},
		{"mirror", tfMust(blacksmith.TransformMirror(blacksmith.FrameXY([3]float64{0, 0, 5}))), [3]float64{1, 2, 3}, [3]float64{1, 2, 7}},
		{"scale_xyz", tfMust(blacksmith.TransformScaleXYZ(fxy, 2, 3, 4)), [3]float64{1, 1, 1}, [3]float64{2, 3, 4}},
		{"scale", tfMust(blacksmith.TransformScale([3]float64{1, 2, 3}, 2)), [3]float64{2, 2, 3}, [3]float64{3, 2, 3}},
		{"scale's centre", tfMust(blacksmith.TransformScale([3]float64{1, 2, 3}, 2)), [3]float64{1, 2, 3}, [3]float64{1, 2, 3}},
		{"shear", tfMust(blacksmith.TransformShear(fxy, [3]float64{5, 0, 0}, 0.5)), [3]float64{0, 0, 2}, [3]float64{1, 0, 2}},
		{"planar_projection", tfMust(blacksmith.TransformPlanarProjection(fxy)), [3]float64{1, 2, 3}, [3]float64{1, 2, 0}},
		{"project_along", tfMust(blacksmith.TransformProjectAlong(fxy, [3]float64{1, 0, 1})), [3]float64{0, 0, 2}, [3]float64{-2, 0, 0}},
		{"plane_to_plane", tfMust(blacksmith.TransformPlaneToPlane(fxy, f123)), tfOrigin, [3]float64{1, 2, 3}},
		{"change_basis", tfMust(blacksmith.TransformChangeBasis(f123, fxy)), tfOrigin, [3]float64{1, 2, 3}},
	} {
		got := c.t.Point(c.p)
		tfCheck(tfNear3(got, c.want, 1e-12), fmt.Sprintf("%s of %v is %v, not %v", c.what, c.p, got, c.want))
	}
	_, err := blacksmith.TransformShear(fxy, [3]float64{0, 0, 1}, 0.5)
	tfRefused(err, "transform_shear: the shear direction must lie in the plane", "a shear off the plane")
	// The raw twelve numbers: a Frame literal is taken as written, so the library judges it.
	skew := blacksmith.Frame{0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1}
	_, err = blacksmith.TransformMirror(skew)
	tfRefused(err, "transform_mirror: the frame is not right-handed and orthonormal", "a skew mirror")
}

// 3. Told and split.
func transformToldAndSplit() {
	fxy := blacksmith.FrameXY(tfOrigin)
	turn := tfMust(blacksmith.TransformRotation([3]float64{1, 2, 3}, [3]float64{1, 1, 0}, 0.7))
	tfCheck(tfMust(turn.IsRigid(1e-9)), "the turn is not rigid")
	k, ok, err := turn.IsSimilarity(1e-9)
	tfCheck(err == nil && ok && math.Abs(k-1) <= 1e-9, fmt.Sprintf("the turn's similarity is %v %v %v", k, ok, err))
	big := tfMust(tfMust(blacksmith.TransformScale(tfOrigin, 2.5)).Compose(turn))
	tfCheck(!tfMust(big.IsRigid(1e-9)), "the scaled turn is rigid")
	k, ok, err = big.IsSimilarity(1e-9)
	tfCheck(err == nil && ok && math.Abs(k-2.5) <= 1e-9, fmt.Sprintf("the scaled turn's similarity is %v %v %v", k, ok, err))
	sim, ok, err := big.DecomposeSimilarity(1e-9)
	tfCheck(err == nil && ok && math.Abs(sim.K-2.5) <= 1e-9 && tfMust(sim.Orthogonal.IsRigid(1e-9)), fmt.Sprintf("the scaled turn splits as %+v %v %v", sim, ok, err))
	sim, ok, err = tfMust(blacksmith.TransformScale([3]float64{1, 2, 3}, 2)).DecomposeSimilarity(1e-9)
	tfCheck(err == nil && ok && tfNear3(sim.Translation, [3]float64{-1, -2, -3}, 1e-12) && math.Abs(sim.K-2) <= 1e-12 &&
		sim.Orthogonal == blacksmith.TransformIdentity(), fmt.Sprintf("the scale about (1,2,3) splits as %+v %v %v", sim, ok, err))
	rigid, ok, err := turn.DecomposeRigid(1e-9)
	r := turn.Rows()
	tfCheck(err == nil && ok && tfNear3(rigid.Translation, [3]float64{r[3], r[7], r[11]}, 1e-12) && tfMust(rigid.Orthogonal.IsRigid(1e-9)),
		fmt.Sprintf("the turn splits as %+v %v %v", rigid, ok, err))
	stretch := tfMust(blacksmith.TransformScaleXYZ(fxy, 1, 2, 3))
	_, ok, err = stretch.IsSimilarity(1e-9)
	tfCheck(err == nil && !ok, "the stretch is a similarity")
	_, ok, err = stretch.DecomposeRigid(1e-9)
	tfCheck(err == nil && !ok, "the stretch has a rigid split")
	_, ok, err = stretch.DecomposeSimilarity(1e-9)
	tfCheck(err == nil && !ok, "the stretch has a similarity split")
	aff, ok, err := tfMust(tfMust(blacksmith.TransformMirror(fxy)).Compose(stretch)).DecomposeAffine()
	tfCheck(err == nil && ok, fmt.Sprintf("the mirrored stretch has no affine split: %v", err))
	tfCheck(tfNear3(aff.Stretch, [3]float64{3, 2, 1}, 1e-9), fmt.Sprintf("the stretch is %v", aff.Stretch))
	// Only the rotation carries the mirror; the axes are a proper rotation -- which pins the order.
	tfCheck(math.Abs(tfDet(aff.Rotation)+1) <= 1e-9 && math.Abs(tfDet(aff.Axes)-1) <= 1e-9,
		fmt.Sprintf("det(rotation) %v, det(axes) %v", tfDet(aff.Rotation), tfDet(aff.Axes)))
	_, ok, err = tfMust(blacksmith.TransformPlanarProjection(fxy)).DecomposeAffine()
	tfCheck(err == nil && !ok, "a projection has an affine split")
	_, err = turn.IsRigid(-1)
	tfRefused(err, "transform_is_rigid: the tolerance must be finite and not negative", "is_rigid(-1)")
	_, _, err = turn.IsSimilarity(-1)
	tfRefused(err, "transform_is_similarity: the tolerance must be finite and not negative", "is_similarity(-1)")
}

// 4. Quaternions.
func transformQuaternions() {
	q := tfMust(blacksmith.QuaternionFromAxisAngle([3]float64{0, 0, 2}, math.Pi/2))
	tfCheck(tfNear4(q.Components(), [4]float64{math.Cos(math.Pi / 4), 0, 0, math.Sin(math.Pi / 4)}, 1e-12), fmt.Sprintf("q is %v", q))
	axis, ok := q.Axis()
	tfCheck(math.Abs(q.Angle()-math.Pi/2) <= 1e-12 && ok && tfNear3(axis, [3]float64{0, 0, 1}, 1e-12), fmt.Sprintf("q's angle %v, axis %v %v", q.Angle(), axis, ok))
	tfCheck(tfNear3(tfMust(q.ToTransform([3]float64{1, 0, 0})).Point([3]float64{2, 0, 0}), [3]float64{1, 1, 0}, 1e-12), "q about (1,0,0) does not take (2,0,0) to (1,1,0)")
	c := q.Components()
	twice := tfMust(blacksmith.NewQuaternion(2*c[0], 2*c[1], 2*c[2], 2*c[3]))
	tfCheck(tfNear3(tfMust(twice.ToTransform(tfOrigin)).Point([3]float64{1, 0, 0}), [3]float64{0, 1, 0}, 1e-12), "2q does not turn as q")
	back := tfMust(blacksmith.QuaternionFromTransform(tfMust(q.ToTransform(tfOrigin))))
	tfCheck(tfNear4(back.Components(), q.Components(), 1e-12), fmt.Sprintf("from_transform(q.to_transform()) is %v", back))
	quarter := tfMust(blacksmith.QuaternionSlerp(blacksmith.QuaternionIdentity(), q, 0.25))
	tfCheck(math.Abs(quarter.Angle()-math.Pi/8) <= 1e-12, fmt.Sprintf("slerp 0.25 turns %v", quarter.Angle()))
	tfCheck(tfNear4(tfMust(q.Mul(q.Conjugate())).Components(), [4]float64{1, 0, 0, 0}, 1e-12), "q * conj(q) is not 1")
	tfCheck(tfMust(tfMust(blacksmith.NewQuaternion(0, 0, 0, 2)).Normalized()) == tfMust(blacksmith.NewQuaternion(0, 0, 0, 1)), "(0,0,0,2) normalised is not (0,0,0,1)")
	zero := tfMust(blacksmith.NewQuaternion(0, 0, 0, 0))
	_, err := zero.ToTransform(tfOrigin)
	tfRefused(err, "quaternion_to_transform: the quaternion is zero", "a zero quaternion's transform")
	_, err = blacksmith.QuaternionFromTransform(tfMust(blacksmith.TransformMirror(blacksmith.FrameXY(tfOrigin))))
	tfRefused(err, "quaternion_from_transform: ", "a mirror's quaternion")
	_, err = blacksmith.NewQuaternion(math.Inf(1), 0, 0, 0)
	tfRefused(err, "Quaternion: not finite", "an infinite quaternion")
	// The product's sign pattern: Python's literal.
	qx := tfMust(blacksmith.QuaternionFromAxisAngle([3]float64{1, 0, 0}, math.Pi/2))
	qy := tfMust(blacksmith.QuaternionFromAxisAngle([3]float64{0, 1, 0}, math.Pi/2))
	tfCheck(tfNear4(tfMust(qx.Mul(qy)).Components(), [4]float64{0.5, 0.5, 0.5, 0.5}, 1e-12), "qx * qy is not (0.5, 0.5, 0.5, 0.5)")
	// Every term of the product, each sign seen: (1,2,3,4) * (5,6,7,8), exactly.
	prod := tfMust(tfMust(blacksmith.NewQuaternion(1, 2, 3, 4)).Mul(tfMust(blacksmith.NewQuaternion(5, 6, 7, 8))))
	tfCheck(prod == tfMust(blacksmith.NewQuaternion(-60, 12, 30, 24)), fmt.Sprintf("(1,2,3,4) * (5,6,7,8) is %v", prod))
}

// 5. Far from unit length: scaled by the largest component first, as the ABI.
func transformQuaternionsFarFromUnit() {
	h := math.Sqrt(0.5)
	for _, k := range []float64{1e200, 1e-170} {
		nq := func(w, x, y, z float64) blacksmith.Quaternion { return tfMust(blacksmith.NewQuaternion(w, x, y, z)) }
		tfCheck(tfMust(nq(k, 0, 0, 0).Normalized()) == nq(1, 0, 0, 0), fmt.Sprintf("(%g,0,0,0) normalised", k))
		tfCheck(tfMust(nq(0, 0, 0, -k).Normalized()) == nq(0, 0, 0, -1), fmt.Sprintf("(0,0,0,-%g) normalised", k))
		kk := nq(k, k, 0, 0)
		tfCheck(tfNear4(tfMust(kk.Normalized()).Components(), [4]float64{h, h, 0, 0}, 1e-12), fmt.Sprintf("(%g,%g,0,0) normalised is %v", k, k, tfMust(kk.Normalized())))
		tfCheck(math.Abs(kk.Length()-k*math.Sqrt2) <= 1e-15*k*math.Sqrt2, fmt.Sprintf("(%g,%g,0,0)'s length is %v", k, k, kk.Length()))
		tfCheck(math.Abs(kk.Angle()-math.Pi/2) <= 1e-12, fmt.Sprintf("(%g,%g,0,0)'s angle is %v", k, k, kk.Angle()))
		axis, ok := nq(0, k, k, 0).Axis()
		tfCheck(ok && tfNear3(axis, [3]float64{h, h, 0}, 1e-12), fmt.Sprintf("(0,%g,%g,0)'s axis is %v %v", k, k, axis, ok))
	}
	_, err := tfMust(blacksmith.NewQuaternion(0, 0, 0, 0)).Normalized()
	tfRefused(err, "Quaternion.normalized: the quaternion is zero", "a zero quaternion normalised")
}

// 6. A solid takes any affine map.
func transformSolids() {
	fxy := blacksmith.FrameXY(tfOrigin)
	box := tfMust(blacksmith.Cuboid(1, 2, 3))
	defer box.Close()
	tfCheck(box.InexactTrims() == 0, "a cuboid has inexact trims")
	stretched := tfMust(box.Transform(tfMust(blacksmith.TransformScaleXYZ(fxy, 2, 3, 0.5))))
	defer stretched.Close()
	b := tfMust(stretched.BoundsAt(0.05))
	tfCheck(tfNear3([3]float64{b.Max[0] - b.Min[0], b.Max[1] - b.Min[1], b.Max[2] - b.Min[2]}, [3]float64{2, 6, 1.5}, 1e-9),
		fmt.Sprintf("the stretched box's bounds are %v", b))
	tfCheck(stretched.InexactTrims() == 0, "the stretched box lost trims")
	moved := tfMust(box.TransformRows(tfMust(blacksmith.TransformTranslation([3]float64{1, 0, 0})).Rows()))
	defer moved.Close()
	tfCheck(moved.InexactTrims() == 0, "the box moved by 16 numbers lost trims")
	mb := tfMust(moved.Bounds())
	tfCheck(math.Abs(mb.Min[0]-0.5) <= 1e-9, fmt.Sprintf("the box moved by 16 numbers starts at x %v", mb.Min[0]))
	can := tfMust(blacksmith.Cylinder(1, 2))
	defer can.Close()
	sheared := tfMust(can.Transform(tfMust(blacksmith.TransformShear(fxy, [3]float64{1, 0, 0}, 0.5))))
	defer sheared.Close()
	m := tfMust(sheared.Mass(1e-7))
	tfCheck(math.Abs(m.Volume-2*math.Pi) <= 1e-6*2*math.Pi, fmt.Sprintf("the sheared can's volume is %v", m.Volume))
	nurbs := false
	for i := range tfMust(sheared.Faces()) {
		nurbs = nurbs || tfMust(sheared.FaceKind(i)) == "nurbs"
	}
	tfCheck(nurbs, "the sheared can has no nurbs face")
	_, err := box.Transform(tfMust(blacksmith.TransformScaleXYZ(fxy, 1, 1, 0)))
	tfRefused(err, "solid_transform: a singular map flattens the solid", "a flattening map")
}

// 7. Colours and name kept.
func transformKeepsColoursAndName() {
	can := tfMust(tfMust(tfMust(blacksmith.Cylinder(1, 2)).ColouredText("#808080")).Named("can"))
	side := -1
	faces := tfMust(can.Faces())
	for i := range faces {
		if tfMust(can.FaceKind(i)) == "cylinder" {
			side = i
			break
		}
	}
	tfCheck(side >= 0, "the can has no cylinder face")
	can = tfMust(can.ColouredFace(side, 0.2, 0.4, 1.0))
	defer can.Close()
	solidColour, ok, err := can.Colour()
	tfCheck(err == nil && ok, "the can has no colour")
	shear := tfMust(blacksmith.TransformShear(blacksmith.FrameXY(tfOrigin), [3]float64{1, 0, 0}, 0.5))
	for _, c := range []struct {
		what string
		out  *blacksmith.Solid
	}{
		{"transform", tfMust(can.Transform(shear))},
		{"convert_to_nurbs", tfMust(can.ConvertToNurbs("all"))},
	} {
		tfCheck(tfMust(c.out.Faces()) == faces, fmt.Sprintf("%s changed the face count", c.what))
		for i := range faces {
			got, ok, err := c.out.FaceColour(i)
			want := solidColour
			if i == side {
				want = [3]float64{0.2, 0.4, 1.0}
			}
			tfCheck(err == nil && ok && got == want, fmt.Sprintf("%s: face %d is %v %v %v, not %v", c.what, i, got, ok, err, want))
		}
		name, ok := c.out.Name()
		tfCheck(ok && name == "can", fmt.Sprintf("%s: the name is %q %v", c.what, name, ok))
		c.out.Close()
	}
}

// 8. Levels.
func transformNurbsLevels() {
	can := tfMust(blacksmith.Cylinder(1, 2))
	defer can.Close()
	kinds := func(s *blacksmith.Solid) map[string]bool {
		out := map[string]bool{}
		for i := range tfMust(s.Faces()) {
			out[tfMust(s.FaceKind(i))] = true
		}
		return out
	}
	every := tfMust(can.ConvertToNurbs("all"))
	defer every.Close()
	k := kinds(every)
	tfCheck(len(k) == 1 && k["nurbs"] && every.InexactTrims() == 0, fmt.Sprintf("all: kinds %v, inexact %d", k, every.InexactTrims()))
	analytic := tfMust(can.ConvertToNurbs("analytic"))
	defer analytic.Close()
	k = kinds(analytic)
	tfCheck(k["plane"] && k["nurbs"], fmt.Sprintf("analytic: kinds %v", k))
	procedural := tfMust(can.ConvertToNurbs("procedural"))
	defer procedural.Close()
	k = kinds(procedural)
	tfCheck(k["plane"] && k["cylinder"] && !k["nurbs"], fmt.Sprintf("procedural: kinds %v", k))
	_, err := can.ConvertToNurbs("some")
	tfRefused(err, `convert_to_nurbs: level 'some' is not "procedural", "analytic" or "all"`, "a bad level")
}
