// Open one file through the C# binding and check what comes back; then build the
// blacksmith's plate and read it back through the reader. Exit code is the verdict.
using System.Text;
using Cadaclysm;
using Cadaclysm.Blacksmith;

var path = args.Length > 0 ? args[0] : "samples/cube.scad";
var license = args.Length > 1 ? args[1] : null;
if (license is not null) Cadaclysm.Cadaclysm.License(license);
Console.WriteLine($"cadaclysm {Cadaclysm.Cadaclysm.Version()} built {Cadaclysm.Cadaclysm.BuildDate()}");
Console.WriteLine($"license: {Cadaclysm.Cadaclysm.LicenseInfo()}");

using var scene = Cadaclysm.Cadaclysm.Open(path);
var bounds = scene.Bounds;
Console.WriteLine($"bounds min=({bounds.Min[0]},{bounds.Min[1]},{bounds.Min[2]}) max=({bounds.Max[0]},{bounds.Max[1]},{bounds.Max[2]})");
uint triangles = 0;
foreach (var node in scene.Walk())
{
    if (!node.CanMesh) continue;
    var mesh = node.Mesh;
    if (mesh is null) continue;
    triangles += mesh.TriangleCount;
}
Console.WriteLine($"triangles={triangles}");
if (path.EndsWith("cube.scad") &&
    (!bounds.Min.SequenceEqual(new float[] { 0, 0, 0 }) || !bounds.Max.SequenceEqual(new float[] { 20, 20, 20 }) || triangles != 12))
    return Fail("the cube did not come back as a 20-unit cube of 12 triangles");

// The reader's own extras: a query, the diagnostics, an in-memory open of the same bytes.
// "class == mesh" does not match here: the OpenSCAD reader's own node.Kind for cube.scad's
// solid is "solid", not "mesh".
var matched = scene.Query("class == solid");
Console.WriteLine($"query: {matched.Count} node(s)");
Console.WriteLine($"diagnostics: {scene.Diagnostics.Count}");
var formats = Cadaclysm.Cadaclysm.Formats();
if (!formats.Any(f => f.Name == "IGES" && f.Extensions.SequenceEqual(new[] { "iges", "igs" }))) return Fail("formats() lacks IGES iges;igs");
if (Cadaclysm.Cadaclysm.MeshFormats().First(f => f.Name == "stl").Label != "STL (binary)") return Fail("mesh format label is not the library's");
Console.WriteLine($"geometry diagnostics: {scene.GeometryDiagnostics.Count}");
// Kinematics: a file with no mechanism carries no links or joints; mechanism.stp, beside
// whatever sample this smoke was given, carries the fixed two-link one-joint mechanism.
if (path.EndsWith("cube.scad") && (scene.Links.Count != 0 || scene.Joints.Count != 0 || scene.States.Count != 0))
    return Fail("the cube scene has links, joints or states");
var mechanismPath = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!, "mechanism.stp");
using (var mechanism = Cadaclysm.Cadaclysm.Open(mechanismPath))
{
    var links = mechanism.Links;
    if (!links.Select(l => l.Name).SequenceEqual(new[] { "base", "arm" })) return Fail("mechanism links are not [base, arm]");
    foreach (var link in links)
        if (!link.Nodes.Select(n => n.Name).SequenceEqual(new[] { link.Name }) || !ReferenceEquals(link.Scene, mechanism))
            return Fail($"link {link.Name} does not name exactly one node of its own name");
    var joints = mechanism.Joints;
    if (joints.Count != 1 || joints[0].Name != "hinge") return Fail("mechanism does not carry exactly one joint named hinge");
    var joint = joints[0];
    // The file's order, (arm, base): a swap into (parent, child) would fail here.
    if (joint.Start.Name != "arm" || joint.Start.Index != 1 || joint.End.Name != "base" || joint.End.Index != 0)
        return Fail($"joint hinge reads start={joint.Start.Name}#{joint.Start.Index} end={joint.End.Name}#{joint.End.Index}");
    Console.WriteLine($"kinematics: links {links.Count}, joints {joints.Count}, hinge {joint.Start.Name}->{joint.End.Name}");

    // The pair: revolute about Z, ranged -1.5..1.5, both contact frames at (0, 0, 100).
    var pair = joint.Pair;
    if (pair is null || pair.Kind != PairKind.Revolute) return Fail("hinge has no pair, or it is not revolute");
    if (pair.TypeName is not null || pair.Pitch is not null) return Fail("a revolute pair has a type name or a pitch");
    bool Close(double a, double b) => Math.Abs(a - b) <= 1e-9;
    foreach (var frame in new[] { pair.RawFrameStart, pair.RawFrameEnd })
    {
        if (!Close(frame[12], 0.0) || !Close(frame[13], 0.0) || !Close(frame[14], 100.0))
            return Fail("a pair frame's origin is not (0, 0, 100)");
        if (!Close(frame[8], 0.0) || !Close(frame[9], 0.0) || !Close(frame[10], 1.0))
            return Fail("a pair frame's z axis is not (0, 0, 1)");
    }
    var freedoms = pair.Freedoms;
    if (freedoms.Count != 1 || freedoms[0].Motion != Motion.Rotation || freedoms[0].Axis != FreedomAxis.Z)
        return Fail("the hinge's freedom is not one rotation about z");
    if (freedoms[0].Lower is not double lower || freedoms[0].Upper is not double upper || !Close(lower, -1.5) || !Close(upper, 1.5))
        return Fail("the hinge's freedom range is not [-1.5, 1.5]");

    // The state: one named "open", one row (hinge, [0.5]).
    var states = mechanism.States;
    if (states.Count != 1 || states[0].Index != 0 || states[0].Name != "open") return Fail("mechanism does not carry exactly one state named open");
    var values = states[0].Values;
    if (values.Count != 1 || values[0].Joint.Name != "hinge" || values[0].Joint.Index != 0
        || values[0].Values.Count != 1 || !Close(values[0].Values[0], 0.5))
        return Fail("state open does not set hinge to [0.5]");
    Console.WriteLine($"pair: {pair.Kind}, freedoms {freedoms.Count}, states {states.Count}");

    // Posing: Scene.Base/Pose/PoseState and Pose, at parity with the Python reference's six
    // pose facts (mechanism.stp declares no base; base=links[0], arm=links[1]).
    var baseLink = links[0];
    var armLink = links[1];
    var armNode = armLink.Nodes[0];
    var baseNode = baseLink.Nodes[0];
    (double X, double Y, double Z) Apply(double[,] m, double x, double y, double z) => (
        m[0, 0] * x + m[0, 1] * y + m[0, 2] * z + m[0, 3],
        m[1, 0] * x + m[1, 1] * y + m[1, 2] * z + m[1, 3],
        m[2, 0] * x + m[2, 1] * y + m[2, 2] * z + m[2, 3]);
    if (mechanism.Base is not null) return Fail("mechanism.stp declares a base but declares none");
    var posedState = mechanism.PoseState(states[0]);
    if (posedState.Ground.Index != baseLink.Index) return Fail("pose_state's ground is not the base link");
    if (posedState.Unsolved.Count != 0 || posedState.OutOfRange.Count != 0) return Fail("pose_state reports unsolved or out-of-range joints");
    const double q = 0.5; // the arm is the joint's start, reached from its end: it turns by -q
    var armTip = Apply(posedState.Transform(armNode), 10, 0, 0);
    if (!Close(armTip.X, 10 * Math.Cos(q)) || !Close(armTip.Y, -10 * Math.Sin(q)) || !Close(armTip.Z, 100))
        return Fail("pose_state does not turn the arm by -0.5");
    var armOrigin = Apply(posedState.Transform(armNode), 0, 0, 0);
    if (!Close(armOrigin.X, 0) || !Close(armOrigin.Y, 0) || !Close(armOrigin.Z, 100))
        return Fail("pose_state's arm origin is not (0, 0, 100)");
    if (!posedState.RawTransform(baseNode).SequenceEqual(baseNode.RawTransform))
        return Fail("pose_state moves the ground link's own node");

    var pastRange = mechanism.Pose(new[] { (joint, (IReadOnlyList<double>)new double[] { 2.0 }) });
    if (pastRange.OutOfRange.Count != 1 || pastRange.OutOfRange[0].Joint.Index != joint.Index
        || pastRange.OutOfRange[0].Freedom != 0 || !Close(pastRange.OutOfRange[0].Value, 2.0))
        return Fail("pose does not report the out-of-range value");
    var pastRangeTip = Apply(pastRange.Transform(armNode), 10, 0, 0);
    if (!Close(pastRangeTip.X, 10 * Math.Cos(2.0)) || !Close(pastRangeTip.Y, -10 * Math.Sin(2.0)) || !Close(pastRangeTip.Z, 100))
        return Fail("pose does not use the out-of-range value");

    var groundedOnArm = mechanism.Pose(new[] { (joint, (IReadOnlyList<double>)new double[] { 0.5 }) }, armLink);
    if (groundedOnArm.Ground.Index != armLink.Index) return Fail("pose does not hold the named ground");
    if (!groundedOnArm.RawTransform(armNode).SequenceEqual(armNode.RawTransform))
        return Fail("pose does not leave the named ground at its rest transform");

    var fromStateValues = mechanism.Pose(values);
    if (!fromStateValues.RawTransform(armNode).SequenceEqual(posedState.RawTransform(armNode)))
        return Fail("pose(state.Values) does not match pose_state(state)");
    var rest = mechanism.Pose(Array.Empty<(Joint, IReadOnlyList<double>)>());
    foreach (var node in mechanism.Nodes)
        if (!rest.RawTransform(node).SequenceEqual(node.RawTransform))
            return Fail("pose([]) does not leave every node at its rest transform");

    try
    {
        mechanism.Pose(new[] { (joint, (IReadOnlyList<double>)new double[] { 1.0, 2.0 }) });
        return Fail("a joint given the wrong number of values was accepted");
    }
    catch (CadaclysmException e) when (e.Message.Contains("takes 1 value(s)")) { }
    Console.WriteLine($"pose: base={mechanism.Base}, ground={posedState.Ground.Name}, out-of-range {pastRange.OutOfRange.Count}");
}
// Motion sequences: samples/mechanism-sequence.stp's two sequences, at parity with the
// Python reference (plan 2026-10-05-motion-sequences-2).
var sequencePath = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!, "mechanism-sequence.stp");
using (var sequenceScene = Cadaclysm.Cadaclysm.Open(sequencePath))
{
    var sequences = sequenceScene.Sequences;
    if (sequences.Count != 2 || sequences[0].Name != "swing" || sequences[1].Name != "snap")
        return Fail("sequences: the file does not carry swing then snap");
    var swing = sequences[0];
    var snap = sequences[1];
    if (!swing.Closed || swing.SecondsPerUnit != 1.0) return Fail("sequences: swing is not closed at 1 second per unit");
    if (snap.Closed || snap.SecondsPerUnit is not null) return Fail("sequences: snap is not open with no unit");
    var wantSwing = new (string State, double T, string Interpolation)[] { ("shut", 0, "linear"), ("open", 1, "synchronous"), ("wide", 2, "linear") };
    var gotSwing = swing.Segments.Select(g => (g.State.Name, g.T, g.Interpolation)).ToArray();
    if (!gotSwing.SequenceEqual(wantSwing)) return Fail("sequences: swing's segments are " + string.Join(", ", gotSwing));
    var wantSnap = new (string State, double T, string Interpolation)[] { ("shut", 0, "discontinuous"), ("wide", 0.5, "discontinuous") };
    var gotSnap = snap.Segments.Select(g => (g.State.Name, g.T, g.Interpolation)).ToArray();
    if (!gotSnap.SequenceEqual(wantSnap)) return Fail("sequences: snap's segments are " + string.Join(", ", gotSnap));
    if (swing.Start != 0 || swing.End != 2) return Fail("sequences: swing does not run 0 to 2");
    foreach (var seg in swing.Segments)
    {
        var at = swing.Pose(seg.T);
        var want = sequenceScene.PoseState(seg.State);
        foreach (var node in sequenceScene.Nodes)
            if (!at.RawTransform(node).SequenceEqual(want.RawTransform(node)))
                return Fail($"sequences: swing at {seg.T} does not match state {seg.State.Name}");
    }
    try
    {
        swing.Pose(double.NaN);
        return Fail("sequences: pose(NaN) was accepted");
    }
    catch (CadaclysmException e) when (e.Message.Contains("the sequence parameter must be a finite number")) { }
    Console.WriteLine("sequences: swing and snap read as the file records them, and swing poses at each keyframe");
}

// IFC work schedules: samples/schedule.ifc, at parity with the Python reference's
// test_a_file_reads_its_work_schedule and the two tests after it (plan 2026-10-06-ifc-4d-2).
const double D = 86400.0;
const double T0 = 1772438400.0; // 2026-03-02T08:00:00
var schedulePath = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!, "schedule.ifc");
using (var scheduleScene = Cadaclysm.Cadaclysm.Open(schedulePath))
{
    if (scheduleScene.Schedules.Count != 1) return Fail("schedules: the file does not carry one schedule");
    var programme = scheduleScene.Schedules[0];
    if (programme.Name != "Programme" || programme.Identification != "WS-1" || programme.Kind != "planned"
        || programme.KindName != "" || programme.Start != T0 || programme.Finish is not null)
        return Fail("schedules: the programme is not Programme, WS-1, planned, starting at T0");
    var taskNames = string.Join(",", programme.Tasks.Select(t => t.Name));
    if (taskNames != "Slab,Structure,Walls north,Walls south,Topping out,Demolish shed,Fit-out")
        return Fail("schedules: the tasks are " + taskNames);
    var tasks = programme.Tasks;
    var (slab, structure, north, south, topping, shed, fitOut) = (tasks[0], tasks[1], tasks[2], tasks[3], tasks[4], tasks[5], tasks[6]);
    if (!Equals(north.Parent, structure) || !Equals(south.Parent, structure) || slab.Parent is not null)
        return Fail("schedules: the parents are off");
    if (slab.Kind != "construction" || shed.Kind != "demolition" || topping.Kind != "notdefined")
        return Fail("schedules: the task kinds are off");
    if (!topping.Milestone || slab.Milestone) return Fail("schedules: milestones are off");
    if (slab.Identification != "T1" || slab.Status != "COMPLETED") return Fail("schedules: Slab's identification or status is off");
    var slabTime = slab.Time;
    if (slabTime.ScheduleStart != T0 || slabTime.ScheduleFinish is not null || slabTime.Duration != 10 * D
        || slabTime.ActualStart != T0 || slabTime.ActualFinish != T0 + 8 * D || slabTime.EarlyStart is not null)
        return Fail("schedules: Slab's dates are off");
    if (!south.Nodes.Select(n => n.Name).OrderBy(n => n, StringComparer.Ordinal).SequenceEqual(new[] { "Wall S1", "Wall S2" })
        || !fitOut.Nodes.Select(n => n.Name).OrderBy(n => n, StringComparer.Ordinal).SequenceEqual(new[] { "Desk", "Room" }))
        return Fail("schedules: the task nodes are off");
    var wantLinks = new (string From, string To, string Kind, double? Lag)[]
    {
        ("Slab", "Structure", "finish_start", null),
        ("Walls north", "Walls south", "start_start", 2 * D),
        ("Walls south", "Topping out", "finish_start", null),
        ("Topping out", "Fit-out", "finish_start", null),
    };
    var gotLinks = programme.Links.Select(l => (l.From.Name, l.To.Name, l.Kind, l.Lag)).ToArray();
    if (!gotLinks.SequenceEqual(wantLinks)) return Fail("schedules: the links are " + string.Join(", ", gotLinks));
    if (programme.Links.Any(l => l.KindName != "")) return Fail("schedules: a link kind name is not empty");

    var early = programme.At(T0 + 3 * D).ToDictionary(e => e.Node.Name);
    var wantNodes = new[] { "Slab", "Wall N1", "Wall N2", "Wall S1", "Wall S2", "Shed", "Room", "Desk" };
    if (!early.Keys.OrderBy(n => n, StringComparer.Ordinal).SequenceEqual(wantNodes.OrderBy(n => n, StringComparer.Ordinal)))
        return Fail("schedules: at(T0+3D) names " + string.Join(", ", early.Keys));
    if (early["Slab"].Phase != "building" || Math.Abs(early["Slab"].Progress - 0.3) > 1e-9)
        return Fail("schedules: Slab is not 30% built on day 3");
    if (early["Shed"].Phase != "demolishing" || early["Wall S1"].Phase != "unbuilt")
        return Fail("schedules: the shed or Wall S1 is off on day 3");
    var late = programme.At(T0 + 32 * D, "actual").ToDictionary(e => e.Node.Name);
    if (late["Wall S1"].Phase != "building" || late["Wall S1"].Variance != 5 * D || late["Slab"].Variance != -2 * D)
        return Fail("schedules: the actual dates' variances are off");
    try
    {
        programme.At(double.NaN);
        return Fail("schedules: at(NaN) was accepted");
    }
    catch (CadaclysmException e) when (e.Message.Contains("the date must be a finite number")) { }
    try
    {
        programme.At(T0, "compare");
        return Fail("schedules: at(T0, \"compare\") was accepted");
    }
    catch (ArgumentException e) when (e.Message.Contains("dates must be 'scheduled' or 'actual'")) { }
    Console.WriteLine("schedules: Programme reads as the file records it, and at() plays its dates");
}
using (var noScheduleScene = Cadaclysm.Cadaclysm.Open(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!, "cube.scad")))
{
    if (noScheduleScene.Schedules.Count != 0) return Fail("schedules: the cube has schedules");
}

// pose([]) on the cube sample (no mechanism) fails with a message naming that, as the
// Python reference's test_a_bad_pose_raises checks on the same file.
var cubePath = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!, "cube.scad");
using (var cubeScene = Cadaclysm.Cadaclysm.Open(cubePath))
{
    try
    {
        cubeScene.Pose(Array.Empty<(Joint, IReadOnlyList<double>)>());
        return Fail("pose([]) on a file without a mechanism was accepted");
    }
    catch (CadaclysmException e) when (e.Message.Contains("no mechanism")) { }
}
scene.ForgetMeshes();
if (scene.Query("class == solid").Count == 0 || scene.Walk().Where(n => n.CanMesh).Sum(n => (long)(n.Mesh?.TriangleCount ?? 0)) != triangles) return Fail("forget_meshes did not rebuild");
if (Cadaclysm.Cadaclysm.LodLevels() != 3) return Fail("lod levels is not 3");
var first = scene.Walk().First(n => n.CanMesh);
if (first.MeshLod(0)!.TriangleCount != first.Mesh!.TriangleCount) return Fail("LOD 0 is not the mesh");
if (first.LodError(0) != 0 || first.MeshLod(4) is not null && first.MeshLod(4)!.TriangleCount != 0) return Fail("LOD errors or levels are off");
if (path.EndsWith("cube.scad") && (first.MeshLod(1)!.TriangleCount != 3 || first.EdgeBeziers.Count != 12 || first.EdgeBeziers.Points.Length != 12 * 12)) return Fail("the cube's LOD 1 or Béziers are off");
// f64 twins: mesh64, beziers64 and bounds64 mirror their f32 twins, narrowed exactly, on
// this small-coordinate cube -- see the far-from-origin note in the task report for what
// this comparison cannot see.
var mesh32 = first.Mesh!;
var mesh64 = first.Mesh64;
if (mesh64 is null || mesh64.VertexCount != mesh32.VertexCount || mesh64.IndexCount != mesh32.IndexCount)
    return Fail("mesh64's vertex/index counts do not equal mesh's");
if (mesh32.Positions.Length >= 3 &&
    ((float)mesh64.Positions[0] != mesh32.Positions[0] || (float)mesh64.Positions[1] != mesh32.Positions[1] || (float)mesh64.Positions[2] != mesh32.Positions[2]))
    return Fail("mesh64's first position narrowed to float does not equal mesh's first position");
var edgeBeziers32 = first.EdgeBeziers;
var edgeBeziers64 = first.EdgeBeziers64;
if (edgeBeziers64.Count != edgeBeziers32.Count || edgeBeziers64.Points.Length != edgeBeziers32.Points.Length)
    return Fail("edgeBeziers64's count/length does not equal edgeBeziers's");
if (edgeBeziers32.Points.Length >= 3 && (float)edgeBeziers64.Points[0] != edgeBeziers32.Points[0])
    return Fail("edgeBeziers64's first point narrowed does not equal edgeBeziers's");
if (first.CurveBeziers64.Count != first.CurveBeziers.Count) return Fail("curveBeziers64's count does not equal curveBeziers's");
if (first.IsocurveBeziers64.Count != first.IsocurveBeziers.Count) return Fail("isocurveBeziers64's count does not equal isocurveBeziers's");
var nodeBounds64 = first.Bounds64;
var nodeBounds32 = first.Bounds;
if ((float)nodeBounds64.Max[0] != nodeBounds32.Max[0] || (float)nodeBounds64.Max[1] != nodeBounds32.Max[1] || (float)nodeBounds64.Max[2] != nodeBounds32.Max[2])
    return Fail("bounds64's max does not equal bounds's max widened");
var sceneBounds64 = scene.Bounds64;
if ((float)sceneBounds64.Max[0] != bounds.Max[0] || (float)sceneBounds64.Max[1] != bounds.Max[1] || (float)sceneBounds64.Max[2] != bounds.Max[2])
    return Fail("scene bounds64's max does not equal bounds's max widened");
Console.WriteLine($"reader f64 twins: mesh64 {mesh64.TriangleCount} triangles, edgeBeziers64 {edgeBeziers64.Count}, bounds64 max ({sceneBounds64.Max[0]},{sceneBounds64.Max[1]},{sceneBounds64.Max[2]})");
// ForgetMeshes frees the document's own mesh, which Mesh64 lends, so a Mesh64 made before
// the forget throws a stale view rather than being read. The float mesh and the edge views
// are the scene's own caches and survive it, as the C ABI says they do -- they must not be
// reported stale, nor must the node.
{
    var lent = first.Mesh64!;
    var keptMesh = first.Mesh!;
    var keptEdges = first.Edges;
    var lentTriangles = lent.TriangleCount;
    var early = lent.Copy();
    scene.ForgetMeshes();
    try { _ = lent.Positions; return Fail("a Mesh64 read after ForgetMeshes did not throw"); }
    catch (CadaclysmException e) when (e.Message.Contains("forgotten")) { }
    try { _ = lent.Copy(); return Fail("a Mesh64 copied after ForgetMeshes did not throw"); }
    catch (CadaclysmException e) when (e.Message.Contains("forgotten")) { }
    if (keptMesh.Positions.Length != keptMesh.VertexCount * 3 || keptEdges.Positions.IsEmpty || !first.CanMesh)
        return Fail("ForgetMeshes staled the float mesh, an edge view or the node");
    var relent = first.Mesh64!;
    if (relent.TriangleCount != lentTriangles || !relent.Positions.SequenceEqual(early.Positions))
        return Fail("a Mesh64 asked for after ForgetMeshes does not read");
}
var fit = first.Collision();
if (fit is null || fit.Error != 0 || fit.Frame.Length != 16 || fit.HullVertexCount != 8) return Fail("the collision fit is off");
if (first.CollisionHull().VertexCount != 8 || first.CollisionHull().Indices.Length != 36) return Fail("the collision hull is off");
var m = first.Mesh!;
using (var meshlets = Meshlets.Build(m.Positions, m.Normals, m.Indices, 124, 64))
{
    if (meshlets.Count < 1) return Fail("no meshlets");
    var one = meshlets.Meshlet(0);
    if (one.Positions.Length != one.VertexCount * 3 || one.Indices.Length != one.TriangleCount * 3 || one.Level != 0) return Fail("meshlet 0 is off");
    if (path.EndsWith("cube.scad") && (meshlets.Count != 1 || one.TriangleCount != 12 || one.VertexCount != 36)) return Fail("the cube's meshlets are off");
}
try { Meshlets.Build(m.Positions, m.Normals, m.Indices, 0, 64); return Fail("a zero budget was accepted"); }
catch (CadaclysmException) { }
if (first.TriangleEstimate <= 0 && first.TriangleEstimate != -1) return Fail("triangle estimate is neither a count nor -1");
if (path.EndsWith("cube.scad"))
{
    if (first.TriangleEstimate != 12 || !first.SurfaceEdges.Positions.IsEmpty || first.SurfaceProxyMesh(4) is not null) return Fail("the cube has no surface products");
    if (first.SurfacePick(new double[] { 10, 10, 100 }, new double[] { 10, 10, -100 }) is not null || !first.BoundsPlaced().IsEmpty) return Fail("the cube picks or bounds through surfaces");
    if (!first.BoundsPlaced64().IsEmpty) return Fail("the cube's boundsPlaced64 is not empty");
    if (first.SurfaceEdgeBeziers.Count != 0) return Fail("the cube hands exact edges to the surface path");
    if (first.EdgeColours.Length != 0 || first.SurfaceEdgeColours.Length != 0) return Fail("the unpainted cube has edge colours");
}
// Edge colours: samples/edge-colours.stp sits beside the given sample and paints one edge
// teal (0.1, 0.6, 0.55) on the body -- everything else, edge and surface-edge alike, stays
// unstyled.
var edgeColoursPath = System.IO.Path.Combine(
    System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path)) ?? ".", "edge-colours.stp");
using (var edgeColoursScene = Cadaclysm.Cadaclysm.Open(edgeColoursPath))
{
    var body = edgeColoursScene.Walk().First(n => n.Edges.PolylineCount > 0);
    foreach (var (count, colours) in new (uint, float[]?[])[]
             { (body.Edges.PolylineCount, body.EdgeColours), (body.SurfaceEdges.PolylineCount, body.SurfaceEdgeColours) })
    {
        if (colours.Length != count) return Fail($"edge colours: {colours.Length} entries for {count} polylines");
        var styled = colours.Where(c => c is not null).ToList();
        if (styled.Count != 1 || colours.Count(c => c is null) != colours.Length - 1)
            return Fail($"edge colours: {styled.Count} styled entries, not exactly one");
        var c = styled[0]!;
        if (Math.Abs(c[0] - 0.1f) > 1e-6 || Math.Abs(c[1] - 0.6f) > 1e-6 || Math.Abs(c[2] - 0.55f) > 1e-6 || Math.Abs(c[3] - 1.0f) > 1e-6)
            return Fail($"edge colours: the styled entry reads ({c[0]},{c[1]},{c[2]},{c[3]}), not (0.1,0.6,0.55,1.0)");
    }
    // The STEP body has surfaces to hand over, so this reads them through RawSurfaces -- which
    // `cadaclysm_node_surfaces` returns by value. A copy shorter than the header's is written
    // past, and silently: the 80-byte copy passed this line, so the layout itself is pinned by
    // tests/bindings.rs, not here.
    if (body.Surfaces.Count == 0) return Fail("surfaces: the STEP body came back with no faces");
    Console.WriteLine($"surfaces: {body.Surfaces.Count} face(s)");
}
using (var fresh = Cadaclysm.Cadaclysm.Open(path))
{
    var body = fresh.Walk().First(n => n.CanMesh);
    if (body.IsMeshed) return Fail("a fresh scene is already meshed");
    var built = fresh.RealizeMeshes(skipSurfaced: false);
    if (built == 0 || !body.IsMeshed) return Fail("RealizeMeshes(false) did not build");
}
// A Rhino extrusion hands its exact edges to the surface path without meshing, in both
// conventions: Unreal goes through the decorator that maps every getter into the caller's
// space. The fixture is the repository's, not an SDK checkout's, so this runs where found.
var sampleRoot = System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path)));
var extrusions = sampleRoot is null ? null : System.IO.Path.Combine(sampleRoot, "crates", "cadaclysm-acis", "tests", "fixtures", "rhino", "extrusion-objects.3dm");
if (extrusions is not null && File.Exists(extrusions))
{
    foreach (var convention in new[] { Convention.Native, Convention.Unreal })
    {
        using var surfaced = Cadaclysm.Cadaclysm.Open(extrusions, convention);
        var found = 0;
        foreach (var node in surfaced.Walk().Where(n => n.CanMesh && !n.SurfaceEdges.Positions.IsEmpty))
        {
            var exact = node.SurfaceEdgeBeziers.Count;
            if (exact == 0 || node.IsMeshed) return Fail("an extrusion's exact edges are not free");
            if (exact != node.EdgeBeziers.Count) return Fail("SurfaceEdgeBeziers is not EdgeBeziers' segments");
            found++;
        }
        if (found == 0) return Fail("extrusion-objects.3dm has no surfaced extrusion");
        Console.WriteLine($"SurfaceEdgeBeziers ({convention}): {found} extrusions, exact and unmeshed");
    }
}
Mesh? borrowed;
using (var again = Cadaclysm.Cadaclysm.OpenMemory(File.ReadAllBytes(path), System.IO.Path.GetFileName(path)))
{
    if (again.Bounds.Max[2] != bounds.Max[2]) return Fail("open_memory disagrees with open");
    // An in-memory scene keeps the name it was given as its path, as Python's does.
    if (again.Path != System.IO.Path.GetFileName(path)) return Fail($"open_memory's path is {again.Path}");
    borrowed = again.Query("class == solid")[0].Mesh;
}
// A view borrowed from a scene since closed refuses to read, as the kernel's stale views do,
// rather than handing out a span over freed memory.
try
{
    _ = borrowed!.Positions;
    return Fail("a mesh view read a closed scene");
}
catch (CadaclysmException)
{
}
// `System.IO.Path` spelt out: the kernel namespace has a `Path` of its own (the outline builder).
var stl = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke.stl");
scene.Roots[0].SaveMesh(stl, "stl");
if (new FileInfo(stl).Length < 84) return Fail("save_mesh wrote no triangles");

// The kernel: the plate with a hole and a pin, filleted, as STEP -- then read back.
if (license is not null) Blacksmith.License(license);
Console.WriteLine($"blacksmith {Blacksmith.Version()} built {Blacksmith.BuildDate()}");
Console.WriteLine($"blacksmith license: {Blacksmith.LicenseInfo()}");
// Every profile is its own handle: the rectangle and the circle stay alive and are disposed
// too, not just the outline made from them.
using var rect = Profile.Rect(80, 40);
using var hole = Profile.Circle(4);
using var outline = rect.WithHole(hole);
// Hits: two radius-5 circles six apart cross at two points, (3, -4) and (3, 4). At
// (3, 4) the first circle's upper arc is at t 0.2952 and the moved one's at 0.7048; at
// (3, -4) the other way round -- which catches the two sides read swapped.
{
    using var left = Profile.Circle(5);
    using var five = Profile.Circle(5);
    using var right = five.Translate(6, 0);
    var crossing = left.Hits(right);
    if (crossing.Count != 2) return Fail($"hits: two circles hit {crossing.Count} times, not 2");
    var ys = crossing.Select(h => h.Start[1]).OrderBy(y => y).ToArray();
    if (Math.Abs(ys[0] + 4) > 1e-9 || Math.Abs(ys[1] - 4) > 1e-9) return Fail($"hits: y {ys[0]}, {ys[1]}, not -4 and 4");
    foreach (var h in crossing)
    {
        var (ta, tb) = h.Start[1] > 0 ? (0.2952, 0.7048) : (0.7048, 0.2952);
        if (h.Run || h.Touch || h.AStart.LoopIndex != 0 || Math.Abs(h.Start[0] - 3) > 1e-9
            || Math.Abs(h.AStart.T - ta) > 1e-3 || Math.Abs(h.BStart.T - tb) > 1e-3)
            return Fail($"hits: {h} is not a crossing at (3, +-4) at t {ta} on a and {tb} on b");
    }
    Console.WriteLine($"hits: {crossing[0]}, {crossing[1]}");
    // Common: the same two circles share one lens, four arcs (each circle's own seam
    // stays a join) between two caps once extruded; moved apart they share nothing.
    var lenses = left.Common(right);
    if (lenses.Count != 1) return Fail($"common: two circles share {lenses.Count} regions, not 1");
    using var lens = lenses[0];
    using var lensSolid = Workplane.Xy().Extrude(lens, 1).Solid();
    if (lensSolid.Faces != 6) return Fail($"common: the lens extrudes to {lensSolid.Faces} faces, not 6");
    using var far = five.Translate(100, 0);
    if (left.Common(far).Count != 0) return Fail("common: circles 100 apart share a region");
    try { left.Common(right, 0.0); return Fail("common: a zero tolerance was accepted"); }
    catch (BuildException e) when (e.Message.Contains("profile_common: tolerance must be positive and finite")) { }
    Console.WriteLine($"common: one lens, {lensSolid.Faces} faces extruded");
}
// Machining: the Python SDK's to_arcs, offset and section, then Tool, Stock and Job -- the
// fixtures of test_cadaclysm_blacksmith.py's "machining" block and Node's pocketedBlock on.
// A profile is measured by extruding it 1 and reading the solid's bounds.
{
    using var rect2010 = Profile.Rect(20, 10);
    var grown = rect2010.Offset(2);
    if (grown.Count != 1 || !Near(Footprint(grown[0]), new[] { -12.0, 12, -7, 7 }, 1e-3))
        return Fail($"offset: grown by 2 is {grown.Count} profile(s)"
            + (grown.Count == 1 ? $", footprint {string.Join(", ", Footprint(grown[0]))}" : ""));
    var shrunk = rect2010.Offset(-2);
    if (shrunk.Count != 1 || !Near(Footprint(shrunk[0]), new[] { -8.0, 8, -3, 3 }, 1e-3))
        return Fail($"offset: shrunk by 2 is {shrunk.Count} profile(s)"
            + (shrunk.Count == 1 ? $", footprint {string.Join(", ", Footprint(shrunk[0]))}, not [-8, 8, -3, 3]" : ", not one profile over [-8, 8, -3, 3]"));
    if (rect2010.Offset(-6).Count != 0) return Fail("offset: a shrink past half the width left something");
    try { rect2010.Offset(double.NaN); return Fail("offset: a NaN distance was accepted"); }
    catch (BuildException e) when (e.Message == "profile_offset: distance must be finite") { }
    Console.WriteLine("offset: grown to [-12, 12, -7, 7], shrunk to [-8, 8, -3, 3], eaten at -6, NaN refused");

    using var spline = Profile.Spline(new[] { (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0) }, closed: true);
    using var fitted = spline.ToArcs(0.01);
    if (!Near(Footprint(fitted), Footprint(spline), 0.011))
        return Fail($"to_arcs: the fit's footprint {string.Join(", ", Footprint(fitted))} is not within 0.011 of the spline's");
    try { spline.ToArcs(0); return Fail("to_arcs: a zero tolerance was accepted"); }
    catch (BuildException e) when (e.Message == "profile_to_arcs: tolerance must be positive and finite") { }
    Console.WriteLine("to_arcs: the fit bounds the spline within 0.011, zero tolerance refused");

    using var box2010 = Solid.Cuboid(20, 10, 5);
    var middle = box2010.Section(0);
    if (middle.Count != 1 || !Near(Footprint(middle[0]), new[] { -10.0, 10, -5, 5 }, 1e-3))
        return Fail($"section: the box's middle is {middle.Count} profile(s)"
            + (middle.Count == 1 ? $", footprint {string.Join(", ", Footprint(middle[0]))}, not [-10, 10, -5, 5]" : ", not one profile over [-10, 10, -5, 5]"));
    if (box2010.Section(50).Count != 0) return Fail("section: a plane missing the box cut something");
    try { box2010.Section(2.5); return Fail("section: a plane on the top face was accepted"); }
    catch (BuildException e) when (e.Message == "solid_section: a face lies in the plane -- section a little above or below it") { }
    Console.WriteLine("section: the box's middle, a miss above it, a face in the plane refused");
}
{
    // The pocketed block: a 6 mm end mill is too big for the pocket's four square corners.
    using var block = PocketedBlock();
    using var endMill = Tool.Flat(1, 6, 20, 800, 200, 12000);
    using var job = new Job(Stock.Around(block, 2), 30);
    var report = job.Machine(block, endMill);
    if (report.Count != 4) return Fail($"machine: the pocketed block reports {report.Count} item(s), not 4:\n{report}");
    if (report.ToString() != report.Text || report.Text.Split('\n').Length != 4)
        return Fail($"machine: the report's text is not four lines:\n{report.Text}");
    foreach (var item in report)
        if (item.Kind != "corner" || !(item.Size > 0) || item.Region.Count == 0 || item.Reason.Length == 0
            || !double.IsFinite(item.At.X) || !double.IsFinite(item.At.Y) || !double.IsFinite(item.At.Z))
            return Fail($"machine: {item} is not a corner with a location, a size and a region");
    var ops = job.Operations();
    if (ops.Count == 0 || ops.Any(o => o.Kind.Length == 0 || o.Tool != 1 || o.Params.Count == 0))
        return Fail("machine: the pocketed block's operations are missing a kind, a tool or params");
    Console.WriteLine($"machine: the pocketed block leaves four corners, {ops.Count} operations ({report[0]})");

    // A drill as the end mill is refused, and leaves the job as it was.
    using var drill5 = Tool.Drill(2, 5, 30, 150, 3000);
    using var fresh = new Job(Stock.Around(block, 2), 30);
    try { fresh.Machine(block, drill5); return Fail("machine: a drill as the end mill was accepted"); }
    catch (BuildException e) when (e.Message.Contains("end mill must not be a drill")) { }
    if (fresh.Operations().Count != 0) return Fail("machine: a refused call changed the job");

    // A disposed job refuses every later call.
    fresh.Dispose();
    fresh.Dispose();   // idempotent
    if (!fresh.Closed) return Fail("job: disposed but not closed");
    foreach (var (what, call) in new (string, Action)[]
             {
                 ("machine", () => fresh.Machine(block, endMill)),
                 ("operations", () => fresh.Operations()),
                 ("gcode", () => fresh.Gcode()),
             })
    {
        try { call(); return Fail($"job: {what}() after Dispose() was accepted"); }
        catch (ObjectDisposedException e) when (e.Message.Contains("job: closed")) { }
    }
    Console.WriteLine("machine: a drill as the end mill refused, the job unchanged; a disposed job refuses");
}
{
    // The plate of spec 2026-09-28: machined cleanly by one end mill and one drill.
    using var plateOutline = Profile.Rect(80, 50).Round(6);
    var platePart = Solid.Extrude(plateOutline, Frame.Xy(), 12);
    using (var pocketOutline = Profile.Rect(40, 24).Round(4).WithHole(Profile.Circle(5)))
    using (var pocket = Solid.Extrude(pocketOutline, Frame.Xy((0, 0, 7)), 5))
    using (var was = platePart)
        platePart = was.Cut(pocket);
    foreach (var x in new[] { -32.0, 32.0 })
        foreach (var y in new[] { -17.0, 17.0 })
            using (var was = platePart)
            using (var bore = Solid.Cylinder(3, 12).Translate(x, y, 0))
                platePart = was.Cut(bore);
    using var plateSolid = platePart;
    using var endMill = Tool.Flat(1, 6, 20, 800, 200, 12000);
    using var drill = Tool.Drill(2, 6, 30, 150, 3000);
    using var job = new Job(Stock.Around(plateSolid, 3), 25, 1.0, 0.01, "plate");
    var report = job.Machine(plateSolid, endMill, new[] { drill });
    if (report.Count != 0 || report.ToString() != "nothing left uncut") return Fail($"plate: the report is not empty:\n{report}");
    var ops = job.Operations();
    if (ops[0].Kind != "face" || !ops.Any(o => o.Kind == "pocket") || ops[^1].Kind != "drill")
        return Fail($"plate: the operations run {string.Join(", ", ops.Select(o => o.Kind))}");
    if (ops[^1].Params["points"] != 4 || !ops[^1].Params.ContainsKey("peck") || ops[^1].Params["peck"] is not null)
        return Fail($"plate: the drill's params are {ops[^1]}");
    var programs = job.Gcode();
    if (programs.Count != 2 || programs.Any(p => p.Tool < 1 || p.Name.Length == 0 || p.Text.Length == 0))
        return Fail($"plate: gcode() gives {string.Join(", ", programs)}");
    var folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"cadaclysm-smoke-cam-{Environment.ProcessId}");
    try
    {
        var written = job.WriteCamotics(System.IO.Path.Combine(folder, "plate.camotics"));
        if (written.Count == 0 || !written.All(File.Exists) || !written[^1].EndsWith("plate.camotics"))
            return Fail($"plate: write_camotics wrote {string.Join(", ", written)}");
        Console.WriteLine($"plate: nothing left uncut, {ops.Count} operations, {programs.Count} programs, {written.Count} CAMotics files");
    }
    finally
    {
        if (Directory.Exists(folder)) Directory.Delete(folder, true);
    }
}
{
    // The four verbs by hand -- the spec's own example -- and the refusals in the kernel's words.
    using var specOutline = Profile.Rect(60, 40).Round(5);
    using var specPart = Solid.Extrude(specOutline, Frame.Xy(), 20);
    using var end = Tool.Flat(1, 6, 20, 800, 200, 12000);
    using var drill = Tool.Drill(2, 5, 30, 150, 3000);
    using var job = new Job(Stock.Around(specPart, 2), 30);
    job.Face(end, 20, 3, 1);
    job.Contour(end, specOutline, 20, 0, "outside", 2);
    using (var level = specPart.Section(15)[0])
        job.Pocket(end, level, 20, 10, 2.4, 2);
    job.Drill(drill, new[] { (10.0, 10.0), (40.0, 10.0) }, 20, -1, peck: 3);
    var programs = job.Gcode();
    if (!programs.Select(p => (p.Tool, p.Name)).SequenceEqual(new[] { (1, "job-T1"), (2, "job-T2") })
        || !programs[0].Text.StartsWith("(cadaclysm: job-T1, T1 flat D6)\n")
        || !programs[1].Text.StartsWith("(cadaclysm: job-T2, T2 drill D5)\n"))
        return Fail($"job: the spec example's programs are {string.Join(", ", programs)}");
    var kinds = job.Operations().Select(o => o.Kind).ToArray();
    if (!kinds.SequenceEqual(new[] { "face", "contour", "pocket", "drill" })) return Fail($"job: the operations are {string.Join(", ", kinds)}");
    var drilled = job.Operations()[3].Params;
    if (drilled["peck"] != 3 || drilled["points"] != 2) return Fail($"job: the drill's params are {job.Operations()[3]}");

    using var stock = Stock.Box((-15, -10, 0), (15, 10, 10));
    using var square = Profile.Rect(20, 10);
    foreach (var (make, text) in new (Action, string)[]
             {
                 (() => Tool.Flat(0, 6, 20, 800, 200, 12000), "tool: number must be at least 1"),
                 (() => Tool.Ball(1, 6, 20, 800, 200, 12000, rampAngle: 91), "tool: ramp angle must be in (0, 90] degrees"),
                 (() => Stock.Box((0, 0, 0), (0, 10, 10)), "stock: min must be below max on every axis, all finite"),
                 (() => new Job(stock, 5), "job: safe z must be above the stock's top"),
                 (() => new Job(stock, 30, clearance: 0), "job: clearance must be positive and finite"),
                 (() => new Job(stock, 30, name: "a/b"), "job: a name must be non-empty and without brackets"),
                 (() => new Job(stock, 30, name: "a\0b"), "job: a name must be non-empty and without brackets"),
             })
    {
        try { make(); return Fail($"cam: \"{text}\" was accepted"); }
        catch (BuildException e) when (e.Message.StartsWith(text)) { }
    }
    using var empty = new Job(stock, 30);
    foreach (var (add, text) in new (Action, string)[]
             {
                 (() => empty.Contour(drill, square, 10, 5), "contour: a drill only drills"),
                 (() => empty.Drill(end, new[] { (0.0, 0.0) }, 10, 5), "drill: drilling needs a drill"),
                 (() => empty.Drill(drill, Array.Empty<(double, double)>(), 10, 5), "drill: there are no points"),
                 (() => empty.Pocket(end, square, 10, 5, 4, 1), "pocket: stepover must be at most the tool's radius for a pocket"),
                 (() => empty.Face(end, 11, 3, 1), "face: z must be finite and not above the stock's top"),
             })
    {
        try { add(); return Fail($"cam: \"{text}\" was accepted"); }
        catch (BuildException e) when (e.Message == text) { }
    }
    try { empty.Contour(end, square, 10, 5, side: "left"); return Fail("contour: side \"left\" was accepted"); }
    catch (ArgumentException e) when (e.Message == "side must be 'outside', 'inside' or 'on'") { }
    if (empty.Gcode().Count != 0) return Fail("cam: a refused operation changed the job");
    // a NUL in a CAMotics stem is refused in the kernel's words, before the library; a stem that
    // is all extension (".camotics") stays whole, as Python's Path.stem keeps it
    const string nulName = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |";
    try { empty.WriteCamotics(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-nul", "a\0b.camotics")); return Fail("write_camotics: a NUL stem was accepted"); }
    catch (BuildException e) when (e.Message == nulName) { }
    {
        using var dotJob = new Job(stock, 30);
        dotJob.Face(end, 8, 3, 1);
        var dotFolder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"cadaclysm-smoke-dot-{Environment.ProcessId}");
        try
        {
            var written = dotJob.WriteCamotics(System.IO.Path.Combine(dotFolder, ".camotics"));
            if (written.Count < 2 || !System.IO.Path.GetFileName(written[0]).StartsWith(".camotics-T1"))
                return Fail($"write_camotics: the stem of \".camotics\" is not kept: {string.Join(", ", written)}");
        }
        finally
        {
            if (Directory.Exists(dotFolder)) Directory.Delete(dotFolder, true);
        }
    }
    Console.WriteLine("job: face, contour, pocket and drill by hand give two programs; every refusal in the kernel's words");
}
// Edge curves: a cylinder's rims are circles of its radius about a cap centre in a unit
// frame, a whole turn each; a cuboid's edges are lines whose origin + x is the far end;
// an extruded closed spline keeps a nurbs edge with knots = poles + degree + 1.
{
    using var cyl = Solid.Cylinder(5, 3);
    var rims = cyl.Edges.Where(e => e.Kind == "circle").Select(e => e.Curve).ToList();
    if (rims.Count < 2 || rims.Any(c => c is null)) return Fail("edge_curve: the cylinder's rims have no curve");
    foreach (var c in rims)
    {
        var unit = Math.Abs(Norm(c!.X) - 1) < 1e-9 && Math.Abs(Norm(c.Y) - 1) < 1e-9
            && Math.Abs(c.X[0] * c.Y[0] + c.X[1] * c.Y[1] + c.X[2] * c.Y[2]) < 1e-9;
        var centred = Math.Abs(c.Origin[0]) < 1e-9 && Math.Abs(c.Origin[1]) < 1e-9
            && Math.Min(Math.Abs(c.Origin[2]), Math.Abs(c.Origin[2] - 3)) < 1e-9;
        if (c.Kind != "circle" || Math.Abs(c.Radius - 5) > 1e-9 || !unit || !centred
            || Math.Abs(Math.Abs(c.T1 - c.T0) - 2 * Math.PI) > 1e-9 || c.Degree != 0 || c.Knots.Length != 0 || c.Weights is not null)
            return Fail($"edge_curve: a rim reads {c}");
    }
    using var box = Solid.Cuboid(2, 4, 6);
    foreach (var e in box.Edges)
    {
        var c = e.Curve;
        if (c is null || c.Kind != "line" || c.T0 != 0 || c.T1 != 1) return Fail($"edge_curve: a cuboid edge reads {c}");
        var far = new[] { c.Origin[0] + c.X[0], c.Origin[1] + c.X[1], c.Origin[2] + c.X[2] };
        var ends = e.Segments.SelectMany(s => new[] { s.A, s.B }).ToList();
        if (!ends.Any(p => Norm(new[] { p[0] - c.Origin[0], p[1] - c.Origin[1], p[2] - c.Origin[2] }) < 1e-9)
            || !ends.Any(p => Norm(new[] { p[0] - far[0], p[1] - far[1], p[2] - far[2] }) < 1e-9))
            return Fail($"edge_curve: a cuboid line's ends are not its own vertices: {c}");
    }
    using var square = Profile.Spline(new[] { (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0) }, 3, closed: true);
    using var loop = Workplane.Xy().Extrude(square, 2).Solid();
    var splines = loop.Edges.Where(e => e.Kind == "nurbs").Select(e => e.Curve!).ToList();
    if (splines.Count == 0) return Fail("edge_curve: the extruded spline keeps no nurbs edge");
    foreach (var c in splines)
        if (c.Kind != "nurbs" || c.Degree != 3 || c.Knots.Length != c.Poles.Length / 3 + c.Degree + 1 || c.Weights is not null)
            return Fail($"edge_curve: the spline edge reads {c}");
    Console.WriteLine($"edge_curve: {rims[0]}; {box.Edges[0].Curve}; {splines[0]}");
}
// Intersect: two equal pipes crossing at right angles meet on ellipse chains whose points lie
// on both pipes; apart, nothing; a zero tolerance refused in the kernel's words. Two coaxial
// pipes overlapping in height share a wall band: an overlap whose rings lie on that wall.
{
    const double tol = 1e-3;
    using var pipeA = Solid.Cylinder(1, 6);
    using var pipeB = Solid.Cylinder(1, 6).Rotate(new[] { 0.0, 0.0, 3.0, 1.0, 0.0, 0.0 }, Math.PI / 2);
    static double OnA(double[] p) => Math.Abs(Math.Sqrt(p[0] * p[0] + p[1] * p[1]) - 1);
    static double OnB(double[] p) => Math.Abs(Math.Sqrt(p[0] * p[0] + (p[2] - 3) * (p[2] - 3)) - 1);
    var found = pipeA.Intersect(pipeB, tol);
    if (found.Chains.Count < 2 || found.Overlaps.Count != 0) return Fail($"intersect: the crossed pipes read {found}");
    var ellipses = 0;
    foreach (var c in found.Chains)
    {
        if (c.FaceA < 0 || c.FaceA >= pipeA.Faces || c.FaceB < 0 || c.FaceB >= pipeB.Faces || c.Points.Length < 2)
            return Fail($"intersect: a chain reads {c}");
        if (c.Points.Any(p => OnA(p) > 50 * tol || OnB(p) > 50 * tol)) return Fail($"intersect: a chain leaves the pipes: {c}");
        if (c.Curve is null) continue;
        if (c.Curve.Kind != "ellipse" && c.Curve.Kind != "nurbs") return Fail($"intersect: a chain's curve reads {c.Curve}");
        if (c.Curve.Kind != "ellipse") continue;
        ellipses++;
        var t = (c.Curve.T0 + c.Curve.T1) / 2;
        var q = new double[3];
        for (var k = 0; k < 3; k++) q[k] = c.Curve.Origin[k] + c.Curve.X[k] * c.Curve.Radius * Math.Cos(t) + c.Curve.Y[k] * c.Curve.Radius2 * Math.Sin(t);
        if (OnA(q) > 50 * tol || OnB(q) > 50 * tol) return Fail($"intersect: the ellipse leaves the pipes at {c.Curve}");
    }
    if (ellipses == 0) return Fail("intersect: two equal pipes cross on ellipses");
    using var far = pipeB.Translate(10, 0, 0);
    var apart = pipeA.Intersect(far);
    if (apart.Chains.Count != 0 || apart.Overlaps.Count != 0) return Fail($"intersect: pipes apart read {apart}");
    try { pipeA.Intersect(pipeB, 0.0); return Fail("intersect: a zero tolerance was accepted"); }
    catch (BuildException e) when (e.Message.Contains("intersect: tolerance must be positive and finite")) { }
    using (var box = Solid.Cuboid(1, 2, 3))
    using (var big = box.Scaled(2))
    {
        var (min, max) = big.Bounds;
        if (Math.Abs(max[0] - min[0] - 2) > 1e-9 || Math.Abs(max[2] - min[2] - 6) > 1e-9) throw new Exception("scaled bounds");
        try { box.Scaled(0); throw new Exception("scaled(0) not refused"); }
        catch (BuildException e) when (e.Message.StartsWith("scaled:")) { }
    }
    using var lower = Solid.Cylinder(1, 4);
    using var upper = Solid.Cylinder(1, 4).Translate(0, 0, 2);
    var shared = lower.Intersect(upper, tol);
    if (shared.Overlaps.Count < 1 || shared.Overlaps[0].Loops.Length < 1) return Fail($"intersect: the coaxial pipes read {shared}");
    foreach (var ring in shared.Overlaps[0].Loops)
        if (ring.Length < 3 || ring.Any(p => OnA(p) > 50 * tol || p[2] < 2 - 50 * tol || p[2] > 4 + 50 * tol))
            return Fail($"intersect: an overlap ring leaves the shared band: {shared.Overlaps[0]}");
    Console.WriteLine($"intersect: {found} ({ellipses} ellipses); {shared.Overlaps[0]}");
}
// The collider: two cuboids overlapping by 2 along x, plus one far away -> one hit (0, 1),
// depth 2, Solid() non-null.
{
    var xy0 = new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    using var partA = Solid.Cuboid(4, 4, 4);
    using var partB = Solid.Cuboid(4, 4, 4).Translate(2, 0, 0);
    using var partC = Solid.Cuboid(4, 4, 4).Translate(100, 0, 0);
    var boxA = partA.BoundsBox();
    var boxB = partB.BoundsBox();
    if (!boxA.Overlaps(boxB)) return Fail("collider: the two overlapping cuboids' bounds boxes do not overlap");
    using var collider = new Collider(new[] { partA, partB, partC });
    if (collider.GroupCount != 3) return Fail("collider: the group count is not one per part");
    var hits = collider.Check(new[] { xy0, xy0, xy0 });
    if (hits.Count != 1) return Fail($"collider: found other than one hit: {string.Join(", ", hits)}");
    var hit = hits[0];
    if (hit.A != 0 || hit.B != 1) return Fail($"collider: the hit does not name parts 0 and 1: {hit}");
    if (!hit.Overlap || hit.Kind != "overlap" || hit.Text != "") return Fail($"collider: the hit is not a clean overlap: {hit}");
    if (Math.Abs(hit.Depth - 2.0) > 1e-9) return Fail($"collider: the hit's depth is not exactly 2: {hit}");
    using var overlapSolid = hit.Solid();
    if (overlapSolid.Faces == 0) return Fail("collider: the hit's rebuilt solid has no faces");
    var stats = collider.Stats;
    if (stats.Considered != 3) return Fail($"collider: the stats do not consider all three pairs: {stats}");
    try { new Collider(new[] { partA, partB, partC }, groups: new uint[] { 0, 1 }); return Fail("collider: a short groups list was accepted"); }
    catch (BuildException e) when (e.Message.Contains("groups must have one entry per solid")) { }
    Console.WriteLine($"collider: {hits.Count} hit(s), depth {hit.Depth}, {stats}");
}
// The SubD cage: Python's test_subd_* one for one (The Kiln, Plan 2b).
{
    string SdRefused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
    }
    // 1. the primitive's read-backs are copies
    using (var cube = Subd.Cuboid())
    {
        var cubePositions = cube.Positions;
        if (cubePositions.Length != 24 || cube.Faces.Length != 6 || cube.Faces.Any(f => f.Length != 4)) return Fail("subd: a cuboid is not 8 positions and 6 quads");
        if (cube.Creases.Length != 0 || cube.Pins.Length != 0 || cube.Symmetry is not null || cube.Selection is not null)
            return Fail("subd: a fresh cuboid has creases, pins, a symmetry or a selection");
        cubePositions[0] = 99;
        if (cube.Positions[0] == 99) return Fail("subd: writing to the returned positions changed the next read");
        using var again = Subd.FromParts(cube.Positions, cube.Faces);
        if (!again.Positions.SequenceEqual(cube.Positions) || !again.Faces.Zip(cube.Faces).All(p => p.First.SequenceEqual(p.Second)))
            return Fail("subd: from_parts did not give equal positions and faces");
        if (again.Selection is not null) return Fail("subd: from_parts selected something");
    }
    // 2. extrude
    using (var cube = Subd.Cuboid())
    using (var tall = cube.Extrude(new uint[] { 1 }, 1))
    {
        if (tall.Positions.Length != 36 || cube.Positions.Length != 24) return Fail("subd: extrude is not 12 positions with the input left at 8");
        var sel = tall.Selection;
        if (sel is null || sel.Kind != SubdElements.Faces || !sel.Ids.SequenceEqual(new uint[] { 1 })) return Fail("subd: extrude does not select faces [1]");
        if (sel != SubdSelection.OfFaces(1) || sel.GetHashCode() != SubdSelection.OfFaces(1).GetHashCode()) return Fail("subd: a selection read back is not equal to one with the same ids");
        if (SubdSelection.OfFaces(1) == SubdSelection.OfVertices(1)) return Fail("subd: selections of different kinds compare equal");
    }
    // 3. crease and pin
    using (var cube = Subd.Cuboid())
    using (var creased = cube.Crease(new[] { new SubdEdge(0, 1) }))
    using (var both = creased.Pin(new uint[] { 6 }))
    {
        var sel = creased.Selection;
        if (sel is null || sel.Kind != SubdElements.Edges || !sel.Edges.SequenceEqual(new[] { new SubdEdge(0, 1) })) return Fail("subd: crease does not select edges [(0,1)]");
        if (sel != SubdSelection.OfEdges(new SubdEdge(0, 1))) return Fail("subd: an edge selection read back is not equal to one with the same edges");
        if (!both.Creases.SequenceEqual(new[] { new SubdEdge(0, 1) }) || !both.Pins.SequenceEqual(new uint[] { 6 })) return Fail("subd: pin lost the crease or the pin");
        var pinned = both.Selection;
        if (pinned is null || pinned.Kind != SubdElements.Vertices || !pinned.Ids.SequenceEqual(new uint[] { 6 })) return Fail("subd: pin does not select vertices [6]");
        using var rebuilt = Subd.FromParts(both.Positions, both.Faces, both.Creases, both.Pins);
        if (!rebuilt.Creases.SequenceEqual(both.Creases) || !rebuilt.Pins.SequenceEqual(both.Pins)) return Fail("subd: from_parts dropped the creases or pins");
        using var uncreased = both.Crease(new[] { new SubdEdge(0, 1) }, false);
        using var released = uncreased.Pin(new uint[] { 6 }, false);
        if (released.Creases.Length != 0 || released.Pins.Length != 0) return Fail("subd: on=false left a crease or a pin");
    }
    // 4. mirror
    using (var wide = Subd.Cuboid((2, 2, 2), (2, 1, 1)))
    using (var half = wide.MirrorOn(SubdAxis.X))
    {
        var sym = half.Symmetry;
        if (sym is null || sym.Value.Axis != SubdAxis.X || !(sym.Value.Tolerance > 0)) return Fail("subd: mirror_on(X) has no X symmetry with a tolerance");
        if (half.Selection is not null) return Fail("subd: mirror_on selected something");
        if (half.Positions.Length >= wide.Positions.Length) return Fail("subd: the mirrored half is not smaller than the whole");
        using var loaded = Subd.FromParts(half.Positions, half.Faces, half.Creases, half.Pins, sym);
        if (!loaded.Positions.SequenceEqual(half.Positions) || loaded.Symmetry != sym) return Fail("subd: from_parts did not keep the half and its symmetry");
        using var whole = half.Full();
        if (whole.Positions.Length != wide.Positions.Length) return Fail("subd: full() is not as many positions as the whole");
        using var baked = half.MirrorOff();
        if (baked.Symmetry is not null) return Fail("subd: mirror_off left a symmetry");
    }
    // 5. edge loops
    using (var grid = Subd.Cuboid((2, 2, 2), (2, 2, 2)))
    {
        var f0 = grid.Faces[0];
        var loop = grid.EdgeLoop(new SubdEdge(f0[0], f0[1]));
        if (loop.Length < 4 || loop[0] != new SubdEdge(Math.Min(f0[0], f0[1]), Math.Max(f0[0], f0[1]))) return Fail($"subd: edge_loop gave {loop.Length} edges");
    }
    using (var cube = Subd.Cuboid())
    {
        var f0 = cube.Faces[0];
        if (cube.EdgeLoop(new SubdEdge(f0[0], f0[2])).Length != 0 || cube.EdgeLoop(new SubdEdge(0, 99)).Length != 0) return Fail("subd: edge_loop of a non-edge is not empty");
    }
    // 6. transform
    using (var cube = Subd.Cuboid())
    {
        var rot = new double[] { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        var before = cube.Positions;
        using (var turned = cube.Transform(SubdSelection.OfVertices(0, 1, 2, 3, 4, 5, 6, 7), rot))
        {
            var after = turned.Positions;
            for (var k = 0; k < 8; k++)
                if (Math.Abs(after[3 * k] + before[3 * k + 1]) > 1e-12 || Math.Abs(after[3 * k + 1] - before[3 * k]) > 1e-12 || Math.Abs(after[3 * k + 2] - before[3 * k + 2]) > 1e-12)
                    return Fail($"subd: the rotation did not map vertex {k} to (-y, x, z)");
        }
        using (var one = cube.Transform(SubdSelection.OfVertices(0), rot))
        {
            var after = one.Positions;
            for (var k = 1; k < 8; k++)
                for (var c = 0; c < 3; c++)
                    if (after[3 * k + c] != before[3 * k + c]) return Fail($"subd: transforming vertex 0 moved vertex {k}");
            if (Math.Abs(after[0] + before[1]) > 1e-12 || Math.Abs(after[1] - before[0]) > 1e-12) return Fail("subd: transforming vertex 0 did not rotate it");
        }
        var shift = new double[] { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 0, 1 };
        using (var moved = cube.Transform(SubdSelection.OfEdges(new SubdEdge(0, 1)), shift))
        {
            if (Math.Abs(moved.Positions[0] - (before[0] + 3)) > 1e-12) return Fail("subd: the edge transform did not add 3 to vertex 0's x");
            var sel = moved.Selection;
            if (sel is null || sel.Kind != SubdElements.Edges || !sel.Edges.SequenceEqual(new[] { new SubdEdge(0, 1) })) return Fail("subd: the edge transform does not select edges [(0,1)]");
        }
        var badMatrix = SdRefused(() => cube.Transform(SubdSelection.OfVertices(0), new double[3]));
        if (!badMatrix.Contains("matrix")) return Fail($"subd: a 3-number matrix was refused as: {badMatrix}");
    }
    // 7. inset, insert_loop
    using (var cube = Subd.Cuboid())
    {
        using (var inset = cube.Inset(new uint[] { 1 }, 0.25))
            if (inset.Faces.Length != 10) return Fail("subd: inset([1], 0.25) is not 10 faces");
        using (var cut = cube.InsertLoop(new SubdEdge(0, 1)))
            if (cut.Positions.Length != 36 || cut.Selection?.Kind != SubdElements.Edges) return Fail("subd: insert_loop is not 12 positions with an edge selection");
        var refused = SdRefused(() => cube.InsertLoop(new SubdEdge(0, 1), 1.5));
        if (!refused.StartsWith("bad selection: ")) return Fail($"subd: insert_loop at 1.5 was refused as: {refused}");
    }
    // 8. smooth_mesh
    SubdMesh keptMesh;
    using (var cube = Subd.Cuboid())
    {
        var mesh = cube.SmoothMesh(2);
        var n = mesh.Positions.Length / 3;
        if (n <= 8 || mesh.Normals.Length != 3 * n) return Fail("subd: smooth_mesh(2) is not n > 8 positions with n normals");
        for (var k = 0; k < n; k++)
            if (Math.Abs(Math.Sqrt(mesh.Normals[3 * k] * mesh.Normals[3 * k] + mesh.Normals[3 * k + 1] * mesh.Normals[3 * k + 1] + mesh.Normals[3 * k + 2] * mesh.Normals[3 * k + 2]) - 1) > 1e-9)
                return Fail($"subd: normal {k} is not unit");
        if (mesh.Indices.Length % 3 != 0 || mesh.Indices.Any(i => i >= n)) return Fail("subd: an index is out of range");
        if (mesh.TriangleFace.Length != mesh.Indices.Length / 3 || mesh.TriangleFace.Any(f => f >= 6)) return Fail("subd: triangle_face is not one entry a triangle, each < 6");
        if (cube.SmoothMesh(1).Positions.Length >= mesh.Positions.Length) return Fail("subd: smooth_mesh(1) is not fewer positions");
        if (!cube.SmoothMesh(2).Positions.SequenceEqual(mesh.Positions)) return Fail("subd: a second smooth_mesh(2) differs");
        var tooDeep = SdRefused(() => cube.SmoothMesh(7));
        if (!tooDeep.Contains("levels")) return Fail($"subd: smooth_mesh(7) was refused as: {tooDeep}");
        keptMesh = mesh;
    }
    GC.Collect();
    GC.WaitForPendingFinalizers();
    if (keptMesh.Positions.Any(double.IsNaN) || keptMesh.Normals.Length != keptMesh.Positions.Length || keptMesh.Indices.Max() >= keptMesh.Positions.Length / 3)
        return Fail("subd: a mesh read after its cage is closed is not whole");
    // 9. pick
    using (var cube = Subd.Cuboid())
    {
        var corner = cube.Positions.Skip(18).Take(3).ToArray();
        var fine = cube.SmoothMesh(3);
        var best = 0;
        var bestD = double.MaxValue;
        for (var k = 0; k < fine.Positions.Length / 3; k++)
        {
            var d = Math.Pow(fine.Positions[3 * k] - corner[0], 2) + Math.Pow(fine.Positions[3 * k + 1] - corner[1], 2) + Math.Pow(fine.Positions[3 * k + 2] - corner[2], 2);
            if (d < bestD) { bestD = d; best = k; }
        }
        var at = fine.Positions.Skip(3 * best).Take(3).ToArray();
        var vertex = cube.Pick(at, SubdElements.Vertices);
        if (vertex is null || vertex.Kind != SubdElements.Vertices || !vertex.Ids.SequenceEqual(new uint[] { 6 })) return Fail($"subd: pick for a vertex gave {vertex}");
        var edge = cube.Pick(at, SubdElements.Edges);
        if (edge is null || edge.Kind != SubdElements.Edges || edge.Edges.Length != 1 || (edge.Edges[0].A != 6 && edge.Edges[0].B != 6)) return Fail($"subd: pick for an edge gave {edge}");
        var face = cube.Pick(at, SubdElements.Faces);
        if (face is null || face.Kind != SubdElements.Faces || face.Ids.Length != 1) return Fail($"subd: pick for a face gave {face}");
        if (cube.Pick(new[] { 100.0, 100, 100 }, SubdElements.Vertices) is not null) return Fail("subd: a far point picked something");
        var nan = SdRefused(() => cube.Pick(new[] { double.NaN, 0, 0 }, SubdElements.Vertices));
        if (nan != "bad selection: pick: point is not finite") return Fail($"subd: a NaN point was refused as: {nan}");
        if (cube.Pick(new[] { 100.0, 100, 100 }, SubdElements.Vertices) is not null) return Fail("subd: a far point after a refusal picked something");
    }
    // 10. to_solid
    using (var cube = Subd.Cuboid())
    {
        var (solid, report) = cube.ToSolid();
        using (solid)
        {
            if (report.Regular != 0 || report.Refined != 24 || report.Levels < 2 || report.Steps < 1 || report.Deviation > 1e-4 || report.G1AngleDeg > 0.1
                || report.DeviationAt.Length != 3 || report.G1At.Length != 3) return Fail($"subd: the cuboid report reads {report}");
            if (!solid.Manifold.IsClosed) return Fail("subd: the cuboid's solid is not closed");
            if (!(solid.Mass().Volume > 0)) return Fail("subd: the cuboid's solid has no volume");
        }
        var (again, _) = cube.ToSolid(1e-4, 0.1, 6);
        again.Dispose();
    }
    // 11. 12. cylinders
    using (var flat = Subd.Cylinder(1, 2, 8, 1, false))
    {
        var refused = SdRefused(() => flat.ToSolid().Solid.Dispose());
        if (!(refused.Contains("subd:") && refused.Contains("tangent break"))) return Fail($"subd: an uncreased cylinder was refused as: {refused}");
    }
    using (var cyl = Subd.Cylinder())
    {
        var (solid, report) = cyl.ToSolid();
        solid.Dispose();
        if (report.Deviation > 1e-4 || report.G1AngleDeg > 0.1) return Fail($"subd: the default cylinder reads {report}");
    }
    // 13. primitives and their refusals
    using (var a = Subd.Cylinder(1, 2, 8, 2, true)) using (var b = Subd.Sphere(1, 2)) using (var c = Subd.Torus(3, 1, 12, 8))
        if (a.Faces.Length == 0 || b.Faces.Length == 0 || c.Faces.Length == 0) return Fail("subd: a primitive has no faces");
    var segs = SdRefused(() => Subd.Cuboid((2, 2, 2), (0, 1, 1)).Dispose());
    if (segs != "bad selection: cuboid: segments >= 1") return Fail($"subd: a cuboid of 0 segments was refused as: {segs}");
    var big = SdRefused(() => Subd.Sphere(1, 2000).Dispose());
    if (!big.Contains("1024")) return Fail($"subd: a sphere of 2000 segments was refused as: {big}");
    // 14. from_parts refusals
    using (var cube = Subd.Cuboid())
    {
        var notEdge = SdRefused(() => Subd.FromParts(cube.Positions, cube.Faces, new[] { new SubdEdge(0, 6) }).Dispose());
        if (!notEdge.StartsWith("bad selection: ")) return Fail($"subd: a crease that is not an edge was refused as: {notEdge}");
        var none = SdRefused(() => Subd.FromParts(Array.Empty<double>(), cube.Faces).Dispose());
        if (!none.Contains("vertex_count")) return Fail($"subd: zero positions were refused as: {none}");
    }
    // 15. the pipeline
    using (var cube = Subd.Cuboid())
    using (var tall = cube.Extrude(new uint[] { 1 }, 0.5))
    using (var cut = tall.Inset(new uint[] { 1 }, 0.25))
    {
        var (solid, report) = cut.ToSolid();
        using (solid)
        {
            if (!solid.Manifold.IsClosed || report.Deviation > 1e-4) return Fail($"subd: the pipeline is not closed within tolerance: {report}");
            var stepText = solid.StepText();
            if (!stepText.StartsWith("ISO-10303-21;") || !stepText.Contains("ADVANCED_FACE")) return Fail("subd: the pipeline's STEP text is not an advanced-face file");
            var stepPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"subd-pipeline-{Environment.ProcessId}.stp");
            File.WriteAllText(stepPath, stepText);
            try
            {
                using var read = Cadaclysm.Cadaclysm.Open(stepPath);
                var meshable = read.Walk().Count(n => n.CanMesh);
                if (meshable != 1) return Fail($"subd: the pipeline's STEP text reads back as {meshable} meshable nodes");
            }
            finally { File.Delete(stepPath); }
        }
    }
    // 16. close and use after close
    {
        var closed = Subd.Cuboid();
        closed.Dispose();
        closed.Dispose();
        void Dead(string what, Action act)
        {
            try { act(); throw new InvalidOperationException($"subd: {what} after close did not fail"); }
            catch (ObjectDisposedException) { }
        }
        try
        {
            Dead("positions", () => _ = closed.Positions);
            Dead("extrude", () => closed.Extrude(new uint[] { 1 }, 1).Dispose());
            Dead("smooth_mesh", () => closed.SmoothMesh(2));
            Dead("pick", () => closed.Pick(new[] { 0.0, 0, 0 }, SubdElements.Vertices));
            Dead("to_solid", () => closed.ToSolid().Solid.Dispose());
        }
        catch (InvalidOperationException e) { return Fail(e.Message); }
    }
    Console.WriteLine("subd: the cage, its edits, its mesh, its pick and its solid");
}
// Solid x profile hits: a line through a cuboid pierces two faces and is cut into three
// pieces, outside/inside/outside, the middle one spanning the box and sweeping; a loop no hit
// cuts is one piece; an open sheet has no pieces; a zero tolerance refused in the kernel's words.
{
    var xy = new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    using var box = Solid.Cuboid(10, 20, 30);
    using var line = Profile.Path((-20, 0)).LineTo(20, 0).EndOpen();
    var found = box.Hits(line, xy);
    if (found.Hits.Count != 2 || found.Pieces.Count != 3) return Fail($"solid hits: a line through a cuboid reads {found}");
    for (var k = 0; k < 2; k++)
    {
        var h = found.Hits[k];
        if (h.Run || h.Touch || Math.Abs(h.Start[0] - (k == 0 ? -5 : 5)) > 0.05 || h.AStart.Segment != 0 || h.AStart.Face != uint.MaxValue
            || h.BStart.Face == uint.MaxValue || !double.IsFinite(h.BStart.U) || !double.IsFinite(h.BStart.V))
            return Fail($"solid hits: hit {k} reads {h} ({h.AStart}, {h.BStart})");
    }
    var p = found.Pieces;
    if (p[0].Inside || !p[1].Inside || p[2].Inside) return Fail($"solid hits: the pieces read {p[0]}, {p[1]}, {p[2]}");
    if (p[0].Start.T != 0 || p[2].End.T != 1 || p[0].End.T != p[1].Start.T || p[1].End.T != p[2].Start.T)
        return Fail($"solid hits: the pieces do not run head to tail: {p[0]}, {p[1]}, {p[2]}");
    using var middle = Solid.ExtrudeOpen(p[1].Profile, xy, 1);
    var (lo, hi) = middle.Bounds;
    if (Math.Abs(lo[0] + 5) > 0.05 || Math.Abs(hi[0] - 5) > 0.05) return Fail($"solid hits: the middle piece spans x {lo[0]} .. {hi[0]}, not the box");
    using var along = SweepPath.Along(p[1].Profile, xy, 0.05, true);
    var far = box.Hits(Profile.Circle(1), new double[] { 100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 });
    if (far.Hits.Count != 0 || far.Pieces.Count != 1 || far.Pieces[0].Inside) return Fail($"solid hits: a circle far off reads {far}");
    using var flat = Solid.Face(Profile.Rect(20, 20), xy);
    var across = flat.Hits(Profile.Path((0, -20)).LineTo(0, 20).EndOpen(), new double[] { 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0 });
    if (across.Hits.Count < 1 || across.Pieces.Count != 0) return Fail($"solid hits: a line across a sheet reads {across}");
    try { box.Hits(line, xy, 0.0); return Fail("solid hits: a zero tolerance was accepted"); }
    catch (BuildException e) when (e.Message == "solid_profile_hits: tolerance must be positive and finite") { }
    Console.WriteLine($"solid hits: {found}; {p[1]}");
}
using var plate = Workplane.Xy().Extrude(outline, 6).Solid();
using var pin = Workplane.FromSolid(plate).Faces(Selector.Max(Axis.Z)).OnFace().Cylinder(5, 10).Solid();
using var part = plate.Join(pin);
var corners = part.Edges.Where(e => e.IsLine && Math.Abs(e.Direction![2]) > 0.99
                                    && e.Faces.All(f => part.FaceKind(f) == "plane")).ToList();
using var rounded = part.Fillet(corners, 1.0);
Console.WriteLine($"faces={rounded.Faces} watertight={rounded.IsWatertight()}");
// A plate has 6 faces, the hole adds 1 cylinder, the pin 2 (its wall and its top), and each
// of the four corners rounded trades one edge for one face.
if (rounded.Faces != 15) return Fail($"the filleted part has {rounded.Faces} faces, not 15");
if (!rounded.IsWatertight()) return Fail("the filleted part is not watertight");
var shape = rounded.Manifold;
Console.WriteLine($"manifold: {shape}");
if (!shape.IsClosed || shape.Faces != rounded.Faces) return Fail($"the filleted part is not a closed manifold: {shape}");
// The sheet verbs: a face from a profile, a solid's face alone, faces dropped, a trim, a
// rounded profile and a path along a curve.
{
    var xy = new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    using var square = Profile.Rect(20, 20);
    using var flat = Solid.Face(square, xy);
    using var peg = Solid.Extrude(Profile.Circle(4), new double[] { 0, 0, -6, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 12);
    using var holed = flat.Trim(peg);
    using var disc = flat.Trim(peg, keep: "inside");
    using var lid = plate.FaceSheet(plate.SelectFace(Selector.Max(Axis.Z)));
    using var walls = plate.DropFaces(new[] { 0, 1 });
    using var roundedSquare = square.Round(2);
    using var slab = Solid.Extrude(roundedSquare, xy, 1);
    using var wave = Profile.Path((0, 0)).BezierTo((20, 0), (20, 20), (40, 10)).EndOpen();
    using var along = SweepPath.Along(wave, xy, 0.01);
    using var tube = Solid.Sweep(Profile.Circle(1), new double[] { 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 }, along);
    using var onPlane = Workplane.Xy().Face(square).Solid();
    if (flat.Faces != 1 || holed.Faces < 1 || disc.Faces < 1 || lid.Faces != 1 || walls.Faces != plate.Faces - 2
        || slab.Faces != 10 || !tube.IsWatertight() || onPlane.Faces != 1)
        return Fail($"sheet verbs: sheet={flat.Faces} holed={holed.Faces} disc={disc.Faces} lid={lid.Faces} walls={walls.Faces} slab={slab.Faces}");
    try
    {
        flat.Trim(peg.Translate(100, 0, 0), keep: "inside");
        return Fail("a trim with nothing inside the tool did not throw");
    }
    catch (BuildException e) when (e.Message.Contains("trim: nothing of the sheet lies inside the tool"))
    {
    }
    // Chain: an L's two sides, the second drawn back to front, joined -- open, two walls.
    using var sideA = Profile.Path((0, 0)).LineTo(10, 0).EndOpen();
    using var sideB = Profile.Path((10, 8)).LineTo(10, 0).EndOpen();
    using var ell = Profile.Chain([sideA, sideB]);
    using var ellWalls = Solid.ExtrudeOpen(ell, xy, 2);
    if (ellWalls.Faces != 2) return Fail($"chain: an L extruded open has {ellWalls.Faces} walls, not 2");
    // Close: the open L's first side and a line back -- closed, a triangle's three walls.
    using var closedL = Profile.Path((0, 0)).LineTo(10, 0).LineTo(10, 8).EndOpen().CloseLoop();
    using var closedWalls = Solid.ExtrudeOpen(closedL, xy, 2);
    if (closedWalls.Faces != 3) return Fail($"close_loop: a closed L has {closedWalls.Faces} walls, not 3");
    // Push-pull: a cube's top raised is one taller box, six faces, not a box and a prism.
    using var cube = Solid.Cuboid(10, 10, 10);
    using var raised = cube.PushPull(cube.SelectFace(Selector.Max(Axis.Z)), 5);
    if (raised.Faces != 6 || !raised.IsWatertight()) return Fail($"push_pull: the raised cube has {raised.Faces} faces, not 6");
    // Its top and a side pushed together: a 15 x 10 x 15 box, still six faces.
    using var grown = cube.PushPull([cube.SelectFace(Selector.Max(Axis.Z)), cube.SelectFace(Selector.Max(Axis.X))], 5);
    if (grown.Faces != 6 || !grown.IsWatertight()) return Fail($"push_pull: the cube grown two ways has {grown.Faces} faces, not 6");
    // Quick solids: a coiled wire and a pipe close; a cube split by a plane is two bodies.
    using var wire = Profile.Circle(1).Translate(10, 0);
    using var spring = Solid.Coil(wire, [0, 0, 0, 0, 0, 1], 4, 2);
    if (!spring.IsWatertight()) return Fail("coil: the spring leaks");
    using var pipePath = SweepPath.At((0, 0, 0)).LineTo((0, 0, 10));
    using var pipe = Solid.Pipe(pipePath, 2, 0.5);
    if (!pipe.IsWatertight() || pipe.Faces != 6) return Fail($"pipe: the tube has {pipe.Faces} faces, not 6");
    var halves = cube.SplitByPlane([2, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0]);
    if (halves.Count != 2 || halves[0].Faces != 6) return Fail($"split_by_plane: {halves.Count} bodies, not 2");
    foreach (var half in halves) half.Dispose();
    // A rectangle drawn above a sphere cores it: the ball with a square hole, then the core.
    using var ball = Solid.Sphere(10);
    using var coreSquare = Profile.Rect(6, 6);
    var cored = ball.SplitByProfile(coreSquare, [0, 0, 40, 1, 0, 0, 0, 1, 0, 0, 0, 1]);
    var whole = ball.Mass().Volume;
    if (cored.Count != 2 || !(cored[1].Mass().Volume > 0 && cored[1].Mass().Volume < cored[0].Mass().Volume)
        || Math.Abs(cored[0].Mass().Volume + cored[1].Mass().Volume - whole) > 0.01 * whole)
        return Fail($"split_by_profile: {cored.Count} bodies, not a hole and a core adding up to the ball");
    foreach (var piece in cored) piece.Dispose();
    // From loops: a circle given before the square it lies in -- the square is the boundary.
    using var loopHole = Profile.Circle(4);
    using var loopSquare = Profile.Rect(30, 30);
    using var fromLoops = Profile.FromLoops([loopHole, loopSquare]);
    using var holedSquare = Solid.Extrude(fromLoops, xy, 2);
    if (holedSquare.Faces != 8) return Fail($"from_loops: the holed square has {holedSquare.Faces} faces, not 8");
    // Revolve in plane: a plate drawn beside the y axis turns into a tube of four walls.
    using var beside = Profile.Polygon([(5, 0), (8, 0), (8, 10), (5, 10)]);
    using var turned = Solid.RevolveInPlane(beside, xy, (0, 0), (0, 1), 2 * Math.PI);
    using var turnedWalls = Solid.RevolveOpenInPlane(beside, xy, (0, 0), (0, 1), Math.PI);
    if (turned.Faces != 4 || !turned.IsWatertight() || turnedWalls.Faces != 4) return Fail($"revolve_in_plane: {turned.Faces} and {turnedWalls.Faces} faces, not 4");
    // A hexagon: six walls and two caps. A closed spline through a square's corners: one wall.
    using var hexagon = Profile.RegularPolygon((0, 0), 10, 6);
    using var hexPrism = Solid.Extrude(hexagon, xy, 2);
    using var loopSpline = Profile.Spline([(0, 0), (10, 0), (10, 10), (0, 10)], 3, null, closed: true);
    using var loopSolid = Solid.Extrude(loopSpline, xy, 2);
    if (hexPrism.Faces != 8 || loopSolid.Faces != 3 || !loopSolid.IsWatertight()) return Fail($"shapes: {hexPrism.Faces} and {loopSolid.Faces} faces, not 8 and 3");
    // A five-pointed star: ten walls and two caps.
    using var star = Profile.Star((0, 0), 10, 4, 5);
    using var starPrism = Solid.Extrude(star, xy, 2);
    if (starPrism.Faces != 12 || !starPrism.IsWatertight()) return Fail($"star: {starPrism.Faces} faces, not 12");
    // Text: an `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring with spline edges.
    var word = Profile.Text("io", 10);
    using var ring = Solid.Extrude(word[2], xy, 2);
    if (word.Count != 3 || !ring.IsWatertight() || !ring.Edges.Any(e => e.Kind == "nurbs")) return Fail($"text: {word.Count} shapes, ring watertight {ring.IsWatertight()}");
    foreach (var p in word) p.Dispose();
    // A reflector: the parabola from rim to rim, closed and revolved -- watertight.
    using var dish = Profile.Parabola((0, 0), (0, 1), 20, 0, 50).LineTo(0, 31.25).LineTo(0, 0).End();
    using var bowl = Solid.RevolveInPlane(dish, xy, (0, 0), (0, 1), 2 * Math.PI);
    if (!bowl.IsWatertight()) return Fail("parabola: the bowl leaks");
    // The library reads a fixed count of weights: a wrong count is refused, not read past.
    static string Refusal(Action build)
    {
        try { build(); return "no refusal"; }
        catch (BuildException e) { return e.Message; }
    }
    (double, double)[] squareCorners = [(0, 0), (10, 0), (10, 10), (0, 10)];
    using var weighted = Profile.Spline(squareCorners, 3, [1, 2, 1, 1], closed: true);
    using var rational = Profile.Path((0, 0)).NurbsTo([(5, 5), (10, 0)], [0, 0, 0, 1, 1, 1], 2, [1, 0.5, 1]).EndOpen();
    var shortSpline = Refusal(() => Profile.Spline(squareCorners, 3, [1, 1], closed: true).Dispose());
    var shortNurbs = Refusal(() => Profile.Path((0, 0)).NurbsTo([(5, 5), (10, 0)], [0, 0, 0, 1, 1, 1], 2, [1, 1]).Dispose());
    if (shortSpline != "spline: 2 weights for 4 points; give one per point") return Fail($"a short weight list: {shortSpline}");
    if (shortNurbs != "nurbs_to: 2 weights for 3 control points (the current point and 2 given); give one per point") return Fail($"a short weight list: {shortNurbs}");
    Console.WriteLine($"sheet verbs: face, trim ({holed.Faces}+{disc.Faces}), face_sheet, drop_faces, round ({slab.Faces} faces), along, chain, push_pull, coil, pipe, split_by_plane, split_by_profile, close_loop, from_loops, revolve_in_plane, regular_polygon, star, text, spline, parabola: ok");
}
// Frames: built, checked, and passed wherever twelve numbers go.
{
    if (!Frame.At((0, 0, 0), (0, -1, 0)).Equals(Frame.Xz()) || !Frame.At((1, 2, 3), (0, 0, 5)).Equals(Frame.Xy((1, 2, 3)))
        || !Frame.Xy().Offset(5).Equals(Frame.Xy((0, 0, 5))) || !Frame.Yz().ToArray().SequenceEqual(Workplane.Yz().Frame))
        return Fail("Frame.At / Xy / Xz / Offset disagree");
    try
    {
        _ = new Frame((0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, -1));
        return Fail("a left-handed frame did not throw");
    }
    catch (BuildException e) when (e.Message.Contains("left-handed"))
    {
    }
    using var rect10 = Profile.Rect(10, 4);
    using var lid = Solid.Extrude(rect10, Frame.Xy((0, 0, 5)), 2);
    using var wall = Workplane.On(Frame.Xz((0, 3, 0))).Extrude(rect10, 1).Solid();
    var top = Frame.Of(lid.FaceFrame(lid.SelectFace(Selector.Max(Axis.Z))));
    var (lo, hi) = lid.Bounds;
    if (Math.Abs(lo[2] - 5) > 1e-6 || Math.Abs(hi[2] - 7) > 1e-6 || Math.Abs(wall.Bounds.Max[1] - 3) > 1e-6
        || Math.Abs(top.Origin.Z - 7) > 1e-6 || Math.Abs(top.Z.Z - 1) > 1e-9)
        return Fail($"frames: lid z {lo[2]}..{hi[2]}, wall max y {wall.Bounds.Max[1]}, top {top}");
    Console.WriteLine($"frames: {Frame.At((0, 0, 0), (1, 1, 1))}: ok");
}
// Colour: a gold plate joined with a blue pin -- the part is gold, the pin's top keeps its blue.
using var gold = plate.Coloured(0.8, 0.6, 0.4);
using var blue = pin.Coloured(0.2, 0.4, 1.0);
using var coloured = gold.Join(blue);
var pinTop = coloured.FaceColour(coloured.SelectFace(Selector.Max(Axis.Z)));
Console.WriteLine($"colour={string.Join(",", coloured.Colour ?? [])} pin top={string.Join(",", pinTop ?? [])}");
if (!(coloured.Colour ?? []).SequenceEqual([0.8, 0.6, 0.4]) || !(pinTop ?? []).SequenceEqual([0.2, 0.4, 1.0]) || plate.Colour is not null)
    return Fail("the colours did not carry through the join");
// Edge and profile colour: all of a plate's edges gold, then edge 0 blue over it; a profile
// carries its own colour too.
using var goldEdges = plate.EdgesColoured(0.8, 0.6, 0.4);
using var blueEdge = goldEdges.EdgesColoured(0.2, 0.4, 1.0, new[] { 0 });
using var goldRect = Profile.Rect(10, 4).Coloured(0.8, 0.6, 0.4);
var edgeColours = blueEdge.EdgePolylineColours();
Console.WriteLine($"edge 0={string.Join(",", blueEdge.EdgeColour(0) ?? [])} edge 1={string.Join(",", blueEdge.EdgeColour(1) ?? [])} polylines={edgeColours.Length} rect={string.Join(",", goldRect.Colour ?? [])}");
if (!(blueEdge.EdgeColour(0) ?? []).SequenceEqual([0.2, 0.4, 1.0]) || !(blueEdge.EdgeColour(1) ?? []).SequenceEqual([0.8, 0.6, 0.4])
    || edgeColours.Length == 0 || !(goldRect.Colour ?? []).SequenceEqual([0.8, 0.6, 0.4]) || plate.EdgeColour(0) is not null)
    return Fail("edge or profile colours");
// An empty edges list colours no edge -- not "every edge" (which null would mean) -- so edge 0
// stays blue and edge 1 stays gold.
using var untouched = blueEdge.EdgesColoured(0.1, 0.1, 0.1, Array.Empty<int>());
if (!(untouched.EdgeColour(0) ?? []).SequenceEqual([0.2, 0.4, 1.0]) || !(untouched.EdgeColour(1) ?? []).SequenceEqual([0.8, 0.6, 0.4]))
    return Fail("an empty edge list should colour nothing");
// CSS colour names and hex forms reach Coloured/EdgesColoured the same way the numeric
// triples do, and a name the parser doesn't know is refused with the wrapper's own text.
using var redBox = Solid.Cuboid(1, 1, 1).Coloured("red");
if (!(redBox.Colour ?? []).SequenceEqual([1.0, 0.0, 0.0])) return Fail("Coloured(\"red\") did not come back (1, 0, 0)");
if (Solid.Cuboid(1, 1, 1).Coloured("#0f0").Colour![1] != 1.0) return Fail("Coloured(\"#0f0\") did not come back green");
try { Solid.Cuboid(1, 1, 1).Coloured("notacolour"); return Fail("coloured: \"notacolour\" was accepted"); }
catch (BuildException e) when (e.Message.Contains("a CSS colour name")) { }
using var redEdgeBox = Solid.Cuboid(1, 1, 1).EdgesColoured("red");
if (!(redEdgeBox.EdgeColour(0) ?? []).SequenceEqual([1.0, 0.0, 0.0])) return Fail("EdgesColoured(\"red\") did not come back (1, 0, 0)");
using var blueEdgeByRef = redEdgeBox.EdgesColoured(new[] { redEdgeBox.Edges[0] }, "blue");
if (!(blueEdgeByRef.EdgeColour(0) ?? []).SequenceEqual([0.0, 0.0, 1.0])) return Fail("EdgesColoured(edges, \"blue\") did not come back (0, 0, 1)");
using var goldRectByName = Profile.Rect(10, 4).Coloured("#cc9966");
if (!(goldRectByName.Colour ?? []).SequenceEqual(Blacksmith.Rgb("#cc9966", "coloured"))) return Fail("Profile.Coloured(string) did not carry through");
if (Blacksmith.Packed("navy") != 0x000080u) return Fail("Blacksmith.Packed(\"navy\") is not 0x000080");
// Packed takes no numeric triple of its own, so its refusal names only the text forms --
// unlike Coloured/EdgesColoured's "notacolour" case above, it must not mention "0..1".
try { Blacksmith.Packed("bogus"); return Fail("Blacksmith.Packed(\"bogus\") was accepted"); }
catch (BuildException e) when (e.Message.Contains("not 'bogus'") && !e.Message.Contains("0..1")) { }
Console.WriteLine("colour: CSS names and hex strings match the numeric overloads, an unknown name is refused");
// A face: the outline as a sheet, which pushed out is the plate again.
using var sheet = Solid.Face(outline, [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]);
using var pushed = sheet.ExtrudeFaces(6);
Console.WriteLine($"face: {sheet.Faces} face, pushed out {pushed.Faces} faces");
if (sheet.Faces != 1 || pushed.Faces != plate.Faces || !pushed.IsWatertight()) return Fail("the outline's face did not push out to the plate");
// A temporary operand -- the cylinder here is nobody's -- must stay alive for the length of
// the call that reads it: the owners hold SafeHandles, which the marshaller pins across every
// P/Invoke, so a collection during the join can neither free the cylinder nor crash the
// process. Two hundred of them, with a collection forced between each and another thread
// collecting throughout (so one lands while a join is running), prove it.
using (var collecting = new CancellationTokenSource())
{
    var collector = new Thread(() =>
    {
        while (!collecting.IsCancellationRequested)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
        }
    });
    collector.Start();
    for (var i = 0; i < 200; i++)
    {
        using var joined = Solid.Cuboid(80, 40, 6).Join(Solid.Cylinder(5, 10));
        if (joined.Faces == 0) return Fail("a joined temporary lost its faces");
        GC.Collect();
        GC.WaitForPendingFinalizers();
    }
    collecting.Cancel();
    collector.Join();
}
Console.WriteLine("200 joins of temporaries under GC pressure: ok");
// A solid crosses to the reader through STEP text: the scene it becomes is its own document,
// with the solid's bounds, and it outlives the solid it was made from.
Scene fromSolid;
using (var throwaway = Solid.Cuboid(80, 40, 6).Join(Solid.Cylinder(5, 10)))
{
    fromSolid = throwaway.ToScene();
    var (lo, hi) = throwaway.Bounds;
    var sb = fromSolid.Bounds;
    if (Math.Abs(sb.Max[2] - hi[2]) > 0.01 || Math.Abs(sb.Min[0] - lo[0]) > 0.01)
        return Fail("to_scene's bounds disagree with the solid's");
}
using (fromSolid)
{
    if (fromSolid.Closed || fromSolid.Bounds.IsEmpty) return Fail("the scene did not survive its solid's dispose");
    Console.WriteLine($"to_scene: {fromSolid.Nodes.Count} node(s), path={fromSolid.Path}");
}
// A mesh view owns a held tessellation: meshing the solid again at another tolerance, or
// disposing the solid, leaves an already-taken view untouched.
var firstMesh = rounded.Mesh(0.05);
var kept = firstMesh.Positions.ToArray();
rounded.Mesh(0.5);
rounded.Mesh(0.01);
if (!firstMesh.Positions.SequenceEqual(kept)) return Fail("a held mesh view changed under a re-mesh at another tolerance");
var meshBox = Solid.Cuboid(1, 2, 3);
var boxMesh = meshBox.Mesh(0.05);
var boxKept = boxMesh.Positions[0];
meshBox.Dispose();
if (boxMesh.Positions[0] != boxKept) return Fail("a held mesh view changed when its solid was disposed");
GC.KeepAlive(firstMesh); GC.KeepAlive(boxMesh);
Console.WriteLine("kernel: mesh views own their tessellation -- a re-mesh and a dispose leave them");
// f64 twins on the kernel: mesh64 shares mesh's cache and bounds64 the same tessellation's
// unnarrowed positions.
var kMesh32 = rounded.Mesh(0.05);
var kMesh64 = rounded.Mesh64(0.05);
if (kMesh64.VertexCount != kMesh32.VertexCount || kMesh64.IndexCount != kMesh32.IndexCount)
    return Fail("blacksmith mesh64(0.05)'s counts do not equal mesh(0.05)'s");
if (kMesh32.Positions.Length >= 3 &&
    ((float)kMesh64.Positions[0] != kMesh32.Positions[0] || (float)kMesh64.Positions[1] != kMesh32.Positions[1] || (float)kMesh64.Positions[2] != kMesh32.Positions[2]))
    return Fail("blacksmith mesh64's first position narrowed does not equal mesh's");
var (kLo, kHi) = rounded.BoundsAt(0.05);
var (kLo64, kHi64) = rounded.BoundsAt64(0.05);
if (Math.Abs(kLo64[0] - kLo[0]) > 1e-9 || Math.Abs(kLo64[1] - kLo[1]) > 1e-9 || Math.Abs(kLo64[2] - kLo[2]) > 1e-9
    || Math.Abs(kHi64[0] - kHi[0]) > 1e-9 || Math.Abs(kHi64[1] - kHi[1]) > 1e-9 || Math.Abs(kHi64[2] - kHi[2]) > 1e-9)
    return Fail("blacksmith bounds64(0.05) does not equal bounds(0.05)");
Console.WriteLine($"blacksmith f64 twins: mesh64 {kMesh64.TriangleCount} triangles, bounds64 max z {kHi64[2]}");
// No schema at all: the kernel writes against its built-in AP203, no ap203.exp needed.
var noSchemaText = rounded.StepText();
if (!noSchemaText.StartsWith("ISO-10303-21;")) return Fail("StepText() with no schema did not write valid STEP");
Console.WriteLine("StepText() with no schema: ISO-10303-21; ok");
var step = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke.stp");
rounded.Step(step);
using (var back = Cadaclysm.Cadaclysm.Open(step))
{
    var b = back.Bounds;
    Console.WriteLine($"step read back: bounds max=({b.Max[0]},{b.Max[1]},{b.Max[2]})");
    // The plate is 80 x 40 x 6, `Profile.Rect` centring it on the origin, and the pin adds 10.
    if (Math.Abs(b.Max[2] - 16) > 0.01 || Math.Abs(b.Max[0] - 40) > 0.01) return Fail("the STEP did not read back as the plate with its pin");
    // And back into the kernel: the read body's brep, shared with the scene rather than
    // copied, as a solid that outlives the scene it came from.
    var node = back.Placements.Select(p => p.Geometry).First(n => { using var brep = n.Brep; return brep is not null; });
    using (var brep = node.Brep!)
    {
        var read = brep.Manifold;
        if (!read.IsClosed || read.Faces != rounded.Faces) return Fail($"the read body is not the closed manifold written: {read}");
        var (sewn, sew) = brep.Sewed();
        using (sewn)
            if (sew.FreeBefore != read.BoundaryEdges || brep.Manifold.BoundaryEdges != read.BoundaryEdges)
                return Fail($"sewed reports {sew.FreeBefore} free edges before, the brep has {read.BoundaryEdges}");
    }
    using var imported = Solid.FromNode(back, node);
    back.Dispose();
    if (imported.Faces != rounded.Faces) return Fail($"from_node gave {imported.Faces} faces, not {rounded.Faces}");
    using var drilled = imported.Cut(Solid.Cylinder(2, 40).Translate(-30, 0, -5));
    if (drilled.Faces <= imported.Faces) return Fail("a boolean on the imported solid added no face");
    Console.WriteLine($"from_node: {imported.Faces} faces, cut to {drilled.Faces} after the scene closed");
}
using (var opened = Solid.Open(step))
{
    if (opened.Faces != rounded.Faces) return Fail($"Solid.Open gave {opened.Faces} faces, not {rounded.Faces}");
    Console.WriteLine($"Solid.Open: {opened.Faces} faces");
}
// The same solid as SAT, written by the library itself, read back the same way.
var sat = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke.sat");
rounded.Sat(sat);
if (!rounded.SatText().StartsWith("400 0 1 0")) return Fail("the SAT text does not open with the record version");
using (var back = Cadaclysm.Cadaclysm.Open(sat))
{
    var b = back.Bounds;
    Console.WriteLine($"sat read back: bounds max=({b.Max[0]},{b.Max[1]},{b.Max[2]})");
    if (Math.Abs(b.Max[2] - 16) > 0.01 || Math.Abs(b.Max[0] - 40) > 0.01) return Fail("the SAT did not read back as the plate with its pin");
}
// The OCCT .brep writer, and its reader.
var brepPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke.brep");
rounded.Brep(brepPath);
if (!rounded.BrepText().StartsWith("DBRep_DrawableShape")) return Fail("the .brep text does not begin as one");
using (var back = Cadaclysm.Cadaclysm.Open(brepPath))
{
    var b = back.Bounds;
    Console.WriteLine($"brep read back: bounds max=({b.Max[0]},{b.Max[1]},{b.Max[2]})");
    if (Math.Abs(b.Max[2] - 16) > 0.01 || Math.Abs(b.Max[0] - 40) > 0.01) return Fail("the .brep did not read back as the plate with its pin");
}

// The FEM surface mesh, both sides of the ABI. Every check below names the wrong
// implementation it catches; `#` marks the ones a break-the-code proof was run against.
{
    // A mesh-only body -- cube.scad carries no brep -- so: one face, every node on it, no
    // B-rep topology at all, and the scene's own convention rather than the file's.
    using var femMesh = first.FemMesh(tolerance: 0.5);
    var nodeCount = femMesh.Nodes.Length / 3;
    if (femMesh.Nodes.Length % 3 != 0 || femMesh.Triangles.Length % 3 != 0 || nodeCount == 0)
        return Fail($"fem: the node and triangle arrays read {femMesh.Nodes.Length} and {femMesh.Triangles.Length}");
    // Catches `Triangles` lent over `NodeCount` (or `Nodes` over `TriangleCount`): the spans
    // would then be the wrong length and the indices would run past the nodes.
    if (femMesh.Triangles.Length != femMesh.TriangleFace.Length * 3) return Fail("fem: triangleFace is not one per triangle");
    foreach (var index in femMesh.Triangles) if (index >= nodeCount) return Fail($"fem: a triangle names node {index} of {nodeCount}");
    foreach (var face in femMesh.TriangleFace) if (face >= femMesh.FaceCount) return Fail($"fem: a triangle lies on face {face} of {femMesh.FaceCount}");
    // Catches NodeKind and NodeEntity lent from each other's pointer: a kind would then be a
    // face index and an entity a 0/1/2. Bounding each entity by the list its own kind names is
    // what tells the two apart -- the widths alone cannot, both being uint32 arrays of nodes.
    if (femMesh.NodeKind.Length != nodeCount || femMesh.NodeEntity.Length != nodeCount) return Fail("fem: nodeKind/nodeEntity are not one per node");
    // Read once, outside the loop: every ask rebuilds the list from the handle at one C call an
    // element, and the two are 0 long here only because this body has no B-rep topology.
    var (femEdges, femVertices) = (femMesh.Edges, femMesh.Vertices);
    for (var k = 0; k < nodeCount; k++)
    {
        var (kind, entity) = (femMesh.NodeKind[k], femMesh.NodeEntity[k]);
        var limit = kind switch { 0 => (uint)femVertices.Count, 1 => (uint)femEdges.Count, 2 => femMesh.FaceCount, _ => 0u };
        if (kind > 2 || entity >= limit) return Fail($"fem: node {k} lies on kind {kind} entity {entity}, of {limit}");
    }
    if (femMesh.MinAngle <= 0 || femMesh.MinAngle >= 90 || femMesh.LongestEdge <= 0
        || femMesh.WorstTriangle >= femMesh.Triangles.Length / 3)
        return Fail($"fem: the quality figures read {femMesh}");
    if (path.EndsWith("cube.scad"))
    {
        // # Catches FromMesh read off the neighbouring `Watertight` field -- which is true for
        // this body too, so only a body where the two differ separates them (the B-rep below).
        if (!femMesh.FromMesh || femMesh.FaceCount != 1 || femEdges.Count != 0 || femVertices.Count != 0)
            return Fail($"fem: the cube reads {femMesh}, not a mesh-only body of one face");
        foreach (var kind in femMesh.NodeKind) if (kind != 2) return Fail("fem: a mesh body's nodes all lie on face 0");
        if (!femMesh.Watertight || femMesh.OpenEdges.Count != 0 || femMesh.FoldedEdges.Count != 0 || femMesh.Crossings.Count != 0)
            return Fail($"fem: the closed cube reads {femMesh.OpenEdges.Count} cracks, {femMesh.FoldedEdges.Count} folds and {femMesh.Crossings.Count} crossings");
    }
    var msh = femMesh.MshText();
    if (!msh.StartsWith("$MeshFormat") || !msh.Contains("$Nodes")) return Fail("fem: mshText is not Gmsh 4.1 ASCII");
    // The borrowed slot is copied out on the way through, so a second ask does not free the
    // first answer: both strings are this program's own and both still read.
    if (femMesh.MshText().Length != msh.Length) return Fail("fem: a second mshText disagrees with the first");
    var mshPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke.msh");
    femMesh.SaveMsh(mshPath);
    if (new FileInfo(mshPath).Length < msh.Length / 2) return Fail("fem: saveMsh wrote less than mshText");
    // The reader's placement is sixteen numbers, column-major; the kernel's is twelve. A
    // caller handing one ABI the other's is refused here rather than read as garbage.
    try { first.FemMesh(placement: new double[12]); return Fail("fem: a twelve-number placement was accepted"); }
    catch (CadaclysmException e) when (e.Message.Contains("16 numbers")) { }
    // A mesh-only body is meshed by a path that takes **no options at all**
    // (`fem::fem_mesh_of_mesh`), so neither field is read here, let alone validated: a zero, a
    // negative and a NaN all come back with the mesh. The rule pinned is the wrapper's, not the
    // mesher's -- a wrapper that validated `tolerance` or `maxSize` itself, instead of passing
    // them through and letting the library decide, would refuse calls this ABI accepts. (Both
    // *are* refused on a B-rep body, which the block below checks, so this is a pass-through
    // check and not a claim that the numbers are unchecked everywhere.)
    foreach (var (why, mesh) in new (string, global::Cadaclysm.FemMesh)[]
             {
                 ("tolerance 0", first.FemMesh(tolerance: 0)),
                 ("tolerance -1", first.FemMesh(tolerance: -1)),
                 ("tolerance NaN", first.FemMesh(tolerance: double.NaN)),
                 ("maxSize -1", first.FemMesh(maxSize: -1)),
                 ("maxSize NaN", first.FemMesh(maxSize: double.NaN)),
                 ("maxSize infinity", first.FemMesh(maxSize: double.PositiveInfinity)),
             })
        using (mesh)
            if (mesh.Nodes.Length != femMesh.Nodes.Length)
                return Fail($"fem: a mesh-only body read its options after all ({why} gave {mesh})");
    // # A freed handle refuses every accessor rather than reading the pointers it left behind:
    // the view is cached, so a property that does not ask the handle first hands out a span over
    // freed memory instead of throwing. The kernel's own sweep, thirty lines down, is the twin --
    // the guard is per wrapper class, so proving one says nothing about the other.
    //
    // What this does *not* prove, because C# cannot: a span already in hand is a bare pointer and
    // a length, and it goes on reading the freed block. Only *asking for* one is guarded.
    var staleReader = first.FemMesh(tolerance: 0.5);
    staleReader.Free();
    if (!staleReader.Freed) return Fail("fem: a freed mesh does not say so");
    staleReader.Free();   // idempotent
    foreach (var read in new Action[]
             {
                 () => { _ = staleReader.Nodes; }, () => { _ = staleReader.Triangles; },
                 () => { _ = staleReader.TriangleFace; }, () => { _ = staleReader.NodeKind; },
                 () => { _ = staleReader.NodeEntity; }, () => { _ = staleReader.FaceCount; },
                 () => { _ = staleReader.Edges; }, () => { _ = staleReader.Vertices; },
                 () => { _ = staleReader.OpenEdges; }, () => { _ = staleReader.FoldedEdges; },
                 () => { _ = staleReader.Crossings; },
                 () => { _ = staleReader.Watertight; }, () => { _ = staleReader.FromMesh; },
                 () => { _ = staleReader.MinAngle; }, () => { _ = staleReader.WorstTriangle; },
                 () => { _ = staleReader.LongestEdge; }, () => staleReader.MshText(),
                 () => staleReader.SaveMsh(mshPath),
             })
    {
        try { read(); return Fail("fem: a freed mesh read anyway"); }
        catch (CadaclysmException e) when (e.Message.Contains("freed")) { }
    }
    Console.WriteLine($"fem (reader): {femMesh}, minAngle {femMesh.MinAngle:F2}, longestEdge {femMesh.LongestEdge:F3};"
                      + " a freed mesh refuses all eighteen reads");
}
// # Which count feeds which entry point -- the census *wiring*, which nothing else here pins.
// Every other FEM check proves a row is extracted correctly; none proves `OpenEdges` reads
// `open_edge_count` rows through `cadaclysm_fem_mesh_open_edge` rather than the folded count or
// the folded call. `samples/open-sheet.scad` is the only body in this repository where both
// censuses are non-empty and of different lengths: the B-rep path computes no census unless the
// topology is closed (the documented "not asked" pair) and every closed body has none, while
// the mesh path always computes one -- so a `polyhedron` with a flap over one of its own
// directed edges is the way in. Six cracks, one fold, and the fold is not the first crack.
if (path.EndsWith("cube.scad"))
{
    var sheetPath = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path)!, "open-sheet.scad");
    using var sheetScene = Cadaclysm.Cadaclysm.Open(sheetPath);
    using var census = sheetScene.Walk().First(n => n.CanMesh).FemMesh();
    if (census.Nodes.Length != 15 || census.Triangles.Length != 9 || !census.FromMesh || census.Watertight)
        return Fail($"fem census: open-sheet.scad reads {census}, not five open, folded, mesh-only nodes");
    // The counts are what separate the two lists: a swapped count reads 1 where 6 belongs, and a
    // swapped call cannot read row 1 of a one-row table at all.
    if (census.OpenEdges.Count != 6 || census.FoldedEdges.Count != 1)
        return Fail($"fem census: {census.OpenEdges.Count} cracks and {census.FoldedEdges.Count} folds, not 6 and 1");
    // And the contents, which is what separates a wrapper that swapped both consistently.
    var (fold, crack) = (census.FoldedEdges[0], census.OpenEdges[0]);
    if (fold.A != 2 || fold.B != 0 || fold.BrepEdge != uint.MaxValue)
        return Fail($"fem census: the fold reads ({fold.A},{fold.B},{fold.BrepEdge}), not (2,0,NONE)");
    if (crack.A != 1 || crack.B != 2) return Fail($"fem census: the first crack reads ({crack.A},{crack.B}), not (1,2)");
    Console.WriteLine($"fem census: open-sheet.scad reads {census.OpenEdges.Count} cracks"
                      + $" and {census.FoldedEdges.Count} fold at ({fold.A},{fold.B})");

    // Crossings: `samples/dented-box.stp` is a closed B-rep box whose top dips through its
    // own floor, 296 pairs measured 2026-09-26 -- once through this reader, and once
    // through the kernel's own open of the same file, which must agree with it.
    var dentedPath = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(path)!, "dented-box.stp");
    using var dentedScene = Cadaclysm.Cadaclysm.Open(dentedPath);
    var dentedNode = dentedScene.Walk().First(n => n.CanMesh);
    using var dentedFem = dentedNode.FemMesh();
    if (!dentedFem.Watertight || dentedFem.FromMesh)
        return Fail($"fem crossings: dented-box.stp reads {dentedFem}, not a watertight brep");
    var dentedCrossings = dentedFem.Crossings;
    if (dentedCrossings.Count != 296) return Fail($"fem crossings: dented-box.stp reads {dentedCrossings.Count} pairs, not 296");
    if (dentedCrossings[0].A >= dentedCrossings[0].B)
        return Fail($"fem crossings: the first pair reads ({dentedCrossings[0].A},{dentedCrossings[0].B}), not a < b");

    using var kernelDented = Solid.Open(dentedPath);
    using var kernelDentedFem = kernelDented.FemMesh();
    var kernelDentedCrossings = kernelDentedFem.Crossings;
    if (kernelDentedCrossings.Count != 296)
        return Fail($"kernel fem crossings: dented-box.stp reads {kernelDentedCrossings.Count} pairs, not 296");
    Console.WriteLine($"fem crossings: dented-box.stp reads {dentedCrossings.Count} pairs through the reader"
                      + $" and {kernelDentedCrossings.Count} through the kernel");
}
// A B-rep body, read back from the STEP this run wrote: the topology the mesh-only body has
// none of -- edges with their own ids, vertices, and nodes on all three kinds of entity.
using (var back = Cadaclysm.Cadaclysm.Open(step))
{
    var body = back.Walk().First(n => n.CanMesh);
    using var fem = body.FemMesh(tolerance: 0.5);
    // # The other half of the FromMesh proof: false here where it was true above.
    if (fem.FromMesh || !fem.Watertight || fem.FaceCount != (uint)rounded.Faces)
        return Fail($"fem: the read plate reads {fem}, not a closed B-rep of {rounded.Faces} faces");
    if (fem.Edges.Count == 0 || fem.Vertices.Count == 0) return Fail("fem: a B-rep body carries edges and vertices");
    var kinds = new HashSet<uint>();
    foreach (var kind in fem.NodeKind) kinds.Add(kind);
    if (!kinds.SetEquals(new uint[] { 0, 1, 2 })) return Fail($"fem: the plate's nodes lie on kinds {string.Join(",", kinds)}, not 0, 1 and 2");
    // # `Id` is the body's own B-rep edge id, not this list's index: the list is a densely
    // renumbered subset ascending by id. Catches an `Id` filled from the loop counter -- which
    // a body whose ids happened to run 0, 1, 2 would hide, so both halves are checked.
    // Read once: every ask rebuilds the list from the handle, one C call an edge.
    var (edges, vertices) = (fem.Edges, fem.Vertices);
    var ids = edges.Select(e => e.Id).ToArray();
    if (!ids.SequenceEqual(ids.OrderBy(i => i))) return Fail($"fem: the edge ids do not ascend: {string.Join(",", ids)}");
    if (!ids.Where((id, at) => id != at).Any()) return Fail("fem: every edge id equals its own index -- Id is the index, not the body's id");
    foreach (var edge in edges)
    {
        if (edge.Runs.Length == 0 || edge.Runs[0] != 0 || edge.Runs[^1] >= edge.Nodes.Length)
            return Fail($"fem: {edge}'s runs do not start at 0 inside its chain");
        foreach (var node in edge.Nodes) if (node >= fem.Nodes.Length / 3) return Fail($"fem: {edge} names a node past the mesh");
        // # A closed body has no rim, so every edge has two faces and neither is the sentinel.
        if (edge.Faces.A >= fem.FaceCount || edge.Faces.B >= fem.FaceCount)
            return Fail($"fem: {edge} on a closed body bounds faces {edge.Faces.A} and {edge.Faces.B} of {fem.FaceCount}");
        if (edge.Closed && edge.Runs.Length > 1) return Fail($"fem: {edge} is one loop with a broken chain");
        if (edge.Seam && edge.Faces.A != edge.Faces.B) return Fail($"fem: {edge} is a seam whose two faces differ");
        // # The chain includes its end vertices, so the two ends name the nodes the chain
        // begins and finishes at -- which is what tells `Ends` from `Faces`, both being a pair
        // of uints that a swap would leave in range on a body of this shape.
        var ends = new[] { edge.Ends.A, edge.Ends.B }.Where(v => v != uint.MaxValue).Select(v => vertices[(int)v].Node).ToHashSet();
        if (!ends.SetEquals(new[] { edge.Nodes[0], edge.Nodes[^1] })) return Fail($"fem: {edge} does not end at its own vertices");
    }
    if (!vertices.Any(v => v.HasPosition)) return Fail("fem: no vertex of the plate has a position");
    foreach (var vertex in vertices)
        if (vertex.Point.Length != 3 || vertex.Node != uint.MaxValue && vertex.Node >= fem.Nodes.Length / 3)
            return Fail($"fem: {vertex} is not a node of this mesh");
    // A B-rep body *does* have geometry to follow, so here the tolerance is read and refused --
    // in the library's own words, not a message this wrapper invented.
    try { body.FemMesh(tolerance: 0); return Fail("fem: a zero tolerance was accepted on a B-rep body"); }
    catch (CadaclysmException e) when (e.Message.Contains("tolerance must be finite and > 0")) { }
    Console.WriteLine($"fem (read brep): {fem}, {edges.Count} edges, {vertices.Count} vertices, edge 0 {edges[0]}");
}
// The kernel's own: the same solid meshed through `cadaclysm_blacksmith_fem_mesh`, whose
// placement is twelve numbers and whose `.msh` text is owned rather than borrowed.
{
    var xy = new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    using var fem = rounded.FemMesh(tolerance: 0.5);
    if (fem.FromMesh || !fem.Watertight || fem.FaceCount != (uint)rounded.Faces || fem.Nodes.Length == 0)
        return Fail($"kernel fem: the filleted part reads {fem}");
    if (fem.OpenEdges.Count != 0 || fem.FoldedEdges.Count != 0 || fem.Crossings.Count != 0)
        return Fail($"kernel fem: a watertight solid reads {fem.OpenEdges.Count} cracks and {fem.Crossings.Count} crossings");
    // `max_size` bounds the boundary segments and only targets the interior, so the figure a
    // solver caller checks is LongestEdge -- not the ceiling it asked for. Catches a wrapper
    // that dropped `maxSize` on the floor (the mesh would not refine at all).
    using var fine = rounded.FemMesh(tolerance: 0.5, maxSize: 3.0);
    // 1.05 and not 3.0 exactly: the ceiling is not a guarantee (1.03 x was measured on a face
    // whose parameters run unevenly), so a tighter pin here would assert something the ABI
    // deliberately does not promise.
    if (fine.LongestEdge > 3.0 * 1.05) return Fail($"kernel fem: maxSize 3 came to longestEdge {fine.LongestEdge}");
    if (fine.Nodes.Length <= fem.Nodes.Length || fine.LongestEdge >= fem.LongestEdge)
        return Fail($"kernel fem: maxSize 3 gave {fine.Nodes.Length / 3} nodes and longestEdge {fine.LongestEdge}, no finer than {fem.Nodes.Length / 3}/{fem.LongestEdge}");
    // An open sheet: the one body where the sentinel and the "not asked" census trio show.
    using var openSheet = Solid.Face(Profile.Rect(20, 20), xy);
    using var sheetFem = openSheet.FemMesh(tolerance: 0.5);
    // # Watertight false with *both* censuses empty is "not asked", not "nothing found": a
    // sheet makes no claim to enclose anything. A caller reading only OpenEdges cannot tell
    // this from a sound body, which is why FoldedEdges is checked beside it.
    if (sheetFem.Watertight || sheetFem.OpenEdges.Count != 0 || sheetFem.FoldedEdges.Count != 0)
        return Fail($"kernel fem: the sheet reads {sheetFem} rather than open with an unasked census");
    // # Catches `face_b` filled with `0` instead of the NONE sentinel: every rim edge of a
    // one-faced sheet bounds face 0 and nothing else, so a 0 there reads as a real second
    // face -- a coherent wrong answer that no count or width can catch.
    var rim = sheetFem.Edges;
    if (sheetFem.FaceCount != 1 || !rim.All(e => e.Faces.A == 0 && e.Faces.B == uint.MaxValue))
        return Fail($"kernel fem: the sheet's rim reads {string.Join("; ", rim.Select(e => $"{e.Faces.A}/{e.Faces.B}"))}");
    var kernelMsh = fem.MshText();
    if (!kernelMsh.StartsWith("$MeshFormat")) return Fail("kernel fem: mshText is not Gmsh 4.1 ASCII");
    // Owned on this side, not borrowed: two asks give two independent texts, and neither dies
    // with the other or with the handle.
    if (fem.MshText().Length != kernelMsh.Length) return Fail("kernel fem: a second mshText disagrees with the first");
    var kernelMshPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke-kernel.msh");
    fem.SaveMsh(kernelMshPath);
    if (new FileInfo(kernelMshPath).Length < kernelMsh.Length / 2) return Fail("kernel fem: saveMsh wrote less than mshText");
    // # The kernel's placement is twelve numbers where the reader's is sixteen.
    try { rounded.FemMesh(placement: new double[16]); return Fail("kernel fem: a sixteen-number placement was accepted"); }
    catch (BuildException e) when (e.Message.Contains("12 numbers")) { }
    try { rounded.FemMesh(tolerance: 0); return Fail("kernel fem: a zero tolerance was accepted"); }
    catch (BuildException) { }
    Console.WriteLine($"kernel fem: {fem}, maxSize 3 -> {fine.Nodes.Length / 3} nodes, longestEdge {fine.LongestEdge:F3}");
    // # A freed handle refuses every accessor rather than reading the pointers it left behind:
    // the view is cached, so a property that does not ask the handle first hands out a span
    // over freed memory instead of throwing.
    var freed = rounded.FemMesh(tolerance: 0.5);
    freed.Free();
    if (!freed.Freed) return Fail("kernel fem: a freed mesh does not say so");
    freed.Free();   // idempotent
    foreach (var read in new Action[]
             {
                 () => { _ = freed.Nodes; }, () => { _ = freed.Triangles; }, () => { _ = freed.TriangleFace; },
                 () => { _ = freed.NodeKind; }, () => { _ = freed.NodeEntity; }, () => { _ = freed.FaceCount; },
                 () => { _ = freed.Edges; }, () => { _ = freed.Vertices; }, () => { _ = freed.OpenEdges; },
                 () => { _ = freed.FoldedEdges; }, () => { _ = freed.Crossings; },
                 () => { _ = freed.Watertight; }, () => { _ = freed.FromMesh; },
                 () => { _ = freed.MinAngle; }, () => { _ = freed.WorstTriangle; }, () => { _ = freed.LongestEdge; },
                 () => freed.MshText(), () => freed.SaveMsh(kernelMshPath),
             })
    {
        try { read(); return Fail("kernel fem: a freed mesh read anyway"); }
        catch (BuildException e) when (e.Message.Contains("freed")) { }
    }
    Console.WriteLine("kernel fem: a freed mesh refuses all eighteen reads");
}

// Assemblies: Assembly, Solid.Named and Solid.Name, at parity with the Python reference's
// _shared_assembly() and the tests built on it.
{
    using var asmBolt = Solid.Cylinder(1, 6).Named("bolt");
    using var asmPlate = Solid.Cuboid(20, 10, 2).Named("plate").Coloured(1, 0.5, 0);
    using var bracket = new Assembly("bracket");
    var platePlacement = bracket.Place(asmPlate, Frame.Xy());
    var bolt1Placement = bracket.Place(asmBolt, Frame.Xy((5, 5, 2)));
    var bolt2Placement = bracket.Place(asmBolt, Frame.Xy((15, 5, 2)));
    if (platePlacement != "plate" || bolt1Placement != "bolt" || bolt2Placement != "bolt 2")
        return Fail($"assembly: bracket placements were \"{platePlacement}\", \"{bolt1Placement}\", \"{bolt2Placement}\", not plate/bolt/bolt 2");

    using var asmFrame = new Assembly("frame");
    var leftPlacement = asmFrame.Place(bracket, Frame.Xy((0, 0, 0)), "left");
    var rightPlacement = asmFrame.Place(bracket, new Frame((100, 0, 0), (0, 1, 0), (-1, 0, 0), (0, 0, 1)), "right");
    var rootBoltPlacement = asmFrame.Place(asmBolt, Frame.Xy((50, 50, 0)));
    if (leftPlacement != "left" || rightPlacement != "right" || rootBoltPlacement != "bolt")
        return Fail($"assembly: frame placements were \"{leftPlacement}\", \"{rightPlacement}\", \"{rootBoltPlacement}\", not left/right/bolt");

    var frameStepText = asmFrame.StepText();
    var manifoldCount = CountOf(frameStepText, "=MANIFOLD_SOLID_BREP(");
    var productCount = CountOf(frameStepText, "=PRODUCT(");
    var nauoCount = CountOf(frameStepText, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(");
    if (manifoldCount != 2 || productCount != 4 || nauoCount != 6)
        return Fail($"assembly: frame step_text has {manifoldCount} breps, {productCount} products, {nauoCount} NAUOs, not 2/4/6");
    if (!frameStepText.Contains("'left'") || !frameStepText.Contains("'right'") || !frameStepText.Contains("'bolt 2'"))
        return Fail("assembly: frame step_text is missing 'left', 'right' or 'bolt 2'");
    Console.WriteLine($"assembly: frame writes {manifoldCount} breps, {productCount} products, {nauoCount} NAUOs");

    // Read-back, through the same reader door as Solid.ToScene -- structure only, at this
    // (pre-late-placement) text: one root "frame", two "bracket" containers each holding
    // plate/bolt/bolt, and one root-level "bolt". The world origins are Python's to check.
    using (var readScene = Cadaclysm.Cadaclysm.OpenMemory(Encoding.UTF8.GetBytes(frameStepText), "frame.stp"))
    {
        var roots = readScene.Roots;
        if (roots.Count != 1 || roots[0].Name != "frame") return Fail("assembly: the read-back root is not one node named \"frame\"");
        var rootChildren = roots[0].Children;
        if (rootChildren.Count != 3) return Fail($"assembly: the read-back root has {rootChildren.Count} children, not 3");
        var containers = rootChildren.Where(c => c.Name == "bracket").ToList();
        var rootBolts = rootChildren.Where(c => c.Name == "bolt").ToList();
        if (containers.Count != 2 || rootBolts.Count != 1)
            return Fail("assembly: the read-back root does not have two bracket containers and one bolt");
        foreach (var container in containers)
        {
            var names = container.Children.Select(c => c.Name).OrderBy(n => n, StringComparer.Ordinal).ToList();
            if (!names.SequenceEqual(new[] { "bolt", "bolt", "plate" }))
                return Fail("assembly: a read-back bracket container does not hold plate, bolt, bolt");
        }
    }
    Console.WriteLine("assembly: the read-back tree has one root, two bracket containers of plate+bolt+bolt, and one root bolt");

    // A late placement into bracket shows up wherever bracket is placed (left and right both).
    bracket.Place(asmBolt, Frame.Xy((10, 8, 2)));
    var laterNauoCount = CountOf(asmFrame.StepText(), "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(");
    if (laterNauoCount != 7) return Fail($"assembly: a late placement gave {laterNauoCount} NAUOs, not 7");
    Console.WriteLine("assembly: a late placement into bracket shows up wherever it is placed");

    // A cycle, a duplicate placement name, a mirrored frame, and an assembly (or one reachable
    // from it) that places nothing are all refused.
    try { bracket.Place(asmFrame, Frame.Xy()); return Fail("assembly: a cycle (bracket -> frame -> bracket) was accepted"); }
    catch (BuildException e) when (e.Message.Contains("bracket → frame → bracket")) { }
    try { asmFrame.Place(bracket, Frame.Xy(), "left"); return Fail("assembly: a duplicate placement name was accepted"); }
    catch (BuildException e) when (e.Message.Contains("left")) { }
    // A raw twelve-number frame, not the Frame type, which refuses a left-handed triple
    // before Place is ever called -- the one way to drive a mirrored frame into the ABI's
    // own rigidity check.
    try
    {
        asmFrame.Place(bracket, new[] { 0.0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1 });
        return Fail("assembly: a mirrored raw frame was accepted");
    }
    catch (BuildException e) when (e.Message.Contains("right-handed and orthonormal")) { }
    try { new Assembly("x").StepText(); return Fail("assembly: an empty assembly wrote step text"); }
    catch (BuildException) { }
    using (var outer = new Assembly("outer"))
    using (var hollow = new Assembly("hollow"))
    {
        outer.Place(hollow, Frame.Xy());
        try { outer.StepText(); return Fail("assembly: an assembly reachable from the root that places nothing wrote step text"); }
        catch (BuildException e) when (e.Message.Contains("hollow")) { }
    }
    Console.WriteLine("assembly: a cycle, a duplicate name, a mirrored frame, and an empty assembly are all refused");

    // Solid.Named/Solid.Name: the name rides through a one-source operation (Place, Coloured)
    // and is dropped by a two-source one (Join) or a fresh primitive.
    if (asmBolt.Name != "bolt") return Fail("assembly: bolt.Name is not \"bolt\"");
    using (var placedBolt = asmBolt.Place(Frame.Xy((1, 2, 3))))
        if (placedBolt.Name != "bolt") return Fail("assembly: bolt.Place(...).Name is not \"bolt\"");
    using (var colouredBolt = asmBolt.Coloured(1, 0, 0))
        if (colouredBolt.Name != "bolt") return Fail("assembly: bolt.Coloured(...).Name is not \"bolt\"");
    using (var joinedBolt = asmBolt.Join(Solid.Cuboid(1, 1, 1)))
        if (joinedBolt.Name is not null) return Fail("assembly: bolt.Join(...).Name is not null");
    using (var freshCube = Solid.Cuboid(1, 1, 1))
        if (freshCube.Name is not null) return Fail("assembly: a fresh cuboid's Name is not null");
    Console.WriteLine("assembly: Named/Name ride through one-source operations and drop through two-source ones");
}

// Mechanisms: Assembly.Link/Assembly.Joint, at parity with the Python reference's
// _mechanism() and its tests (test_a_mechanism_is_written_as_ap242_kinematic_topology,
// test_every_bad_link_or_joint_is_refused_and_changes_nothing).
{
    using var mechBolt = Solid.Cylinder(1, 6).Named("bolt");
    using var mechPlate = Solid.Cuboid(20, 10, 2).Named("plate");   // uncoloured
    using var mechBracket = new Assembly("bracket");
    mechBracket.Place(mechPlate, Frame.Xy());
    mechBracket.Place(mechBolt, Frame.Xy((5, 5, 2)));
    mechBracket.Place(mechBolt, Frame.Xy((15, 5, 2)));
    mechBracket.Link("fixed", "plate");
    mechBracket.Link("bolts", "bolt", "bolt 2");
    mechBracket.Joint("screw", "fixed", "bolts");

    using var arm = new Assembly("arm");
    arm.Place(mechPlate, Frame.Xy(), "base");
    arm.Place(mechBracket, Frame.Xy((0, 0, 10)), "upper");
    arm.Place(mechBolt, Frame.Xy((5, 5, 2)), "pin");
    arm.Link("ground", "base");
    arm.Link("upper arm", "upper", "pin");
    arm.Joint("shoulder", "ground", "upper arm");

    // Fact 1: the default schema (no explicit schema) carries the kinematic entities.
    var armStepText = arm.StepText();
    if (!armStepText.Contains("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"))
        return Fail("mechanism: arm.StepText() does not name AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF");
    var linkCount = CountOf(armStepText, "=KINEMATIC_LINK(");
    var rigidCount = CountOf(armStepText, "=RIGID_LINK_REPRESENTATION(");
    var cdklrCount = CountOf(armStepText, "=CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION(");
    var jointCount = CountOf(armStepText, "=KINEMATIC_JOINT(");
    var topoCount = CountOf(armStepText, "=KINEMATIC_TOPOLOGY_STRUCTURE(");
    if (linkCount != 4 || rigidCount != 6 || cdklrCount != 6 || jointCount != 2 || topoCount != 2)
        return Fail($"mechanism: arm.StepText() has {linkCount} links, {rigidCount} rigid reps, " +
            $"{cdklrCount} context-dependent reps, {jointCount} joints, {topoCount} topologies, not 4/6/6/2/2");
    Console.WriteLine($"mechanism: arm.StepText() writes {linkCount} links, {rigidCount} rigid reps, " +
        $"{cdklrCount} context-dependent reps, {jointCount} joints, {topoCount} topologies");

    // Fact 2: an explicit schema without kinematic entities is refused.
    try { arm.StepText("config_control_design"); return Fail("mechanism: config_control_design wrote a mechanism"); }
    catch (BuildException e) when (e.Message.Contains("no kinematic entities")) { }
    Console.WriteLine("mechanism: an explicit schema without kinematic entities is refused");

    // Fact 3: each of the eleven refusals raises with exactly its message, and afterwards
    // the STEP text (with FILE_NAME( lines stripped) is unchanged.
    static string NoStamp(string text) =>
        string.Join("\n", text.Split('\n').Where(l => !l.StartsWith("FILE_NAME(")));
    var before = NoStamp(arm.StepText());
    var refusals = new (Action Call, string Message)[]
    {
        (() => arm.Link("", "base"), "link: a name cannot be empty"),
        (() => arm.Link("ground", "base"), "link: assembly 'arm' already has a link named 'ground'"),
        (() => arm.Link("free"), "link: link 'free' names no placements"),
        (() => arm.Link("free", "base", "base"), "link: link 'free' names placement 'base' twice"),
        (() => arm.Link("free", "bolt"), "link: assembly 'arm' has no placement named 'bolt'"),
        (() => arm.Link("free", "pin"), "link: placement 'pin' of assembly 'arm' is already in link 'upper arm'"),
        (() => arm.Joint("", "ground", "upper arm"), "joint: a name cannot be empty"),
        (() => arm.Joint("shoulder", "upper arm", "ground"), "joint: assembly 'arm' already has a joint named 'shoulder'"),
        (() => arm.Joint("wrist", "ground", "hand"), "joint: assembly 'arm' has no link named 'hand'"),
        (() => arm.Joint("wrist", "ground", "ground"), "joint: joint 'wrist' joins link 'ground' to itself"),
        (() => arm.Joint("wrist", "ground", "upper arm"), "joint: assembly 'arm' already joins 'ground' to 'upper arm'"),
    };
    foreach (var (call, message) in refusals)
    {
        try { call(); return Fail($"mechanism: \"{message}\" was accepted"); }
        catch (BuildException e) when (e.Message == message) { }
    }
    if (NoStamp(arm.StepText()) != before) return Fail("mechanism: a refused link or joint changed the assembly");
    Console.WriteLine("mechanism: all eleven bad links and joints are refused with their exact message, unchanged");

    // Fact 5: read-back through the reader, before fact 4 adds "back" -- arm.ToScene()
    // carries the same links and joints back in, by name and node count, with no
    // kinematics diagnostic. (The Python reference checks this on a fresh _mechanism()
    // build, i.e. before the reverse-pair joint exists; done here in place, ahead of
    // fact 4, so it sees the same two joints.)
    using (var mechScene = arm.ToScene())
    {
        var mechLinks = mechScene.Links;
        if (!mechLinks.Select(l => l.Name).SequenceEqual(new[] { "fixed", "bolts", "ground", "upper arm" }))
            return Fail("mechanism: read-back links are not [fixed, bolts, ground, upper arm]");
        if (!mechLinks.Select(l => l.Nodes.Count).SequenceEqual(new[] { 1, 2, 1, 2 }))
            return Fail("mechanism: read-back link node counts are not [1, 2, 1, 2]");
        var mechJoints = mechScene.Joints;
        if (mechJoints.Count != 2 ||
            mechJoints[0].Name != "screw" || mechJoints[0].Start.Index != 0 || mechJoints[0].End.Index != 1 ||
            mechJoints[1].Name != "shoulder" || mechJoints[1].Start.Index != 2 || mechJoints[1].End.Index != 3)
            return Fail("mechanism: read-back joints are not (screw, 0, 1) and (shoulder, 2, 3)");
        if (mechScene.Diagnostics.Any(d => d.StartsWith("kinematics:")))
            return Fail("mechanism: read-back carries a kinematics: diagnostic");
        Console.WriteLine("mechanism: read-back through arm.ToScene() matches links, joints and diagnostics");
    }

    // Pairs: Assembly.Pair/Assembly.State/Assembly.Base and the free PairFreedomCount, at
    // parity with the Python reference's _paired() fixture and its tests (spec 2026-09-29).
    // Built on bracket/arm before "back" is added below: a joint with no pair refuses
    // StepText(), so facts 1-6 and 9's diagnostics check need arm without it.
    static bool NearValue(double a, double b) => Math.Abs(a - b) <= 1e-9;

    mechBracket.Pair("screw", "prismatic", Frame.Xy((1, 2, 3)), endFrame: Frame.Xy((4, 2, 3)));
    arm.Pair("shoulder", "revolute", Frame.Xy((0, 0, 10)), ranges: new (double? Lower, double? Upper)[] { (-1.5, 1.5) });
    arm.State("reach", new (string Joint, IReadOnlyList<double> Values)[] { ("shoulder", new double[] { 0.5 }) });
    arm.Base("ground");

    // Assembly.Posed (spec 2026-10-05): a new assembly with joints moved; this one unchanged.
    {
        static (string Joint, IReadOnlyList<double> Values) Row(string joint, params double[] values) => (joint, values);
        var armBefore = NoStamp(arm.StepText());
        using (var upperScene = arm.ToScene())
        {
            var upper = upperScene.Links.Single(l => l.Name == "upper arm");
            var pinIndex = upper.Nodes.Single(n => Math.Abs(n.Transform[0, 3] - 5.0) <= 1e-9
                && Math.Abs(n.Transform[1, 3] - 5.0) <= 1e-9 && Math.Abs(n.Transform[2, 3] - 2.0) <= 1e-9).Index;
            using var posedArm = arm.Posed(new[] { Row("shoulder", 0.5) });
            using var posedScene = posedArm.ToScene();
            var pt = posedScene.Nodes[(int)pinIndex].Transform;
            var wantX = 5 * Math.Cos(0.5) - 5 * Math.Sin(0.5);
            var wantY = 5 * Math.Sin(0.5) + 5 * Math.Cos(0.5);
            if (!(NearValue(pt[0, 3], wantX) && NearValue(pt[1, 3], wantY) && NearValue(pt[2, 3], 2.0)))
                return Fail("posed: the shoulder did not carry the pin to the hand-computed spot");
            var restBolts = upperScene.Links.Where(l => l.Name == "bolts").SelectMany(l => l.Nodes)
                .ToDictionary(n => n.Index, n => (X: n.Transform[0, 3], Y: n.Transform[1, 3], Z: n.Transform[2, 3]));
            using var slid = arm.Posed(new[] { Row("upper/screw", 5.0) });
            using var slidScene = slid.ToScene();
            foreach (var l in slidScene.Links.Where(l => l.Name == "bolts"))
                foreach (var n in l.Nodes)
                {
                    var r = restBolts[n.Index];
                    if (!(NearValue(n.Transform[0, 3], r.X + 2.0) && NearValue(n.Transform[1, 3], r.Y)
                          && NearValue(n.Transform[2, 3], r.Z)))
                        return Fail("posed: the screw did not slide the bolts by 2");
                }
        }
        Console.WriteLine("posed: the shoulder carries the pin and the screw slides the bolts, read back through the scene");

        using (var reachPosed = arm.Posed(state: "reach"))
        using (var rowPosed = arm.Posed(new[] { Row("shoulder", 0.5) }))
        using (var heldPosed = arm.Posed(new[] { Row("shoulder", 0.5) }, ground: "upper arm"))
        {
            if (NoStamp(reachPosed.StepText()) != NoStamp(rowPosed.StepText()))
                return Fail("posed: state \"reach\" differs from shoulder = [0.5]");
            if (NoStamp(heldPosed.StepText()) == NoStamp(rowPosed.StepText()))
                return Fail("posed: ground \"upper arm\" made no difference");
        }
        try { arm.Posed(new[] { Row("shoulder", 2.0) }); return Fail("posed: shoulder = 2.0 was accepted"); }
        catch (BuildException e) when (e.Message == "posed: value 0 of joint 'shoulder' is 2, outside its range") { }
        catch (BuildException e) { return Fail("posed: wrong range refusal: " + e.Message); }
        try { arm.Posed(state: "fold"); return Fail("posed: state \"fold\" was accepted"); }
        catch (BuildException e) when (e.Message == "posed: assembly 'arm' has no state named 'fold'") { }
        catch (BuildException e) { return Fail("posed: wrong state refusal: " + e.Message); }
        if (NoStamp(arm.StepText()) != armBefore) return Fail("posed: posing changed the assembly");
        Console.WriteLine("posed: a state, a ground, and the kernel's own refusals (range, unknown state)");

        // Two copies of a bracket whose bolts turn on 'turn'; one copy is named 'right/rear'.
        using var turnBolt = Solid.Cuboid(1, 1, 6).Named("bolt");
        using var turnPlate = Solid.Cuboid(20, 10, 2).Named("plate");
        using var turnBracket = new Assembly("bracket");
        turnBracket.Place(turnPlate, Frame.Xy());
        turnBracket.Place(turnBolt, Frame.Xy((5, 5, 2)));
        turnBracket.Link("fixed", "plate");
        turnBracket.Link("bolts", "bolt");
        turnBracket.Joint("turn", "fixed", "bolts");
        turnBracket.Pair("turn", "revolute", Frame.Xy((10, 5, 2)));
        using var turnFrame = new Assembly("frame");
        turnFrame.Place(turnBracket, Frame.Xy(), "left");
        turnFrame.Place(turnBracket, Frame.Xy((100, 0, 0)), "right/rear");
        var frameBefore = NoStamp(turnFrame.StepText());
        try { turnFrame.Posed(new[] { Row("turn", 0.3) }); return Fail("posed: an ambiguous name was accepted"); }
        catch (BuildException e) when (e.Message == "posed: 'turn' names 2 joints: left/turn, right\\/rear/turn; give one by its path") { }
        catch (BuildException e) { return Fail("posed: wrong ambiguity refusal: " + e.Message); }
        using (var turned = turnFrame.Posed(new[] { Row("right\\/rear/turn", 0.3) }))
        using (var unturned = turnFrame.Posed(new[] { Row("right\\/rear/turn", 0.0) }))
        {
            if (turned.Name != "frame") return Fail("posed: the posed copy is not named frame");
            if (NoStamp(turned.StepText()) == frameBefore) return Fail("posed: turning right/rear changed nothing");
            if (NoStamp(unturned.StepText()) != frameBefore) return Fail("posed: turning by 0.0 changed the frame");
        }
        if (NoStamp(turnFrame.StepText()) != frameBefore) return Fail("posed: posing changed the frame");
        Console.WriteLine("posed: a bare ambiguous name is refused naming both paths; a path with an escaped slash poses one");
    }

    // Fact 1: the pair/state entity counts in the default schema.
    var pairedStepText = arm.StepText();
    var mechReprCount = CountOf(pairedStepText, "=MECHANISM_REPRESENTATION(");
    var pairRelCount = CountOf(pairedStepText, "=PAIR_REPRESENTATION_RELATIONSHIP(");
    var revoluteRangeCount = CountOf(pairedStepText, "REVOLUTE_PAIR_WITH_RANGE");
    var prismaticCount = CountOf(pairedStepText, "PRISMATIC_PAIR");
    var kinPropCount = CountOf(pairedStepText, "=KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION(");
    var mechStateCount = CountOf(pairedStepText, "=MECHANISM_STATE_REPRESENTATION(");
    if (mechReprCount != 2 || pairRelCount != 2 || revoluteRangeCount != 1 || prismaticCount != 1
        || kinPropCount != 1 || mechStateCount != 1)
        return Fail($"pairs: arm.StepText() has {mechReprCount} mechanism reps, {pairRelCount} pair rels, " +
            $"{revoluteRangeCount} revolute-with-range, {prismaticCount} prismatic, {kinPropCount} kinematic " +
            $"property reps, {mechStateCount} mechanism states, not 2/2/1/1/1/1");
    Console.WriteLine($"pairs: arm.StepText() writes {mechReprCount} mechanism reps, {pairRelCount} pair rels, " +
        $"{revoluteRangeCount} revolute-with-range, {prismaticCount} prismatic, {kinPropCount} kinematic " +
        $"property reps, {mechStateCount} mechanism states");

    // Facts 2-6 and 9 (diagnostics half): read back through the reader.
    using (var pairedScene = arm.ToScene())
    {
        var shoulder = pairedScene.Joints.Single(j => j.Name == "shoulder");
        var shoulderPair = shoulder.Pair ?? throw new Exception("pairs: shoulder has no pair");
        if (shoulderPair.Kind != PairKind.Revolute) return Fail("pairs: shoulder's pair is not revolute");
        foreach (var frame in new[] { shoulderPair.FrameStart, shoulderPair.FrameEnd })
            if (!NearValue(frame[0, 3], 0.0) || !NearValue(frame[1, 3], 0.0) || !NearValue(frame[2, 3], 10.0)
                || !NearValue(frame[0, 2], 0.0) || !NearValue(frame[1, 2], 0.0) || !NearValue(frame[2, 2], 1.0))
                return Fail("pairs: shoulder's pair frames are not at (0,0,10) with z (0,0,1)");
        var shoulderFreedoms = shoulderPair.Freedoms;
        if (shoulderFreedoms.Count != 1 || shoulderFreedoms[0].Motion != Motion.Rotation
            || shoulderFreedoms[0].Axis != FreedomAxis.Z
            || shoulderFreedoms[0].Lower is not { } shoulderLower || !NearValue(shoulderLower, -1.5)
            || shoulderFreedoms[0].Upper is not { } shoulderUpper || !NearValue(shoulderUpper, 1.5))
            return Fail("pairs: shoulder's pair is not one rotation-about-z freedom ranged [-1.5, 1.5]");
        Console.WriteLine("pairs: shoulder's pair is revolute, one rotation-about-z freedom ranged [-1.5, 1.5]");

        var screw = pairedScene.Joints.Single(j => j.Name == "screw");
        var screwPair = screw.Pair ?? throw new Exception("pairs: screw has no pair");
        if (screwPair.Kind != PairKind.Prismatic) return Fail("pairs: screw's pair is not prismatic");
        if (screwPair.Freedoms.Any(f => f.Lower is not null || f.Upper is not null))
            return Fail("pairs: screw's pair has a ranged freedom");
        if (!NearValue(screwPair.FrameStart[0, 3], 1.0) || !NearValue(screwPair.FrameStart[1, 3], 2.0) || !NearValue(screwPair.FrameStart[2, 3], 13.0)
            || !NearValue(screwPair.FrameEnd[0, 3], 4.0) || !NearValue(screwPair.FrameEnd[1, 3], 2.0) || !NearValue(screwPair.FrameEnd[2, 3], 13.0))
            return Fail("pairs: screw's pair frames are not (1,2,13) to (4,2,13)");
        Console.WriteLine("pairs: screw's pair is prismatic with no ranges, frames (1,2,13) to (4,2,13)");

        if (pairedScene.Base is not { } pairedBaseLink || pairedBaseLink.Name != "ground")
            return Fail("pairs: the scene's base is not 'ground'");
        var pairedStates = pairedScene.States;
        if (pairedStates.Count != 1 || pairedStates[0].Name != "reach")
            return Fail("pairs: the scene does not carry exactly one state named 'reach'");
        var reachValues = pairedStates[0].Values;
        if (reachValues.Count != 1 || reachValues[0].Joint.Name != "shoulder"
            || reachValues[0].Values.Count != 1 || !NearValue(reachValues[0].Values[0], 0.5))
            return Fail("pairs: state 'reach' is not exactly one row (shoulder, [0.5])");
        Console.WriteLine("pairs: the scene's base is 'ground', with one state 'reach' of (shoulder, [0.5])");

        // Fact 5: pose_state(reach) carries the pin node to (5cos0.5-5sin0.5, 5sin0.5+5cos0.5, 2).
        var reachPose = pairedScene.PoseState(pairedStates[0]);
        var upperArmLink = pairedScene.Links.Single(l => l.Name == "upper arm");
        var pinNode = upperArmLink.Nodes.Single(n => NearValue(n.Transform[0, 3], 5.0) && NearValue(n.Transform[1, 3], 5.0) && NearValue(n.Transform[2, 3], 2.0));
        var posedPin = reachPose.Transform(pinNode);
        var wantX = 5 * Math.Cos(0.5) - 5 * Math.Sin(0.5);
        var wantY = 5 * Math.Sin(0.5) + 5 * Math.Cos(0.5);
        if (!NearValue(posedPin[0, 3], wantX) || !NearValue(posedPin[1, 3], wantY) || !NearValue(posedPin[2, 3], 2.0))
            return Fail("pairs: pose_state(reach) did not carry the pin node to the expected point");
        Console.WriteLine("pairs: pose_state(reach) carries the pin node to the expected point");

        // Fact 6: pose([(screw, [3.0])]) leaves every 'bolts' node at rest; [5.0] moves by (2,0,0).
        var pose3 = pairedScene.Pose(new[] { (screw, (IReadOnlyList<double>)new double[] { 3.0 }) });
        var pose5 = pairedScene.Pose(new[] { (screw, (IReadOnlyList<double>)new double[] { 5.0 }) });
        var bolts = pairedScene.Links.Single(l => l.Name == "bolts");
        foreach (var node in bolts.Nodes)
        {
            var rest = node.Transform;
            var at3 = pose3.Transform(node);
            var at5 = pose5.Transform(node);
            if (!NearValue(at3[0, 3], rest[0, 3]) || !NearValue(at3[1, 3], rest[1, 3]) || !NearValue(at3[2, 3], rest[2, 3]))
                return Fail("pairs: pose([(screw, [3.0])]) moved a 'bolts' node off rest");
            if (!NearValue(at5[0, 3], rest[0, 3] + 2.0) || !NearValue(at5[1, 3], rest[1, 3]) || !NearValue(at5[2, 3], rest[2, 3]))
                return Fail("pairs: pose([(screw, [5.0])]) did not move a 'bolts' node by (2,0,0)");
        }
        Console.WriteLine("pairs: pose([(screw, [3.0])]) rests, pose([(screw, [5.0])]) moves 'bolts' by (2,0,0)");

        // Fact 9 (diagnostics half): no diagnostic names kinematics.
        if (pairedScene.Diagnostics.Any(d => d.StartsWith("kinematics:")))
            return Fail("pairs: the paired scene carries a kinematics: diagnostic");
    }

    // Motion sequences, written: a state rest and a swing over rest and reach, read back.
    arm.State("rest", new (string Joint, IReadOnlyList<double> Values)[] { ("shoulder", new double[] { 0.0 }) });
    arm.Sequence("swing", new (string State, double T, string Interpolation)[] { ("rest", 0.0, "linear"), ("reach", 1.0, "linear") }, seconds: true);
    using (var swingScene = arm.ToScene())
    {
        var written = swingScene.Sequences;
        if (written.Count != 1 || written[0].Name != "swing" || !written[0].Closed || written[0].SecondsPerUnit != 1.0)
            return Fail("sequences: the written swing did not read back closed at 1 second per unit");
        var writtenSegments = written[0].Segments.Select(g => (g.State.Name, g.T, g.Interpolation)).ToArray();
        if (!writtenSegments.SequenceEqual(new (string, double, string)[] { ("rest", 0, "linear"), ("reach", 1, "linear") }))
            return Fail("sequences: the written swing's segments are " + string.Join(", ", writtenSegments));
    }
    try
    {
        arm.Sequence("bad", new (string State, double T, string Interpolation)[] { ("rest", 0.0, "linear"), ("nowhere", 1.0, "linear") });
        return Fail("sequences: a sequence over an unknown state was accepted");
    }
    catch (BuildException e) when (e.Message == "sequence: assembly 'arm' has no state named 'nowhere'") { }
    Console.WriteLine("sequences: Assembly.Sequence round-trips and refuses an unknown state exactly");

    // Fact 4: the reverse pair is a new joint.
    arm.Joint("back", "upper arm", "ground");
    Console.WriteLine("mechanism: the reverse pair (\"back\") is accepted as a new joint");

    // Fact 7: the eight bad pair/state/base calls are refused with exactly their message,
    // and Fact 8's unpaired-joint refusal ("back" has no pair) stays byte-identical before
    // and after -- proof none of them mutated "back", or anything else StepText() would
    // notice, even though a wholly valid StepText() snapshot is unavailable while "back" has
    // no pair.
    string PairedUnpairedMessage()
    {
        try { arm.StepText(); throw new Exception("pairs: arm.StepText() with an unpaired joint 'back' was accepted"); }
        catch (BuildException e) { return e.Message; }
    }
    var pairedBefore = PairedUnpairedMessage();
    var pairRefusals = new (Action Call, string Message)[]
    {
        (() => arm.Pair("shoulder", "revolute", Frame.Xy((0, 0, 10))), "pair: joint 'shoulder' already has a pair"),
        (() => arm.Pair("back", "orbital", Frame.Xy()),
            "pair: 'orbital' is not a pair kind (revolute, prismatic, cylindrical, screw, gear, rack_and_pinion, spherical, " +
            "spherical_with_pin, planar, universal, homokinetic, fully_constrained, unconstrained)"),
        (() => arm.Pair("back", "screw", Frame.Xy()), "pair: a screw needs a non-zero pitch"),
        (() => arm.Pair("back", "revolute", Frame.Xy(), ranges: new (double? Lower, double? Upper)[] { (-1, 1), (-1, 1) }),
            "pair: 'revolute' has 1 freedoms, but 2 ranges were given"),
        (() => arm.Pair("back", "revolute", Frame.Xy(), ranges: new (double? Lower, double? Upper)[] { (1, -1) }),
            "pair: range 0 of joint 'back' has lower >= upper"),
        (() => arm.Pair("back", "prismatic", Frame.At((0, 0, 0), (0, 0, 1), (0, 1, 0)), endFrame: Frame.Xy()),
            "pair: joint 'back' is prismatic, but its end frame is turned 90° about -z, " +
            "which prismatic (does not turn) cannot make"),
        (() => arm.State("overreach", new (string Joint, IReadOnlyList<double> Values)[] { ("shoulder", new double[] { 5.0 }) }),
            "state: value 0 of joint 'shoulder' is outside its range"),
        (() => arm.Base("upper arm"), "base: assembly 'arm' already has base 'ground'"),
    };
    foreach (var (call, message) in pairRefusals)
    {
        try { call(); return Fail($"pairs: \"{message}\" was accepted"); }
        catch (BuildException e) when (e.Message == message) { }
    }
    Console.WriteLine("pairs: all eight bad pair/state/base calls are refused with their exact message");

    // Fact 8: after "back" alone (added above), StepText() is refused with exactly this
    // message -- Fact 7 already computed it as the before/after snapshot; checked here
    // against the brief's exact text.
    const string NoPairMessage =
        "assembly_step: assembly 'arm': joint 'back' has no pair; a mechanism with pairs needs one on every joint (AP242)";
    if (pairedBefore != NoPairMessage)
        return Fail($"pairs: StepText()'s unpaired-joint refusal is \"{pairedBefore}\", not the expected text");
    var pairedAfter = PairedUnpairedMessage();
    if (pairedAfter != pairedBefore) return Fail("pairs: a refused pair/state/base call changed the unpaired-joint refusal");
    Console.WriteLine("pairs: joint 'back' with no pair refuses StepText() with exactly its message, unchanged by any refusal above");

    // Fact 9 (freedom-count half): PairFreedomCount.
    if (Blacksmith.PairFreedomCount("spherical") != 3 || Blacksmith.PairFreedomCount("revolute") != 1
        || Blacksmith.PairFreedomCount("fully_constrained") != 0 || Blacksmith.PairFreedomCount("not_a_kind") != 0)
        return Fail("pairs: Blacksmith.PairFreedomCount does not give 3/1/0/0 for spherical/revolute/fully_constrained/unknown");
    Console.WriteLine("pairs: Blacksmith.PairFreedomCount gives 3/1/0/0 for spherical/revolute/fully_constrained/an unknown name");

    // Fact 10 (controller ruling, added after review): a one-sided range survives the
    // round trip. Without has_lower/has_upper actually carried (an implementation that
    // always sends true for both would pass every other fact), joint "j"'s freedom would
    // come back with a lower limit it was never given.
    using (var hinge = new Assembly("hinge"))
    {
        hinge.Place(mechPlate, Frame.Xy(), "base");
        hinge.Place(mechBolt, Frame.Xy((0, 0, 2)), "arm");
        hinge.Link("base", "base");
        hinge.Link("arm", "arm");
        hinge.Joint("j", "base", "arm");
        hinge.Pair("j", "revolute", Frame.Xy(), ranges: new (double? Lower, double? Upper)[] { (null, 1.0) });
        using var hingeScene = hinge.ToScene();
        var hingeJoint = hingeScene.Joints.Single(j => j.Name == "j");
        var hingeFreedoms = (hingeJoint.Pair ?? throw new Exception("pairs: hinge joint 'j' has no pair")).Freedoms;
        if (hingeFreedoms.Count != 1 || hingeFreedoms[0].Lower is not null
            || hingeFreedoms[0].Upper is not { } hingeUpper || !NearValue(hingeUpper, 1.0))
            return Fail("pairs: hinge joint 'j' is not one freedom with no lower limit and upper exactly 1.0");
        Console.WriteLine("pairs: a one-sided range (no lower, upper 1.0) survives the round trip");
    }

}

// Drives plan 4: a gear pair round-trips and poses from its driver; pair_with refuses a wrong
// parameter count. Port of the Python _geared() fixture and its two tests.
{
    Assembly Geared(bool mesh)
    {
        using var gPlate = Solid.Cuboid(40, 10, 2).Named("plate");
        using var gPin = Solid.Cylinder(1, 6).Named("pin");
        using var gHub = Solid.Cylinder(2, 4).Named("hub");
        var gears = new Assembly("gears");
        gears.Place(gPlate, Frame.Xy(), "frame");
        gears.Place(gPin, Frame.Xy((0, 0, 2)), "pinion");
        gears.Place(gHub, Frame.Xy((35, 0, 2)), "wheel");
        gears.Link("base", "frame");
        gears.Link("driver", "pinion");
        gears.Link("follower", "wheel");
        gears.Joint("drive", "base", "driver");
        gears.Joint("driven", "base", "follower");
        gears.Joint("mesh", "driver", "follower");
        gears.Pair("drive", "revolute", Frame.Xy((0, 0, 2)));
        gears.Pair("driven", "revolute", Frame.Xy((30, 0, 2)));
        if (mesh) gears.PairWith("mesh", "gear", Frame.Xy((0, 0, 2)), parameters: new[] { 10, 20, -0.5, 0.25, 0.125 });
        return gears;
    }

    using (var gears = Geared(true))
    using (var gearScene = gears.ToScene())
    {
        var gj = gearScene.Joints.ToDictionary(j => j.Name);
        var meshPair = gj["mesh"].Pair ?? throw new Exception("gears: mesh has no pair");
        if (meshPair.Kind != PairKind.Other || meshPair.KindName != "gear")
            return Fail($"gears: mesh pair is {meshPair.Kind}/{meshPair.KindName}, not Other/gear");
        var want5 = new[] { 10, 20, -0.5, 0.25, 0.125 };
        if (meshPair.Parameters.Count != 5 || !meshPair.Parameters.Zip(want5, (a, b) => Math.Abs(a - b) <= 1e-9).All(x => x))
            return Fail("gears: mesh parameters are not [10, 20, -0.5, 0.25, 0.125]");
        var drivePair = gj["drive"].Pair!;
        if (drivePair.KindName != "revolute" || drivePair.Parameters.Count != 0)
            return Fail("gears: drive is not revolute with no parameters");

        var driven0 = gearScene.Pose(new[] { (gj["drive"], (IReadOnlyList<double>)new double[] { 0.4 }) });
        if (driven0.Diagnostics.Count != 0 || driven0.Unsolved.Count != 0)
            return Fail("gears: a driver-only pose reported diagnostics or unsolved joints");
        var wheelNode = gearScene.Links[2].Nodes[0];
        var wt = driven0.Transform(wheelNode);
        if (!(Math.Abs(wt[0, 3] - (30 + 5 * Math.Cos(-0.2))) <= 1e-9 && Math.Abs(wt[1, 3] - 5 * Math.Sin(-0.2)) <= 1e-9
              && Math.Abs(wt[2, 3] - 2.0) <= 1e-9))
            return Fail("gears: the wheel is not where the ratio puts it");

        var both = gearScene.Pose(new[] {
            (gj["drive"], (IReadOnlyList<double>)new double[] { 0.4 }),
            (gj["driven"], (IReadOnlyList<double>)new double[] { 0.4 }) });
        if (both.Diagnostics.Count != 1
            || !both.Diagnostics[0].StartsWith("coupling 'mesh': both 'drive' and 'driven' are given and disagree by"))
            return Fail("gears: disagreeing driver and driven did not give the one coupling diagnostic: "
                + string.Join(" | ", both.Diagnostics));
        Console.WriteLine("gears: a gear pair round-trips (other/gear, 5 params) and poses from its driver, one diagnostic when over-given");
    }

    using (var noMesh = Geared(false))
    {
        try { noMesh.PairWith("mesh", "gear", Frame.Xy(), parameters: new double[] { 10, 20 }); return Fail("gears: PairWith accepted two parameters"); }
        catch (BuildException e) when (e.Message == "pair: a gear takes 3 or 5 parameters, not 2") { }
        catch (BuildException e) { return Fail("gears: wrong refusal text: " + e.Message); }
        noMesh.PairWith("mesh", "gear", Frame.Xy(), parameters: new double[] { 10, 20, -0.5 });
        Console.WriteLine("gears: PairWith refuses a wrong parameter count in the kernel's words, and takes three");
    }

    using (var posedGears = Geared(true))
    {
        static (string Joint, IReadOnlyList<double> Values) GRow(string joint, double v) => (joint, new[] { v });
        static string Bare(string text) => string.Join("\n", text.Split('\n').Where(l => !l.StartsWith("FILE_NAME(")));
        var gearsBefore = Bare(posedGears.StepText());
        using (var driven = posedGears.Posed(new[] { GRow("drive", 0.4) }))
            if (driven.Name != "gears") return Fail("gears: Posed from the driver alone is not named gears");
        try
        {
            posedGears.Posed(new[] { GRow("drive", 0.4), GRow("driven", 0.4) });
            return Fail("gears: Posed accepted a disagreeing driver and driven");
        }
        catch (BuildException e) when (e.Message.StartsWith(
            "posed: assembly 'gears': coupling 'mesh': both 'drive' and 'driven' are given and disagree by")) { }
        catch (BuildException e) { return Fail("gears: wrong Posed refusal: " + e.Message); }
        if (Bare(posedGears.StepText()) != gearsBefore) return Fail("gears: Posed changed the assembly");
        Console.WriteLine("gears: Posed from the driver alone succeeds; a disagreeing driver and driven is refused in the kernel's words");
    }
}

// SVG: the library's own camera, no viewer -- the reader (a scene, a node) and the kernel
// (a solid) each write a wireframe. `fov = 200` is a refusal both ABIs word the same way.
var svgText = scene.SvgText();
if (!svgText.StartsWith("<svg") || !svgText.Contains("<path")) return Fail("scene SVG text did not look like an SVG wireframe");
var svgPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke.svg");
scene.Svg(svgPath);
if (new FileInfo(svgPath).Length == 0) return Fail("Scene.Svg wrote an empty file");
var nodeSvgText = first.SvgText();
if (!nodeSvgText.StartsWith("<svg") || !nodeSvgText.Contains("<path")) return Fail("node SVG text did not look like an SVG wireframe");
try { scene.SvgText(new Cadaclysm.SvgOptions { Fov = 200 }); return Fail("scene svg: fov=200 was accepted"); }
catch (CadaclysmException) { }
var namedSvgText = scene.SvgText(new Cadaclysm.SvgOptions { Stroke = "Red" });
if (!namedSvgText.Contains("stroke=\"#ff0000\"")) return Fail("scene svg: Stroke = \"Red\" did not come back #ff0000");
if (Cadaclysm.Cadaclysm.Packed("navy") != 0x000080u) return Fail("Cadaclysm.Packed(\"navy\") is not 0x000080");
// Background takes colour text directly, and Stroke a packed number, each through SvgColour.
var textBackground = scene.SvgText(new Cadaclysm.SvgOptions { Stroke = 0x00FF00, Background = "Navy" });
if (!textBackground.Contains("#000080")) return Fail("scene svg: Background = \"Navy\" did not come back #000080");
if (!textBackground.Contains("stroke=\"#00ff00\"")) return Fail("scene svg: Stroke = 0x00FF00 did not come back #00ff00");
try { scene.SvgText(new Cadaclysm.SvgOptions { Background = "bogus" }); return Fail("scene svg: Background = \"bogus\" was accepted"); }
catch (CadaclysmException e) when (e.Message.StartsWith("svg: background:")) { }
Console.WriteLine("svg: scene and node text, file written, fov=200 refused, a CSS colour name stroke");

var solidSvgText = rounded.SvgText();
if (!solidSvgText.StartsWith("<svg") || !solidSvgText.Contains("<path")) return Fail("solid SVG text did not look like an SVG wireframe");
var solidSvgPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke-solid.svg");
rounded.Svg(solidSvgPath);
if (new FileInfo(solidSvgPath).Length == 0) return Fail("Solid.Svg wrote an empty file");
try { rounded.SvgText(new Cadaclysm.Blacksmith.SvgOptions { Fov = 200 }); return Fail("blacksmith svg: fov=200 was accepted"); }
catch (BuildException) { }
var paintedSvgText = rounded.SvgText(new Cadaclysm.Blacksmith.SvgOptions { Stroke = "red", Background = Blacksmith.Packed("navy") });
if (!paintedSvgText.ToLowerInvariant().Contains("#ff0000")) return Fail("blacksmith svg: Stroke = \"red\" did not come back #ff0000");
if (!paintedSvgText.Contains("#000080")) return Fail("blacksmith svg: Background = Packed(\"navy\") did not come back #000080");
var textPaintedSvg = rounded.SvgText(new Cadaclysm.Blacksmith.SvgOptions { Stroke = 0x00FF00, Background = "Navy" });
if (!textPaintedSvg.Contains("#000080")) return Fail("blacksmith svg: Background = \"Navy\" did not come back #000080");
if (!textPaintedSvg.ToLowerInvariant().Contains("#00ff00")) return Fail("blacksmith svg: Stroke = 0x00FF00 did not come back #00ff00");
try { rounded.SvgText(new Cadaclysm.Blacksmith.SvgOptions { Background = "bogus" }); return Fail("blacksmith svg: Background = \"bogus\" was accepted"); }
catch (BuildException e) when (e.Message.StartsWith("svg: background:")) { }
Console.WriteLine("blacksmith svg: solid text, file written, fov=200 refused, a CSS colour name stroke and Packed background");

// A profile draws its own plane, top by default -- unlike a solid, a sketch has no camera-
// facing convention of its own, so its plane (z = 0) is already the page. The default is
// pinned against an explicit iso view, not just checked non-empty: a top default silently
// left at iso would make the two calls identical and this comparison would pass wrongly.
var profileSvgText = rect.SvgText();
if (!profileSvgText.StartsWith("<svg") || !profileSvgText.Contains("<path")) return Fail("profile SVG text did not look like an SVG wireframe");
if (profileSvgText == rect.SvgText(new Cadaclysm.Blacksmith.SvgOptions { View = Cadaclysm.Blacksmith.SvgView.Iso }))
    return Fail("profile svg: top default did not differ from an explicit iso view");
var profileSvgPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke-profile.svg");
rect.Svg(profileSvgPath);
if (new FileInfo(profileSvgPath).Length == 0) return Fail("Profile.Svg wrote an empty file");
Console.WriteLine("blacksmith svg: profile text, file written, top default confirmed against iso");

// The module writer draws a solid and a profile on one page: one <g> per drawable, an id
// each -- the overload `WriteSvgText`/`WriteSvg` take, widened from the solids-only ones.
var mixedSvgText = Blacksmith.WriteSvgText(new[] { rounded }, new[] { rect });
if (!mixedSvgText.Contains("<path") || !mixedSvgText.Contains("id=\"solid-0\"") || !mixedSvgText.Contains("id=\"profile-0\""))
    return Fail("mixed solid+profile SVG did not carry both group ids");
var mixedSvgPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke-mixed.svg");
Blacksmith.WriteSvg(mixedSvgPath, new[] { rounded }, new[] { rect });
if (new FileInfo(mixedSvgPath).Length == 0) return Fail("WriteSvg (solids and profiles) wrote an empty file");
Console.WriteLine("blacksmith svg: solid and profile drawn together, both group ids present");

// ---- silhouette_beziers, both libraries ------------------------------------------------------
// The curves where a body's surfaces turn away from the eye. The kernel assertions below are on
// values that pin the layout, not on shapes: a stride-16 unpack with the weights read as a
// coordinate, or the points shifted a slice, still gives arrays of the right length.
{
    // Kernel. A radius-2 sphere's rim: the end points of every arc lie ON the sphere to 1e-9
    // (radius 2), and the end weights are exactly 1 with the two interior ones in (0, 1). The
    // interior control points are not checked, and the interior weights only to lie in (0, 1):
    // both move with how the rim is subdivided.
    using var silSphere = Solid.Sphere(2.0);
    var silRim = silSphere.SilhouetteBeziers();
    if (silRim.Count == 0) return Fail("silhouette: a sphere gave no rim");
    if (silRim.Points.Length != silRim.Count * 12 || silRim.Weights.Length != silRim.Count * 4)
        return Fail($"silhouette: {silRim.Count} curves but {silRim.Points.Length} point doubles and {silRim.Weights.Length} weights");
    for (var c = 0; c < silRim.Count; c++)
    {
        double R(int k) => Norm(new[] { silRim.Points[c * 12 + k * 3], silRim.Points[c * 12 + k * 3 + 1], silRim.Points[c * 12 + k * 3 + 2] });
        double W(int k) => silRim.Weights[c * 4 + k];
        if (Math.Abs(R(0) - 2.0) > 1e-9 || Math.Abs(R(3) - 2.0) > 1e-9)
            return Fail($"silhouette: arc {c} end points are at radius {R(0)} and {R(3)}, not 2");
        if (W(0) != 1.0 || W(3) != 1.0 || !(W(1) > 0 && W(1) < 1) || !(W(2) > 0 && W(2) < 1))
            return Fail($"silhouette: arc {c} weights are [{W(0)}, {W(1)}, {W(2)}, {W(3)}], not 1, then two weights in (0, 1), then 1");
    }
    Console.WriteLine($"silhouette: a radius-2 sphere gives {silRim.Count} arcs, ends at radius 2, end weights 1, interior weights in (0, 1)");

    // A cylinder seen from the side is straight rulings: polynomial, every weight exactly 1.
    using var silCylinder = Solid.Cylinder(1.0, 3.0);
    var silRulings = silCylinder.SilhouetteBeziers(new Cadaclysm.Blacksmith.SvgOptions { View = Cadaclysm.Blacksmith.SvgView.Front });
    if (silRulings.Count == 0 || silRulings.Weights.Any(w => w != 1.0)) return Fail("silhouette: a cylinder's rulings are not all weight 1");
    // The axis. hypot(x, y) and the z extent are both symmetric in x and y, so an unpack that
    // returned [y, x, z] passes both; |x| at the radius and |y| at zero tell the two apart (seen
    // from the front a ruling sits at x = +-radius, y = 0). Only the magnitude of x is asserted,
    // not its sign, and the number of rulings is not asserted.
    for (var k = 0; k < silRulings.Count * 4; k++)
    {
        var x = silRulings.Points[k * 3]; var y = silRulings.Points[k * 3 + 1];
        if (Math.Abs(Math.Sqrt(x * x + y * y) - 1.0) > 1e-6) return Fail("silhouette: a ruling's control point is off the cylinder's wall");
        if (Math.Abs(Math.Abs(x) - 1.0) > 1e-6) return Fail($"silhouette: a ruling's control point has |x| = {Math.Abs(x)}, not the radius 1");
        if (Math.Abs(y) > 1e-6) return Fail($"silhouette: a ruling's control point has |y| = {Math.Abs(y)}, not 0");
    }
    var silHeights = Enumerable.Range(0, 4).Select(k => silRulings.Points[k * 3 + 2]).Order().ToArray();
    if (!Near(silHeights, new[] { 0.0, 1.0, 2.0, 3.0 }, 1e-6)) return Fail($"silhouette: a ruling's heights are {string.Join(",", silHeights)}, not 0..3 evenly");

    // An infinite tolerance is refused in the library's words; and a refusal left in the error slot
    // must not turn a later empty answer into an exception. The cuboid is built BEFORE the refusal,
    // not between it and the ask: every call that builds, reads or writes geometry in the library
    // runs under its `guard`, whose first act is `clear_error` (blacksmith-capi lib.rs:117), so
    // building one in between would wipe the refusal's message. The order is build, refuse, ask.
    // What this pins is narrower than it looks, though: the slot is already clear when the
    // silhouette's native call begins, because the wrapper first packs its options and packing the
    // default stroke "#000000" goes through `cadaclysm_blacksmith_parse_colour`, itself a `guard`
    // (lib.rs:200) that clears it (C# `BuildSvgOptions` -> `Packed` -> `TryParse` ->
    // `cadaclysm_blacksmith_parse_colour`). `cadaclysm_blacksmith_svg_options_init` is a bare
    // struct fill and does not clear. So the test pins that the wrapper must not read the slot
    // BEFORE packing its options: a read there fails it, while a read placed after packing and
    // before the native call would pass. The library's own clearing at the silhouette's entry is a
    // library property, pinned for the reader's entry point by
    // `an_empty_answer_after_a_refusal_carries_no_stale_error`
    // (crates/cadaclysm-capi/tests/silhouette_abi.rs:401); this test covers the wrapper's half.
    // Only calls under `guard` clear: `cadaclysm_blacksmith_solid_free` and
    // `cadaclysm_blacksmith_silhouette_beziers_free` just drop a box and the error getter does not
    // clear either, so a free running between the refusal and the ask cannot wipe the slot.
    using var silBox = Solid.Cuboid(10, 10, 10);
    try { silSphere.SilhouetteBeziers(new Cadaclysm.Blacksmith.SvgOptions { Tolerance = double.PositiveInfinity }); return Fail("silhouette: an infinite tolerance was accepted"); }
    catch (BuildException e) when (e.Message.Contains("silhouette: ")) { }
    BeziersData64 silNone;
    try { silNone = silBox.SilhouetteBeziers(); }
    catch (BuildException e) { return Fail($"silhouette: the empty answer after a refusal was an error: {e.Message}"); }
    if (silNone.Count != 0 || silNone.Points.Length != 0 || silNone.Weights.Length != 0) return Fail("silhouette: an all-planar body gave a silhouette");
    Console.WriteLine("silhouette: cylinder rulings polynomial, infinite tolerance refused, a planar body is the empty answer");

    // Reader. The fixtures are the repository's, not an SDK checkout's, so this runs where found.
    var silFixtures = sampleRoot is null ? null : System.IO.Path.Combine(sampleRoot, "crates", "cadaclysm-acis", "tests", "fixtures", "rhino");
    var silSpherePath = silFixtures is null ? null : System.IO.Path.Combine(silFixtures, "sphere.sat");
    var silBoxPath = silFixtures is null ? null : System.IO.Path.Combine(silFixtures, "box-chamfer-all.blacksmith.stp");
    if (silSpherePath is not null && silBoxPath is not null && File.Exists(silSpherePath) && File.Exists(silBoxPath))
    {
        using var silScene = Cadaclysm.Cadaclysm.Open(silSpherePath);
        // The body node above the lump holds no shape of its own; the first node with extent is the part.
        var silNode = silScene.Walk().First(n => !n.Bounds.Min.SequenceEqual(n.Bounds.Max));
        // Asked the LARGER answer first: iso gives 236 curves against front's 174, so the second call
        // below refills the scene's one slot in place and overwrites the head of what was kept, which is
        // what makes a non-copying implementation fail loudly. The reverse order can pass with a view.
        // It was front first until the lattice's spacing became a length in space (44efabc88): front
        // gave 1248 against iso's 1210 then.
        var silOptions = new Cadaclysm.SvgOptions { View = Cadaclysm.SvgView.Iso };
        var silFirst = silNode.SilhouetteBeziers(silOptions);
        if (silFirst.Count == 0) return Fail("silhouette (reader): a sphere gave no rim");
        if (silFirst.Points.Length != silFirst.Count * 12 || silFirst.Weights.Length != silFirst.Count * 4)
            return Fail("silhouette (reader): the arrays are not count*4*3 and count*4");
        if (silFirst.Weights.Any(w => !double.IsFinite(w) || !(w > 0.0)))
            return Fail("silhouette (reader): a weight is not finite and strictly positive");
        // Every control point lies within the library's fit budget of the sphere, at the bounds
        // radius from the bounds centre. That is NOT because control points lie on the sphere: the
        // silhouette curve does, but a cubic's interior control points do not. It holds because the
        // arcs are short (half a unit on a radius of 10), and the budget is the tolerance the library
        // fits the CURVE to, not its control polygon. The margin is narrow: the curve itself uses
        // nearly the whole budget (3.42e-3 against 3.46e-3) since the lattice's spacing became a
        // length in space (44efabc88); before, a lattice ten times too fine left it at 1e-4. So this
        // catches a displaced or scaled result and a wildly mis-strided
        // unpack. What it does with a slip of the unpack was measured here as the worst radius
        // DEVIATION of any control point from the sphere's radius 10 (budget about 3.5e-3): a
        // correct read deviates by 3.04e-3 on iso and 2.97e-3 on front; a one-double wrap slip by
        // 0.87 on iso and 8.8 on front, over the budget at either view; a one-CONTROL-POINT slip
        // by exactly the correct read's figure at either view, because it only moves whole points.
        // So this catches a one-double slip but can never catch a one-control-point slip, which is
        // why the chaining assertion below is the only one that does. This test asks iso, because
        // the ownership order below forces it. It also does NOT pin the eye or `up` (a silhouette
        // point is a point of the surface, so it is on the sphere from any view), the node choice
        // (a wrong node fails earlier, as a refusal or an empty answer), or the weights (all 1.0 on
        // this fixture: degree-1 chords). The bound is the library's own budget: it fits the
        // silhouette to within `extent * tolerance / width` (`world_tolerance`, capi svg.rs), the
        // extent being the bounds' diagonal. Measured on the iso view this test asks, the radius
        // deviation is 3.04e-3 on a radius of 10 (front: 2.97e-3).
        var silB = silNode.Bounds;
        var silC = new[] { (silB.Min[0] + silB.Max[0]) / 2.0, (silB.Min[1] + silB.Max[1]) / 2.0, (silB.Min[2] + silB.Max[2]) / 2.0 };
        var silR = Enumerable.Range(0, silFirst.Points.Length / 3)
            .Select(k => Math.Sqrt(Enumerable.Range(0, 3).Sum(d => Math.Pow(silFirst.Points[k * 3 + d] - silC[d], 2)))).ToArray();
        var silRadius = (silB.Max[0] - silB.Min[0]) / 2.0;
        var silDiagonal = Math.Sqrt(Enumerable.Range(0, 3).Sum(d => Math.Pow(silB.Max[d] - silB.Min[d], 2)));
        var silBudget = silDiagonal * (silOptions.Tolerance / silOptions.Width); // read off the options the call was given
        if (silRadius <= 0 || silR.Any(r => Math.Abs(r - silRadius) > silBudget))
            return Fail($"silhouette (reader): control points are at radii {silR.Min()}..{silR.Max()} from the bounds centre, not the sphere's {silRadius}");
        var silKeepPoints = (double[])silFirst.Points.Clone();
        var silKeepWeights = (double[])silFirst.Weights.Clone();
        // The next silhouette call on this scene refills the library's one slot in place.
        var silSecond = silNode.SilhouetteBeziers(new Cadaclysm.SvgOptions { View = Cadaclysm.SvgView.Front });
        if (silSecond.Count == 0) return Fail("silhouette (reader): the second view gave no rim");
        if (silSecond.Count > silFirst.Count)
            return Fail($"silhouette (reader): the larger answer must come first (iso {silFirst.Count}, front {silSecond.Count})");
        if (silSecond.Count == silKeepPoints.Length / 12 && silSecond.Points.SequenceEqual(silKeepPoints))
            return Fail("silhouette (reader): the two views gave the same silhouette, so this cannot tell a copy from a view");
        if (!silFirst.Points.SequenceEqual(silKeepPoints))
            return Fail("silhouette (reader): the first answer's points changed when the second was asked");
        if (!silFirst.Weights.SequenceEqual(silKeepWeights))
            return Fail("silhouette (reader): the first answer's weights changed when the second was asked");
        // Chaining, the assertion that sees an offset slip; asked of the iso answer, whose figures are
        // quoted here (the front view chains much less). Count the consecutive pairs whose last control
        // point equals the next curve's first, to 1e-9 per coordinate (x, y and z each, so a passing
        // pair can be up to 1.73e-9 apart). The arcs come back in RUNS, not as one ordered traversal,
        // so "every arc ends where the next begins" is false and this is a count with a margin, not an
        // identity: measured on iso, 232 of the 235 consecutive pairs chain (98.7%, four runs); the
        // front view chains 96 of 173 (55%), which is why the eye matters and the bound is 80, not near
        // 230. A read shifted by one double or by one control point leaves none (0 of 235 each). Those are
        // wrap-around slips, which preserve the length and the count, so each denominator is the
        // unshifted pair count (a truncating slip loses a curve and drops it by one). The count varies
        // with how the sphere is tessellated; what makes a lower bound of 80 safe is not that it cannot
        // drift but that it sits about three times below the count measured here. It has drifted once:
        // the bound was 400 against 1206 of 1209 until the lattice's spacing became a length in space
        // (44efabc88) and the same four runs came back in arcs five times longer.
        // Its limit: a shift by a whole CURVE (12 doubles) is NOT caught, because it preserves the
        // chaining: 231 of 235 pairs still chain on iso, since every arc is replaced by its
        // neighbour's and the neighbours still join.
        if (silSecond.Points.Length != silSecond.Count * 12 || silSecond.Weights.Length != silSecond.Count * 4)
            return Fail("silhouette (reader): the front arrays are not count*4*3 and count*4");
        if (silSecond.Weights.Any(w => !double.IsFinite(w) || !(w > 0.0)))
            return Fail("silhouette (reader): a front weight is not finite and strictly positive");
        var silChained = 0;
        for (var ci = 0; ci + 1 < silFirst.Count; ci++)
        {
            var last = ci * 12 + 9;
            var next = (ci + 1) * 12;
            if (Math.Abs(silFirst.Points[last] - silFirst.Points[next]) <= 1e-9
                && Math.Abs(silFirst.Points[last + 1] - silFirst.Points[next + 1]) <= 1e-9
                && Math.Abs(silFirst.Points[last + 2] - silFirst.Points[next + 2]) <= 1e-9) silChained++;
        }
        if (silChained < 80)
            return Fail($"silhouette (reader): only {silChained} of {silFirst.Count - 1} consecutive arcs chain (last control point = the next one's first), want at least 80");
        // A refusal: an infinite tolerance, in the library's words.
        try { silNode.SilhouetteBeziers(new Cadaclysm.SvgOptions { Tolerance = double.PositiveInfinity }); return Fail("silhouette (reader): an infinite tolerance was accepted"); }
        catch (CadaclysmException e) when (e.Message.Contains("silhouette: ")) { }

        // A planar body: the empty answer, after a refusal has left its reason in the slot.
        using var silBoxScene = Cadaclysm.Cadaclysm.Open(silBoxPath);
        var silBoxNode = silBoxScene.Walk().First(n => !n.Bounds.Min.SequenceEqual(n.Bounds.Max));
        try { silBoxNode.SilhouetteBeziers(new Cadaclysm.SvgOptions { Tolerance = double.PositiveInfinity }); return Fail("silhouette (reader): an infinite tolerance was accepted on the box"); }
        catch (CadaclysmException) { }
        var silBoxAnswer = silBoxNode.SilhouetteBeziers();
        if (silBoxAnswer.Count != 0 || silBoxAnswer.Points.Length != 0) return Fail("silhouette (reader): an all-planar body gave a silhouette");
        Console.WriteLine($"silhouette (reader): sphere {silFirst.Count} then {silSecond.Count} curves, first answer kept; infinite tolerance refused; planar box empty");
    }
}
return 0;

static int Fail(string why) { Console.Error.WriteLine(why); return 1; }
static double Norm(double[] v) => Math.Sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
static int CountOf(string haystack, string needle) => (haystack.Length - haystack.Replace(needle, "").Length) / needle.Length;
// A profile's [x0, x1, y0, y1], read off the bounds of it extruded 1, at a fine tolerance.
static double[] Footprint(Profile profile)
{
    using var solid = Workplane.Xy().Extrude(profile, 1).Solid();
    var (lo, hi) = solid.BoundsAt(0.001);
    return new[] { lo[0], hi[0], lo[1], hi[1] };
}
static bool Near(double[] a, double[] b, double tolerance) => a.Zip(b).All(p => Math.Abs(p.First - p.Second) <= tolerance);
// A 40x30x10 block on z = 0 with a 20x10 pocket 8 deep: four corners a 6 mm end mill misses.
static Solid PocketedBlock()
{
    using var block0 = Solid.Cuboid(40, 30, 10);
    using var block = block0.Translate(0, 0, 5);
    using var pocket0 = Solid.Cuboid(20, 10, 8);
    using var pocket = pocket0.Translate(0, 0, 6);
    return block.Cut(pocket);
}
