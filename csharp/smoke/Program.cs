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
    if (tasks.Any(t => t.ScheduleIndex != 0) || fitOut.ScheduleIndex != programme.Index) return Fail("schedules: a task's ScheduleIndex is not the programme's");
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
// The scene saved as a Rhino .3dm (its meshes), read back to the same meshable nodes.
var sceneRhino = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"cadaclysm-smoke-{Environment.ProcessId}.3dm");
scene.Save(sceneRhino, "3dm");
using (var savedRhino = Cadaclysm.Cadaclysm.Open(sceneRhino))
{
    var meshable = savedRhino.Walk().Count(n => n.CanMesh);
    if (meshable == 0 || meshable != scene.Walk().Count(n => n.CanMesh)) return Fail($"save 3dm: the scene reads back with {meshable} meshable nodes");
    Console.WriteLine($"save 3dm: {meshable} meshable node(s) read back");
}
File.Delete(sceneRhino);

// The kernel: the plate with a hole and a pin, filleted, as STEP -- then read back.
if (license is not null) Blacksmith.License(license);
Console.WriteLine($"blacksmith {Blacksmith.Version()} built {Blacksmith.BuildDate()}");
Console.WriteLine($"blacksmith license: {Blacksmith.LicenseInfo()}");
// A box as a Rhino .3dm, bytes and file, read back through the reader: its faces and volume.
{
    using var brick = Solid.Cuboid(10, 20, 30);
    var rhino = brick.Rhino3dmBytes();
    if (rhino.Length < 24 || Encoding.ASCII.GetString(rhino, 0, 24) != "3D Geometry File Format ") return Fail("3dm: the bytes are not an openNURBS file");
    var rhinoPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"cadaclysm-smoke-brick-{Environment.ProcessId}.3dm");
    brick.Write3dm(rhinoPath);
    try
    {
        if (!File.ReadAllBytes(rhinoPath).SequenceEqual(rhino)) return Fail("3dm: the file is not the bytes");
        var back = Solid.OpenAll(rhinoPath);
        try
        {
            if (back.Count != 1 || back[0].Faces != 6 || Math.Abs(back[0].Mass().Volume - 6000) > 6e-6)
                return Fail($"3dm: the file reads back as {back.Count} solid(s), {(back.Count > 0 ? back[0].Faces : 0)} faces");
        }
        finally { foreach (var s in back) s.Dispose(); }
        using (var memory = Cadaclysm.Cadaclysm.OpenMemory(rhino, "brick.3dm"))
        {
            var bodies = memory.Walk().Where(n => n.CanMesh).ToList();
            if (bodies.Count != 1) return Fail($"3dm: the bytes open as {bodies.Count} meshable nodes");
            using var fromBytes = Solid.FromNode(memory, bodies[0]);
            if (fromBytes.Faces != 6 || Math.Abs(fromBytes.Mass().Volume - 6000) > 6e-6) return Fail($"3dm: the bytes read back as {fromBytes.Faces} faces");
        }
        using (var can = Solid.Cylinder(4, 10))
        using (var moved = can.Translate(40, 0, 0))
        {
            Blacksmith.Write3dm(rhinoPath, new[] { brick, moved }, "m");
            var two = Solid.OpenAll(rhinoPath);
            var faces = string.Join(",", two.Select(s => s.Faces));
            foreach (var s in two) s.Dispose();
            if (faces != "6,3") return Fail($"3dm: two solids read back with faces {faces}");
            if (!Blacksmith.Rhino3dmBytes(new[] { brick, moved }, "in").AsSpan(0, 24).SequenceEqual(rhino.AsSpan(0, 24))) return Fail("3dm: the module bytes are not an openNURBS file");
        }
        using (var arm = new Assembly("arm"))
        using (var rig = new Assembly("rig"))
        {
            using (var bolt = Solid.Cuboid(1, 1, 1).Named("bolt"))
            {
                arm.Place(bolt, new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, null);
                arm.Place(bolt, new double[] { 2, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, null);
                rig.Place(arm, new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, null);
                rig.Place(bolt, new double[] { 10, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, null);
            }
            if (!rig.Rhino3dmBytes().AsSpan(0, 24).SequenceEqual(rhino.AsSpan(0, 24))) return Fail("3dm: the assembly bytes are not an openNURBS file");
            rig.Write3dm(rhinoPath);
            var placed = Solid.OpenAll(rhinoPath);
            var count = placed.Count;
            var allBoxes = placed.All(s => s.Faces == 6);
            foreach (var s in placed) s.Dispose();
            if (count != 3 || !allBoxes) return Fail($"3dm: the assembly reads back as {count} solids");
        }
    }
    finally { File.Delete(rhinoPath); }
    try { brick.Rhino3dmBytes("furlong"); return Fail("3dm: a furlong was taken"); }
    catch (BuildException e) when (e.Message.Contains("unit must be one of")) { }
    Console.WriteLine($"3dm: {rhino.Length} bytes, read back to 6 faces and 6000 mm3; an assembly of 3 placements");
}
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
    try { left.Common(right, -1.0); return Fail("common: a negative tolerance was accepted"); }
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
    try { spline.ToArcs(-1); return Fail("to_arcs: a negative tolerance was accepted"); }
    catch (BuildException e) when (e.Message == "profile_to_arcs: tolerance must be positive and finite") { }
    Console.WriteLine("to_arcs: the fit bounds the spline within 0.011, negative tolerance refused");

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
    // Rest machining: a list of end mills, the Z range of each corner, an empty list refused.
    using var block = PocketedBlock();
    using var t1 = Tool.Flat(1, 6, 20, 800, 200, 12000);
    using var t2 = Tool.Flat(2, 2, 20, 800, 200, 12000);
    using (var single = new Job(Stock.Around(block, 2), 30))
    {
        var one = single.Machine(block, t1);
        if (one.Count != 4 || one.Any(i => Math.Abs(i.Top - 10) > 1e-6 || Math.Abs(i.Bottom - 2) > 1e-6))
            return Fail($"machine: the single tool's corners are not from z 10 down to z 2:\n{string.Join("\n", one.Select(i => $"{i.Top} {i.Bottom}"))}");
    }
    using (var job = new Job(Stock.Around(block, 2), 30))
    {
        var rest = job.MachineWith(block, new[] { t1, t2 });
        if (rest.Count != 4) return Fail($"machine_with: {rest.Count} item(s), not 4:\n{rest}");
        foreach (var item in rest)
            if (!item.Reason.Contains("T2 (2 mm)") || Math.Abs(item.Top - 10) > 1e-6 || Math.Abs(item.Bottom - 2) > 1e-6)
                return Fail($"machine_with: {item} is not T2's corner from z 10 down to z 2");
        if (!job.Operations().Any(o => o.Kind == "pocket" && o.Tool == 2))
            return Fail("machine_with: no pocket with tool 2");
    }
    using (var job = new Job(Stock.Around(block, 2), 30))
    {
        try { job.MachineWith(block, Array.Empty<Tool>()); return Fail("machine_with: an empty list was accepted"); }
        catch (BuildException e) when (e.Message.Contains("machine: at least one end mill is needed")) { }
        if (job.Operations().Count != 0) return Fail("machine_with: a refused call changed the job");
        try { job.MachineWith(block, new Tool[] { t1, null! }); return Fail("machine_with: a null end mill was accepted"); }
        catch (BuildException e) when (e.Message.Contains("job_machine_with: null end mill 1")) { }
        if (job.Operations().Count != 0) return Fail("machine_with: a refused null changed the job");
    }
    Console.WriteLine("machine_with: two end mills leave T2's four corners, z 10 down to z 2; an empty list refused");
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
// on both pipes; apart, nothing; a negative tolerance refused in the kernel's words. Two coaxial
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
    try { pipeA.Intersect(pipeB, -1.0); return Fail("intersect: a negative tolerance was accepted"); }
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
// Transforms: Python's test_a_transform_is_sixteen_numbers_row_major_and_composes_right_to_left
// .. test_a_profile_turns_scales_mirrors_and_maps (transforms plan A4). A frame goes as the 12
// numbers Frame converts to; the skew one below is passed raw, since Frame refuses it first.
{
    var tfXy = Frame.Xy();
    double[] TfF(double x, double y, double z) => Frame.Xy((x, y, z));
    bool TfAt((double X, double Y, double Z) p, double x, double y, double z, double tol = 1e-12) =>
        Math.Abs(p.X - x) <= tol && Math.Abs(p.Y - y) <= tol && Math.Abs(p.Z - z) <= tol;
    bool TfNear(double a, double b, double tol = 1e-9) => Math.Abs(a - b) <= tol;
    string TfRefused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
    }
    double TfDet(Transform t)
    {
        var r = t.Rows;
        return r[0] * (r[5] * r[10] - r[6] * r[9]) - r[1] * (r[4] * r[10] - r[6] * r[8]) + r[2] * (r[4] * r[9] - r[5] * r[8]);
    }

    // 1. rows and composition: `a * b` (and a.Compose(b)) is a after b.
    var tfT = Transform.Translation((1, 2, 3));
    if (!tfT.Rows.SequenceEqual(new double[] { 1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1 }))
        return Fail($"transform: translation rows read {string.Join(",", tfT.Rows)}");
    var tfS = Transform.Scale((0, 0, 0), 2);
    if (!TfAt((tfT * tfS).Point((1, 1, 1)), 3, 4, 5) || !TfAt(tfT.Compose(tfS).Point((1, 1, 1)), 3, 4, 5))
        return Fail($"transform: (t after s)(1,1,1) reads {(tfT * tfS).Point((1, 1, 1))}");
    if (!TfAt((tfS * tfT).Point((1, 1, 1)), 4, 6, 8) || !TfAt(tfS.Compose(tfT).Point((1, 1, 1)), 4, 6, 8))
        return Fail($"transform: (s after t)(1,1,1) reads {(tfS * tfT).Point((1, 1, 1))}");
    var tfTs = tfT * tfS;
    if (!TfAt((tfTs.Inverse() * tfTs).Point((3, -4, 5)), 3, -4, 5)) return Fail("transform: the inverse does not undo the map");
    if (Transform.FromRows(tfT.Rows) != tfT || new Transform() != Transform.Identity())
        return Fail("transform: from_rows or the identity does not compare equal");
    var tfNested = new double[4, 4];
    for (var i = 0; i < 16; i++) tfNested[i / 4, i % 4] = tfT.Rows[i];
    if (Transform.FromRows(tfNested) != tfT) return Fail("transform: four rows of four is not the same map");
    var tfBottom = TfRefused(() => new Transform(new double[] { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1 }));
    if (!tfBottom.StartsWith("Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)")) return Fail($"transform: a bad bottom row gave '{tfBottom}'");
    var tfFifteen = TfRefused(() => new Transform(new double[15]));
    if (!tfFifteen.StartsWith("Transform: a matrix is 16 numbers, got 15")) return Fail($"transform: 15 numbers gave '{tfFifteen}'");
    var tfNan = new double[16];
    tfNan[15] = 1;
    tfNan[0] = double.NaN;
    var tfNotFinite = TfRefused(() => new Transform(tfNan));
    if (!tfNotFinite.StartsWith("Transform: not finite")) return Fail($"transform: a NaN gave '{tfNotFinite}'");
    var tfSingular = TfRefused(() => Transform.ScaleXyz(tfXy, 1, 1, 0).Inverse());
    if (!tfSingular.StartsWith("transform_inverse: the map is singular")) return Fail($"transform: a singular inverse gave '{tfSingular}'");

    // 2. the constructors' closed forms
    if (!TfAt(Transform.Rotation((1, 0, 0), (0, 0, 1), Math.PI / 2).Point((2, 0, 0)), 1, 1, 0)) return Fail("transform: rotation");
    if (!TfAt(Transform.Mirror(TfF(0, 0, 5)).Point((1, 2, 3)), 1, 2, 7)) return Fail("transform: mirror");
    if (!TfAt(Transform.ScaleXyz(tfXy, 2, 3, 4).Point((1, 1, 1)), 2, 3, 4)) return Fail("transform: scale_xyz");
    if (!TfAt(Transform.Scale((1, 2, 3), 2).Point((2, 2, 3)), 3, 2, 3) || !TfAt(Transform.Scale((1, 2, 3), 2).Point((1, 2, 3)), 1, 2, 3))
        return Fail("transform: scale about a centre");
    if (!TfAt(Transform.Shear(tfXy, (5, 0, 0), 0.5).Point((0, 0, 2)), 1, 0, 2)) return Fail("transform: shear");
    if (!TfAt(Transform.PlanarProjection(tfXy).Point((1, 2, 3)), 1, 2, 0)) return Fail("transform: planar_projection");
    if (!TfAt(Transform.ProjectAlong(tfXy, (1, 0, 1)).Point((0, 0, 2)), -2, 0, 0)) return Fail("transform: project_along");
    if (!TfAt(Transform.PlaneToPlane(tfXy, TfF(1, 2, 3)).Point((0, 0, 0)), 1, 2, 3)) return Fail("transform: plane_to_plane");
    if (!TfAt(Transform.ChangeBasis(TfF(1, 2, 3), tfXy).Point((0, 0, 0)), 1, 2, 3)) return Fail("transform: change_basis");
    var tfOffPlane = TfRefused(() => Transform.Shear(tfXy, (0, 0, 1), 0.5));
    if (!tfOffPlane.StartsWith("transform_shear: the shear direction must lie in the plane")) return Fail($"transform: an off-plane shear gave '{tfOffPlane}'");
    var tfSkew = TfRefused(() => Transform.Mirror(new double[] { 0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1 }));
    if (!tfSkew.StartsWith("transform_mirror: the frame is not right-handed and orthonormal")) return Fail($"transform: a skew mirror frame gave '{tfSkew}'");

    // 3. told and split
    var tfTurn = Transform.Rotation((1, 2, 3), (1, 1, 0), 0.7);
    if (!tfTurn.IsRigid() || tfTurn.IsSimilarity() is not double tfK1 || !TfNear(tfK1, 1)) return Fail("transform: a turn is not rigid");
    var tfBig = Transform.Scale((0, 0, 0), 2.5) * tfTurn;
    if (tfBig.IsRigid() || tfBig.IsSimilarity() is not double tfK25 || !TfNear(tfK25, 2.5)) return Fail("transform: a scaled turn is not a similarity of 2.5");
    if (tfBig.DecomposeSimilarity() is not { } tfBigSplit || !TfNear(tfBigSplit.K, 2.5) || !tfBigSplit.Orthogonal.IsRigid())
        return Fail("transform: the scaled turn does not split as 2.5 times a rigid map");
    if (Transform.Scale((1, 2, 3), 2).DecomposeSimilarity() is not { } tfScaleSplit
        || !TfAt(tfScaleSplit.Translation, -1, -2, -3, 1e-9) || !TfNear(tfScaleSplit.K, 2) || tfScaleSplit.Orthogonal != Transform.Identity())
        return Fail("transform: a scale about (1, 2, 3) does not split as translation (-1, -2, -3), k 2");
    var tfTurnRows = tfTurn.Rows;
    if (tfTurn.DecomposeRigid() is not { } tfTurnSplit || !TfAt(tfTurnSplit.Translation, tfTurnRows[3], tfTurnRows[7], tfTurnRows[11], 1e-9)
        || !tfTurnSplit.Orthogonal.IsRigid())
        return Fail("transform: the turn does not split rigidly");
    var tfStretch = Transform.ScaleXyz(tfXy, 1, 2, 3);
    if (tfStretch.IsSimilarity() is not null || tfStretch.DecomposeRigid() is not null || tfStretch.DecomposeSimilarity() is not null)
        return Fail("transform: a stretch reads as a similarity");
    if ((Transform.Mirror(tfXy) * tfStretch).DecomposeAffine() is not { } tfPolar)
        return Fail("transform: a mirrored stretch has no polar split");
    if (!TfAt(tfPolar.Stretch, 3, 2, 1, 1e-9) || !TfNear(TfDet(tfPolar.Rotation), -1) || !TfNear(TfDet(tfPolar.Axes), 1)
        || !tfPolar.Rotation.IsRigid() || !tfPolar.Axes.IsRigid())
        return Fail($"transform: the polar split reads stretch {tfPolar.Stretch}, det(rotation) {TfDet(tfPolar.Rotation)}, det(axes) {TfDet(tfPolar.Axes)}");
    if (Transform.PlanarProjection(tfXy).DecomposeAffine() is not null) return Fail("transform: a projection has a polar split");
    var tfRigidTol = TfRefused(() => tfTurn.IsRigid(-1));
    if (!tfRigidTol.StartsWith("transform_is_rigid: the tolerance must be finite and not negative")) return Fail($"transform: is_rigid(-1) gave '{tfRigidTol}'");
    var tfSimTol = TfRefused(() => tfTurn.IsSimilarity(-1));
    if (!tfSimTol.StartsWith("transform_is_similarity: the tolerance must be finite and not negative")) return Fail($"transform: is_similarity(-1) gave '{tfSimTol}'");

    // 4. quaternions
    var tfQ = Quaternion.FromAxisAngle((0, 0, 2), Math.PI / 2);
    if (!TfNear(tfQ.W, Math.Cos(Math.PI / 4), 1e-12) || !TfNear(tfQ.X, 0, 1e-12) || !TfNear(tfQ.Y, 0, 1e-12) || !TfNear(tfQ.Z, Math.Sin(Math.PI / 4), 1e-12))
        return Fail($"quaternion: from_axis_angle reads {tfQ}");
    if (!TfNear(tfQ.Angle, Math.PI / 2, 1e-12) || tfQ.Axis is not { } tfQAxis || !TfAt(tfQAxis, 0, 0, 1)) return Fail("quaternion: angle or axis");
    if (!TfAt(tfQ.ToTransform((1, 0, 0)).Point((2, 0, 0)), 1, 1, 0)) return Fail("quaternion: to_transform about (1, 0, 0)");
    if (!TfAt(new Quaternion(2 * tfQ.W, 2 * tfQ.X, 2 * tfQ.Y, 2 * tfQ.Z).ToTransform().Point((1, 0, 0)), 0, 1, 0)) return Fail("quaternion: a doubled one does not turn alike");
    var tfBack = Quaternion.FromTransform(tfQ.ToTransform());
    if (!TfNear(tfBack.W, tfQ.W) || !TfNear(tfBack.X, tfQ.X) || !TfNear(tfBack.Y, tfQ.Y) || !TfNear(tfBack.Z, tfQ.Z)) return Fail($"quaternion: from_transform reads {tfBack}");
    if (!TfNear(Quaternion.Slerp(new Quaternion(), tfQ, 0.25).Angle, Math.PI / 8)) return Fail("quaternion: slerp a quarter of the way");
    var tfOne = tfQ * tfQ.Conjugate();
    if (!TfNear(tfOne.W, 1) || !TfNear(tfOne.X, 0) || !TfNear(tfOne.Y, 0) || !TfNear(tfOne.Z, 0)) return Fail($"quaternion: q * conjugate reads {tfOne}");
    if (new Quaternion(0, 0, 0, 2).Normalized() != new Quaternion(0, 0, 0, 1)) return Fail("quaternion: normalized (0, 0, 0, 2)");
    var tfZeroTurn = TfRefused(() => new Quaternion(0, 0, 0, 0).ToTransform());
    if (!tfZeroTurn.StartsWith("quaternion_to_transform: the quaternion is zero")) return Fail($"quaternion: a zero to_transform gave '{tfZeroTurn}'");
    var tfFromMirror = TfRefused(() => Quaternion.FromTransform(Transform.Mirror(tfXy)));
    if (!tfFromMirror.StartsWith("quaternion_from_transform: ")) return Fail($"quaternion: from_transform of a mirror gave '{tfFromMirror}'");
    var tfXY = Quaternion.FromAxisAngle((1, 0, 0), Math.PI / 2) * Quaternion.FromAxisAngle((0, 1, 0), Math.PI / 2);
    if (!TfNear(tfXY.W, 0.5, 1e-12) || !TfNear(tfXY.X, 0.5, 1e-12) || !TfNear(tfXY.Y, 0.5, 1e-12) || !TfNear(tfXY.Z, 0.5, 1e-12))
        return Fail($"quaternion: x turn * y turn reads {tfXY}, not (0.5, 0.5, 0.5, 0.5)");
    // No zero components, so every term counts: the y term's x*z part multiplies a zero above.
    var tfFull = new Quaternion(1, 2, 3, 4) * new Quaternion(5, 6, 7, 8);
    if (tfFull != new Quaternion(-60, 12, 30, 24)) return Fail($"quaternion: (1, 2, 3, 4) * (5, 6, 7, 8) reads {tfFull}, not (-60, 12, 30, 24)");
    // Every term's sign, which the figure above leaves partly unread: for two generic turns the
    // product turns as the two transforms composed.
    var tfQa = Quaternion.FromAxisAngle((1, 2, 3), 0.7);
    var tfQb = Quaternion.FromAxisAngle((-2, 1, 0.5), 1.1);
    var tfProduct = (tfQa * tfQb).ToTransform().Rows;
    var tfComposed = (tfQa.ToTransform() * tfQb.ToTransform()).Rows;
    if (!tfProduct.Zip(tfComposed).All(p => TfNear(p.First, p.Second, 1e-12)))
        return Fail($"quaternion: a * b does not turn as a's transform after b's");

    // 5. far from unit length
    var tfHalf = Math.Sqrt(0.5);
    foreach (var k in new[] { 1e200, 1e-170 })
    {
        if (new Quaternion(k, 0, 0, 0).Normalized() != new Quaternion(1, 0, 0, 0)) return Fail($"quaternion: ({k}, 0, 0, 0) normalized");
        if (new Quaternion(0, 0, 0, -k).Normalized() != new Quaternion(0, 0, 0, -1)) return Fail($"quaternion: (0, 0, 0, -{k}) normalized");
        var kk = new Quaternion(k, k, 0, 0);
        var kkn = kk.Normalized();
        if (!TfNear(kkn.W, tfHalf, 1e-12) || !TfNear(kkn.X, tfHalf, 1e-12) || kkn.Y != 0 || kkn.Z != 0) return Fail($"quaternion: ({k}, {k}, 0, 0) normalized reads {kkn}");
        if (!(Math.Abs(kk.Length - k * Math.Sqrt(2)) <= 1e-15 * k * Math.Sqrt(2))) return Fail($"quaternion: ({k}, {k}, 0, 0) length reads {kk.Length}");
        if (!TfNear(kk.Angle, Math.PI / 2, 1e-12)) return Fail($"quaternion: ({k}, {k}, 0, 0) angle reads {kk.Angle}");
        if (new Quaternion(0, k, k, 0).Axis is not { } kAxis || !TfAt(kAxis, tfHalf, tfHalf, 0)) return Fail($"quaternion: (0, {k}, {k}, 0) axis");
    }
    var tfZeroNorm = TfRefused(() => new Quaternion(0, 0, 0, 0).Normalized());
    if (!tfZeroNorm.StartsWith("Quaternion.normalized: the quaternion is zero")) return Fail($"quaternion: a zero normalized gave '{tfZeroNorm}'");

    // 6. a solid takes any affine map
    using var tfBox = Solid.Cuboid(1, 2, 3);
    if (tfBox.InexactTrims != 0) return Fail("transform: a solid no map made has lost trims");
    using (var stretched = tfBox.Transform(Transform.ScaleXyz(tfXy, 2, 3, 0.5)))
    {
        var (lo, hi) = stretched.BoundsAt(0.05);
        if (!TfNear(hi[0] - lo[0], 2) || !TfNear(hi[1] - lo[1], 6) || !TfNear(hi[2] - lo[2], 1.5) || stretched.InexactTrims != 0)
            return Fail($"transform: the stretched box spans {hi[0] - lo[0]}, {hi[1] - lo[1]}, {hi[2] - lo[2]}");
    }
    using (var moved = tfBox.Transform(Transform.Translation((1, 0, 0)).Rows))
        if (moved.InexactTrims != 0 || !TfNear(moved.Bounds.Min[0], 0.5, 1e-3)) return Fail("transform: 16 numbers did not move the box");
    using (var can0 = Solid.Cylinder(1, 2))
    using (var sheared = can0.Transform(Transform.Shear(tfXy, (1, 0, 0), 0.5)))
    {
        if (!(Math.Abs(sheared.Mass(1e-7).Volume - 2 * Math.PI) <= 1e-6 * 2 * Math.PI)) return Fail($"transform: the sheared can's volume is {sheared.Mass(1e-7).Volume}");
        if (!Enumerable.Range(0, sheared.Faces).Any(i => sheared.FaceKind(i) == "nurbs")) return Fail("transform: the sheared can has no nurbs face");
    }
    var tfFlat = TfRefused(() => tfBox.Transform(Transform.ScaleXyz(tfXy, 1, 1, 0)).Dispose());
    if (!tfFlat.StartsWith("solid_transform: a singular map flattens the solid")) return Fail($"transform: a flattening map gave '{tfFlat}'");

    // 7. colours and name kept
    using (var plainCan = Solid.Cylinder(1, 2))
    using (var greyCan = plainCan.Coloured("#808080"))
    using (var namedCan = greyCan.Named("can"))
    {
        var side = Enumerable.Range(0, namedCan.Faces).First(i => namedCan.FaceKind(i) == "cylinder");
        using var can = namedCan.Coloured(0.2, 0.4, 1.0, face: side);
        var solidColour = can.Colour!;
        using var canSheared = can.Transform(Transform.Shear(tfXy, (1, 0, 0), 0.5));
        using var canNurbs = can.ConvertToNurbs();
        foreach (var (label, outSolid) in new[] { ("transform", canSheared), ("convert_to_nurbs", canNurbs) })
        {
            if (outSolid.Faces != can.Faces) return Fail($"{label}: {outSolid.Faces} faces from {can.Faces}");
            if (!outSolid.FaceColour(side)!.SequenceEqual(new[] { 0.2, 0.4, 1.0 })) return Fail($"{label}: the side's colour reads {string.Join(",", outSolid.FaceColour(side)!)}");
            for (var i = 0; i < outSolid.Faces; i++)
                if (i != side && !outSolid.FaceColour(i)!.SequenceEqual(solidColour)) return Fail($"{label}: face {i}'s colour is not the solid's");
            if (outSolid.Name != "can") return Fail($"{label}: the name reads {outSolid.Name}");
        }
    }

    // 8. levels
    using (var levelCan = Solid.Cylinder(1, 2))
    {
        using var every = levelCan.ConvertToNurbs();
        if (!Enumerable.Range(0, every.Faces).All(i => every.FaceKind(i) == "nurbs") || every.InexactTrims != 0) return Fail("convert_to_nurbs: all leaves a face not nurbs");
        using var analytic = levelCan.ConvertToNurbs("analytic");
        var kinds = Enumerable.Range(0, analytic.Faces).Select(analytic.FaceKind).ToHashSet();
        if (!kinds.Contains("plane") || !kinds.Contains("nurbs")) return Fail($"convert_to_nurbs: analytic gives {string.Join(",", kinds)}");
        var tfLevel = TfRefused(() => levelCan.ConvertToNurbs("some").Dispose());
        if (!tfLevel.StartsWith("convert_to_nurbs: level 'some' is not \"procedural\", \"analytic\" or \"all\"")) return Fail($"convert_to_nurbs: a bad level gave '{tfLevel}'");
    }

    // 9. profiles, measured by their footprints (extruded 1, bounds at 0.001)
    using (var tfRect = Profile.Rect(80, 40))
    {
        var f0 = Footprint(tfRect);
        double rx = (f0[0] + f0[1]) / 2, ry = (f0[2] + f0[3]) / 2;
        double[] Spans(Profile p) { var f = Footprint(p); return new[] { f[1] - f[0], f[3] - f[2], (f[0] + f[1]) / 2, (f[2] + f[3]) / 2 }; }
        using (var p = tfRect.Rotate((0, 0), Math.PI / 2)) { var s = Spans(p); if (!TfNear(s[0], 40, 1e-3) || !TfNear(s[1], 80, 1e-3)) return Fail($"profile rotate: spans {s[0]}, {s[1]}"); }
        using (var p = tfRect.Scale((0, 0), 0.5, 2)) { var s = Spans(p); if (!TfNear(s[0], 40, 1e-3) || !TfNear(s[1], 80, 1e-3)) return Fail($"profile scale: spans {s[0]}, {s[1]}"); }
        using (var p = tfRect.Rotate((10, 20), Math.PI / 2))
        {
            var s = Spans(p);
            if (!TfNear(s[2], 10 - (ry - 20), 1e-3) || !TfNear(s[3], 20 + (rx - 10), 1e-3)) return Fail($"profile rotate about (10, 20): centre {s[2]}, {s[3]}");
        }
        using (var p = tfRect.Scale((10, 0), 0.5, 2))
        {
            var s = Spans(p);
            if (!TfNear(s[2], 10 + 0.5 * (rx - 10), 1e-3) || !TfNear(s[3], 2 * ry, 1e-3)) return Fail($"profile scale about (10, 0): centre {s[2]}, {s[3]}");
        }
        using (var p = tfRect.Mirror((100, 0), (0, 1))) { var s = Spans(p); if (!TfNear(s[2], 200, 1e-3)) return Fail($"profile mirror: x centre {s[2]}"); }
        using (var p = tfRect.Transform2d(new[] { 1, 0.5, 0, 0, 1, 0 })) { var s = Spans(p); if (!TfNear(s[0], 100, 1e-3)) return Fail($"profile transform2d: x span {s[0]}"); }
        var tfSingular2d = TfRefused(() => tfRect.Transform2d(new double[] { 1, 2, 0, 2, 4, 0 }).Dispose());
        if (!tfSingular2d.StartsWith("profile_transform2d: the 2D map is singular")) return Fail($"profile transform2d: a singular map gave '{tfSingular2d}'");
    }
    Console.WriteLine("transforms: rows, constructors, splits, quaternions, solid maps, NURBS levels and profile maps all read back");
}
// Value geometry: Python's TestInterval, TestFrameVerbs, TestCurveValues, TestSurfaceValues and
// TestCuboidValue (value geometry plan B3), with the same numbers and tolerances. The Rhino
// records are crates/cadaclysm/tests/fixtures/rhino/value_vectors.txt, found from this source
// file's own path ([CallerFilePath]), never from the working directory; a missing file fails.
{
    const double VgExact = 1e-12;
    const double VgNurbsFoot = 1e-7;
    var vgXy = new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    // Right-handed and exact: x = world y, y = world z, z = world x, off the origin.
    var vgYzx = new double[] { 1, 2, 3, 0, 1, 0, 0, 0, 1, 1, 0, 0 };
    var vgChecks = 0;
    string? vgFailed = null;
    void VgCheck(bool ok, string why)
    {
        vgChecks++;
        if (!ok && vgFailed is null) vgFailed = why;
    }
    string VgRefused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
    }
    double[] VgP((double X, double Y, double Z) p) => new[] { p.X, p.Y, p.Z };
    (double X, double Y, double Z) VgT(double[] v, int at = 0) => (v[at], v[at + 1], v[at + 2]);
    bool VgClose(IEnumerable<double> got, IEnumerable<double> want, double tol)
    {
        var g = got.ToArray();
        var w = want.ToArray();
        return g.Length == w.Length && g.Zip(w).All(p => Math.Abs(p.First - p.Second) <= tol);
    }
    bool VgAt((double X, double Y, double Z) p, double x, double y, double z, double tol = 1e-15) => VgClose(VgP(p), new[] { x, y, z }, tol);
    bool VgRel(double got, double want, double rel) => Math.Abs(got - want) <= rel * Math.Abs(want);
    // pytest.approx's default: rel 1e-6, abs 1e-12.
    bool VgApprox(double got, double want) => Math.Abs(got - want) <= Math.Max(1e-6 * Math.Abs(want), 1e-12);
    double VgDist(double[] a, double[] b) => Math.Sqrt(a.Zip(b).Sum(p => (p.First - p.Second) * (p.First - p.Second)));
    double VgMod(double x, double m) => ((x % m) + m) % m; // Python's floored %

    var vgPath = System.IO.Path.GetFullPath(System.IO.Path.Combine(SmokeSourceDir(), "..", "..", "..", "..",
        "cadaclysm", "tests", "fixtures", "rhino", "value_vectors.txt"));
    if (!System.IO.File.Exists(vgPath)) return Fail($"values: the Rhino vectors are not at {vgPath}");
    var vgRecords = new Dictionary<(string, string), string[]>();
    foreach (var rawLine in System.IO.File.ReadAllLines(vgPath))
    {
        var line = rawLine.Trim();
        if (line.Contains("ERROR")) return Fail($"values: an ERROR line in the Rhino vectors: {line}");
        if (line.Length == 0 || line.StartsWith('#')) continue;
        var words = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (!vgRecords.TryAdd((words[0], words[1]), words[2..])) return Fail($"values: ({words[0]}, {words[1]}) twice in the Rhino vectors");
    }
    double[] VgNums(string c, string what) =>
        vgRecords[(c, what)].Select(w => double.Parse(w, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
    IEnumerable<(string Case, double[] Q)> VgQueries(string vgShape) =>
        Enumerable.Range(0, 12).Select(i => ($"{vgShape}_{i:00}", VgNums($"{vgShape}_{i:00}", "query")));
    // A foot Rhino found by iteration on a NURBS form: the distance to 1e-12, never beaten by
    // Rhino's, the point to 1e-7 -- as B1's `nurbs_foot`.
    void VgNurbsFootCheck(string label, double[] q, double[] ours, double[] rhino)
    {
        double d = VgDist(q, ours), dr = VgDist(q, rhino);
        VgCheck(d <= dr + VgExact && Math.Abs(d - dr) <= VgExact, $"{label}: distance {d} against Rhino's {dr}");
        VgCheck(VgClose(ours, rhino, VgNurbsFoot), $"{label}: point ({string.Join(", ", ours)}) against ({string.Join(", ", rhino)})");
    }

    // ---- TestInterval ----
    var up = new Interval(2, 6);
    var down = new Interval(6, 2);
    // test_measures_keep_the_orientation
    VgCheck(up.Length == 4.0 && down.Length == -4.0, "interval: length");
    VgCheck(up.Mid == 4.0 && down.Mid == 4.0, "interval: mid");
    VgCheck(up.Min == 2.0 && up.Max == 6.0 && down.Min == 2.0 && down.Max == 6.0, "interval: min/max");
    VgCheck(up.IsIncreasing && !down.IsIncreasing && !new Interval(3, 3).IsIncreasing, "interval: is_increasing");
    VgCheck(new Interval(3, 3).IsSingleton && !up.IsSingleton, "interval: is_singleton");
    VgCheck(up.Swapped() == down && down.Swapped() == up, "interval: swapped");
    VgCheck(down.ToArray().SequenceEqual(new[] { 6.0, 2.0 }) && down.T0 == 6.0 && down.T1 == 2.0, "interval: t0/t1 keep the order");
    // test_set_operations_answer_increasing_and_touching_is_a_singleton
    VgCheck(up.Grown(9) == new Interval(2, 9) && down.Grown(-1) == new Interval(-1, 6) && down.Grown(3) == up, "interval: grown");
    VgCheck(up.Union(new Interval(8, 7)) == new Interval(2, 8) && down.Union((1, 3)) == new Interval(1, 6), $"interval: union reads {up.Union(new Interval(8, 7))}");
    VgCheck(down.Intersect((9, 4)) == new Interval(4, 6) && up.Intersect((3, 5)) == new Interval(3, 5), "interval: intersect");
    VgCheck(up.Intersect((7, 9)) is null && down.Intersect((1, 1.5)) is null, "interval: apart intersect to none");
    VgCheck(new Interval(0, 1).Intersect((1, 2)) == new Interval(1, 1) && new Interval(2, 1).Intersect((0, 1)) == new Interval(1, 1),
        "interval: touching intervals intersect to a singleton");
    foreach (var x in new[] { up, down })
        VgCheck(x.Contains(2) && x.Contains(6) && x.Contains(4.5) && !x.Contains(1.999) && !x.Contains(6.001), $"interval: contains on {x}");
    // test_parameters_round_trip
    VgCheck(up.ParameterAt(0.25) == 3.0 && down.ParameterAt(0.25) == 5.0, "interval: parameter_at");
    foreach (var x in new[] { up, down, new Interval(-1.5, 0.7) })
        foreach (var s in new[] { -0.5, 0.0, 0.3, 1.0, 2.0 })
            VgCheck(x.NormalizedParameterAt(x.ParameterAt(s)) is { } back && Math.Abs(back - s) <= 1e-15, $"interval: {x} round trip at {s}");
    VgCheck(new Interval(3, 3).NormalizedParameterAt(3) is null, "interval: a singleton has no normalized parameter");
    // test_is_a_frozen_hashable_value
    var vgA = new Interval(1, 2);
    VgCheck(vgA == new Interval(1.0, 2.0) && vgA.GetHashCode() == new Interval(1.0, 2.0).GetHashCode()
        && new HashSet<Interval> { vgA, new Interval(1, 2) }.Count == 1, "interval: equal and hashed by value");
    VgCheck(vgA.ToString() == "Interval(1, 2)", $"interval: prints {vgA}");
    var vgArr = vgA.ToArray();
    vgArr[0] = 5;
    VgCheck(vgA.T0 == 1.0, "interval: ToArray is not a copy");
    VgCheck(VgRefused(() => _ = new Interval(double.NaN, 1)).StartsWith("Interval: not finite"), "interval: a NaN end is not refused");
    VgCheck(VgRefused(() => Interval.Of(new double[] { 1, 2, 3 })).StartsWith("Interval: an interval is 2 numbers, got 3"), "interval: three numbers are not refused");
    VgCheck(Interval.Of(new double[] { 4, 1 }) == new Interval(4, 1), "interval: of two numbers");
    // test_matches_rhino
    foreach (var name in new[] { "apart", "dec_dec", "inc_dec", "inc_inc", "touch" })
    {
        var c = $"interval_{name}";
        var args0 = VgNums(c, "args");
        Interval a = new(args0[0], args0[1]), b = new(args0[2], args0[3]);
        VgCheck(a.Union(b).ToArray().SequenceEqual(VgNums(c, "union")), $"{c}: union");
        var got = a.Intersect(b);
        if (vgRecords[(c, "intersection")].SequenceEqual(new[] { "none" })) VgCheck(got is null, $"{c}: intersection is not none");
        else VgCheck(got is not null && got.ToArray().SequenceEqual(VgNums(c, "intersection")), $"{c}: intersection reads {got}");
    }
    foreach (var name in new[] { "inc_inside", "inc_out", "dec_low", "dec_inside" })
    {
        var args0 = VgNums($"grow_{name}", "args");
        VgCheck(new Interval(args0[0], args0[1]).Grown(args0[2]).ToArray().SequenceEqual(VgNums($"grow_{name}", "grown")), $"grow_{name}");
    }
    foreach (var name in new[] { "inc", "dec" })
        for (var k = 0; k < 4; k++)
        {
            var c = $"param_{name}_{k}";
            var args0 = VgNums(c, "args");
            var x = new Interval(args0[0], args0[1]);
            var t = args0[2];
            VgCheck(VgClose(new[] { x.ParameterAt(t) }, VgNums(c, "parameter_at"), VgExact), $"{c}: parameter_at");
            VgCheck(x.NormalizedParameterAt(2.5 + t) is { } n && VgClose(new[] { n }, VgNums(c, "normalized_at"), VgExact), $"{c}: normalized_at");
        }
    if (vgFailed is not null) return Fail(vgFailed);

    // ---- TestFrameVerbs ----
    // test_plane_verbs_match_rhino
    var vgPlane = Frame.Of(VgNums("plane", "frame"));
    VgCheck(VgClose(vgPlane.Flipped().ToArray(), VgNums("plane", "flip"), VgExact), $"frame: flipped reads {vgPlane.Flipped()}");
    VgCheck(VgClose(vgPlane.Rotated(0.6, (1, -1, 0.5)).ToArray(), VgNums("plane", "rotate"), VgExact), "frame: rotated");
    foreach (var (c, q) in VgQueries("plane"))
    {
        var qp = VgT(q);
        VgCheck(VgClose(VgP(vgPlane.ToLocal(qp)), VgNums(c, "remap"), VgExact), $"{c}: to_local");
        VgCheck(VgClose(VgP(vgPlane.ClosestPoint(qp)), VgNums(c, "closest"), VgExact), $"{c}: closest_point");
        VgCheck(VgClose(new[] { vgPlane.DistanceTo(qp) }, VgNums(c, "distance"), VgExact), $"{c}: distance_to reads {vgPlane.DistanceTo(qp)}");
    }
    // test_fit_matches_rhino_and_refuses_in_the_librarys_words
    var vgFlat = VgNums("fit", "points");
    var vgPts = Enumerable.Range(0, vgFlat.Length / 3).Select(k => VgT(vgFlat, 3 * k)).ToArray();
    var (vgFitted, vgDeviation) = Frame.Fit(vgPts);
    var vgWant = Frame.Of(VgNums("fit", "frame"));
    var vgSign = VgP(vgFitted.Z).Zip(VgP(vgWant.Z)).Sum(p => p.First * p.Second) < 0 ? -1.0 : 1.0;
    VgCheck(VgClose(VgP(vgFitted.Z).Select(c => vgSign * c), VgP(vgWant.Z), VgExact), "frame: fit's normal");
    VgCheck(VgClose(new[] { vgWant.DistanceTo(vgFitted.Origin), vgFitted.DistanceTo(vgWant.Origin) }, new[] { 0.0, 0.0 }, VgExact), "frame: fit's origin");
    VgCheck(VgClose(new[] { vgDeviation }, VgNums("fit", "deviation"), VgExact), $"frame: fit's deviation reads {vgDeviation}");
    VgCheck(VgRefused(() => Frame.Fit(vgPts.Take(2))) == "frame_fit: needs three points", "frame: two points fit");
    VgCheck(VgRefused(() => Frame.Fit(new (double, double, double)[] { (0, 0, 0), (1, 1, 1), (2, 2, 2) })) == "frame_fit: the points lie on one line",
        "frame: three points on a line fit");
    if (vgFailed is not null) return Fail(vgFailed);

    // ---- TestCurveValues ----
    // test_a_bad_value_is_refused_by_value_check
    foreach (var (make, words) in new (Action, string)[]
    {
        (() => _ = new Circle(vgXy, 0), "the radius must be positive"),
        (() => _ = new Line((1, 1, 1), (1, 1, 1)), "the line has no length"),
        (() => _ = new Arc(vgXy, 1, (0, 7)), "the angle must increase by at most a full turn"),
        (() => _ = new Arc(vgXy, 1, new Interval(1, 0)), "the angle must increase by at most a full turn"),
        (() => _ = new Ellipse(vgXy, 3, -1), "the second radius must be positive"),
        (() => _ = new Circle(new double[] { 0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1 }, 1), "the frame is not right-handed and orthonormal"),
    })
    {
        var why = VgRefused(make);
        VgCheck(why == $"value_check: {words}", $"values: '{words}' came back as '{why}'");
    }
    // 1e-7 off square is squared up, not refused.
    var vgNear = new Circle(new double[] { 0, 0, 0, 1, 1e-7, 0, 0, 1, 0, 0, 0, 1 }, 1);
    VgCheck(Math.Abs(VgP(vgNear.Frame.X).Zip(VgP(vgNear.Frame.Y)).Sum(p => p.First * p.Second)) < 1e-15 && vgNear.Frame.X.Y != 0, "values: 1e-7 off square is not squared up");
    // value_size: a raw array of the wrong count, refused in the library's sentence.
    var vgTwelve = VgRefused(() => Circle.FromValues(new double[12]));
    VgCheck(vgTwelve == "value_check: a circle is 13 numbers, got 12", $"values: 12 numbers for a circle gave '{vgTwelve}'");
    VgCheck(Circle.FromValues(vgXy.Append(2.0).ToArray()) == new Circle(vgXy, 2), "values: a circle from its 13 numbers");
    // test_each_call_answers_b1s_figures
    var vgUnit = new Circle(vgXy, 1);
    VgCheck(VgAt(vgUnit.PointAt(Math.PI / 2), 0, 1, 0), "circle: point_at");
    VgCheck(VgAt(vgUnit.TangentAt(0), 0, 1, 0), "circle: tangent_at");
    var vgLine = new Line((0, 0, 0), (1, 2, 3));
    VgCheck(vgLine.PointAt(0.5) == (0.5, 1.0, 1.5) && vgLine.Length() == Math.Sqrt(14), "line: point_at and length");
    VgCheck(vgLine.Start == (0, 0, 0) && vgLine.End == (1, 2, 3), "line: start and end");
    VgCheck(VgAt(vgLine.TangentAt(0), 1 / Math.Sqrt(14), 2 / Math.Sqrt(14), 3 / Math.Sqrt(14)), "line: tangent_at");
    var vgQuarter = new Arc(vgXy, 2, (0, Math.PI / 2));
    VgCheck(vgQuarter.Length() == Math.PI && vgQuarter.Angle == new Interval(0, Math.PI / 2), "arc: length and angle");
    VgCheck(VgAt(vgQuarter.Start, 2, 0, 0) && VgAt(vgQuarter.End, 0, 2, 0), $"arc: start {vgQuarter.Start} and end {vgQuarter.End}");
    VgCheck(VgAt(vgQuarter.Mid, Math.Sqrt(2), Math.Sqrt(2), 0), "arc: mid");
    // On the axis the foot is a pick: t = 0, not unique.
    VgCheck(vgUnit.ClosestPoint((2, 0, 5)) == new CurveFoot(0.0, (1.0, 0.0, 0.0), true), $"circle: closest to (2, 0, 5) reads {vgUnit.ClosestPoint((2, 0, 5))}");
    VgCheck(vgUnit.ClosestPoint((0, 0, 5)) == new CurveFoot(0.0, (1.0, 0.0, 0.0), false), $"circle: closest to (0, 0, 5) reads {vgUnit.ClosestPoint((0, 0, 5))}");
    VgCheck(VgApprox(vgUnit.DistanceTo((2, 0, 5)), Math.Sqrt(26)), "circle: distance_to");
    VgCheck(new Line((1, 5, 0), (0, 2, 3)).Bounds() == ((0, 2, 0), (1, 5, 3)), "line: bounds");
    VgCheck(VgRel(new Ellipse(vgXy, 3, 1).Length(), 13.364893220555258, 1e-12), "ellipse: length");
    // test_constructors_and_transforms
    (double, double, double) ca = (1, 0, 0), cb = (0, 1, 0), cc = (-1, 0, 0);
    var vgThrough = Circle.Through(ca, cb, cc);
    VgCheck(VgClose(vgThrough.Values, vgXy.Append(1.0), 1e-15), "circle: through");
    VgCheck(VgClose(Arc.Through(ca, cb, cc).Values, vgXy.Concat(new[] { 1.0, 0.0, Math.PI }), 1e-15), "arc: through");
    VgCheck(VgClose(Arc.FromStartTangentEnd(ca, (0, 1, 0), cc).Values, vgXy.Concat(new[] { 1.0, 0.0, Math.PI }), 1e-15), "arc: from_start_tangent_end");
    VgCheck(VgRefused(() => Circle.Through(ca, ca, cc)) == "circle_through: the points are coincident or collinear", "circle: through a doubled point");
    VgCheck(VgRefused(() => Arc.FromStartTangentEnd(ca, (0, 0, 0), cc)) == "arc_from_start_tangent_end: the tangent is zero or the end lies on the tangent line",
        "arc: a zero tangent");
    VgCheck(Ellipse.FromCircle(new Circle(vgXy, 2)) == new Ellipse(vgXy, 2, 2), "ellipse: from_circle");
    VgCheck(new Circle(vgXy, 1).Transform(Transform.Scale((0, 0, 0), 2)) == new Circle(vgXy, 2), "circle: scaled");
    var vgStretch = Transform.ScaleXyz(Frame.Xy(), 1, 3, 1);
    VgCheck(VgRefused(() => new Circle(vgXy, 1).Transform(vgStretch)) == "value_transform: a circle takes only a similarity (use ellipse_from_circle)",
        "circle: stretched");
    var vgE = Ellipse.FromCircle(new Circle(vgXy, 1)).Transform(vgStretch.Rows);
    VgCheck(Math.Abs(vgE.R1 - 3) <= 1e-15 && Math.Abs(vgE.R2 - 1) <= 1e-15, $"ellipse: stretched reads {vgE}");
    VgCheck(new Line((0, 0, 0), (1, 0, 0)).Transform(Transform.Translation((0, 0, 2))) == new Line((0, 0, 2), (1, 0, 2)), "line: moved");
    // test_values_are_immutable_hashable_and_iterate_as_their_array
    var vgC = new Circle(vgYzx, 2);
    VgCheck(vgC.Values.SequenceEqual(vgYzx.Append(2.0)) && vgC.Radius == 2.0 && vgC.Frame.Equals(Frame.Of(vgYzx)), "circle: values, radius, frame");
    VgCheck(vgC == new Circle(Frame.Of(vgYzx), 2.0) && vgC.GetHashCode() == new Circle(vgYzx, 2).GetHashCode(), "circle: equal and hashed by value");
    VgCheck(vgC != new Sphere(vgYzx, 2) && !vgC.Equals((object)new Sphere(vgYzx, 2))
        && new HashSet<GeometryValue> { vgC, new Circle(vgYzx, 2), new Sphere(vgYzx, 2) }.Count == 2, "circle: equals a sphere of the same numbers");
    VgCheck(vgC.ToString().StartsWith("Circle(frame=Frame(origin=(1, 2, 3)") && vgC.ToString().EndsWith("radius=2)"), $"circle: prints {vgC}");
    var vgCopy = vgC.Values;
    vgCopy[12] = 3;
    VgCheck(vgC.Radius == 2.0, "circle: Values is not a copy");
    // test_lines_circles_and_arcs_match_rhino
    var ends = VgNums("line", "ends");
    var rl = new Line(VgT(ends, 0), VgT(ends, 3));
    VgCheck(VgClose(new[] { rl.Length() }, VgNums("line", "length"), VgExact), "rhino line: length");
    VgCheck(VgClose(VgP(rl.TangentAt(0.5)), VgNums("line", "tangent"), VgExact), "rhino line: tangent");
    for (var k = 0; k < 5; k++)
    {
        var n = VgNums($"line_at_{k}", "point");
        VgCheck(VgClose(VgP(rl.PointAt(n[0])), n[1..], VgExact), $"line_at_{k}");
    }
    foreach (var (c, q) in VgQueries("line"))
        VgCheck(VgClose(VgP(rl.ClosestPoint(VgT(q)).Point), VgNums(c, "closest"), VgExact), c);
    var rc = new Circle(VgNums("circle", "frame"), VgNums("circle", "radius")[0]);
    VgCheck(VgClose(new[] { rc.Length() }, VgNums("circle", "length"), VgExact), "rhino circle: length");
    for (var k = 0; k < 5; k++)
    {
        var n = VgNums($"circle_at_{k}", "point");
        VgCheck(VgClose(VgP(rc.PointAt(n[0])), n[1..4], VgExact), $"circle_at_{k}");
        VgCheck(VgClose(VgP(rc.TangentAt(n[0])), n[4..7], VgExact), $"circle_at_{k} tangent");
    }
    foreach (var (c, q) in VgQueries("circle"))
    {
        var want = VgNums(c, "closest");
        var foot = rc.ClosestPoint(VgT(q));
        VgCheck(foot.Unique, $"{c}: not unique");
        VgCheck(VgClose(new[] { foot.T }, new[] { VgMod(want[0], 2 * Math.PI) }, VgExact), $"{c}: t reads {foot.T}");
        VgCheck(VgClose(VgP(foot.Point), want[1..], VgExact), $"{c}: point");
    }
    var ra = new Arc(VgNums("arc", "frame"), VgNums("arc", "radius")[0], Interval.Of(VgNums("arc", "angle")));
    VgCheck(VgClose(new[] { ra.Length() }, VgNums("arc", "length"), VgExact), "rhino arc: length");
    for (var k = 0; k < 4; k++)
    {
        var n = VgNums($"arc_at_{k}", "point");
        VgCheck(VgClose(VgP(ra.PointAt(n[0])), n[1..4], VgExact), $"arc_at_{k}");
        VgCheck(VgClose(VgP(ra.TangentAt(n[0])), n[4..7], VgExact), $"arc_at_{k} tangent");
    }
    foreach (var (c, q) in VgQueries("arc"))
    {
        var want = VgNums(c, "closest");
        var foot = ra.ClosestPoint(VgT(q));
        VgCheck(VgClose(new[] { foot.T }, want[..1], VgExact), $"{c}: t reads {foot.T}");
        VgCheck(VgClose(VgP(foot.Point), want[1..], VgExact), $"{c}: point");
    }
    // test_an_edges_curve_is_its_value
    using (var can = Solid.Cylinder(5, 3))
        foreach (var rim in can.Edges.Where(e => e.Kind == "circle"))
            VgCheck(rim.Curve?.Value is Circle rv && VgApprox(rv.Radius, 5) && (VgApprox(rv.Frame.Origin.Z, 0) || VgApprox(rv.Frame.Origin.Z, 3)),
                $"edges: a cylinder rim's value is {rim.Curve?.Value}");
    double[] VgRound(double[] p) => p.Select(c => Math.Round(c, 9) + 0.0).ToArray();
    using (var box246 = Solid.Cuboid(2, 4, 6))
        foreach (var e in box246.Edges)
        {
            var ok = e.Curve?.Value is Line lv;
            if (ok && e.Curve!.Value is Line lv2)
            {
                var segEnds = e.Segments.SelectMany(s => new[] { VgRound(s.A), VgRound(s.B) }).ToList();
                ok = new[] { VgRound(VgP(lv2.Start)), VgRound(VgP(lv2.End)) }.All(p => segEnds.Any(s => s.SequenceEqual(p)));
            }
            VgCheck(ok, $"edges: cuboid edge {e.Index}'s value is {e.Curve?.Value}");
        }
    using (var cube = Solid.Cuboid(10, 10, 10))
    {
        var upright = cube.Edges.Where(e => e.Direction is { } d && Math.Abs(Math.Abs(d[2]) - 1) < 1e-9).ToList();
        using var vgRounded = cube.Fillet(upright.Take(1), 2.0);
        var arcs = vgRounded.Edges.Where(e => e.Kind == "circle").ToList();
        VgCheck(arcs.Count == 2, $"edges: the filleted cube has {arcs.Count} circle edges");
        foreach (var e in arcs)
        {
            var ok = e.Curve?.Value is Arc av && VgApprox(av.Radius, 2) && VgApprox(av.Angle.Length, Math.PI / 2);
            if (ok && e.Curve!.Value is Arc av2)
            {
                var vertices = new[] { e.Segments[0].A, e.Segments[^1].B };
                ok = vertices.Any(p => VgDist(VgP(av2.Start), p) < 1e-9) && vertices.Any(p => VgDist(VgP(av2.End), p) < 1e-9);
            }
            VgCheck(ok, $"edges: a fillet edge's value is {e.Curve?.Value}");
        }
    }
    using (var splineProfile = Profile.Spline(new (double, double)[] { (0, 0), (10, 0), (10, 10), (0, 10) }, 3, closed: true))
    using (var spline = Solid.Extrude(splineProfile, Frame.Xy(), 2))
    {
        var nurbsEdges = spline.Edges.Where(e => e.Kind == "nurbs").ToList();
        VgCheck(nurbsEdges.Count > 0 && nurbsEdges.All(e => e.Curve is not null && e.Curve.Value is null), "edges: a spline edge has a value");
    }
    if (vgFailed is not null) return Fail(vgFailed);

    // ---- TestSurfaceValues ----
    // test_a_bad_value_is_refused_by_value_check
    foreach (var (make, words) in new (Action, string)[]
    {
        (() => _ = new Cylinder(vgXy, 1, (2, 1)), "the height must increase"),
        (() => _ = new Torus(vgXy, 1, 1), "the minor radius must be less than the major"),
        (() => _ = new Cone(vgXy, 1, 0), "the height must be positive"),
        (() => _ = new Sphere(vgXy, double.NaN), "not finite"),
    })
    {
        var why = VgRefused(make);
        VgCheck(why == $"value_check: {words}", $"values: '{words}' came back as '{why}'");
    }
    // test_each_call_answers_b1s_figures
    var vgSphere = new Sphere(vgXy, 2);
    VgCheck(VgAt(vgSphere.PointAt(0, Math.PI / 2), 0, 0, 2), "sphere: point_at");
    var vgCyl = new Cylinder(vgXy, 1, (-1, 2));
    VgCheck(vgCyl.Height == new Interval(-1, 2), "cylinder: height");
    VgCheck(VgAt(vgCyl.NormalAt(Math.PI / 2, 0), 0, 1, 0), "cylinder: normal_at");
    VgCheck(VgAt(new Torus(vgXy, 3, 1).PointAt(0, 0), 4, 0, 0), "torus: point_at");
    var vgFoot = vgSphere.ClosestPoint((0, 0, 5));
    VgCheck(vgFoot.Unique && VgClose(new[] { vgFoot.U, vgFoot.V }.Concat(VgP(vgFoot.Point)), new[] { 0, Math.PI / 2, 0, 0, 2 }, 1e-15),
        $"sphere: closest to (0, 0, 5) reads {vgFoot}");
    VgCheck(!vgSphere.ClosestPoint((0, 0, 0)).Unique, "sphere: the centre is a pick");
    VgCheck(VgApprox(vgSphere.DistanceTo((0, 0, 5)), 3), "sphere: distance_to");
    VgCheck(vgCyl.Domain() == (new Interval(0, 2 * Math.PI), new Interval(-1, 2)), $"cylinder: domain reads {vgCyl.Domain()}");
    VgCheck(new Cone(vgXy, 1, 2).Domain() == (new Interval(0, 2 * Math.PI), new Interval(0, 2)), "cone: domain");
    VgCheck(Math.Abs(vgSphere.Volume() - 32 * Math.PI / 3) < 1e-13 && Math.Abs(vgSphere.Area() - 16 * Math.PI) < 1e-13, "sphere: volume and area");
    VgCheck(new Torus(vgXy, 3, 1).Contains((3, 0, 0.5)) && !vgSphere.Contains((0, 0, 2.5)), "values: contains");
    VgCheck(vgSphere.Contains((0, 0, 2.5), tolerance: 0.5), "sphere: contains within a tolerance");
    var vgNegative = VgRefused(() => vgSphere.Contains((0, 0, 0), -1));
    VgCheck(vgNegative == "solid_value_contains: the tolerance must be finite and not negative", $"sphere: a negative tolerance gave '{vgNegative}'");
    VgCheck(vgSphere.Bounds() == ((-2, -2, -2), (2, 2, 2)), "sphere: bounds");
    VgCheck(VgRefused(() => vgSphere.Transform(Transform.ScaleXyz(Frame.Xy(), 1, 3, 1))) == "value_transform: a sphere takes only a similarity", "sphere: stretched");
    VgCheck(vgSphere.Transform(Transform.Translation((1, 0, 0))) == new Sphere(Frame.Xy((1, 0, 0)), 2), "sphere: moved");
    using (var vgSheet = vgCyl.ToNurbsSheet())
        VgCheck(vgSheet.Faces == 1, $"cylinder: the nurbs vgSheet has {vgSheet.Faces} faces");
    // test_each_shape_becomes_a_solid_of_its_volume
    foreach (var (vgShape, volume) in new (SolidValue, double)[]
    {
        (new Sphere(vgXy, 2), 32 * Math.PI / 3), (new Cylinder(vgXy, 1, (-1, 2)), 3 * Math.PI),
        (new Cone(vgXy, 1, 2), 2 * Math.PI / 3), (new Torus(vgXy, 3, 1), 6 * Math.PI * Math.PI),
        (new Cuboid(vgYzx, (0, 1), (0, 2), (0, 3)), 6.0),
    })
    {
        using var solid = vgShape.ToSolid();
        VgCheck(VgRel(solid.Mass(1e-9).Volume, volume, 1e-6), $"{vgShape}: the solid's volume is {solid.Mass(1e-9).Volume}");
        VgCheck(VgRel(vgShape.Volume(), volume, 1e-12), $"{vgShape}: volume reads {vgShape.Volume()}");
    }
    // test_spheres_tori_cylinders_and_cones_match_rhino
    var rs = new Sphere(VgNums("sphere", "frame"), VgNums("sphere", "radius")[0]);
    foreach (var (c, q) in VgQueries("sphere"))
    {
        var want = VgNums(c, "closest");
        var foot = rs.ClosestPoint(VgT(q));
        VgCheck(VgClose(new[] { foot.U, foot.V }, new[] { VgMod(want[0], 2 * Math.PI), want[1] }, VgExact), $"{c}: u, v read {foot.U}, {foot.V}");
        VgCheck(VgClose(VgP(foot.Point), want[2..], VgExact), $"{c}: point");
    }
    var radii = VgNums("torus", "radii");
    var rt = new Torus(VgNums("torus", "frame"), radii[0], radii[1]);
    foreach (var (c, q) in VgQueries("torus"))
    {
        var foot = rt.ClosestPoint(VgT(q));
        VgCheck(foot.Unique, $"{c}: not unique");
        VgNurbsFootCheck(c, q, VgP(foot.Point), VgNums(c, "closest"));
    }
    var rcyl = new Cylinder(VgNums("cylinder", "frame"), VgNums("cylinder", "radius")[0], Interval.Of(VgNums("cylinder", "height")));
    foreach (var (c, q) in VgQueries("cylinder"))
        VgNurbsFootCheck(c, q, VgP(rcyl.ClosestPoint(VgT(q)).Point), VgNums(c, "closest"));
    var size = VgNums("cone", "size");
    var rcone = new Cone(VgNums("cone", "frame"), size[0], size[1]);
    foreach (var (c, q) in VgQueries("cone"))
        VgNurbsFootCheck(c, q, VgP(rcone.ClosestPoint(VgT(q)).Point), VgNums(c, "closest"));
    if (vgFailed is not null) return Fail(vgFailed);

    // ---- TestCuboidValue ----
    // test_construction_bounds_and_around
    var vgBox = new Cuboid(vgYzx, (0, 1), (0, 2), new Interval(0, 3));
    VgCheck(vgBox.X == new Interval(0, 1) && vgBox.Y == new Interval(0, 2) && vgBox.Z == new Interval(0, 3), "cuboid: ranges");
    // x along world y (0..1), y along world z (0..2), z along world x (0..3), from (1, 2, 3).
    VgCheck(vgBox.Bounds() == ((1, 2, 3), (4, 3, 5)), $"cuboid: bounds read {vgBox.Bounds()}");
    VgCheck(Cuboid.FromBounds((0, 0, 0), (1, 2, 3)) == new Cuboid(vgXy, (0, 1), (0, 2), (0, 3)), "cuboid: from_bounds");
    VgCheck(VgRefused(() => Cuboid.FromBounds((0, 0, 0), (1, 0, 3))) == "cuboid_from_bounds: the bounds must increase along every axis", "cuboid: flat bounds");
    VgCheck(VgRefused(() => _ = new Cuboid(vgXy, (0, 1), (2, 2), (0, 1))) == "value_check: the y range must increase", "cuboid: an empty y range");
    var vgAroundPts = new (double, double, double)[] { (0, 0, 0), (1, 2, 3), (0.5, -1, 0.25) };
    VgCheck(Cuboid.Around(Frame.Xy(), vgAroundPts) == new Cuboid(vgXy, (0, 1), (-1, 2), (0, 3)), "cuboid: around");
    var vgFlatAround = VgRefused(() => Cuboid.Around(vgXy, new (double, double, double)[] { (0, 0, 0), (1, 1, 0) }));
    VgCheck(vgFlatAround == "cuboid_around: the points are flat along an axis of the frame", $"cuboid: around flat points gave '{vgFlatAround}'");
    var vgNoPoints = VgRefused(() => Cuboid.Around(vgXy, Array.Empty<(double, double, double)>()));
    VgCheck(vgNoPoints == "cuboid_around: no points", $"cuboid: around no points gave '{vgNoPoints}'");
    // test_each_call_answers_b1s_figures
    var vgB = new Cuboid(vgXy, (0, 1), (0, 2), (0, 3));
    VgCheck(vgB.Area() == 22.0 && vgB.Volume() == 6.0, "cuboid: area and volume");
    VgCheck(vgB.Contains((0.5, 0.5, 0.5)) && !vgB.Contains((1.5, 0.5, 0.5), 0.4) && vgB.Contains((1.5, 0.5, 0.5), 0.5), "cuboid: contains");
    var vgTilted = new Cuboid(vgYzx, (0, 1), (0, 2), (0, 3));
    VgCheck(vgTilted.ClosestPoint((9, 9, 9)) == (4, 3, 5), $"cuboid: closest reads {vgTilted.ClosestPoint((9, 9, 9))}");
    VgCheck(VgAt(vgTilted.PointAt(0.5, 0.5, 0.5), 2.5, 2.5, 4), "cuboid: point_at");
    var vgCorners = vgB.Corners();
    VgCheck(vgCorners.Length == 8 && vgCorners[0] == (0, 0, 0) && vgCorners[2] == (1, 2, 0) && vgCorners[6] == (1, 2, 3),
        $"cuboid: corners read {string.Join(" ", vgCorners)}");
    var vgMoved = vgB.Transform(Transform.Translation((0, 0, 1)));
    VgCheck(vgMoved.Bounds() == ((0, 0, 1), (1, 2, 4)), "cuboid: moved");
    // test_boxes_match_rhino
    var ranges = VgNums("box", "ranges");
    var rbox = new Cuboid(VgNums("box", "frame"), (ranges[0], ranges[1]), (ranges[2], ranges[3]), (ranges[4], ranges[5]));
    var rCorners = VgNums("box", "corners");
    var rGot = rbox.Corners();
    for (var k = 0; k < 8; k++)
        VgCheck(VgClose(VgP(rGot[k]), rCorners[(3 * k)..(3 * k + 3)], VgExact), $"rhino box: corner {k}");
    for (var k = 0; k < 4; k++)
    {
        var n = VgNums($"box_at_{k}", "point");
        VgCheck(VgClose(VgP(rbox.PointAt(n[0], n[1], n[2])), n[3..6], VgExact), $"box_at_{k}");
    }
    foreach (var (c, q) in VgQueries("box"))
        VgCheck(VgClose(VgP(rbox.ClosestPoint(VgT(q))), VgNums(c, "closest"), VgExact), c);

    // ---- TestPlanarValues (plan B4): the rectangle, the triangle and the ray ----
    // test_a_rectangle_is_a_curve_with_calls_of_its_own
    var vrect = new Rectangle(vgXy, (1, 4), new Interval(0, 4));
    VgCheck(vrect.X == new Interval(1, 4) && vrect.Y == new Interval(0, 4) && vrect.Frame.Equals(Frame.Of(vgXy)), "rectangle: fields");
    VgCheck(vrect is CurveValue, "rectangle: a curve value");
    VgCheck(vrect.PointAt(2.25) == (3.25, 4, 0) && vrect.PointAt(9) == (1, 0, 0), $"rectangle: point_at reads {vrect.PointAt(2.25)}, clamped {vrect.PointAt(9)}");
    VgCheck(vrect.TangentAt(1.5) == (0, 1, 0) && vrect.Length() == 14.0, "rectangle: tangent_at and length");
    VgCheck(vrect.ClosestPoint((2, -1, 7)) == new CurveFoot(1.0 / 3, (2, 0, 0), true), $"rectangle: closest reads {vrect.ClosestPoint((2, -1, 7))}");
    VgCheck(!new Rectangle(vgXy, (0, 2), (0, 2)).ClosestPoint((1, 1, 0)).Unique, "rectangle: the centre is a pick");
    VgCheck(vrect.Corners().SequenceEqual(new (double, double, double)[] { (1, 0, 0), (4, 0, 0), (4, 4, 0), (1, 4, 0) }) && vrect.Area() == 12.0,
        $"rectangle: corners read {string.Join(" ", vrect.Corners())}");
    VgCheck(vrect.ClosestPointIn((2, 1, 5)) == (2, 1, 0) && vrect.ClosestPointIn((2, 1, 5), false) == (1, 1, 0), "rectangle: closest_point_in");
    VgCheck(vrect.Bounds() == ((1, 0, 0), (4, 4, 0)), "rectangle: bounds");
    VgCheck(VgRefused(() => _ = new Rectangle(vgXy, (1, 1), (0, 4))) == "value_check: the x range must increase", "rectangle: an empty x range");
    VgCheck(VgRefused(() => Rectangle.FromValues(vgXy.Concat(new[] { 1.0, 4.0, 0.0 }).ToArray())) == "value_check: a rectangle is 16 numbers, got 15",
        "rectangle: 15 numbers");
    VgCheck(VgRefused(() => vrect.Transform(new double[] { 1, 0.5, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }))
        == "value_transform: a rectangle takes only a map that keeps its sides square (no shear in its plane)", "rectangle: a shear");
    VgCheck(vrect.Transform(Transform.ScaleXyz(vgXy, 2, 3, 1)) == new Rectangle(vgXy, (2, 8), (0, 12)), "rectangle: scaled");
    using (var rsheet = vrect.ToSheet())
        VgCheck(rsheet.Faces == 1 && VgRel(rsheet.Mass(1e-9).Area, 12.0, 1e-9), $"rectangle: the sheet's area is {rsheet.Mass(1e-9).Area}");
    using (var ring = vrect.ToNurbs())
    {
        var rp = ring.Point(2.25);
        VgCheck(ring.Degree == 1 && ring.IsClosed && !ring.IsRational && ring.Domain == (0.0, 4.0), "rectangle: the boundary's curve is closed degree 1 over 0..4");
        VgCheck(Math.Abs(rp.X - 3.25) + Math.Abs(rp.Y - 4) + Math.Abs(rp.Z) <= 1e-12, $"rectangle: the boundary's curve at 2.25 is {rp}");
    }
    // test_rectangle_contains_takes_none_as_its_effective_tolerance_and_zero_as_exact
    var vrc = new Rectangle(vgXy, (1, 4), (0, 4)); // diagonal 5: effective 5e-4
    VgCheck(vrc.Contains((2, 2, 9), 0) == "inside" && vrc.Contains((0, 2, 0), 0) == "outside" && vrc.Contains((1, 2, 0), 0) == "on", "rectangle: contains, exact");
    VgCheck(vrc.Contains((1 - 4e-4, 2, 0), 0) == "outside" && vrc.Contains((1 - 4e-4, 2, 0), 1e-3) == "on", "rectangle: contains, named");
    VgCheck(vrc.Contains((1 - 4e-4, 2, 0)) == "on" && vrc.Contains((1 - 4e-4, 2, 0), double.NaN) == "on" && vrc.Contains((1 - 6e-4, 2, 0)) == "outside",
        "rectangle: contains, unset");
    VgCheck(VgRefused(() => vrc.Contains((0, 0, 0), -1)) == "rectangle_contains: the tolerance must be finite and not negative", "rectangle: a negative tolerance");
    var vgEff = 1e-4 * 4 * Math.Sqrt(3);
    VgCheck(new Sphere(vgXy, 2).Contains((2 + 0.9 * vgEff, 0, 0), double.NaN) && !new Sphere(vgXy, 2).Contains((2 + 0.9 * vgEff, 0, 0))
        && !new Sphere(vgXy, 2).Contains((2 + 1.1 * vgEff, 0, 0), double.NaN), "sphere: contains takes NaN as unset");
    // test_a_triangle_answers_its_closed_forms
    var vtri = new Triangle((0, 0, 0), (4, 0, 0), (0, 3, 0));
    VgCheck(vtri.A == (0, 0, 0) && vtri.B == (4, 0, 0) && vtri.C == (0, 3, 0), "triangle: fields");
    VgCheck(vtri.Area() == 6.0 && vtri.Perimeter() == 12.0, "triangle: area and perimeter");
    VgCheck(VgAt(vtri.Centroid(), 4.0 / 3, 1, 0), $"triangle: centroid reads {vtri.Centroid()}");
    var vcc = vtri.Circumcircle();
    VgCheck(VgAt(vcc.Frame.Origin, 2, 1.5, 0) && Math.Abs(vcc.Radius - 2.5) <= 1e-15, $"triangle: circumcircle reads {vcc}");
    VgCheck(vtri.PointAt(0.5, 0.25, 0.25) == (1, 0.75, 0), "triangle: point_at");
    VgCheck(VgAt(vtri.Barycentric((1, 0.75, 5)), 0.5, 0.25, 0.25), $"triangle: barycentric reads {vtri.Barycentric((1, 0.75, 5))}");
    VgCheck(vtri.ClosestPoint((2, -1, 0)) == (2, 0, 0) && vtri.ClosestPoint((1, 1, 3)) == (1, 1, 0), "triangle: closest_point");
    VgCheck(vtri.DistanceTo((1, 1, 3)) == 3.0, "triangle: distance_to");
    VgCheck(vtri.Edge(1) == new Line((4, 0, 0), (0, 3, 0)), $"triangle: edge 1 reads {vtri.Edge(1)}");
    VgCheck(VgRefused(() => vtri.Edge(3)) == "triangle_edge: edge 3 is not 0, 1 or 2", "triangle: edge 3");
    VgCheck(VgRefused(() => _ = new Triangle((0, 0, 0), (1, 1, 1), (2, 2, 2))) == "value_check: the triangle is degenerate (its points are collinear or coincident)",
        "triangle: degenerate");
    VgCheck(VgRefused(() => Triangle.FromValues(new double[] { 0, 0, 0, 4, 0, 0, 0, 3 })) == "value_check: a triangle is 9 numbers, got 8", "triangle: 8 numbers");
    VgCheck(vtri.Transform(new double[] { 1, 0.5, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }) == new Triangle((0, 0, 0), (4, 0, 0), (1.5, 3, 0)), "triangle: any affine map");
    using (var tsheet = vtri.ToSheet())
        VgCheck(VgRel(tsheet.Mass(1e-9).Area, 6.0, 1e-9), $"triangle: the sheet's area is {tsheet.Mass(1e-9).Area}");
    VgCheck(vtri != new Triangle((0, 0, 0), (0, 3, 0), (4, 0, 0)) && vtri.GetHashCode() == new Triangle(vtri.A, vtri.B, vtri.C).GetHashCode(),
        "triangle: equality and hashing");
    // test_a_ray_holds_to_its_half_line_only_in_closest_point
    var vray = new Ray((1, 2, 3), (0, 0, 2));
    VgCheck(vray.Values.SequenceEqual(new double[] { 1, 2, 3, 0, 0, 2 }) && vray.Position == (1, 2, 3) && vray.Direction == (0, 0, 2), "ray: kept as given");
    VgCheck(vray.PointAt(1.5) == (1, 2, 6) && vray.PointAt(-1) == (1, 2, 1), "ray: point_at");
    VgCheck(vray.ClosestPoint((5, 2, 7)) == new CurveFoot(2, (1, 2, 7), true), $"ray: closest reads {vray.ClosestPoint((5, 2, 7))}");
    VgCheck(vray.ClosestPoint((5, 2, -7)) == new CurveFoot(0, (1, 2, 3), true), "ray: behind, the start");
    VgCheck(VgApprox(vray.DistanceTo((5, 2, -7)), Math.Sqrt(16 + 100)), "ray: distance_to");
    VgCheck(VgRefused(() => vray.Bounds()) == "value_bounds: a ray has no box (it is unbounded)", "ray: bounds");
    VgCheck(VgRefused(() => _ = new Ray((0, 0, 0), (0, 0, 0))) == "value_check: the ray's direction is zero", "ray: zero direction");
    VgCheck(VgRefused(() => Ray.FromValues(new double[] { 0, 0, 0, 1, 0, 0, 0 })) == "value_check: a ray is 6 numbers, got 7", "ray: 7 numbers");
    VgCheck(vray.Transform(Transform.ScaleXyz(vgXy, 1, 1, 3)) == new Ray((1, 2, 9), (0, 0, 6)), "ray: scaled");
    // test_rectangles_triangles_and_rays_match_rhino
    var rrr = VgNums("rectangle", "ranges");
    var rrect = new Rectangle(VgNums("rectangle", "frame"), (rrr[0], rrr[1]), (rrr[2], rrr[3]));
    var rrc = VgNums("rectangle", "corners");
    var rrGot = rrect.Corners();
    for (var k = 0; k < 4; k++)
        VgCheck(VgClose(VgP(rrGot[k]), rrc[(3 * k)..(3 * k + 3)], VgExact), $"rhino rectangle: corner {k}");
    VgCheck(VgClose(new[] { rrect.Area(), rrect.Length() }, VgNums("rectangle", "area").Concat(VgNums("rectangle", "circumference")), VgExact),
        "rhino rectangle: area and circumference");
    for (var k = 0; k < 9; k++)
    {
        var n = VgNums($"rectangle_at_{k}", "point");
        VgCheck(VgClose(VgP(rrect.PointAt(n[0])), n[1..4], VgExact), $"rectangle_at_{k}");
    }
    var rWords = new Dictionary<string, string> { ["Inside"] = "inside", ["Outside"] = "outside", ["Coincident"] = "on" };
    foreach (var (c, q) in VgQueries("rectangle").Concat(VgQueries("rectangle_in")))
    {
        VgCheck(VgClose(VgP(rrect.ClosestPoint(VgT(q)).Point), VgNums(c, "boundary"), VgExact), $"{c}: boundary");
        VgCheck(VgClose(VgP(rrect.ClosestPointIn(VgT(q), true)), VgNums(c, "filled"), VgExact), $"{c}: filled");
        VgCheck(rrect.Contains(VgT(q), 0) == rWords[vgRecords[(c, "contains")][0]], $"{c}: contains");
    }
    var rtp = VgNums("triangle", "points");
    var rtri = new Triangle(VgT(rtp, 0), VgT(rtp, 3), VgT(rtp, 6));
    VgCheck(VgClose(new[] { rtri.Area(), rtri.Perimeter() }, VgNums("triangle", "area").Concat(VgNums("triangle", "perimeter")), VgExact),
        "rhino triangle: area and perimeter");
    VgCheck(VgClose(VgP(rtri.Centroid()), VgNums("triangle", "centroid"), VgExact), "rhino triangle: centroid");
    VgCheck(VgClose(rtri.Circumcircle().Values, VgNums("triangle", "circumcircle"), VgExact), "rhino triangle: circumcircle");
    foreach (var (c, q) in VgQueries("triangle").Concat(VgQueries("triangle_in")))
    {
        var w = rtri.Barycentric(VgT(q));
        VgCheck(VgClose(new[] { w.Y, w.Z }, VgNums(c, "barycentric")[..2], VgExact), $"{c}: barycentric");
        VgCheck(VgClose(VgP(rtri.PointAt(w.X, w.Y, w.Z)), VgNums(c, "projected"), VgExact), $"{c}: projected");
        if (Math.Min(w.X, Math.Min(w.Y, w.Z)) < 0)
            VgCheck(VgClose(VgP(rtri.ClosestPoint(VgT(q))), VgNums(c, "boundary"), VgExact), $"{c}: closest");
    }
    var rray = VgNums("ray", "ray");
    var rr = new Ray(VgT(rray, 0), VgT(rray, 3));
    for (var k = 0; k < 4; k++)
    {
        var n = VgNums($"ray_at_{k}", "point");
        VgCheck(VgClose(VgP(rr.PointAt(n[0])), n[1..4], VgExact), $"ray_at_{k}");
    }
    if (vgFailed is not null) return Fail(vgFailed);
    Console.WriteLine($"values: {vgChecks} checks (interval, frame verbs, curves, surfaces, cuboid, rectangle, triangle, ray, Rhino records) all read back");
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
// Clash: Python's test_clash_* trimmed to the marshalling, plus the edge row (clash plan 3).
{
    double[] ClashAt(double x) => new double[] { x, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    string ClashRefused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
    }
    // 1. balls too close: every field read
    using (var a = Solid.Sphere(1))
    using (var b = Solid.Sphere(1))
    using (var collider = new Collider(new[] { a, b }, 1e-3))
    {
        var rows = collider.Clash(new[] { ClashAt(0), ClashAt(2.5) }, 1.0);
        if (rows.Count != 1) return Fail($"clash: the balls gave {rows.Count} rows, not one");
        var r = rows[0];
        if (r.A != 0 || r.B != 1 || r.Kind != "too_close") return Fail($"clash: the balls' row is {r}");
        if (Math.Abs(r.Distance - 0.5) > 1e-3) return Fail($"clash: the balls' distance is {r.Distance}");
        if (r.KindA != "face" || r.KindB != "face" || r.IndexA is null || r.IndexB is null || r.EdgeA is not null || r.EdgeB is not null)
            return Fail($"clash: the balls' features read {r.KindA}#{r.IndexA}/{r.EdgeA}, {r.KindB}#{r.IndexB}/{r.EdgeB}");
        if (Math.Abs(r.OnA[0] - 1) > 2e-3 || Math.Abs(r.OnB[0] - 1.5) > 2e-3) return Fail($"clash: the balls' points read {r.OnA[0]}, {r.OnB[0]}");
        if (r.Text != "" || r.Depth != 0) return Fail($"clash: the balls' text or depth read '{r.Text}', {r.Depth}");
        Console.WriteLine($"clash: {r} refined={r.Refined}");
        if (collider.Clash(new[] { ClashAt(0), ClashAt(2.5) }, 0.25).Count != 0) return Fail("clash: clearance 0.25 still found the balls");
    }
    // 2. boxes face to face: touching, no solid, one overlap region of area 4 on x = 1
    Clash touching;
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    using (var collider = new Collider(new[] { a, b }, 1e-3))
    {
        var rows = collider.Clash(new[] { ClashAt(0), ClashAt(2) });
        if (rows.Count != 1 || rows[0].Kind != "touching" || rows[0].Distance > 1e-3) return Fail($"clash: the boxes face to face read {string.Join(", ", rows)}");
        touching = rows[0];
    }
    var notPenetrating = ClashRefused(() => touching.Solid());
    if (!notPenetrating.StartsWith("clashes_solid: pair (0, 1) is not penetrating")) return Fail($"clash: a touching pair's solid gave '{notPenetrating}'");
    var face = touching.Intersect();
    if (face.Overlaps.Count != 1 || face.Overlaps[0].Loops.Length < 1) return Fail($"clash: the touching pair intersects as {face}");
    var ring = face.Overlaps[0].Loops[0];
    if (ring.Any(p => Math.Abs(p[0] - 1) > 1e-3)) return Fail("clash: the touching ring leaves x = 1");
    var twice = 0.0;
    for (var i = 0; i < ring.Length; i++) twice += ring[i][1] * ring[(i + 1) % ring.Length][2] - ring[(i + 1) % ring.Length][1] * ring[i][2];
    if (Math.Abs(Math.Abs(twice) / 2 - 4) > 1e-6) return Fail($"clash: the touching ring's area is {Math.Abs(twice) / 2}");
    // 3. boxes interpenetrating: depth, features none, the row outlives its collider and its list
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    {
        Clash Penetrating()
        {
            var collider = new Collider(new[] { a, b }, 1e-3);
            var rows = collider.Clash(new[] { ClashAt(0), ClashAt(1.75) });
            collider.Dispose();
            return rows.Count == 1 ? rows[0] : throw new Exception($"clash: the boxes overlapping read {string.Join(", ", rows)}");
        }
        var r = Penetrating();
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        if (r.Kind != "penetrating" || Math.Abs(r.Depth - 0.25) >= 1e-9 || r.Distance != 0) return Fail($"clash: the overlapping row is {r}, depth {r.Depth}");
        if (r.KindA != "none" || r.IndexA is not null || r.EdgeA is not null || r.KindB != "none" || r.IndexB is not null || r.EdgeB is not null)
            return Fail($"clash: a penetrating row's features read {r.KindA}#{r.IndexA}/{r.EdgeA}, {r.KindB}#{r.IndexB}/{r.EdgeB}");
        using var common = r.Solid();
        if (Math.Abs(common.Mass().Volume - 1) > 1e-6) return Fail($"clash: the overlap's volume is {common.Mass().Volume}");
        r.Intersect();
    }
    // 4. the one-shot, over two sets, one set, and one set with the pair allowed
    using (var a0 = Solid.Sphere(1))
    using (var a1 = Solid.Sphere(1).Translate(2.05, 0, 0))
    using (var b0 = Solid.Sphere(1).Translate(0, 2.5, 0))
    using (var b1 = Solid.Sphere(1).Translate(10, 0, 0))
    {
        var two = Blacksmith.Clash(new[] { a0, a1 }, new[] { b0, b1 }, clearance: 1.0, tolerance: 1e-3);
        if (two.Count != 1 || two[0].A != 0 || two[0].B != 0 || two[0].Kind != "too_close" || Math.Abs(two[0].Distance - 0.5) > 1e-3)
            return Fail($"clash: two sets read {string.Join(", ", two)}");
        var one = Blacksmith.Clash(new[] { a0, a1 }, clearance: 1.0, tolerance: 1e-3);
        if (one.Count != 1 || one[0].A != 0 || one[0].B != 1) return Fail($"clash: one set read {string.Join(", ", one)}");
        if (Blacksmith.Clash(new[] { a0, a1 }, clearance: 1.0, tolerance: 1e-3, allowed: new uint[] { 0, 1 }).Count != 0)
            return Fail("clash: an allowed pair was still tested");
    }
    // 5. the refusals, by prefix
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    using (var collider = new Collider(new[] { a, b }))
    {
        foreach (var (got, want) in new[] {
            (ClashRefused(() => collider.Clash(new[] { ClashAt(0), ClashAt(1.75) }, -1)), "collider_clash: clearance -1"),
            (ClashRefused(() => collider.Clash(new[] { ClashAt(0) })), "collider_clash: 1 frames for 2 groups"),
            (ClashRefused(() => collider.Clash(new[] { ClashAt(0), ClashAt(1.75) }, share: (2, 2))), "collider_clash: share (2, 2)"),
            (ClashRefused(() => Blacksmith.Clash(new[] { a, b }, clearance: -1)), "clash: clearance -1"),
            (ClashRefused(() => Blacksmith.Clash(new[] { a, b }, allowed: new uint[] { 5, 0 })), "clash: allowed pair (5, 0) names a part out of range"),
            (ClashRefused(() => Blacksmith.Clash(new[] { a, b }, Array.Empty<Solid>())), "clash: an empty set"),
            (ClashRefused(() => Blacksmith.Clash(new[] { a, b }, allowed: new uint[] { 0, 1, 0 })), "clash: allowed is 3 numbers, not pairs"),
        })
            if (!got.StartsWith(want)) return Fail($"clash: expected '{want}...', got '{got}'");
    }
    // 6. the edge row: b turned 45 degrees about z and tipped, its edge 0.1 from a's edge on x = 1, y = 1
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    using (var collider = new Collider(new[] { a, b }, 1e-3))
    {
        double c = Math.Sqrt(0.5), s = 0.1 * c;
        var tipped = new double[] { 2 + s, 2 + s, 0, c, -c, 0, 0.5, 0.5, c, -0.5, -0.5, c };
        var rows = collider.Clash(new[] { ClashAt(0), tipped }, 0.5);
        if (rows.Count != 1 || rows[0].Kind != "too_close" || Math.Abs(rows[0].Distance - 0.1) > 1e-3) return Fail($"clash: the edge pose read {string.Join(", ", rows)}");
        var r = rows[0];
        if (!Near(r.OnA, new double[] { 1, 1, 0 }, 2e-3)) return Fail($"clash: the edge row's on_a is ({string.Join(", ", r.OnA)})");
        if (r.KindA != "edge" || r.KindB != "edge" || r.EdgeA is null || r.EdgeB is null) return Fail($"clash: the edge row's features read {r.KindA}/{r.EdgeA}, {r.KindB}/{r.EdgeB}");
        var edgesA = a.Edges;
        var onEdge = edgesA[(int)r.EdgeA.Value].Segments.SelectMany(g => new[] { g.A, g.B });
        if (onEdge.Any(p => Math.Abs(p[0] - 1) > 2e-3 || Math.Abs(p[1] - 1) > 2e-3)) return Fail($"clash: a's edge {r.EdgeA} is not the one on x = 1, y = 1");
        if (r.EdgeB.Value >= b.Edges.Count) return Fail($"clash: b's edge {r.EdgeB} is past its {b.Edges.Count} edges");
        Console.WriteLine($"clash: edge row {r}, edge_a {r.EdgeA}, edge_b {r.EdgeB} of {edgesA.Count}");
    }
    // ... and a ball 0.2 off that edge: side a an edge, side b a face, so a swap of the sides shows
    using (var box = Solid.Cuboid(2, 2, 2))
    using (var ball = Solid.Sphere(1))
    using (var collider = new Collider(new[] { box, ball }, 1e-3))
    {
        var off = 1 + 1.2 * Math.Sqrt(0.5);
        var rows = collider.Clash(new[] { ClashAt(0), new double[] { off, off, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 } }, 0.5);
        if (rows.Count != 1 || Math.Abs(rows[0].Distance - 0.2) > 1e-3) return Fail($"clash: the ball by the edge read {string.Join(", ", rows)}");
        var r = rows[0];
        if (r.KindA != "edge" || r.EdgeA is null || r.KindB != "face" || r.EdgeB is not null) return Fail($"clash: the ball by the edge names {r.KindA}/{r.EdgeA}, {r.KindB}/{r.EdgeB}");
    }
}
// Swept clash: Python's test_swept_clash_* trimmed to the marshalling (swept clash plan 2b). A
// 2-cube moving along x from -5 to 5 through a 2-cube at the origin meets it at t = 0.3 and
// leaves at 0.7, at a relative speed of 10 a segment.
{
    const double SweptTol = 1e-3, SweptRes = 1e-3;
    double[] SweptAt(double x, double y = 0) => new double[] { x, y, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    string SweptRefused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
    }
    var through = new[] { new[] { SweptAt(-5), SweptAt(0) }, new[] { SweptAt(5), SweptAt(0) } };
    bool StartsNear(double got, double want) => Math.Abs(got - want) <= SweptTol / 10 + 1e-9;
    bool EndsNear(double got, double want) => Math.Abs(got - want) <= SweptRes + SweptTol / 10;
    // 1. a cube through a cube: every field read; `First` outlives the collider and the swept list
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    {
        IReadOnlyList<SweptClash> Crossing()
        {
            var collider = new Collider(new[] { a, b }, SweptTol);
            var found = collider.SweptClash(through);
            collider.Dispose();
            return found;
        }
        var rows = Crossing();
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        if (rows.Count != 1) return Fail($"swept clash: a cube through a cube gave {rows.Count} rows, not one");
        var r = rows[0];
        if (r.A != 0 || r.B != 1) return Fail($"swept clash: the crossing row is {r}");
        if (!StartsNear(r.FirstTime, 0.3)) return Fail($"swept clash: the crossing's first time is {r.FirstTime}");
        if (r.Intervals.Count != 1 || r.Intervals[0].Start != r.FirstTime || !EndsNear(r.Intervals[0].End, 0.7))
            return Fail($"swept clash: the crossing's intervals read {r}");
        if (r.First.A != 0 || r.First.B != 1 || r.First.Kind != "touching") return Fail($"swept clash: the crossing's first is {r.First}");
        var notPenetrating = SweptRefused(() => r.First.Solid());
        if (!notPenetrating.StartsWith("clashes_solid: pair (0, 1) is not penetrating"))
            return Fail($"swept clash: a touching first's solid gave '{notPenetrating}'");
        var x = r.First.Intersect();
        if (x.Overlaps.Count != 1) return Fail($"swept clash: the crossing's first intersects as {x}");
        if (x.Overlaps[0].Loops.Any(loop => loop.Any(p => Math.Abs(p[0] + 1) > 2 * SweptTol)))
            return Fail("swept clash: the crossing's first contact leaves x = -1");
        Console.WriteLine($"swept clash: {r}");
    }
    // 2. there and back: two intervals, in order
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    using (var collider = new Collider(new[] { a, b }, SweptTol))
    {
        var rows = collider.SweptClash(through.Append(new[] { SweptAt(-5), SweptAt(0) }));
        if (rows.Count != 1 || rows[0].Intervals.Count != 2) return Fail($"swept clash: there and back read {string.Join(", ", rows)}");
        var spans = rows[0].Intervals;
        if (!StartsNear(spans[0].Start, 0.3) || !EndsNear(spans[0].End, 0.7) || !StartsNear(spans[1].Start, 1.3) || !EndsNear(spans[1].End, 1.7))
            return Fail($"swept clash: there and back read {rows[0]}");
    }
    // 3. a miss, seen only within the clearance
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    using (var collider = new Collider(new[] { a, b }, SweptTol))
    {
        var passing = new[] { new[] { SweptAt(-5, 2.5), SweptAt(0) }, new[] { SweptAt(5, 2.5), SweptAt(0) } };
        if (collider.SweptClash(passing, clearance: 0.4).Count != 0) return Fail("swept clash: clearance 0.4 still found the miss");
        var rows = collider.SweptClash(passing, clearance: 0.6);
        if (rows.Count != 1 || rows[0].First.Kind != "too_close" || rows[0].First.Distance < 0.5 - SweptTol || rows[0].First.Distance > 0.6)
            return Fail($"swept clash: the miss at clearance 0.6 read {string.Join(", ", rows)}");
    }
    // 4. a pair starting inside: first time 0, the overlap rebuilt there
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    using (var collider = new Collider(new[] { a, b }, SweptTol))
    {
        var rows = collider.SweptClash(new[] { new[] { SweptAt(1.75), SweptAt(0) }, new[] { SweptAt(5), SweptAt(0) } });
        if (rows.Count != 1 || rows[0].FirstTime != 0 || rows[0].First.Kind != "penetrating")
            return Fail($"swept clash: starting inside read {string.Join(", ", rows)}");
        using var common = rows[0].First.Solid();
        if (Math.Abs(common.Mass().Volume - 1) > 1e-6) return Fail($"swept clash: the starting overlap's volume is {common.Mass().Volume}");
    }
    // 5. the one-shot: set a still at the origin and at y = 20, set b carried along x through them
    using (var a0 = Solid.Cuboid(2, 2, 2))
    using (var a1 = Solid.Cuboid(2, 2, 2).Translate(0, 20, 0))
    using (var b0 = Solid.Cuboid(2, 2, 2))
    using (var b1 = Solid.Cuboid(2, 2, 2))
    {
        var still = new[] { new[] { SweptAt(0), SweptAt(0) }, new[] { SweptAt(0), SweptAt(0) } };
        var moving = new[] { new[] { SweptAt(-5), SweptAt(-5, 20) }, new[] { SweptAt(5), SweptAt(5, 20) } };
        var two = Blacksmith.SweptClash(new[] { a0, a1 }, still, new[] { b0, b1 }, moving, tolerance: SweptTol);
        if (string.Join(" ", two.Select(r => $"{r.A}{r.B}{r.First.A}{r.First.B}")) != "0000 1111")
            return Fail($"swept clash: two sets read {string.Join(", ", two)}");
        using (var collider = new Collider(new[] { a0, a1, b0, b1 }, SweptTol))
        {
            var via = collider.SweptClash(still.Zip(moving, (sa, sb) => sa.Concat(sb)));
            if (string.Join(" ", via.Select(r => $"{r.A},{r.B - 2},{r.FirstTime:R},{string.Join(";", r.Intervals)}"))
                != string.Join(" ", two.Select(r => $"{r.A},{r.B},{r.FirstTime:R},{string.Join(";", r.Intervals)}")))
                return Fail($"swept clash: the collider read {string.Join(", ", via)} where the one-shot read {string.Join(", ", two)}");
        }
        var across = new[] { new[] { SweptAt(0), SweptAt(-5) }, new[] { SweptAt(0), SweptAt(5) } };
        var one = Blacksmith.SweptClash(new[] { a0, b0 }, across, tolerance: SweptTol);
        if (one.Count != 1 || one[0].A != 0 || one[0].B != 1) return Fail($"swept clash: one set read {string.Join(", ", one)}");
        if (Blacksmith.SweptClash(new[] { a0, b0 }, across, tolerance: SweptTol, allowed: new uint[] { 0, 1 }).Count != 0)
            return Fail("swept clash: an allowed pair was still tested");
    }
    // 6. the refusals, by prefix
    using (var a = Solid.Cuboid(2, 2, 2))
    using (var b = Solid.Cuboid(2, 2, 2))
    using (var collider = new Collider(new[] { a, b }, SweptTol))
    {
        var still = new[] { new[] { SweptAt(0) }, new[] { SweptAt(0) } };
        foreach (var (got, want) in new[] {
            (SweptRefused(() => collider.SweptClash(through.Take(1))), "collider_swept_clash: 1 poses, at least 2 are needed"),
            (SweptRefused(() => collider.SweptClash(still)), "collider_swept_clash: 1 frames for 2 groups"),
            (SweptRefused(() => collider.SweptClash(new[] { new[] { SweptAt(0), SweptAt(0) }, new[] { SweptAt(0) } })), "collider_swept_clash: 1 frames for 2 groups"),
            (SweptRefused(() => collider.SweptClash(through, resolution: 0)), "collider_swept_clash: resolution 0"),
            (SweptRefused(() => collider.SweptClash(through, maxSteps: 0)), "collider_swept_clash: max_steps must be at least 1"),
            (SweptRefused(() => collider.SweptClash(through, clearance: -1)), "collider_swept_clash: clearance -1"),
            (SweptRefused(() => collider.SweptClash(through, share: (2, 2))), "collider_swept_clash: share (2, 2)"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a }, still, new[] { b })), "swept_clash: others and other_poses go together"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a }, still, otherPoses: still)), "swept_clash: others and other_poses go together"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a }, still, new[] { b }, still.Take(1))), "swept_clash: 2 poses for set a, 1 for set b"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a }, still, new[] { b }, new[] { new[] { SweptAt(0) }, new[] { SweptAt(0), SweptAt(0) } })),
                "swept_clash: pose 1 of set b has 2 frames for 1 parts"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a }, still, Array.Empty<Solid>(), new[] { Array.Empty<double[]>(), Array.Empty<double[]>() })),
                "swept_clash: an empty set"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a, b }, through, allowed: new uint[] { 5, 0 })), "swept_clash: allowed pair (5, 0) names a part out of range"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a, b }, through, allowed: new uint[] { 0, 1, 0 })), "swept_clash: allowed is 3 numbers, not pairs"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a, b }, through, maxSteps: 0)), "swept_clash: max_steps must be at least 1"),
            (SweptRefused(() => Blacksmith.SweptClash(new[] { a, b }, through.Take(1))), "swept_clash: 1 poses, at least 2 are needed"),
        })
            if (!got.StartsWith(want)) return Fail($"swept clash: expected '{want}...', got '{got}'");
    }
}
// Identity and attributes: Python's TestIdentity trimmed to the marshalling (identity plan C3).
// `BlockAndPin` is a 10-cube on the origin and a pin through it (radius 2, along z, z -10..10),
// both tracked; `IdXy` the split plane.
{
    double[] IdXy = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    (Solid Block, Solid Pin) BlockAndPin()
    {
        using var block0 = Solid.Cuboid(10, 10, 10);
        using var pin0 = Solid.Cylinder(2, 20);
        using var pin1 = pin0.Translate(0, 0, -10);
        return (block0.Tracked(), pin1.Tracked());
    }
    double Nz(Solid s, int f) => s.FaceRef(f)[6];
    string IdRefused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
    }
    string Os(IEnumerable<(int Operand, ulong Id)> o) => "[" + string.Join(", ", o.Select(p => $"({p.Operand}, {p.Id})")) + "]";
    // 1. tracking numbers faces and edges; an untracked solid has no ids
    using (var plain = Solid.Cuboid(1, 2, 3))
    using (var t = plain.Tracked())
    using (var tt = t.Tracked())
    {
        if (plain.IsTracked || plain.FaceId(0) is not null || plain.EdgeId(0) is not null || plain.FaceOrigins(0).Count != 0)
            return Fail("identity: an untracked cuboid reads ids or origins");
        if (!t.IsTracked || tt.FaceId(5) != 6UL) return Fail("identity: tracked() of a tracked solid lost its ids");
        if (string.Join(",", Enumerable.Range(0, 6).Select(f => t.FaceId(f))) != "1,2,3,4,5,6") return Fail("identity: the faces are not 1..6");
        if (string.Join(",", Enumerable.Range(0, 12).Select(e => t.EdgeId(e))) != string.Join(",", Enumerable.Range(1, 12)))
            return Fail("identity: the edges are not 1..12");
        if (t.FaceWithId(4) != 3 || t.FaceWithId(7) is not null || t.FaceWithId(0) is not null) return Fail("identity: face_with_id read wrong");
        if (t.EdgeWithId(12) != 11 || t.EdgeWithId(13) is not null) return Fail("identity: edge_with_id read wrong");
        if (Os(t.FaceOrigins(2)) != "[(0, 3)]" || Os(t.EdgeOrigins(11)) != "[(0, 12)]")
            return Fail($"identity: origins read {Os(t.FaceOrigins(2))} and {Os(t.EdgeOrigins(11))}");
        foreach (var (got, want) in new[] {
            (IdRefused(() => t.FaceId(6)), "face_id: face 6 of 6"),
            (IdRefused(() => t.FaceOrigins(6)), "face_origin_count: face 6 of 6"),
            (IdRefused(() => t.EdgeId(12)), "edge_id: edge 12 of 12"),
        })
            if (got != want) return Fail($"identity: expected '{want}', got '{got}'");
    }
    // 2. a cut's origins and history
    {
        var (block, idPin) = BlockAndPin();
        using (block)
        using (idPin)
        using (var cut = block.Cut(idPin))
        using (var untracked = Solid.Cuboid(1, 1, 1))
        {
            var wall = Enumerable.Range(0, idPin.Faces).First(f => idPin.FaceKind(f) == "cylinder");
            var wallId = idPin.FaceId(wall)!.Value;
            var caps = Enumerable.Range(0, idPin.Faces).Where(f => f != wall).Select(f => (1, idPin.FaceId(f)!.Value)).ToList();
            var bore = Enumerable.Range(0, cut.Faces).First(f => cut.FaceKind(f) == "cylinder");
            if (Os(cut.FaceOrigins(bore)) != $"[(1, {wallId})]") return Fail($"identity: the bore's origins read {Os(cut.FaceOrigins(bore))}");
            if (cut.FaceId(bore) != 7UL) return Fail($"identity: the bore's id is {cut.FaceId(bore)}");
            if (Enumerable.Range(0, cut.Faces).Any(f => f != bore && Os(cut.FaceOrigins(f)) != $"[(0, {cut.FaceId(f)})]"))
                return Fail("identity: a box face of the cut names another origin");
            var h = cut.History(block, idPin);
            if (!h.Kept.SequenceEqual(Enumerable.Range(1, 6).Select(k => ((0, (ulong)k), (ulong)k)))) return Fail($"identity: the cut kept {h}");
            if (h.Modified.Count != 1 || h.Modified[0].Input != (1, wallId) || !h.Modified[0].Outputs.SequenceEqual(new ulong[] { 7 }))
                return Fail($"identity: the cut modified {h}");
            if (h.Generated.Count != 0 || !h.Deleted.SequenceEqual(caps)) return Fail($"identity: the cut generated or deleted {h}");
            if (h.ToString() != "History(kept=6, modified=1, generated=0, deleted=2)") return Fail($"identity: the history reads {h}");
            if (!h.Equals(cut.History(block, idPin))) return Fail("identity: two reads of one history differ");
            var e = cut.EdgeHistory(block, idPin);
            if (e.Kept.Count != 12 || Os(e.Deleted) != "[(1, 1), (1, 2), (1, 3)]" || e.Generated.Count != 3 || e.Modified.Count != 0)
                return Fail($"identity: the cut's edge history reads {e}");
            var oneInput = IdRefused(() => cut.History(block));
            if (!System.Text.RegularExpressions.Regex.IsMatch(oneInput, @"^history: face \d+ names operand 1"))
                return Fail($"identity: one input gave '{oneInput}'");
            foreach (var (got, want) in new[] {
                (IdRefused(() => cut.History(block, untracked)), "history: input 1 is not tracked"),
                (IdRefused(() => untracked.EdgeHistory(block)), "edge_history: the result is not tracked"),
            })
                if (got != want) return Fail($"identity: expected '{want}', got '{got}'");
        }
    }
    // 3. a union renumbers the second operand's clashing ids
    using (var a0 = Solid.Cuboid(10, 10, 10))
    using (var a = a0.Tracked())
    using (var b0 = Solid.Cuboid(10, 10, 10).Translate(5, 5, 5))
    using (var b = b0.Tracked())
    using (var joined = a.Join(b))
    {
        if (joined.Faces != 12) return Fail($"identity: the union has {joined.Faces} faces");
        var firsts = new SortedSet<ulong>();
        var seconds = new List<(ulong Id, ulong Origin)>();
        for (var f = 0; f < joined.Faces; f++)
        {
            var (k, id) = joined.FaceOrigins(f)[0];
            if (k == 0)
            {
                if (joined.FaceId(f) != id) return Fail($"identity: union face {f} lost operand 0's id");
                firsts.Add(id);
            }
            else seconds.Add((joined.FaceId(f)!.Value, id));
        }
        if (string.Join(",", firsts) != "1,2,3,4,5,6") return Fail($"identity: the union's first operand ids are {string.Join(",", firsts)}");
        if (string.Join(",", seconds.Select(s => s.Id)) != "7,8,9,10,11,12") return Fail("identity: the second operand is not renumbered 7..12 in face order");
        if (string.Join(",", seconds.Select(s => s.Origin).OrderBy(x => x)) != "1,2,3,4,5,6") return Fail("identity: the renumbered faces' origins are not operand 1's ids");
    }
    // 4. a split halves the sides and its bodies keep the split's origins
    using (var block0 = Solid.Cuboid(2, 4, 6))
    using (var block = block0.Tracked())
    {
        var pieces = block.SplitByPlane(IdXy);
        try
        {
            if (pieces.Count != 2) return Fail($"identity: the split gave {pieces.Count} pieces");
            var sides = Enumerable.Range(0, 6).Where(f => Math.Abs(Nz(block, f)) < 0.5).Select(f => block.FaceId(f)!.Value).ToHashSet();
            if (sides.Count != 4) return Fail("identity: the block has not four sides");
            var halves = sides.ToDictionary(s => s, _ => new List<ulong>());
            int cutFaces = 0, capFaces = 0;
            foreach (var piece in pieces)
                for (var f = 0; f < piece.Faces; f++)
                {
                    var o = piece.FaceOrigins(f);
                    var id = piece.FaceId(f)!.Value;
                    if (o.Count == 0)
                    {
                        if (id <= 6) return Fail($"identity: a cut face kept id {id}");
                        cutFaces++;
                    }
                    else if (sides.Contains(o[0].Id))
                    {
                        if (o.Count != 1 || o[0].Operand != 0) return Fail($"identity: a half reads {Os(o)}");
                        halves[o[0].Id].Add(id);
                    }
                    else
                    {
                        if (Os(o) != $"[(0, {id})]") return Fail($"identity: a cap reads {Os(o)}");
                        capFaces++;
                    }
                }
            if (cutFaces != 2 || capFaces != 2) return Fail($"identity: the split has {cutFaces} cut faces and {capFaces} caps");
            foreach (var (s, ids) in halves)
                if (ids.Count != 2 || ids.Count(x => x == s) != 1) return Fail($"identity: side {s} split as [{string.Join(", ", ids)}]");
            foreach (var piece in pieces)
            {
                var h = piece.History(block);
                if (h.Generated.Count != 1 || h.Deleted.Count != 1) return Fail($"identity: a piece's history reads {h}");
            }
        }
        finally
        {
            foreach (var p in pieces) p.Dispose();
        }
    }
    // 5. a fillet's round is generated
    using (var block0 = Solid.Cuboid(10, 10, 10))
    using (var block = block0.Tracked())
    using (var idRounded = block.Fillet(new[] { 0 }, 1.0))
    {
        if (idRounded.Faces != 7) return Fail($"identity: the fillet has {idRounded.Faces} faces");
        var round = Enumerable.Range(0, idRounded.Faces).First(f => idRounded.FaceKind(f) != "plane");
        if (idRounded.FaceOrigins(round).Count != 0 || idRounded.FaceId(round) != 7UL) return Fail("identity: the round is not generated with id 7");
        var h = idRounded.History(block);
        if (!h.Generated.SequenceEqual(new ulong[] { 7 }) || h.Kept.Count != 6) return Fail($"identity: the fillet's history reads {h}");
        if (idRounded.EdgeWithId(1) is not null) return Fail("identity: the idRounded edge is still found");
    }
    // 6. a flush join with merge names one origin per input (the `Merged` step)
    using (var a0 = Solid.Cuboid(10, 10, 10))
    using (var a = a0.Tracked())
    using (var b0 = Solid.Cuboid(4, 10, 10).Translate(7, 0, 0))
    using (var b = b0.Tracked())
    using (var merged = a.Join(b, merge: true))
    {
        if (merged.Faces != 6) return Fail($"identity: the merged join has {merged.Faces} faces");
        var two = 0;
        for (var f = 0; f < merged.Faces; f++)
        {
            var o = merged.FaceOrigins(f);
            if (Math.Abs(merged.FaceRef(f)[4]) < 0.5)
            {
                if (o.Count != 2 || o[0].Operand != 0 || o[1].Operand != 1) return Fail($"identity: merged face {f} reads {Os(o)}");
                if (a.FaceWithId(o[0].Id) is null || b.FaceWithId(o[1].Id) is null) return Fail($"identity: merged face {f}'s origins are not on the inputs");
                two++;
            }
            else if (o.Count != 1) return Fail($"identity: merged face {f} reads {Os(o)}");
        }
        if (two != 4) return Fail($"identity: {two} merged faces have two origins");
        var h = merged.History(a, b);
        if (h.Generated.Count != 0 || h.Deleted.Count != 2) return Fail($"identity: the merged join's history reads {h}");
        if (h.Modified.Count(mod => mod.Outputs.Count == 1 && mod.Input.Operand == 1) != 4) return Fail($"identity: the merged join's modified reads {h}");
    }
    // 7. the same chain twice numbers the same
    {
        string Run()
        {
            var (block, idPin) = BlockAndPin();
            using (block)
            using (idPin)
            using (var cut = block.Cut(idPin))
            {
                var line = cut.Edges.First(e => e.IsLine).Index;
                using var r = cut.Fillet(new[] { line }, 1.0);
                return string.Join(",", Enumerable.Range(0, r.Faces).Select(f => r.FaceId(f))) + "|"
                    + string.Join(",", Enumerable.Range(0, r.Edges.Count).Select(e => r.EdgeId(e)));
            }
        }
        var chainFirst = Run();
        if (chainFirst != Run()) return Fail("identity: the same chain numbered differently");
    }
    // 8. attributes are set, read, listed in key order and refused
    using (var cube = Solid.Cuboid(1, 2, 3))
    using (var s = cube.WithAttribute("material", "steel"))
    {
        if (!s.IsTracked) return Fail("identity: an attribute did not track the solid");
        if (s.Attribute("material") != "steel" || s.Attribute("absent") is not null) return Fail("identity: attribute() read wrong");
        string Pairs(IReadOnlyDictionary<string, string> map) => string.Join(";", map.Select(p => $"{p.Key}={p.Value}"));
        if (Pairs(s.Attributes) != "material=steel") return Fail($"identity: attributes read {Pairs(s.Attributes)}");
        if (s.Attributes is IDictionary<string, string> { IsReadOnly: false }) return Fail("identity: attributes are writable");
        if (!ReferenceEquals(s.Attributes, s.Attributes)) return Fail("identity: attributes are built twice");
        using (var both = s.WithAttributes(new Dictionary<string, string> { ["zeta"] = "1", ["alpha"] = "2" }))
            if (Pairs(both.Attributes) != "alpha=2;material=steel;zeta=1") return Fail($"identity: attributes listed as {Pairs(both.Attributes)}");
        const string text = "acciaio inossidabile è ☃ \U0001f527";
        using (var withText = s.WithAttribute("m", text))
            if (withText.Attribute("m") != text) return Fail($"identity: the non-ASCII value read back as {withText.Attribute("m")}");
        using (var empty = s.WithAttribute("empty", ""))
            if (empty.Attribute("empty") != "") return Fail("identity: an empty value did not round-trip");
        var refused = IdRefused(() => s.WithAttribute("", "x"));
        if (refused != "with_attribute: the key is empty") return Fail($"identity: an empty key gave '{refused}'");
        using (var absent = s.WithoutAttribute("absent"))
            if (Pairs(absent.Attributes) != "material=steel") return Fail("identity: removing an absent key changed the attributes");
        using (var none = s.WithoutAttribute("material"))
            if (none.Attributes.Count != 0) return Fail("identity: removing the key left it");
        if (cube.Attributes.Count != 0) return Fail("identity: a plain cuboid has attributes");
    }
    // 9. face attributes survive a translate and a split
    using (var block = Solid.Cuboid(10, 10, 10))
    {
        var side = Enumerable.Range(0, 6).First(f => Math.Abs(Nz(block, f)) < 0.5);
        using var s = block.WithFaceAttribute(side, "finish", "ground");
        if (s.FaceAttribute(side, "finish") != "ground") return Fail("identity: the face attribute did not read back");
        var other = (side + 1) % 6;
        if (s.FaceAttribute(other, "finish") is not null || s.FaceAttributes(other).Count != 0) return Fail("identity: another face has the attribute");
        if (string.Join(";", s.FaceAttributes(side).Select(p => $"{p.Key}={p.Value}")) != "finish=ground") return Fail("identity: face_attributes read wrong");
        if (s.FaceAttributes(side) is IDictionary<string, string> { IsReadOnly: false }) return Fail("identity: face attributes are writable");
        using (var two = s.WithFaceAttributes(side, new Dictionary<string, string> { ["b"] = "1", ["a"] = "2" }))
            if (string.Join(",", two.FaceAttributes(side).Keys) != "a,b,finish") return Fail($"identity: face attributes listed as {string.Join(",", two.FaceAttributes(side).Keys)}");
        using (var without = s.WithoutFaceAttribute(side, "finish"))
            if (without.FaceAttributes(side).Count != 0) return Fail("identity: removing the face attribute left it");
        using (var moved = s.Translate(5, 0, 0))
            if (moved.FaceAttribute(side, "finish") != "ground") return Fail("identity: a translate lost the face attribute");
        foreach (var (got, want) in new[] {
            (IdRefused(() => s.FaceAttribute(6, "finish")), "face_attribute: face 6 is not one of the solid's 6"),
            (IdRefused(() => s.WithFaceAttribute(side, "", "x")), "with_face_attribute: the key is empty"),
        })
            if (got != want) return Fail($"identity: expected '{want}', got '{got}'");
        var sideId = s.FaceId(side)!.Value;
        var pieces = s.SplitByPlane(IdXy);
        var found = pieces.SelectMany(p => Enumerable.Range(0, p.Faces).Where(f => p.FaceOrigins(f).Contains((0, sideId))).Select(f => p.FaceAttribute(f, "finish"))).ToList();
        foreach (var p in pieces) p.Dispose();
        if (string.Join(",", found) != "ground,ground") return Fail($"identity: the split side's pieces read {string.Join(",", found)}");
    }
    // 10. a solid's attributes reach STEP
    using (var cube = Solid.Cuboid(1, 2, 3))
    using (var s = cube.WithAttribute("material", "steel"))
    {
        var stepText = s.StepText();
        if (CountOf(stepText, "PROPERTY_DEFINITION('material','user defined attribute',") != 1) return Fail("identity: the attribute is not in STEP once");
        if (!stepText.Contains("DESCRIPTIVE_REPRESENTATION_ITEM('material','steel')")) return Fail("identity: the attribute's value is not in STEP");
        if (!stepText.Split("ENDSEC;")[0].Contains("AP242")) return Fail("identity: the STEP header does not name AP242");
    }
    // 11. edges are found again after a stretch, vertices after a move
    using (var box = Solid.Cuboid(10, 10, 10))
    using (var longer = Solid.Cuboid(11, 10, 10))
    using (var moved = box.Translate(1e-4, 0, 0))
    {
        var n = box.Edges.Count;
        var refs = Enumerable.Range(0, n).Select(box.EdgeRef).ToList();
        if (refs.Any(r => r.Length != 15)) return Fail("identity: an edge reference is not fifteen numbers");
        var found = refs.Select(r => longer.FindEdge(r)).ToList();
        if (found.Any(g => g is null) || !found.Select(g => g!.Value).OrderBy(g => g).SequenceEqual(Enumerable.Range(0, n)))
            return Fail($"identity: the stretched box's edges found as [{string.Join(", ", found)}]");
        for (var i = 0; i < n; i++)
        {
            var tangent = longer.EdgeRef(found[i]!.Value);
            if (Math.Abs(refs[i][4] * tangent[4] + refs[i][5] * tangent[5] + refs[i][6] * tangent[6]) <= 0.99)
                return Fail($"identity: edge {i} found one running another way");
        }
        var bad = (double[])refs[0].Clone();
        bad[1] = double.NaN;
        foreach (var (got, want) in new[] {
            (IdRefused(() => box.FindEdge(bad)), "find_edge: an edge reference is fifteen finite numbers"),
            (IdRefused(() => box.FindEdge(refs[0].Take(14).ToArray())), "find_edge: an edge reference is fifteen finite numbers"),
            (IdRefused(() => box.EdgeRef(12)), "edge_ref: edge 12 of 12"),
        })
            if (got != want) return Fail($"identity: expected '{want}', got '{got}'");
        if (box.VertexCount != 8) return Fail($"identity: the box has {box.VertexCount} vertices");
        for (var v = 0; v < 8; v++)
        {
            var p = box.VertexRef(v);
            if (p.Length != 3 || moved.FindVertex(p) != v) return Fail($"identity: vertex {v} not found after the move");
        }
        if (box.FindVertex(new[] { 100.0, 0, 0 }) is not null) return Fail("identity: a far point found a vertex");
        var nan = IdRefused(() => box.FindVertex(new[] { 0, 0, double.NaN }));
        if (!nan.StartsWith("find_vertex: ")) return Fail($"identity: a NaN point gave '{nan}'");
    }
    Console.WriteLine("identity: tracking, a cut's history, a union, a split, a fillet, a merged join, a chain twice, attributes, face attributes, STEP and edge/vertex references: ok");
}
// An assembly's swept clash: Python's test_assembly_* swept tests trimmed to the marshalling
// (swept clash plan 3c). The rig: a `base` plate on link `ground`; an `arm`, cuboid(3, 0.2, 0.2)
// from the hinge out along x, on link `arm`, turning on `hinge`; a `carriage` far out on `slide`
// (cylindrical, two values); and two cubes in no link: `chord` below the hinge, which the chord
// between the arm's end poses crosses and its arc never does, and `circle` on the arm's circle.
{
    const double SweptTol = 1e-3;
    double[] RigAt(double x, double y = 0, double z = 0) => new double[] { x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    string RigRefused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
    }
    static (string Joint, IReadOnlyList<double> Values) Key(string joint, params double[] values) => (joint, values);
    Assembly Hand()
    {
        // a `tip` cube on link `body`, and a `nub` well above it on `nubs`, turning on `turn`
        var hand = new Assembly("hand");
        using (var tip = Solid.Cuboid(0.4, 0.4, 0.4)) hand.Place(tip, RigAt(0), "tip");
        using (var nub = Solid.Cuboid(0.2, 0.2, 0.2)) hand.Place(nub, RigAt(0, 0, 2), "nub");
        hand.Link("body", "tip");
        hand.Link("nubs", "nub");
        hand.Joint("turn", "body", "nubs");
        hand.Pair("turn", "revolute", Frame.Xy());
        return hand;
    }
    Assembly Rig(Assembly? hand = null)
    {
        var rig = new Assembly("rig");
        using (var plate = Solid.Cuboid(1, 1, 0.4)) rig.Place(plate, RigAt(0, 0, -1), "base");
        if (hand is null)
        {
            using var arm = Solid.Cuboid(3, 0.2, 0.2);
            rig.Place(arm, RigAt(1.5), "arm");
        }
        else rig.Place(hand, RigAt(1.5), "hand");
        foreach (var (name, at) in new[] { ("chord", RigAt(0, -1.2)), ("circle", RigAt(0, 1.5)), ("carriage", RigAt(20)) })
            using (var cube = Solid.Cuboid(0.4, 0.4, 0.4)) rig.Place(cube, at, name);
        rig.Link("ground", "base");
        rig.Link("arm", hand is null ? "arm" : "hand");
        rig.Link("carriage", "carriage");
        foreach (var (joint, end, kind) in new[] { ("hinge", "arm", "revolute"), ("slide", "carriage", "cylindrical") })
        {
            rig.Joint(joint, "ground", end);
            rig.Pair(joint, kind, Frame.Xy());
        }
        rig.Base("ground");
        return rig;
    }
    // the hinge at 0, 90 and 180 degrees, the carriage sliding 0, 0.5, 1 unturned
    var swing = new[] {
        new[] { Key("hinge", 0.0), Key("slide", 0.0, 0.0) },
        new[] { Key("hinge", Math.PI / 2), Key("slide", 0.5, 0.0) },
        new[] { Key("hinge", Math.PI), Key("slide", 1.0, 0.0) },
    };
    // the time the arm's leading face (y = 0.1 in its own frame) is `gap` from the circle cube's
    // corner (0.2, 1.3), the first point it meets, in the first segment
    double CircleTime(double gap)
    {
        double r = Math.Sqrt(1.3 * 1.3 + 0.2 * 0.2), phi = Math.Atan2(0.2, 1.3);
        return (Math.Acos((0.1 + gap) / r) - phi) / (Math.PI / 2);
    }
    string Named(IReadOnlyList<string> names, IEnumerable<SweptClash> rows) => string.Join(" ", rows.Select(r => $"({names[r.A]}, {names[r.B]})"));
    // 1. parts: depth first, placements in order, a "/" inside a name escaped
    using (var sub = new Assembly("pair"))
    using (var top = new Assembly("top"))
    using (var empty = new Assembly("empty"))
    {
        using (var x = Solid.Cuboid(1, 1, 1)) sub.Place(x, RigAt(0), "x");
        using (var y = Solid.Cuboid(1, 1, 1)) sub.Place(y, RigAt(2), "y");
        using (var p = Solid.Cuboid(1, 1, 1)) top.Place(p, RigAt(0, 5), "p");
        top.Place(sub, RigAt(0), "a/b");
        using (var q = Solid.Cuboid(1, 1, 1)) top.Place(q, RigAt(0, 9), "q");
        var parts = top.Parts();
        if (!parts.SequenceEqual(new[] { "p", "a\\/b/x", "a\\/b/y", "q" })) return Fail($"assembly parts: read [{string.Join(", ", parts)}]");
        if (empty.Parts().Count != 0) return Fail("assembly parts: an empty assembly lists parts");
    }
    // 2. the arm sweeps its arc, not its chord: one row, (arm, circle), within the arc's window
    using (var rig = Rig())
    {
        var names = rig.Parts();
        if (!names.SequenceEqual(new[] { "base", "arm", "chord", "circle", "carriage" })) return Fail($"assembly swept clash: the rig's parts read [{string.Join(", ", names)}]");
        var rows = rig.SweptClash(swing, tolerance: SweptTol);
        if (Named(names, rows) != "(arm, circle)") return Fail($"assembly swept clash: the swing read {Named(names, rows)}");
        double within = CircleTime(SweptTol), meets = CircleTime(0.0);
        if (rows[0].FirstTime < within - 1e-9 || rows[0].FirstTime > meets + 1e-9)
            return Fail($"assembly swept clash: the swing's first time {rows[0].FirstTime} is outside [{within}, {meets}]");
        if (rows[0].First is not Clash) return Fail("assembly swept clash: the swing's first is not a Clash");
        Console.WriteLine($"assembly swept clash: {rows[0]}");
    }
    // 3. the first clash is at the posed frames: the arm starts at 1.5 rad, through the circle cube
    using (var rig = Rig())
    {
        var rows = rig.SweptClash(new[] { new[] { Key("hinge", 1.5), Key("slide", 0.0, 0.0) }, new[] { Key("hinge", Math.PI), Key("slide", 0.0, 0.0) } },
            tolerance: SweptTol);
        if (string.Join(" ", rows.Select(r => $"({r.A}, {r.B}, {r.FirstTime})")) != "(1, 3, 0)")
            return Fail($"assembly swept clash: from 1.5 rad read {string.Join(", ", rows)}");
        using var common = rows[0].First.Solid();
        var got = common.BoundsBox(SweptTol);
        double co = Math.Cos(1.5), si = Math.Sin(1.5);
        using var armBar = Solid.Cuboid(3, 0.2, 0.2).Translate(1.5, 0, 0);
        var want = armBar.BoundsBox(SweptTol).Moved(new double[] { 0, 0, 0, co, si, 0, -si, co, 0, 0, 0, 1 });
        for (var k = 0; k < 3; k++)
            if (got.Lo[k] < want.Lo[k] - 1e-6 || got.Hi[k] > want.Hi[k] + 1e-6)
                return Fail($"assembly swept clash: the first overlap {got} leaves the turned arm {want}");
        if (got.Lo[1] < 1.3 - 4 * SweptTol || got.Hi[1] > 1.7 + 4 * SweptTol || got.Hi[0] <= got.Lo[0])
            return Fail($"assembly swept clash: the first overlap {got} is not at the circle cube");
    }
    // 4. joined links are tested only when asked: a pin on the arm's link inside a bore on ground
    using (var pinned = new Assembly("pinned"))
    {
        using (var bore = Solid.Cuboid(0.6, 0.6, 0.6)) pinned.Place(bore, RigAt(0), "bore");
        using (var pinCube = Solid.Cuboid(0.2, 0.2, 0.2)) pinned.Place(pinCube, RigAt(0), "pin");
        pinned.Link("ground", "bore");
        pinned.Link("arm", "pin");
        pinned.Joint("hinge", "ground", "arm");
        pinned.Pair("hinge", "revolute", Frame.Xy());
        var keys = new[] { new[] { Key("hinge", 0.0) }, new[] { Key("hinge", 1.0) } };
        if (pinned.SweptClash(keys, tolerance: SweptTol).Count != 0) return Fail("assembly swept clash: a joined pair was tested unasked");
        var rows = pinned.SweptClash(keys, tolerance: SweptTol, joined: true);
        if (string.Join(" ", rows.Select(r => $"({r.A}, {r.B}, {r.FirstTime})")) != "(0, 1, 0)")
            return Fail($"assembly swept clash: joined read {string.Join(", ", rows)}");
        if (pinned.SweptClash(keys, tolerance: SweptTol, joined: true, allowed: new uint[] { 0, 1 }).Count != 0)
            return Fail("assembly swept clash: an allowed joined pair was still tested");
    }
    // 5. a sub-assembly rides its placement's link
    using (var hand = Hand())
    using (var rig = Rig(hand))
    {
        var names = rig.Parts();
        if (!names.SequenceEqual(new[] { "base", "hand/tip", "hand/nub", "chord", "circle", "carriage" }))
            return Fail($"assembly swept clash: the handed rig's parts read [{string.Join(", ", names)}]");
        var rows = rig.SweptClash(swing, tolerance: SweptTol);
        if (Named(names, rows) != "(hand/tip, circle)") return Fail($"assembly swept clash: the handed swing read {Named(names, rows)}");
    }
    // 6. the refusals, by their exact words: the wrapper's own first, then the kernel's passed on
    using (var hand = Hand())
    using (var rig = Rig(hand))
    {
        var two = new[] { new[] { Key("hinge", 0.0) }, new[] { Key("hinge", 1.0) } };
        foreach (var (got, want) in new[] {
            (RigRefused(() => rig.SweptClash(new[] { new[] { Key("hinge", 0.0), Key("slide", 0, 0) }, new[] { Key("hinge", 1.0), Key("slide", 0, 0) }, new[] { Key("hinge", 2.0) } })),
                "swept_clash: joint 'slide' is in keyframe 0 and not in keyframe 2"),
            (RigRefused(() => rig.SweptClash(new[] { new[] { Key("hinge", 0.0) }, new[] { Key("hinge", 1.0), Key("slide", 0, 0) } })),
                "swept_clash: joint 'slide' is in keyframe 1 and not in keyframe 0"),
            (RigRefused(() => rig.SweptClash(new[] { new[] { Key("hinge", 0.0) }, new[] { Key("hinge", 1.0), Key("hinge", 2.0) } })),
                "swept_clash: joint 'hinge' is given twice"),
            (RigRefused(() => rig.SweptClash(new[] { new[] { Key("slide", 0, 0) }, new[] { Key("slide", 1) } })),
                "swept_clash: joint 'slide' has 2 values in keyframe 0 and 1 in keyframe 1"),
            (RigRefused(() => rig.SweptClash(new[] { new[] { Key("hand/turn", 0.0) }, new[] { Key("hand/turn", 1.0) } })),
                "swept_clash: joint 'hand/turn' is in a sub-assembly; a sweep moves this assembly's own joints"),
            (RigRefused(() => rig.SweptClash(new[] { new[] { Key("elbow", 0.0) }, new[] { Key("elbow", 1.0) } })),
                "swept_clash: no joint named 'elbow' in assembly 'rig' or under it"),
            (RigRefused(() => rig.SweptClash(new[] { new[] { Key("hinge", 0, 0) }, new[] { Key("hinge", 1, 1) } })),
                "swept_clash: joint 'hinge' takes 1 values, but 2 were given"),
            (RigRefused(() => rig.SweptClash(two.Take(1))), "swept_clash: 1 poses, at least 2 are needed"),
            (RigRefused(() => rig.SweptClash(two, resolution: 0)), "swept_clash: resolution 0"),
            (RigRefused(() => rig.SweptClash(two, maxSteps: 0)), "swept_clash: max_steps must be at least 1"),
            (RigRefused(() => rig.SweptClash(two, allowed: new uint[] { 9, 0 })), "swept_clash: allowed pair (9, 0) names a part out of range"),
            (RigRefused(() => rig.SweptClash(two, allowed: new uint[] { 0, 1, 2 })), "swept_clash: allowed is 3 numbers, not pairs"),
            (RigRefused(() => rig.SweptClash(two, ground: "wheel")), "swept_clash: assembly 'rig' has no link named 'wheel'"),
        })
            if (got != want && !(want == "swept_clash: resolution 0" && got.StartsWith(want)))
                return Fail($"assembly swept clash: expected '{want}', got '{got}'");
    }
}
// Wall thickness:Python's test_thickness_* / test_mesh_thickness_* trimmed to the marshalling (plan 2b).
{
    var xy = new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    string ThickRefused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
        catch (ObjectDisposedException e) { return e.Message; }
    }
    uint FaceHolding(ThicknessGauge gauge, Solid solid, uint body, double[] p)
    {
        for (uint f = 0; f < solid.Faces; f++)
        {
            var r = gauge.ThicknessAt(body, f, p, 100.0, 0.5);
            if (r is not null && Near(r.Point, p, 1e-9)) return f;
        }
        throw new Exception($"thickness: no face holds ({string.Join(", ", p)})");
    }
    // 1. a wallPlate reads 2 at every cap vertex
    using (var wallPlate = Solid.Cuboid(10, 10, 2))
    {
        IReadOnlyList<Thickness> rows;
        ThicknessMesh mesh;
        using (var g = new ThicknessGauge(new[] { wallPlate }))
        {
            if (g.Count != 1 || g.Tolerance != 0.01) return Fail($"thickness: the gauge reads {g.Count} bodies at {g.Tolerance}");
            rows = g.Thickness(10.0, 0.5);
            mesh = g.Mesh(0);
        }
        var caps = rows.Where(r => Math.Abs(Math.Abs(r.Point[2]) - 1) < 1e-9 && Math.Abs(r.Opposite[2] + r.Point[2]) < 1e-9).ToList();
        if (caps.Count < 8) return Fail($"thickness: {caps.Count} cap rows");
        foreach (var r in caps)
        {
            if (Math.Abs(r.Value - 2) > 1e-9 || Math.Abs(r.ExactThickness - 2) > 1e-9) return Fail($"thickness: a cap row reads {r}");
            if (Math.Abs(r.ExactOpposite[2] + r.Point[2]) > 1e-9) return Fail($"thickness: a cap row's exact opposite is {r.ExactOpposite[2]}");
            if (r.Knife || r.OppositeBody != 0) return Fail($"thickness: a cap row reads knife {r.Knife}, opposite body {r.OppositeBody}");
        }
        foreach (var r in rows)
        {
            if (r.Body != 0 || r.Vertex is null || r.Point.Length != 3 || r.Opposite.Length != 3 || r.ExactOpposite.Length != 3)
                return Fail($"thickness: a row reads {r}");
            if (!Near(mesh.Positions[(int)r.Vertex.Value], r.Point, 0)) return Fail($"thickness: row {r} is not at mesh vertex {r.Vertex}");
        }
        if (!rows.Any(r => r.Sphere is not null)) return Fail("thickness: no row carries a sphere");
        using (var g = new ThicknessGauge(new[] { wallPlate }, tolerance: 0.01))
        {
            if (g.Thickness(1.0).Count != 0) return Fail("thickness: a maximum under the wall still read");
            if (g.Thickness(10.0).Count != rows.Count) return Fail("thickness: the sharp angle does not default to 0");
        }
        Console.WriteLine($"thickness: plate {rows.Count} rows, {caps.Count} on the caps");
    }
    // 2. the measuring mesh is a copy that matches the readings
    using (var wallPlate = Solid.Cuboid(10, 10, 2))
    {
        var g = new ThicknessGauge(new[] { wallPlate });
        var gaugeMesh = g.Mesh(0);
        if (gaugeMesh.Faces.Length != gaugeMesh.Triangles.Length || gaugeMesh.Triangles.Length < 12) return Fail($"thickness: mesh has {gaugeMesh.Faces.Length} faces, {gaugeMesh.Triangles.Length} triangles");
        if (gaugeMesh.Normals.Length != gaugeMesh.Positions.Length || gaugeMesh.Positions.Length == 0) return Fail("thickness: mesh normals and positions differ in count");
        if (gaugeMesh.Positions.Concat(gaugeMesh.Normals).Any(p => p.Length != 3) || gaugeMesh.Triangles.Any(t => t.Length != 3)) return Fail("thickness: mesh rows are not triples");
        if (gaugeMesh.Faces.Any(f => f >= wallPlate.Faces)) return Fail("thickness: a triangle names a face past the solid");
        if (gaugeMesh.Triangles.SelectMany(t => t).Any(k => k >= gaugeMesh.Positions.Length)) return Fail("thickness: a triangle names a vertex past the mesh");
        if (gaugeMesh.Normals.Any(n => Math.Abs(Norm(n) - 1) > 1e-9)) return Fail("thickness: a mesh normal is not a unit");
        var rows = g.Thickness(100.0, 0.5);
        if (rows.Count != gaugeMesh.Positions.Length) return Fail($"thickness: {rows.Count} rows for {gaugeMesh.Positions.Length} vertices");
        foreach (var r in rows)
        {
            var t = Array.FindIndex(gaugeMesh.Triangles, tri => tri.Contains(r.Vertex!.Value));
            if (t < 0 || gaugeMesh.Faces[t] != r.Face) return Fail($"thickness: row {r} sits on face {r.Face} but its triangle is on {(t < 0 ? -1 : (int)gaugeMesh.Faces[t])}");
        }
        var noBody = ThickRefused(() => g.Mesh(1));
        if (noBody != "thickness_gauge_mesh: no body 1 -- there are 1") return Fail($"thickness: mesh(1) gave '{noBody}'");
        g.Dispose();
        if (gaugeMesh.Positions.Length != rows.Count) return Fail("thickness: the mesh did not outlive its gauge");
        var closed = ThickRefused(() => g.Mesh(0));
        if (!closed.StartsWith("thickness_gauge: closed")) return Fail($"thickness: a closed gauge's mesh gave '{closed}'");
    }
    // 3. a reading at a point: one row, no vertex
    using (var wallPlate = Solid.Cuboid(10, 10, 2))
    using (var g = new ThicknessGauge(new[] { wallPlate }))
    {
        var probe = new double[] { 1, 2, 1 };
        var top = FaceHolding(g, wallPlate, 0, probe);
        var r = g.ThicknessAt(0, top, probe, 100.0, 0.5);
        if (r is null || r.Vertex is not null) return Fail($"thickness: the point reading is {r}");
        if (r.Body != 0 || r.Face != top || r.OppositeBody != 0 || !Near(r.Point, probe, 0)) return Fail($"thickness: the point reading reads {r}");
        if (Math.Abs(r.Value - 2) > 1e-9 || Math.Abs(r.ExactThickness - 2) > 1e-9) return Fail($"thickness: the point reading's thickness is {r.Value} / {r.ExactThickness}");
        if (Math.Abs(r.Opposite[2] + 1) > 1e-9 || Math.Abs(r.ExactOpposite[2] + 1) > 1e-9) return Fail("thickness: the point reading's opposite is off");
        if (r.Sphere is null || Math.Abs(r.Sphere.Value - 2) > 0.02) return Fail($"thickness: the point reading's sphere is {r.Sphere}");
        if (g.ThicknessAt(0, top, probe, 1.0, 0.5) is not null) return Fail("thickness: a wall past the maximum still read at a point");
        if (g.ThicknessAt(0, top, probe, 100.0)!.Value != r.Value) return Fail("thickness: the point reading's sharp angle does not default to 0");
    }
    // 4. a face's thickness, and none where nothing is found
    using (var wallPlate = Solid.Cuboid(10, 10, 2))
    {
        uint top;
        using (var g = new ThicknessGauge(new[] { wallPlate }))
        {
            top = FaceHolding(g, wallPlate, 0, new double[] { 1, 2, 1 });
            var f = g.ThicknessAtFace(0, top, 100.0);
            if (f is null || Math.Abs(f.Thickness - 2) > 1e-9 || !f.Uniform || Math.Abs(f.Min - 2) > 1e-9 || Math.Abs(f.Max - 2) > 1e-9)
                return Fail($"thickness: the face reads {f}");
            var at = new double[] { 1, 2, 5 };
            var a = g.ThicknessAtFace(0, top, at, 100.0);
            if (a is null || Math.Abs(a.Thickness - 2) > 1e-9 || a.Min != a.Max || !a.Uniform) return Fail($"thickness: the face at a point reads {a}");
            if (g.ThicknessAtFace(0, top, null, 100.0)!.Thickness != f.Thickness) return Fail("thickness: a null `at` is not the whole face");
            if (g.ThicknessAtFace(0, top, 1.0) is not null) return Fail("thickness: a face past the maximum still read");
            if (g.ThicknessAtFace(0, top, new double[] { 50, 2, 5 }, 100.0) is not null) return Fail("thickness: an `at` off the face still read");
        }
        var s = wallPlate.ThicknessAtFace(top, 100.0);
        if (s is null || Math.Abs(s.Thickness - 2) > 1e-9 || !s.Uniform) return Fail($"thickness: the solid's face reads {s}");
        var t = wallPlate.ThicknessAtFace(top, new double[] { 1, 2, 5 }, 100.0, 0.05);
        if (t is null || Math.Abs(t.Thickness - 2) > 1e-9) return Fail($"thickness: the solid's face at a point reads {t}");
        if (wallPlate.ThicknessAtFace(top, 1.0) is not null) return Fail("thickness: the solid's face past the maximum still read");
    }
    // 5. a ball past the maximum is none
    using (var wedgeOutline = Profile.Polygon([(0, 0), (10, 0), (0, 10)]))
    using (var wedge = Solid.Extrude(wedgeOutline, xy, 20))
    using (var g = new ThicknessGauge(new[] { wedge }))
    {
        var probe = new double[] { 5, 0, 10 };
        var f = FaceHolding(g, wedge, 0, probe);
        var wide = g.ThicknessAt(0, f, probe, 100.0, 0.5);
        if (wide?.Sphere is null || Math.Abs(wide.Sphere.Value - 2 * 5 / (1 + Math.Sqrt(2))) > 0.01) return Fail($"thickness: the wide ball reads {wide}");
        var narrow = g.ThicknessAt(0, f, probe, 4.0, 0.5);
        if (narrow is null || Math.Abs(narrow.Value - 5 / Math.Sqrt(2)) > 1e-9) return Fail($"thickness: the narrow reading is {narrow}");
        if (narrow.Sphere is not null) return Fail($"thickness: a ball past the maximum reads {narrow.Sphere}");
    }
    // 6. two bodies read each other, and the one-shot agrees
    using (var slabOutline = Profile.Polygon([(0, 0), (10, 0), (10, 3), (0, 1)]))
    using (var slab = Solid.Extrude(slabOutline, xy, 4))
    using (var outer = Profile.Circle(5))
    using (var inner = Profile.Circle(4))
    using (var ring = outer.WithHole(inner))
    using (var tube = Solid.Extrude(ring, xy, 10))
    {
        IReadOnlyList<Thickness> via;
        using (var g = new ThicknessGauge(new[] { slab, tube }))
        {
            if (g.Count != 2) return Fail($"thickness: two bodies count {g.Count}");
            via = g.Thickness(100.0, 0.5);
        }
        var one = Blacksmith.Thickness(new[] { slab, tube }, 100.0, 0.5);
        var key = (Func<Thickness, (uint, uint?, uint, double, uint)>)(r => (r.Body, r.Vertex, r.Face, r.Value, r.OppositeBody));
        if (!one.Select(key).SequenceEqual(via.Select(key))) return Fail("thickness: the one-shot differs from the gauge");
        if (!one.Any(r => r.Body == 0 && r.OppositeBody == 1)) return Fail("thickness: the slab never reads the tube");
        if (!one.Any(r => r.Body == 1 && r.OppositeBody == 0)) return Fail("thickness: the tube never reads the slab");
        if (Blacksmith.Thickness(new[] { slab }, 0.001).Count != 0) return Fail("thickness: a tiny maximum still read");
        if (Blacksmith.Thickness(new[] { slab }, 100.0, tolerance: 0.05).Count == 0) return Fail("thickness: the coarser one-shot read nothing");
    }
    // 7. mesh thickness: two triangles one apart
    {
        var lower = (new[] { new double[] { 0, 0, 0 }, new double[] { 0, 1, 0 }, new double[] { 1, 0, 0 } }, new[] { new uint[] { 0, 1, 2 } });
        var upper = (new[] { new double[] { 0, 0, 1 }, new double[] { 1, 0, 1 }, new double[] { 0, 1, 1 } }, new[] { new uint[] { 0, 1, 2 } });
        var meshes = new[] { lower, upper };
        var rows = Blacksmith.MeshThickness(meshes, 10.0, 0.5);
        if (rows.Count != 6) return Fail($"mesh_thickness: {rows.Count} rows, not 6");
        foreach (var r in rows)
        {
            if (Math.Abs(r.Thickness - 1) > 1e-12 || r.Knife) return Fail($"mesh_thickness: a row reads {r}");
            if (r.OppositeMesh != 1 - r.Mesh || r.OppositeTriangle != 0) return Fail($"mesh_thickness: a row's opposite is {r.OppositeMesh}/{r.OppositeTriangle}");
            if (!Near(r.Point, meshes[r.Mesh].Item1[r.Vertex], 0)) return Fail($"mesh_thickness: row {r} is not at its vertex");
            if (Math.Abs(r.Opposite[2] - (1 - r.Point[2])) > 1e-12 || r.Opposite[0] != r.Point[0] || r.Opposite[1] != r.Point[1])
                return Fail($"mesh_thickness: row {r} reads to ({string.Join(", ", r.Opposite)})");
        }
        if (!rows.Select(r => (r.Mesh, r.Vertex)).SequenceEqual(new (uint, uint)[] { (0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2) }))
            return Fail("mesh_thickness: the rows are not by mesh then vertex");
        if (Blacksmith.MeshThickness(meshes, 0.5, 0.5).Count != 0) return Fail("mesh_thickness: a maximum under the gap still read");
        if (Blacksmith.MeshThickness(Array.Empty<(double[][], uint[][])>(), 1.0).Count != 0) return Fail("mesh_thickness: no meshes read something");
        if (Blacksmith.MeshThickness(meshes, 10.0).Count != 6) return Fail("mesh_thickness: the sharp angle does not default to 0");
    }
    // 8. every refusal carries the call's prefix
    using (var wallPlate = Solid.Cuboid(10, 10, 2))
    {
        foreach (var (got, want) in new[] {
            (ThickRefused(() => new ThicknessGauge(new[] { wallPlate }, -1.0)), "thickness_gauge_new: the tolerance must be positive and finite"),
        })
            if (!got.StartsWith(want)) return Fail($"thickness: expected '{want}...', got '{got}'");
        var g = new ThicknessGauge(new[] { wallPlate });
        var p121 = new double[] { 1, 2, 1 };
        var meshes = new[] {
            (new[] { new double[] { 0, 0, 0 }, new double[] { 0, 1, 0 }, new double[] { 1, 0, 0 } }, new[] { new uint[] { 0, 1, 2 } }),
            (new[] { new double[] { 0, 0, 1 }, new double[] { 1, 0, 1 }, new double[] { 0, 1, 1 } }, new[] { new uint[] { 0, 1, 2 } }),
        };
        var tri = new[] { new uint[] { 0, 1, 2 } };
        foreach (var (got, want) in new[] {
            (ThickRefused(() => g.Thickness(0.0)), "thickness_gauge_measure: the maximum must be positive and finite"),
            (ThickRefused(() => g.Thickness(10.0, -0.1)), "thickness_gauge_measure: the sharp angle must be zero or positive and finite"),
            (ThickRefused(() => g.ThicknessAt(3, 0, p121, 10.0)), "thickness_gauge_at: no body 3 -- there are 1"),
            (ThickRefused(() => g.ThicknessAt(0, 99, p121, 10.0)), "thickness_gauge_at: no face 99 -- the solid has 6 (0 to 5)"),
            (ThickRefused(() => g.ThicknessAt(0, 0, new double[] { 1, double.NaN, 1 }, 10.0)), "thickness_gauge_at: the point must be finite"),
            (ThickRefused(() => g.ThicknessAt(0, 0, new double[] { 1, 2 }, 10.0)), "thickness_gauge_at: a point is 3 numbers, got 2"),
            (ThickRefused(() => g.ThicknessAt(0, 0, null!, 10.0)), "thickness_gauge_at: a point is 3 numbers, got 0"),
            (ThickRefused(() => g.ThicknessAtFace(2, 0, 10.0)), "thickness_gauge_face: no body 2 -- there are 1"),
            (ThickRefused(() => g.ThicknessAtFace(0, 99, 10.0)), "thickness_gauge_face: no face 99 -- the solid has 6 (0 to 5)"),
            (ThickRefused(() => g.ThicknessAtFace(0, 0, new double[] { double.PositiveInfinity, 0, 1 }, 10.0)), "thickness_gauge_face: the point must be finite"),
            (ThickRefused(() => g.ThicknessAtFace(0, 0, new double[] { 1, 2 }, 10.0)), "thickness_gauge_face: a point is 3 numbers, got 2"),
            (ThickRefused(() => g.ThicknessAtFace(0, 0, 0.0)), "thickness_gauge_face: the maximum must be positive and finite"),
        })
            if (!got.StartsWith(want)) return Fail($"thickness: expected '{want}...', got '{got}'");
        g.Dispose();
        g.Dispose();
        foreach (var (name, act) in new (string, Action)[] {
            ("Thickness", () => g.Thickness(10.0)),
            ("ThicknessAt", () => g.ThicknessAt(0, 0, p121, 10.0)),
            ("ThicknessAtFace", () => g.ThicknessAtFace(0, 0, 10.0)),
            ("Count", () => _ = g.Count),
            ("Tolerance", () => _ = g.Tolerance),
        })
        {
            var got = ThickRefused(act);
            if (!got.StartsWith("thickness_gauge: closed")) return Fail($"thickness: a closed gauge's {name} gave '{got}'");
        }
        // the conveniences refuse with the gauge call's own prefix
        foreach (var (got, want) in new[] {
            (ThickRefused(() => Blacksmith.Thickness(new[] { wallPlate }, -1.0)), "thickness_gauge_measure: the maximum must be positive and finite"),
            (ThickRefused(() => Blacksmith.Thickness(new[] { wallPlate }, 10.0, tolerance: double.PositiveInfinity)), "thickness_gauge_new: the tolerance must be positive and finite"),
            (ThickRefused(() => wallPlate.ThicknessAtFace(99, 10.0)), "thickness_gauge_face: no face 99"),
            // mesh_thickness: the kernel's refusals and the wrapper's own
            (ThickRefused(() => Blacksmith.MeshThickness(meshes, 0.0)), "mesh_thickness: the maximum must be positive and finite"),
            (ThickRefused(() => Blacksmith.MeshThickness(meshes, 10.0, -0.5)), "mesh_thickness: the sharp angle must be zero or positive and finite"),
            (ThickRefused(() => Blacksmith.MeshThickness(new[] { (new[] { new double[] { 0, 0, 0 }, new double[] { 1, 0, 0 } }, tri) }, 10.0)),
                "mesh_thickness: a triangle names a position past the mesh"),
            (ThickRefused(() => Blacksmith.MeshThickness(new[] { (new[] { new double[] { 0, 0, 0 }, new double[] { 1, double.NaN, 0 }, new double[] { 0, 1, 0 } }, tri) }, 10.0)),
                "mesh_thickness: a mesh position is not finite"),
            (ThickRefused(() => Blacksmith.MeshThickness(new[] { meshes[0], (null!, null!) }, 10.0)),
                "mesh_thickness: mesh 1 is not a (positions, triangles) pair"),
            (ThickRefused(() => Blacksmith.MeshThickness(new[] { (new[] { new double[] { 0, 0, 0 }, new double[] { 1, 0 } }, tri) }, 10.0)),
                "mesh_thickness: mesh 0 position 1 is not three numbers"),
            (ThickRefused(() => Blacksmith.MeshThickness(new[] { (new[] { new double[] { 0, 0, 0 }, new double[] { 1, 0, 0 }, new double[] { 0, 1, 0 } }, new[] { new uint[] { 0, 1 } }) }, 10.0)),
                "mesh_thickness: mesh 0 triangle 0 is not three indices"),
        })
            if (!got.StartsWith(want)) return Fail($"thickness: expected '{want}...', got '{got}'");
    }
    Console.WriteLine("thickness: gauge, readings, face, mesh and refusals all read back");
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
    // 7b. subdivide: whole, one face, a bad face
    using (var kiln = Subd.Cuboid((2, 2, 2), (2, 2, 2)))
    {
        using (var whole = kiln.Subdivide())
            if (whole.Faces.Length != 96) return Fail($"subd: subdivide() is {whole.Faces.Length} faces, not 96");
        using (var one = kiln.Subdivide(new uint[] { 1 }))
        {
            if (one.Faces.Length != 27) return Fail($"subd: subdivide([1]) is {one.Faces.Length} faces, not 27");
            if (one.Selection?.Kind != SubdElements.Faces || one.Selection.Ids.Length != 4) return Fail("subd: subdivide([1]) does not select 4 faces");
        }
        var refused = SdRefused(() => kiln.Subdivide(new uint[] { 999 }));
        if (!refused.Contains("subdivide: face 999 is not in the cage")) return Fail($"subd: subdivide([999]) was refused as: {refused}");
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
// The 2D constraint sketcher: Python's test_a_sketch_* one for one (sketch constraints, plan 4).
{
    BuildException? SkRefused(Action act)
    {
        try { act(); return null; }
        catch (BuildException e) { return e; }
    }
    bool Near1(double a, double b, double tolerance) => Math.Abs(a - b) <= tolerance;
    // S1: a plate, dimensioned, solved, diagnosed and extruded
    using (var s = new Sketch())
    {
        var (plateCorners, plateSides) = s.AddRect((0, 0), (40, 30));
        if (plateCorners.Length != 4 || plateSides.Length != 4) return Fail("sketch: add_rect is not 4 corners and 4 sides");
        s.Fix(plateCorners[0]);
        var width = s.Length(plateSides[0], 60);
        s.Length(plateSides[1], 30);
        var sk_hole = s.AddCircle(s.AddPoint(30, 15), 5);
        s.RadiusOf(sk_hole, 5);
        var report = s.Solve();
        if (!report.Converged || report.Status != "converged" || report.Ids.Count != 0) return Fail($"sketch: the plate did not converge: {report}");
        var corner = s.Point(plateCorners[1]);
        if (!Near1(corner.X, 60, 1e-9) || !Near1(corner.Y, 0, 1e-9)) return Fail($"sketch: the plate's second corner is {corner}");
        if (s.ConstraintKind(width) != "length" || s.ConstraintValue(width) != 60.0) return Fail("sketch: the width reads back wrong");
        var dof = s.Diagnose();
        if (dof.Free != 2 || dof.State != "under") return Fail($"sketch: the plate's dof is {dof}");
        var profiles = s.Profiles(1e-9);
        if (profiles.Count != 1) return Fail($"sketch: the plate has {profiles.Count} profiles");
        using var body = Solid.Extrude(profiles[0], Frame.Xy().ToArray(), 10);
        if (!(body.Mass().Volume > 0)) return Fail("sketch: the extruded sk_plate has no volume");
    }
    // S2: a conflict refused with its ids, a point in use, a plain refusal with none, a closed sketch
    {
        var s = new Sketch();
        var (plateCorners, plateSides) = s.AddRect((0, 0), (40, 30));
        s.Fix(plateCorners[0]); s.Length(plateSides[0], 40); s.Length(plateSides[1], 30);
        var clash = SkRefused(() => s.Distance(plateCorners[0], plateCorners[2], 10));
        if (clash is null || !clash.Message.StartsWith("sketch_constrain: over-constrained")) return Fail($"sketch: the conflict gave '{clash?.Message}'");
        if (!clash.Ids.SequenceEqual(new uint[] { 0, 1, 5, 6 })) return Fail($"sketch: the conflict's ids are [{string.Join(", ", clash.Ids)}]");
        if (s.Constraints().Length != 7) return Fail("sketch: the refused constraint was kept");
        var inUse = SkRefused(() => s.RemoveEntity(plateCorners[0]));
        if (inUse is null || !inUse.Message.StartsWith("sketch_remove_entity: point")) return Fail($"sketch: removing a used point gave '{inUse?.Message}'");
        if (!inUse.Ids.OrderBy(i => i).SequenceEqual(new[] { plateSides[0], plateSides[3] }.OrderBy(i => i))) return Fail($"sketch: the point's users are [{string.Join(", ", inUse.Ids)}]");
        var unknown = SkRefused(() => s.Kind(9999));
        if (unknown is null || !unknown.Message.Contains("sketch_kind")) return Fail($"sketch: kind(9999) gave '{unknown?.Message}'");
        if (unknown.Ids.Count != 0) return Fail($"sketch: kind(9999) carried the ids [{string.Join(", ", unknown.Ids)}]");
        s.Dispose();
        s.Dispose();
        try { s.Solve(); return Fail("sketch: solve after dispose did not fail"); }
        catch (ObjectDisposedException e) when (e.Message.Contains("sketch: closed")) { }
    }
    // S3: dragging a point
    using (var s = new Sketch())
    {
        var (plateCorners, _) = s.AddRect((0, 0), (40, 30));
        var r = s.Drag(new Dictionary<uint, (double X, double Y)> { [plateCorners[0]] = (5, 5) });
        if (!r.Converged || r.Ids.Count != 0) return Fail($"sketch: the drag gave {r}");
        var p = s.Point(plateCorners[0]);
        if (!Near1(p.X, 5, 1e-9) || !Near1(p.Y, 5, 1e-9)) return Fail($"sketch: the dragged corner is {p}");
        if (!Near1(s.Point(plateCorners[1]).Y, 5, 1e-9)) return Fail("sketch: the dragged side did not stay level");
        // (a 3-number target is not expressible with tuple points; skipped)
    }
    // S4: a reference follows its source
    using (var sk_plate = new Sketch())
    using (var sk_boss = new Sketch())
    {
        var (plateCorners, plateSides) = sk_plate.AddRect((0, 0), (40, 30));
        sk_plate.Fix(plateCorners[0]);
        var width = sk_plate.Length(plateSides[0], 40);
        sk_plate.Length(plateSides[1], 30);
        var edge = sk_boss.Reference(sk_plate, plateSides[1]);
        if (!sk_boss.IsReference(edge) || !sk_boss.IsConstruction(edge)) return Fail("sketch: a reference is not a construction reference");
        var o = sk_boss.AddPoint(130, 15);
        var sk_hole = sk_boss.AddCircle(o, 12);
        sk_boss.RadiusOf(sk_hole, 12);
        sk_boss.PointLineDistance(o, edge, 100);
        if (!Near1(sk_boss.Point(o).X, 140, 1e-9)) return Fail($"sketch: the boss starts at {sk_boss.Point(o)}");
        if (sk_boss.Profiles(1e-9).Count != 1) return Fail("sketch: the reference is part of a profile");
        if (!sk_plate.SetValue(width, 60).Converged) return Fail("sketch: widening the plate did not converge");
        var r = sk_boss.UpdateReference(edge, sk_plate);
        if (!r.Converged || r.Ids.Count != 0) return Fail($"sketch: update_reference gave {r}");
        if (!Near1(sk_boss.Point(o).X, 160, 1e-9)) return Fail($"sketch: the boss did not follow the plate: {sk_boss.Point(o)}");
        var notRef = SkRefused(() => sk_boss.UpdateReference(o, sk_plate));
        if (notRef is null || !notRef.Message.StartsWith("sketch_update_reference: entity") || notRef.Ids.Count != 0) return Fail($"sketch: update_reference of a plain point gave '{notRef?.Message}'");
        var itself = SkRefused(() => sk_boss.Reference(sk_boss, o));
        if (itself is null || !itself.Message.Contains("cannot reference itself")) return Fail($"sketch: referencing itself gave '{itself?.Message}'");
    }
    // S5: from a profile, keeping its tangent joints
    using (var slot = Profile.Slot((0, 0), 60, 8))
    using (var s = Sketch.FromProfile(slot, tolerance: 1e-9))
    {
        var tangents = s.Constraints().Where(c => s.ConstraintKind(c) == "tangent").ToArray();
        if (tangents.Length != 4 || !tangents.All(s.IsJointTangent)) return Fail($"sketch: the slot has {tangents.Length} tangents");
        if (s.Diagnose().Free != 4) return Fail("sketch: the slot's dof is not 4");
    }
    // S6: reads back what it holds
    using (var s = new Sketch())
    {
        var a = s.AddPoint(0, 0); var b = s.AddPoint(10, 0);
        var line = s.AddLine(a, b);
        if (s.Kind(a) != "point" || s.Kind(line) != "line") return Fail("sketch: kinds of a point and a line");
        if (!s.Entities().SequenceEqual(new[] { a, b, line }.OrderBy(i => i)) || !s.Ends(line).SequenceEqual(new[] { a, b })) return Fail("sketch: entities or ends");
        var c = s.AddCircle(s.AddPoint(0, 20), 3);
        if (s.Kind(c) != "circle" || s.Radius(c) != 3.0 || s.Kind(s.Centre(c)) != "point") return Fail("sketch: the circle reads back wrong");
        s.SetRadius(c, 4);
        if (s.Radius(c) != 4.0) return Fail("sketch: set_radius");
        s.SetPoint(b, 12, 0);
        if (s.Point(b) != (12.0, 0.0)) return Fail("sketch: set_point");
        s.SetConstruction(c);
        if (!s.IsConstruction(c) || s.IsReference(c)) return Fail("sketch: set_construction");
        var h = s.Horizontal(a, b);
        if (s.ConstraintKind(h) != "horizontal" || !s.ConstraintRefs(h).SequenceEqual(new[] { a, b })) return Fail("sketch: the horizontal reads back wrong");
        if (s.ConstraintValue(h) is not null || s.ConstraintDriving(h) || s.ConstraintSense(h) != "auto") return Fail("sketch: a horizontal has a value, driving or a sense");
        var d = s.Distance(a, b, 15, driving: false);
        if (s.ConstraintValue(d) != 15.0 || s.ConstraintDriving(d) || !Near1(s.Measure(d), 12, 1e-12)) return Fail("sketch: the reporting distance reads back wrong");
        var r = s.SetDriving(d, true);
        if (!r.Converged || !s.ConstraintDriving(d) || s.ConstraintValue(d) != 12.0) return Fail($"sketch: set_driving gave {r}");
        r = s.SetValue(d, 20);
        if (!r.Converged || !Near1(s.Measure(d), 20, 1e-9)) return Fail($"sketch: set_value gave {r}");
        r = s.Drag(new Dictionary<uint, (double X, double Y)> { [b] = (25, 5) });
        if (r.Status is not ("converged" or "conflicting" or "diverged") || r.Ids is null) return Fail($"sketch: drag gave {r}");
        if (!s.Constraints().SequenceEqual(new[] { h, d }.OrderBy(i => i))) return Fail("sketch: constraints");
        s.Remove(h);
        if (!s.Constraints().SequenceEqual(new[] { d })) return Fail("sketch: remove");
        if (!s.RemoveEntity(line).SequenceEqual(new[] { d })) return Fail("sketch: remove_entity did not name the distance");
        if (s.Entities().Contains(a) || s.Constraints().Length != 0) return Fail("sketch: remove_entity left its ends or constraints");
        var bez = s.AddBezier(s.AddPoint(0, 0), (1, 1), (2, 1), (3, 0));
        if (s.Kind(bez) != "free_curve" || s.Ends(bez).Length != 4) return Fail("sketch: the bezier reads back wrong");
        if (s.OpenChains(1e-9).Count != 1) return Fail("sketch: open_chains");
        var bad = SkRefused(() => s.Kind(9999));
        if (bad is null || !bad.Message.Contains("sketch_kind")) return Fail("sketch: kind(9999) was not refused");
        // an unknown id is refused by the readers whose failure is ambiguous (not read as "none" or false)
        var noValue = SkRefused(() => s.ConstraintValue(999));
        if (noValue is null || noValue.Ids.Count != 0) return Fail($"sketch: constraint_value(999) gave '{noValue?.Message}'");
        var noDriving = SkRefused(() => s.ConstraintDriving(999));
        if (noDriving is null) return Fail("sketch: constraint_driving(999) was not refused");
        if (s.IsConstruction(999) || s.IsReference(999) || s.IsJointTangent(999)) return Fail("sketch: an unknown id reads as construction, reference or joint tangent");
        var sideways = SkRefused(() => s.Tangent(bez, c, sense: "sideways"));
        if (sideways is null || !sideways.Message.Contains("sense")) return Fail($"sketch: a sideways tangent gave '{sideways?.Message}'");
    }
    // the sense of a signed distance: "positive" and "negative" put the point on opposite sides of the line
    foreach (var (name, expectY) in new[] { ("positive", 3.0), ("negative", -3.0) })
    {
        using var s = new Sketch();
        var la = s.AddPoint(0, 0); var lb = s.AddPoint(10, 0);
        var ln = s.AddLine(la, lb);
        s.Fix(la); s.Fix(lb);
        var pt = s.AddPoint(5, 1);
        var dc = s.PointLineDistance(pt, ln, 3, sense: name);
        if (s.ConstraintSense(dc) != name) return Fail($"sketch: the {name} sense reads back as {s.ConstraintSense(dc)}");
        if (!s.Solve().Converged || !Near1(s.Point(pt).Y, expectY, 1e-6)) return Fail($"sketch: the {name} sense put the point at {s.Point(pt)}");
    }
    // S7: tangent_at_end reads its end back
    using (var s = new Sketch())
    {
        var a = s.AddPoint(0, 0); var b = s.AddPoint(4, 0);
        var line = s.AddLine(a, b);
        var bez = s.AddBezier(b, (5, 0), (6, 1), (7, 1));
        if (s.ConstraintEnd(s.TangentAtEnd(bez, line, end: "end")) != "end") return Fail("sketch: tangent_at_end(end) reads back wrong");
        if (s.ConstraintEnd(s.TangentAtEnd(bez, line)) != "start") return Fail("sketch: tangent_at_end default is not start");
        if (s.ConstraintEnd(s.Length(line, 4)) != "start") return Fail("sketch: a length has an end");
        var none = SkRefused(() => s.ConstraintEnd(999));
        if (none is null || !none.Message.Contains("sketch_constraint_end: no constraint 999")) return Fail($"sketch: constraint_end(999) gave '{none?.Message}'");
    }
    // S8: nurbs weights and finite points
    using (var s = new Sketch())
    {
        var start = s.AddPoint(0, 0);
        var points = new (double X, double Y)[] { (1, 2), (3, 2), (4, 0) };
        var knots = new double[] { 0, 0, 0, 0.5, 1, 1, 1 };
        var few = SkRefused(() => s.AddNurbs(start, points, knots, 2, new double[] { 1, 1, 1 }));
        if (few is null || !few.Message.Contains("sketch_add_nurbs")) return Fail($"sketch: too few weights gave '{few?.Message}'");
        var curve = s.AddNurbs(start, points, knots, 2, new double[] { 1, 0.5, 0.5, 1 });
        var ends = s.Ends(curve);
        if (s.Kind(curve) != "free_curve" || ends.Length != 4 || ends[0] != start) return Fail("sketch: the nurbs reads back wrong");
    }
    using (var s = new Sketch())
    {
        var nan = SkRefused(() => s.AddPoint(double.NaN, 0));
        if (nan is null || !nan.Message.Contains("sketch_add_point: the coordinates must be finite")) return Fail($"sketch: a NaN point gave '{nan?.Message}'");
        if (s.Entities().Length != 0) return Fail("sketch: a refused point was kept");
        // the bindings the facts above skip
        var conic = s.AddConic(s.AddPoint(0, 0), (1, 1), (2, 0), 0.7);
        var arcCentre = s.AddPoint(0, 0); var arcStart = s.AddPoint(1, 0); var arcEnd = s.AddPoint(0, 1);
        var arc = s.AddArc(arcCentre, arcStart, arcEnd);
        if (s.Kind(conic) != "free_curve" || s.Kind(arc) != "arc") return Fail("sketch: conic or arc kinds");
        var dof = s.Diagnose();
        if (dof.Parts.Count == 0 || dof.Parts[0].Params == 0) return Fail($"sketch: diagnose has no parts: {dof}");
    }
    // S11: the diagnosis names the redundant and the conflicting ones (a swapped code table fails here)
    using (var s = new Sketch())
    {
        var (rc, rs) = s.AddRect((0, 0), (40, 30));
        s.Fix(rc[0]); s.Length(rs[0], 40); s.Length(rs[1], 30);
        var h = s.Horizontal(rc[3], rc[2]);
        if (h != 7) return Fail($"sketch: the redundant horizontal is constraint {h}, not 7");
        var dof = s.Diagnose();
        if (dof.Free != 0 || dof.State != "full" || !dof.Redundant.SequenceEqual(new uint[] { 7 }) || dof.Conflicting.Count != 0 || dof.Parts.Count != 1)
            return Fail($"sketch: the redundant diagnosis reads {dof}");
        var pd = dof.Parts[0];
        if (pd.Free != 0 || pd.State != "full" || !pd.Redundant.SequenceEqual(new uint[] { 7 }) || pd.Conflicting.Count != 0
            || !pd.Constraints.SequenceEqual(new uint[] { 0, 1, 2, 3, 5, 6, 7 }))
            return Fail($"sketch: the redundant pd reads {pd}");
    }
    // S12: a diverged edit is refused with the text and the ids [2, 0, 1], and the sketch still solves
    using (var s = new Sketch())
    {
        var a = s.AddPoint(0, 0); var b = s.AddPoint(1, 0); var c = s.AddPoint(0, 1);
        s.Distance(a, b, 1); s.Distance(b, c, 1);
        var d3 = s.Distance(a, c, 1);
        var diverged = SkRefused(() => s.SetValue(d3, 10));
        if (diverged is null || !diverged.Message.StartsWith("sketch_set_value: the solve did not converge")) return Fail($"sketch: the diverged set_value gave '{diverged?.Message}'");
        if (!diverged.Ids.SequenceEqual(new uint[] { 2, 0, 1 })) return Fail($"sketch: the diverged set_value's ids are [{string.Join(", ", diverged.Ids)}]");
        if (!s.Solve().Converged) return Fail("sketch: the sketch does not solve after a refused edit");
    }
    // every constraint method on a fixture none refuses: kind, refs in order, value for the dimensions
    {
        var cases = new List<(string Kind, Func<Sketch, uint[], uint> Make, int[] Refs, double? Value, Func<Sketch, uint[], (double Got, double Want)>? Effect)>
        {
            ("coincident", (s, i) => s.Coincident(i[0], i[2]), new[] { 0, 2 }, null, (s, i) => (Dist(s, i[0], i[2]), 0)),
            ("point_on_line", (s, i) => s.PointOnLine(i[2], i[4]), new[] { 2, 4 }, null, (s, i) => (LineOff(s, i[4], i[2]), 0)),
            ("point_on_circle", (s, i) => s.PointOnCircle(i[2], i[6]), new[] { 2, 6 }, null, (s, i) => (Dist(s, i[2], s.Centre(i[6])), s.Radius(i[6]))),
            ("horizontal", (s, i) => s.Horizontal(i[0], i[1]), new[] { 0, 1 }, null, (s, i) => (s.Point(i[0]).Y - s.Point(i[1]).Y, 0)),
            ("vertical", (s, i) => s.Vertical(i[1], i[0]), new[] { 1, 0 }, null, (s, i) => (s.Point(i[1]).X - s.Point(i[0]).X, 0)),
            ("parallel", (s, i) => s.Parallel(i[4], i[5]), new[] { 4, 5 }, null, (s, i) => (Cross(s, i[4], i[5]), 0)),
            ("perpendicular", (s, i) => s.Perpendicular(i[4], i[5]), new[] { 4, 5 }, null, (s, i) => (Dot(s, i[4], i[5]), 0)),
            ("collinear", (s, i) => s.Collinear(i[4], i[5]), new[] { 4, 5 }, null, (s, i) => (Cross(s, i[4], i[5]) + LineOff(s, i[4], s.Ends(i[5])[0]), 0)),
            ("tangent", (s, i) => s.Tangent(i[4], i[6]), new[] { 4, 6 }, null, (s, i) => (Math.Abs(LineOff(s, i[4], s.Centre(i[6]))), s.Radius(i[6]))),
            ("tangent_at_end", (s, i) => s.TangentAtEnd(i[9], i[4]), new[] { 9, 4 }, null, null),
            ("concentric", (s, i) => s.Concentric(i[6], i[7]), new[] { 6, 7 }, null, (s, i) => (Dist(s, s.Centre(i[6]), s.Centre(i[7])), 0)),
            ("equal_length", (s, i) => s.EqualLength(i[4], i[5]), new[] { 4, 5 }, null, (s, i) => (Len(s, i[4]) - Len(s, i[5]), 0)),
            ("equal_radius", (s, i) => s.EqualRadius(i[6], i[7]), new[] { 6, 7 }, null, (s, i) => (s.Radius(i[6]) - s.Radius(i[7]), 0)),
            ("midpoint", (s, i) => s.Midpoint(i[2], i[4]), new[] { 2, 4 }, null, (s, i) => (Dist2(s.Point(i[2]), Mid(s, i[4])), 0)),
            ("symmetric", (s, i) => s.Symmetric(i[2], i[3], i[4]), new[] { 2, 3, 4 }, null, null),
            // a drag that would move the point: the fixed one stays at (0, 0)
            ("fix", (s, i) => s.Fix(i[0]), new[] { 0 }, null, (s, i) =>
            {
                s.Drag(new Dictionary<uint, (double X, double Y)> { [i[0]] = (5, 5) });
                return (Dist2(s.Point(i[0]), (0, 0)), 0);
            }),
            ("distance", (s, i) => s.Distance(i[0], i[2], 5), new[] { 0, 2 }, 5, (s, i) => (Dist(s, i[0], i[2]), 5)),
            ("point_line_distance", (s, i) => s.PointLineDistance(i[2], i[4], 3), new[] { 2, 4 }, 3, (s, i) => (Math.Abs(LineOff(s, i[4], i[2])), 3)),
            ("line_distance", (s, i) => s.LineDistance(i[4], i[5], 2), new[] { 4, 5 }, 2, null),
            ("circle_line_distance", (s, i) => s.CircleLineDistance(i[6], i[4], 2), new[] { 6, 4 }, 2, null),
            ("circle_distance", (s, i) => s.CircleDistance(i[6], i[7], 5), new[] { 6, 7 }, 5, null),
            ("horizontal_distance", (s, i) => s.HorizontalDistance(i[0], i[2], 4), new[] { 0, 2 }, 4, (s, i) => (Math.Abs(s.Point(i[2]).X - s.Point(i[0]).X), 4)),
            ("vertical_distance", (s, i) => s.VerticalDistance(i[0], i[2], 4), new[] { 0, 2 }, 4, (s, i) => (Math.Abs(s.Point(i[2]).Y - s.Point(i[0]).Y), 4)),
            ("length", (s, i) => s.Length(i[4], 9), new[] { 4 }, 9, (s, i) => (Len(s, i[4]), 9)),
            ("angle", (s, i) => s.Angle(i[4], i[5], 0.5), new[] { 4, 5 }, 0.5, (s, i) => (Math.Abs(Math.Atan2(Cross(s, i[4], i[5]), Dot(s, i[4], i[5]))), 0.5)),
            ("radius", (s, i) => s.RadiusOf(i[6], 2.5), new[] { 6 }, 2.5, (s, i) => (s.Radius(i[6]), 2.5)),
            ("diameter", (s, i) => s.Diameter(i[6], 7), new[] { 6 }, 7, (s, i) => (s.Radius(i[6]), 3.5)),
        };
        if (cases.Count != 27 || cases.Select(c => c.Kind).Distinct().Count() != 27) return Fail("sketch: the every-method table is not 27 distinct kinds");
        // what the solved geometry shows each kind did (a swapped kind table round-trips by name, so the geometry is the witness)
        double Dist2((double X, double Y) a, (double X, double Y) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
        double Dist(Sketch s, uint a, uint b) => Dist2(s.Point(a), s.Point(b));
        (double X, double Y) Dir(Sketch s, uint line) { var e = s.Ends(line); var a = s.Point(e[0]); var b = s.Point(e[1]); return (b.X - a.X, b.Y - a.Y); }
        double Len(Sketch s, uint line) { var d = Dir(s, line); return Math.Sqrt(d.X * d.X + d.Y * d.Y); }
        double Cross(Sketch s, uint l, uint m) { var a = Dir(s, l); var b = Dir(s, m); return (a.X * b.Y - a.Y * b.X) / (Len(s, l) * Len(s, m)); }
        double Dot(Sketch s, uint l, uint m) { var a = Dir(s, l); var b = Dir(s, m); return (a.X * b.X + a.Y * b.Y) / (Len(s, l) * Len(s, m)); }
        double LineOff(Sketch s, uint line, uint point)
        {
            var e = s.Ends(line); var a = s.Point(e[0]); var d = Dir(s, line); var p = s.Point(point);
            return ((p.X - a.X) * d.Y - (p.Y - a.Y) * d.X) / Math.Sqrt(d.X * d.X + d.Y * d.Y);
        }
        (double X, double Y) Mid(Sketch s, uint line) { var e = s.Ends(line); var a = s.Point(e[0]); var b = s.Point(e[1]); return ((a.X + b.X) / 2, (a.Y + b.Y) / 2); }
        foreach (var (kind, make, refs, value, effect) in cases)
        {
            using var s = new Sketch();
            // 0..3 points, 4 and 5 lines, 6 and 7 circles, 8 an arc, 9 a free curve
            var pts = new[] { s.AddPoint(0, 0), s.AddPoint(10, 2), s.AddPoint(3, 7), s.AddPoint(12, 9) };
            var l1 = s.AddLine(pts[0], pts[1]); var l2 = s.AddLine(pts[2], pts[3]);
            var c1 = s.AddCircle(s.AddPoint(20, 20), 3); var c2 = s.AddCircle(s.AddPoint(30, 22), 4);
            var arc = s.AddArc(s.AddPoint(0, 30), s.AddPoint(5, 30), s.AddPoint(0, 35));
            var curve = s.AddBezier(s.AddPoint(40, 0), (41, 1), (42, 1), (43, 0));
            var ids = new[] { pts[0], pts[1], pts[2], pts[3], l1, l2, c1, c2, arc, curve };
            uint id;
            try { id = make(s, ids); }
            catch (BuildException e) { return Fail($"sketch: {kind} was refused: {e.Message}"); }
            if (s.ConstraintKind(id) != kind) return Fail($"sketch: {kind} reads back as {s.ConstraintKind(id)}");
            if (!s.ConstraintRefs(id).SequenceEqual(refs.Select(r => ids[r]))) return Fail($"sketch: {kind}'s refs read [{string.Join(", ", s.ConstraintRefs(id))}]");
            if (s.ConstraintValue(id) != value) return Fail($"sketch: {kind}'s value reads {s.ConstraintValue(id)}");
            if (effect is not null)
            {
                if (!s.Solve().Converged) return Fail($"sketch: {kind} does not solve");
                var (got, want) = effect(s, ids);
                if (Math.Abs(got - want) > 1e-6) return Fail($"sketch: {kind} left {got} where {want} was meant");
            }
        }
        using var k = new Sketch();
        var arcId = k.AddArc(k.AddPoint(0, 0), k.AddPoint(1, 0), k.AddPoint(0, 1));
        var conicId = k.AddConic(k.AddPoint(5, 5), (6, 7), (8, 5), 0.7);
        if (k.Kind(arcId) != "arc" || k.Kind(conicId) != "free_curve") return Fail("sketch: add_arc or add_conic kind");
    }
    // the drag rule: ascending id order to the library, a repeated id refused
    {
        var shuffled = new[]
        {
            new KeyValuePair<uint, (double X, double Y)>(9, (1, 2)),
            new KeyValuePair<uint, (double X, double Y)>(2, (3, 4)),
            new KeyValuePair<uint, (double X, double Y)>(5, (5, 6)),
        };
        var (order, xy) = Sketch.DragOrder(shuffled);
        if (!order.SequenceEqual(new uint[] { 2, 5, 9 }) || !xy.SequenceEqual(new double[] { 3, 4, 5, 6, 1, 2 })) return Fail($"sketch: drag order is [{string.Join(", ", order)}] / [{string.Join(", ", xy)}]");
        using var s = new Sketch();
        var (rc, _) = s.AddRect((0, 0), (40, 30));
        var twice = SkRefused(() => s.Drag(new[]
        {
            new KeyValuePair<uint, (double X, double Y)>(rc[0], (1, 1)),
            new KeyValuePair<uint, (double X, double Y)>(rc[0], (2, 2)),
        }));
        if (twice is null || twice.Message != $"sketch_drag: point {rc[0]} given twice") return Fail($"sketch: a repeated drag id gave '{twice?.Message}'");
        var back = s.Drag(new[]
        {
            new KeyValuePair<uint, (double X, double Y)>(rc[2], (45, 35)),
            new KeyValuePair<uint, (double X, double Y)>(rc[0], (5, 5)),
        });
        if (back.Status is not ("converged" or "conflicting" or "diverged")) return Fail($"sketch: a two-point drag gave {back}");
    }
    // report numbers convert exactly (a NaN or a fraction is an error naming the call, never a code)
    {
        if (Sketch.Exact(7, "sketch_solve") != 7 || Sketch.Exact(-3, "sketch_solve") != -3) return Fail("sketch: Exact of a whole number");
        foreach (var bad in new[] { double.NaN, 1.5, 3e9, -3e9, double.PositiveInfinity })
        {
            var e = SkRefused(() => Sketch.Exact(bad, "sketch_diagnose"));
            if (e is null || !e.Message.StartsWith("sketch_diagnose:")) return Fail($"sketch: Exact({bad}) gave '{e?.Message}'");
        }
    }
    // a closed other sketch and a bad end name
    {
        using var s = new Sketch();
        var other = new Sketch();
        var a = s.AddPoint(0, 0);
        other.AddPoint(1, 1);
        other.Dispose();
        try { s.Reference(other, 0); return Fail("sketch: referencing a closed sketch did not fail"); }
        catch (ObjectDisposedException e) when (e.Message.Contains("sketch: closed")) { }
        var line = s.AddLine(a, s.AddPoint(4, 0));
        var curve = s.AddBezier(s.AddPoint(5, 0), (6, 0), (7, 1), (8, 1));
        var middle = SkRefused(() => s.TangentAtEnd(curve, line, end: "middle"));
        if (middle is null || !middle.Message.Contains("end must be one of")) return Fail($"sketch: a bad end name gave '{middle?.Message}'");
    }
    Console.WriteLine("sketch: entities, constraints, solves, diagnosis, references and refusals with ids");
}
// Solid x profile hits: a line through a cuboid pierces two faces and is cut into three
// pieces, outside/inside/outside, the middle one spanning the box and sweeping; a loop no hit
// cuts is one piece; an open sheet has no pieces; a negative tolerance refused in the kernel's words.
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
    try { box.Hits(line, xy, -1.0); return Fail("solid hits: a negative tolerance was accepted"); }
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
// Health and healing on the kernel: Python's test_health_* / test_healed_* figures.
{
    static bool Rel(double a, double b, double rel) => Math.Abs(a - b) <= rel * Math.Abs(b);
    // 1. a closed cuboid: nothing free, nothing small, cracks only on request
    using var hBox = Solid.Cuboid(10, 10, 10);
    var hr = hBox.Health();
    if (hr.FreeEdges.Count != 0 || hr.Wires.Count != 0 || hr.Small.Count != 0 || hr.Cracks is not null)
        return Fail($"health: the closed cuboid reads {hr}");
    if (!Rel(hr.Extent, 10 * Math.Sqrt(3), 1e-12) || !Rel(hr.Rounding, 1e-7 * hr.Extent, 1e-12) || !Rel(hr.Tolerance, 1e-4 * hr.Extent, 1e-12))
        return Fail($"health: the cuboid's figures are extent {hr.Extent}, rounding {hr.Rounding}, tolerance {hr.Tolerance}");
    if (hr.LooseEdges != 0 || hr.WorstLoose != 0 || hr.SewPairs != 0 || hr.SewRefused != 0 || hr.SewWorstGap != 0)
        return Fail($"health: the cuboid has loose or sewing figures: {hr}");
    var hMeshed = hBox.Health(mesh: true).Cracks;
    if (hMeshed is null || !hMeshed.Watertight || hMeshed.Open != 0 || hMeshed.Folded != 0 || hMeshed.Crossings != 0 || hMeshed.Edges.Count != 0)
        return Fail($"health: the meshed cuboid's cracks read {hMeshed}");
    if (hBox.Health(0.5).Tolerance != 0.5 || hBox.Health(-1).Tolerance != hr.Tolerance)
        return Fail("health: a given tolerance is not the one used, or -1 is not the default");
    // 2. the cuboid without face 0: one closed rim of four edges, each partnered across the hole
    using var hHole = hBox.DropFaces(new[] { 0 });
    var ho = hHole.Health();
    if (ho.FreeEdges.Count != 4 || ho.Wires.Count != 1) return Fail($"health: the open cuboid has {ho.FreeEdges.Count} free edges in {ho.Wires.Count} wires");
    var hWire = ho.Wires[0];
    if (hWire.First != 0 || hWire.Count != 4 || !hWire.Closed || !Rel(hWire.Length, 40, 1e-6)) return Fail($"health: the rim reads {hWire}");
    var hRows = ho.FreeEdges.Select(e => (e.Trim, e.Edge, e.Face, e.Partner)).ToArray();
    var hWant = new (uint, uint?, uint, uint?)[] { (4, 3, 1, 2), (16, 2, 4, 3), (11, 1, 2, 0), (15, 0, 3, 1) };
    if (!hRows.SequenceEqual(hWant)) return Fail($"health: the rim's (trim, edge, face, partner) rows are {string.Join(" ", hRows)}");
    foreach (var e in ho.FreeEdges)
        if (e.Wire != 0 || e.SharedEnds != 0 || !Rel(e.Length, 10, 1e-6) || !Rel(e.Gap, 10, 1e-6)) return Fail($"health: a rim edge reads {e}");
    if (!Rel(ho.WorstGap, 10, 1e-6) || !ho.WireEdges(0).SequenceEqual(ho.FreeEdges)) return Fail($"health: the rim's worst gap {ho.WorstGap} or wire_edges(0) is wrong");
    var hoc = hHole.Health(mesh: true).Cracks;
    if (hoc is null || hoc.Watertight || hoc.Open != 0 || hoc.Folded != 0 || hoc.Crossings != 0 || hoc.Edges.Count != 0)
        return Fail($"health: the open cuboid's cracks read {hoc}");
    // 3. a thin plate at 0.01: its four thickness edges and four side faces, in that order
    using var hPlate = Solid.Cuboid(10, 10, 0.001);
    var hp = hPlate.Health(0.01);
    var hSmall = hp.Small.Select(s => (s.Kind, s.Index)).ToArray();
    var hSmallWant = new uint[] { 8, 9, 10, 11 }.Select(i => ("short_edge", i)).Concat(new uint[] { 2, 3, 4, 5 }.Select(i => ("sliver_face", i))).ToArray();
    if (!hSmall.SequenceEqual(hSmallWant)) return Fail($"health: the plate's small features are {string.Join(" ", hSmall)}");
    if (hp.Small.Take(4).Any(s => !Rel(s.Size, 0.001, 1e-6)) || hp.Small.Skip(4).Any(s => !Rel(s.Size, 0.0009999, 1e-3)))
        return Fail($"health: the plate's small sizes are {string.Join(" ", hp.Small.Select(s => s.Size))}");
    // 4. a tiny body: twelve short edges, six tiny faces, one tiny body
    using var hTiny = Solid.Cuboid(0.0005, 0.0005, 0.0005);
    var ht = hTiny.Health(0.01);
    var hTinyFaces = ht.Small.Where(s => s.Kind == "tiny_face").ToArray();
    var hTinyBody = ht.Small.Where(s => s.Kind == "tiny_body").ToArray();
    if (ht.Small.Count(s => s.Kind == "short_edge") != 12 || hTinyFaces.Length != 6 || hTinyBody.Length != 1 || ht.Small.Count != 19)
        return Fail($"health: the tiny body's small features are {string.Join(" ", ht.Small)}");
    if (!hTinyFaces.Select(s => s.Index).SequenceEqual(new uint[] { 0, 1, 2, 3, 4, 5 }) || hTinyFaces.Any(s => !Rel(s.Size, 2.5e-7, 1e-6)))
        return Fail($"health: the tiny faces read {string.Join(" ", hTinyFaces.AsEnumerable())}");
    if (hTinyBody[0].Index != 0 || !Rel(hTinyBody[0].Size, 0.0005 * Math.Sqrt(3), 1e-9)) return Fail($"health: the tiny body reads {hTinyBody[0]}");
    // 5. the cuboid heals to itself, as a new solid; every edge exact
    var (hHealed, hh) = hBox.Healed();
    using (hHealed)
    {
        if (hHealed.Handle.DangerousGetHandle() == hBox.Handle.DangerousGetHandle()) return Fail("healed: the cuboid came back as the same handle");
        if (hh.Fixes.Count != 0 || hh.Refused.Count != 0 || hh.Guarded) return Fail($"healed: the cuboid's report is {hh}");
        if (hh.SmallBefore != 0 || hh.SmallAfter != 0 || hh.FreeBefore != 0 || hh.FreeAfter != 0 || !hh.ClosedBefore || !hh.ClosedAfter
            || hh.NonmanifoldBefore != 0 || hh.NonmanifoldAfter != 0)
            return Fail($"healed: the cuboid's before/after counts are {hh}");
        if (!Rel(hh.Tolerance, hr.Tolerance, 1e-12) || hh.Moved != 0) return Fail($"healed: the cuboid's tolerance {hh.Tolerance} or moved {hh.Moved}");
        if (hHealed.Faces != 6 || !Rel(hHealed.Mass().Volume, 1000, 1e-6)) return Fail($"healed: the healed cuboid has {hHealed.Faces} faces");
        for (uint e = 0; e < 12; e++)
            if (hHealed.EdgeTolerance(e) != 0.0) return Fail($"edge_tolerance: cuboid edge {e} reads {hHealed.EdgeTolerance(e)}");
        if (hHealed.EdgeTolerance(0xFFFFFFF0) is not null) return Fail("edge_tolerance: an id no trim names is not null");
    }
    var (hHalf, hHalfReport) = hBox.Healed(0.5);
    hHalf.Dispose();
    if (hHalfReport.Tolerance != 0.5) return Fail($"healed: a tolerance of 0.5 reads back {hHalfReport.Tolerance}");
    // 6. every kind switched off: each of the plate's small features refused as toggled
    var (hOffBody, hOff) = hPlate.Healed(0.01, edges: false, faces: false, holes: false);
    hOffBody.Dispose();
    var hOffRows = hOff.Refused.Select(r => (r.Kind, r.Index, r.Why, r.Figure)).ToArray();
    var hOffWant = new uint[] { 8, 9, 10, 11 }.Select(i => ("short_edge", i, "toggled", 0.0))
        .Concat(new uint[] { 2, 3, 4, 5 }.Select(i => ("sliver_face", i, "toggled", 0.0))).ToArray();
    if (hOff.Fixes.Count != 0 || hOff.SmallBefore != 8 || hOff.SmallAfter != 8 || !hOffRows.SequenceEqual(hOffWant))
        return Fail($"healed: every kind off gave fixes {hOff.Fixes.Count}, small {hOff.SmallBefore}/{hOff.SmallAfter}, refused {string.Join(" ", hOffRows)}");
    var (hOnBody, hOn) = hPlate.Healed(0.01);
    hOnBody.Dispose();
    if (hOn.SmallBefore != 8 || hOn.Refused.Any(r => r.Why == "toggled") || (hOn.Guarded && hOn.Refused.Any(r => r.Why != "body_guard")))
        return Fail($"healed: every kind on gave {hOn}, refused {string.Join(" ", hOn.Refused)}");
    // a pinhole in a sheet (a 0.003 hole, its loop 1): a small hole, healed with holes on, refused as toggled with holes off
    using (var hSheet = Solid.Face(Profile.Rect(20, 20), new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }))
    using (var hPin = Solid.Extrude(Profile.Circle(0.003), new double[] { 0, 0, -1, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 2))
    using (var hPinhole = hSheet.Trim(hPin, tolerance: 1e-4))
    {
        var hPinSmall = hPinhole.Health(0.01).Small;
        var (hNoHolesBody, hNoHoles) = hPinhole.Healed(0.01, holes: false);
        hNoHolesBody.Dispose();
        var (hHolesBody, hHoles) = hPinhole.Healed(0.01);
        hHolesBody.Dispose();
        if (!hPinSmall.Any(s => s.Kind == "small_hole" && s.Index == 1)) return Fail($"health: the pinhole sheet lists no small hole: {string.Join(" ", hPinSmall)}");
        if (!hNoHoles.Refused.Any(r => (r.Kind, r.Index, r.Why) == ("small_hole", 1u, "toggled")) || hNoHoles.Fixes.Count != 0)
            return Fail($"healed: holes off did not refuse the pinhole as toggled: {string.Join(" ", hNoHoles.Refused)}");
        if (!hHoles.Fixes.Select(f => (f.Kind, f.Index)).SequenceEqual(new[] { ("small_hole", 1u) }) || hHoles.Refused.Any(r => r.Why == "toggled"))
            return Fail($"healed: holes on did not heal the pinhole: {string.Join(" ", hHoles.Fixes)}");
    }
    // the switches as the C ABI's flag bits: 1 edges, 2 faces, 4 holes
    if (Solid.HealFlags(true, true, true) != 7 || Solid.HealFlags(true, false, false) != 1 || Solid.HealFlags(false, true, false) != 2
        || Solid.HealFlags(false, false, true) != 4 || Solid.HealFlags(false, false, false) != 0)
        return Fail("healed: the flag bits are not 1 edges, 2 faces, 4 holes");
    // 7. a closed solid: every call refuses at the binding, in its words
    var hClosed = Solid.Cuboid(1, 1, 1);
    hClosed.Dispose();
    foreach (var (what, call) in new (string, Action)[] { ("health", () => hClosed.Health()), ("healed", () => hClosed.Healed()), ("edge_tolerance", () => hClosed.EdgeTolerance(0)) })
    {
        try { call(); return Fail($"{what}: a closed solid answered"); }
        catch (ObjectDisposedException e) when (e.Message.Contains("closed")) { }
    }
    // The decoders, on Python's distinct rows: a swapped column cannot read back the same.
    const uint hNone = 0xFFFFFFFF;
    var dr = Cadaclysm.Blacksmith.HealthReport.FromRows(
        new uint[] { 2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2 }, new[] { 0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5 },
        new uint[] { 10, 20, 30, 40, 1, 2, 11, hNone, 31, 41, hNone, 0 }, new[] { 1.5, 2.5, 3.5, double.PositiveInfinity },
        new uint[] { 0, 2, 1 }, new[] { 8.5, 2.5 }, new uint[] { 1, 77, 4, 99 }, new[] { 0.125, 0.0625 }, new uint[] { 5, 6 });
    if ((dr.Tolerance, dr.Rounding, dr.Extent, dr.WorstGap) != (0.5, 0.25, 9.0, 7.5)
        || (dr.LooseEdges, dr.WorstLoose, dr.SewPairs, dr.SewRefused, dr.SewWorstGap) != (3u, 6.5, 4u, 5u, 5.5))
        return Fail($"health decoder: the summary reads {dr}");
    if (!dr.FreeEdges.SequenceEqual(new[] { new Cadaclysm.Blacksmith.FreeEdge(10, 20, 30, 40, 1, 2, 1.5, 2.5),
                                            new Cadaclysm.Blacksmith.FreeEdge(11, null, 31, 41, null, 0, 3.5, double.PositiveInfinity) }))
        return Fail($"health decoder: the free edges read {string.Join(" ", dr.FreeEdges)}");
    if (!dr.Wires.SequenceEqual(new[] { new Cadaclysm.Blacksmith.FreeWire(0, 2, true, 8.5, 2.5) })) return Fail($"health decoder: the wires read {string.Join(" ", dr.Wires)}");
    if (!dr.Small.SequenceEqual(new[] { new Cadaclysm.Blacksmith.SmallFeature("collapsed_edge", 77, 0.125), new Cadaclysm.Blacksmith.SmallFeature("tiny_body", 99, 0.0625) }))
        return Fail($"health decoder: the small features read {string.Join(" ", dr.Small)}");
    if (dr.Cracks is null || (dr.Cracks.Watertight, dr.Cracks.Open, dr.Cracks.Folded, dr.Cracks.Crossings) != (false, 11u, 12u, 13u) || !dr.Cracks.Edges.SequenceEqual(new uint[] { 5, 6 }))
        return Fail($"health decoder: the cracks read {dr.Cracks}");
    var dh = Cadaclysm.Blacksmith.HealReport.FromRows(new uint[] { 2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4 }, new[] { 0.5, 0.25 },
        new uint[] { 5, 11, 0, 12 }, new[] { 1.5, 0.125, 2.5, 0.0625 }, new uint[] { 3, 21, 9, 4, 22, 3, 2, 23, 10 }, new[] { 0.0, 7.5, 0.0 });
    if ((dh.Tolerance, dh.Moved, dh.Guarded) != (0.5, 0.25, true) || (dh.SmallBefore, dh.SmallAfter, dh.FreeBefore, dh.FreeAfter) != (9u, 8u, 7u, 6u)
        || (dh.ClosedBefore, dh.ClosedAfter, dh.NonmanifoldBefore, dh.NonmanifoldAfter) != (true, false, 5u, 4u))
        return Fail($"heal decoder: the summary reads {dh}");
    if (!dh.Fixes.SequenceEqual(new[] { new Cadaclysm.Blacksmith.HealFix("small_hole", 11, 1.5, 0.125), new Cadaclysm.Blacksmith.HealFix("short_edge", 12, 2.5, 0.0625) }))
        return Fail($"heal decoder: the fixes read {string.Join(" ", dh.Fixes)}");
    if (!dh.Refused.SequenceEqual(new[] { new Cadaclysm.Blacksmith.HealRefusal("tiny_face", 21, "toggled", 0.0),
                                          new Cadaclysm.Blacksmith.HealRefusal("tiny_body", 22, "chain", 7.5),
                                          new Cadaclysm.Blacksmith.HealRefusal("sliver_face", 23, "unsupported", 0.0) }))
        return Fail($"heal decoder: the refusals read {string.Join(" ", dh.Refused)}");
    Console.WriteLine("kernel health/healed: cuboid, open rim, plate, tiny body, healed cuboid, toggled, pinhole, closed solid and both decoders: ok");
}
// Health and healing on the reader: Python's test_brep_health_* / test_brep_healed_* figures on
// st203-bapl.stp's 188-free-edge body (breps[1]; body 0 takes minutes). The sample is the
// repository's, not an SDK checkout's, so this runs where found; the decoders run everywhere.
{
    static bool Rel(double a, double b, double rel) => Math.Abs(a - b) <= rel * Math.Abs(b);
    var st203 = sampleRoot is null ? null : System.IO.Path.Combine(sampleRoot, "st203-bapl.stp");
    if (st203 is not null && File.Exists(st203))
    {
        using var stScene = Cadaclysm.Cadaclysm.Open(st203);
        var breps = stScene.Nodes.Select(n => n.Brep).Where(b => b is not null).Select(b => b!).ToList();
        try
        {
            var stBody = breps[1];
            // 8. health
            var stReport = stBody.Health();
            if (stReport.FreeEdges.Count != 188 || stReport.Wires.Count != 45 || stReport.Wires.Sum(w => (long)w.Count) != 188)
                return Fail($"brep health: {stReport.FreeEdges.Count} free edges in {stReport.Wires.Count} wires");
            if (!stReport.WireEdges(0).SequenceEqual(stReport.FreeEdges.Take((int)stReport.Wires[0].Count)) || stReport.WireEdges(0).Any(e => e.Wire != 0))
                return Fail("brep health: wire_edges(0) is not the first wire's rows");
            var stFirst = stReport.FreeEdges[0];
            if ((stFirst.Trim, stFirst.Edge, stFirst.Face, stFirst.Wire, stFirst.Partner, stFirst.SharedEnds) != (0u, (uint?)41363, 0u, 0u, (uint?)67, 0u)
                || !Rel(stFirst.Gap, 95.01496054, 1e-6))
                return Fail($"brep health: the first free edge reads {stFirst}");
            if (stReport.FreeEdges.Any(e => e.Partner is null ? !double.IsPositiveInfinity(e.Gap) : e.Partner == e.Trim))
                return Fail("brep health: a free edge without a partner has a finite gap, or one partners itself");
            if (!Rel(stReport.Extent, 253.66439715552204, 1e-12) || !Rel(stReport.Rounding, 1e-7 * stReport.Extent, 1e-12)
                || !Rel(stReport.Tolerance, 1e-4 * stReport.Extent, 1e-12))
                return Fail($"brep health: extent {stReport.Extent}, rounding {stReport.Rounding}, tolerance {stReport.Tolerance}");
            if (stReport.Cracks is not null || stBody.Health(double.NaN).Tolerance != stReport.Tolerance) return Fail("brep health: cracks unasked, or NaN is not the default");
            var (stSewn, stSew) = stBody.Sewed();
            stSewn.Dispose();
            if (stReport.LooseEdges != 0 || stReport.WorstLoose != 0 || stReport.SewRefused != 4 || stSew.Refused != 4 || stReport.SewPairs != stSew.Pairs
                || !Rel(stReport.SewWorstGap, stSew.WorstGap, 1e-12) || stReport.SewWorstGap <= 0)
                return Fail($"brep health: loose {stReport.LooseEdges}, sew {stReport.SewPairs}/{stReport.SewRefused}/{stReport.SewWorstGap} against sewed's {stSew}");
            var stCracks = stBody.Health(mesh: true).Cracks;
            if (stCracks is null || (stCracks.Watertight, stCracks.Open, stCracks.Folded, stCracks.Crossings) != (false, 0u, 0u, 166u) || stCracks.Edges.Count != 0)
                return Fail($"brep health: the meshed report's cracks read {stCracks}");
            var stWide = stBody.Health(5.0);
            var stKinds = stWide.Small.Select(s => s.Kind).Distinct().OrderBy(k => k).ToArray();
            if (stWide.Small.Count != 96 || !stKinds.SequenceEqual(new[] { "short_edge", "sliver_face", "tiny_face" }))
                return Fail($"brep health: at 5, {stWide.Small.Count} small features of kinds {string.Join(" ", stKinds)}");
            var stShort = stWide.Small.First(s => s.Kind == "short_edge");
            if (stShort.Index != 41550 || !Rel(stShort.Size, 3.1622776616321775, 1e-9)) return Fail($"brep health: the first short edge reads {stShort}");
            // 9. healed
            var (stSame, stDefaults) = stBody.Healed();
            stSame.Dispose();
            if (stDefaults.SmallBefore != 0 || stDefaults.FreeBefore != 188 || stDefaults.FreeAfter > 188 || !Rel(stDefaults.Tolerance, 1e-4 * stReport.Extent, 1e-12))
                return Fail($"brep healed: at the default tolerance {stDefaults}");
            var (stHealed, stHeal) = stBody.Healed(5.0);
            using (stHealed)
            {
                if (stHeal.Tolerance != 5.0 || stHeal.SmallBefore != 96 || stHeal.Fixes.Count != 28 || stHeal.SmallAfter != 8 || stHeal.FreeBefore != 188 || stHeal.FreeAfter != 88)
                    return Fail($"brep healed: at 5 {stHeal}");
                if (stHeal.Refused.Count != 8 || stHeal.Refused.Any(r => r.Kind != "sliver_face" || r.Why != "uneven"))
                    return Fail($"brep healed: the refusals read {string.Join(" ", stHeal.Refused)}");
                if (stHeal.ClosedBefore || stHeal.ClosedAfter || stHeal.NonmanifoldBefore != 0 || stHeal.NonmanifoldAfter != 0)
                    return Fail($"brep healed: closed/non-manifold before and after read {stHeal}");
                if (!Rel(stHeal.Moved, 1.581138831332503, 1e-9) || !Rel(stHeal.Fixes.Max(f => f.Moved), 1.8248105306211464, 1e-9))
                    return Fail($"brep healed: moved {stHeal.Moved}, the largest fix moved {stHeal.Fixes.Max(f => f.Moved)}");
                var stFix = stHeal.Fixes.First(f => f.Kind == "short_edge");
                if (stFix.Index != 41550 || !Rel(stFix.Size, 3.1622776616321775, 1e-9)) return Fail($"brep healed: the first short-edge fix reads {stFix}");
                if (stBody.EdgeTolerance(41550) != 0.0 || stHealed.EdgeTolerance(41550) is not null || stHealed.EdgeTolerance(41363) != 0.0
                    || stHealed.EdgeTolerance(0xFFFFFFF0) is not null)
                    return Fail($"brep edge_tolerance: {stBody.EdgeTolerance(41550)} {stHealed.EdgeTolerance(41550)} {stHealed.EdgeTolerance(41363)} {stHealed.EdgeTolerance(0xFFFFFFF0)}");
                if (stHealed.Health(5.0).Small.Count != 8 || stBody.Health(5.0).Small.Count != 96) return Fail("brep healed: the result's or the input's small count moved");
            }
            var (stOffBody, stOff) = stBody.Healed(5.0, edges: false, faces: false, holes: false);
            stOffBody.Dispose();
            var stPerKind = new[] { "short_edge", "sliver_face", "tiny_face" }.Select(k => stOff.Refused.Count(r => r.Kind == k)).ToArray();
            if (stOff.Fixes.Count != 0 || stOff.Refused.Count != 96 || stOff.Refused.Any(r => r.Why != "toggled" || r.Figure != 0.0)
                || !stPerKind.SequenceEqual(new[] { 64, 26, 6 }) || stOff.FreeAfter != stOff.FreeBefore)
                return Fail($"brep healed: every kind off gave {stOff.Fixes.Count} fixes, {stOff.Refused.Count} refused, per kind {string.Join(" ", stPerKind)}");
            var (stEdgesBody, stEdgesOnly) = stBody.Healed(5.0, faces: false, holes: false);
            stEdgesBody.Dispose();
            if (stEdgesOnly.Refused.Any(r => r.Kind != "short_edge" && r.Why != "toggled") || stEdgesOnly.Fixes.Any(f => f.Kind != "short_edge" && f.Kind != "collapsed_edge"))
                return Fail($"brep healed: edges only gave {string.Join(" ", stEdgesOnly.Fixes)}");
        }
        finally
        {
            foreach (var b in breps) b.Dispose();
        }
        var stReleased = breps[1];
        foreach (var (what, call) in new (string, Action)[] { ("health", () => stReleased.Health()), ("healed", () => stReleased.Healed()), ("edge_tolerance", () => stReleased.EdgeTolerance(0)) })
        {
            try { call(); return Fail($"brep {what}: a released brep answered"); }
            catch (CadaclysmException e) when (e.Message.Contains("released")) { }
        }
        Console.WriteLine("reader health/healed: st203-bapl body 1's free edges, wires, cracks, small features, heal at 5, toggled and released: ok");
    }
    else Console.WriteLine($"reader health/healed: {st203} not to hand, skipped");
    // The decoders, on Python's distinct rows: a swapped column cannot read back the same.
    const uint rNone = 0xFFFFFFFF;
    var rdr = Cadaclysm.HealthReport.FromRows(
        new uint[] { 2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2 }, new[] { 0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5 },
        new uint[] { 10, 20, 30, 40, 1, 2, 11, rNone, 31, 41, rNone, 0 }, new[] { 1.5, 2.5, 3.5, double.PositiveInfinity },
        new uint[] { 0, 2, 1 }, new[] { 8.5, 2.5 }, new uint[] { 1, 77, 4, 99 }, new[] { 0.125, 0.0625 }, new uint[] { 5, 6 });
    if ((rdr.Tolerance, rdr.Rounding, rdr.Extent, rdr.WorstGap) != (0.5, 0.25, 9.0, 7.5)
        || (rdr.LooseEdges, rdr.WorstLoose, rdr.SewPairs, rdr.SewRefused, rdr.SewWorstGap) != (3u, 6.5, 4u, 5u, 5.5))
        return Fail($"brep health decoder: the summary reads {rdr}");
    if (!rdr.FreeEdges.SequenceEqual(new[] { new Cadaclysm.FreeEdge(10, 20, 30, 40, 1, 2, 1.5, 2.5),
                                            new Cadaclysm.FreeEdge(11, null, 31, 41, null, 0, 3.5, double.PositiveInfinity) }))
        return Fail($"brep health decoder: the free edges read {string.Join(" ", rdr.FreeEdges)}");
    if (!rdr.Wires.SequenceEqual(new[] { new Cadaclysm.FreeWire(0, 2, true, 8.5, 2.5) })) return Fail($"brep health decoder: the wires read {string.Join(" ", rdr.Wires)}");
    if (!rdr.Small.SequenceEqual(new[] { new Cadaclysm.SmallFeature("collapsed_edge", 77, 0.125), new Cadaclysm.SmallFeature("tiny_body", 99, 0.0625) }))
        return Fail($"brep health decoder: the small features read {string.Join(" ", rdr.Small)}");
    if (rdr.Cracks is null || (rdr.Cracks.Watertight, rdr.Cracks.Open, rdr.Cracks.Folded, rdr.Cracks.Crossings) != (false, 11u, 12u, 13u) || !rdr.Cracks.Edges.SequenceEqual(new uint[] { 5, 6 }))
        return Fail($"brep health decoder: the cracks read {rdr.Cracks}");
    var rdh = Cadaclysm.HealReport.FromRows(new uint[] { 2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4 }, new[] { 0.5, 0.25 },
        new uint[] { 5, 11, 0, 12 }, new[] { 1.5, 0.125, 2.5, 0.0625 }, new uint[] { 3, 21, 9, 4, 22, 3, 2, 23, 10 }, new[] { 0.0, 7.5, 0.0 });
    if ((rdh.Tolerance, rdh.Moved, rdh.Guarded) != (0.5, 0.25, true) || (rdh.SmallBefore, rdh.SmallAfter, rdh.FreeBefore, rdh.FreeAfter) != (9u, 8u, 7u, 6u)
        || (rdh.ClosedBefore, rdh.ClosedAfter, rdh.NonmanifoldBefore, rdh.NonmanifoldAfter) != (true, false, 5u, 4u))
        return Fail($"brep heal decoder: the summary reads {rdh}");
    if (!rdh.Fixes.SequenceEqual(new[] { new Cadaclysm.HealFix("small_hole", 11, 1.5, 0.125), new Cadaclysm.HealFix("short_edge", 12, 2.5, 0.0625) }))
        return Fail($"brep heal decoder: the fixes read {string.Join(" ", rdh.Fixes)}");
    if (!rdh.Refused.SequenceEqual(new[] { new Cadaclysm.HealRefusal("tiny_face", 21, "toggled", 0.0),
                                          new Cadaclysm.HealRefusal("tiny_body", 22, "chain", 7.5),
                                          new Cadaclysm.HealRefusal("sliver_face", 23, "unsupported", 0.0) }))
        return Fail($"brep heal decoder: the refusals read {string.Join(" ", rdh.Refused)}");
    if (Brep.HealFlags(true, true, true) != 7 || Brep.HealFlags(true, false, false) != 1 || Brep.HealFlags(false, true, false) != 2
        || Brep.HealFlags(false, false, true) != 4 || Brep.HealFlags(false, false, false) != 0)
        return Fail("brep healed: the flag bits are not 1 edges, 2 faces, 4 holes");
    Console.WriteLine("reader health/heal decoders and flags: ok");
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

// Solid.WithMaterial and Solid.Styled with their readers, at parity with the Python
// reference's test_a_material_and_an_outside_style_ride_operations_and_reach_step.
{
    using var cube = Solid.Cuboid(1, 1, 1);
    if (cube.Material != null) return Fail("material: a fresh cuboid has a material");
    using var made = cube.WithMaterial("Steel");
    using var steel = made.Styled("materials/steel.mtlx", "BrushedSteel");
    if (steel.Material != "Steel" || steel.StyleLocation != "materials/steel.mtlx" || steel.StyleIdentification != "BrushedSteel")
        return Fail($"material: read back {steel.Material}, {steel.StyleLocation}, {steel.StyleIdentification}");
    using var tool = cube.Translate(0.5, 0.5, 0.5);
    using var cut = steel.Cut(tool);
    if (cut.Material != "Steel") return Fail($"material: a cut is made of {cut.Material}, not its target's Steel");
    using var only = cube.Styled(null, "BrushedSteel");
    if (only.StyleLocation != null) return Fail("material: a style given no location has one");
    var text = steel.StepText();
    if (!text.Contains("MATERIAL_DESIGNATION('Steel'") || !text.Contains("EXTERNALLY_DEFINED_STYLE(IDENTIFIER('BrushedSteel')"))
        return Fail("material: STEP is missing the material or the style");
    try { cube.WithMaterial(" "); return Fail("material: a blank material was accepted"); }
    catch (BuildException) { }
    try { cube.Styled(null, null); return Fail("material: a style naming nothing was accepted"); }
    catch (BuildException) { }
    Console.WriteLine("kernel material: read back, kept by a cut, written to STEP");
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
// Oriented box, lengths, containment and closest points: Python's test_oriented_box_* ..
// test_closest_*, trimmed to what proves the marshalling (measure plan 3).
{
    bool Within(double a, double b, double tol) => Math.Abs(a - b) <= tol;
    string Refused(Action act)
    {
        try { act(); return "(no exception)"; }
        catch (BuildException e) { return e.Message; }
    }
    // 1. the oriented box of a turned cuboid
    using (var turned0 = Solid.Cuboid(2, 3, 4))
    using (var turned = turned0.Rotate(new double[] { 0, 0, 0, 0, 0, 1 }, Math.PI / 6))
    {
        var ob = turned.OrientedBox(1e-9);
        var want = new[] { 1.0, 1.5, 2.0 };
        var sorted = ob.Half.OrderBy(h => h).ToArray();
        for (var i = 0; i < 3; i++)
            if (!(sorted[i] >= want[i] - 1e-9 && sorted[i] <= want[i] + 1e-3)) return Fail($"oriented box: half {string.Join(",", ob.Half)} is not (1, 1.5, 2)");
        if (ob.Centre.Length != 3 || ob.Centre.Any(c => Math.Abs(c) > 1e-3)) return Fail($"oriented box: centre {string.Join(",", ob.Centre)} is not the origin");
        if (ob.Axes.Length != 3 || ob.Axes.Any(r => r.Length != 3)) return Fail("oriented box: axes are not three rows of three");
        for (var i = 0; i < 3; i++)
            for (var j = 0; j < 3; j++)
            {
                var dot = ob.Axes[i][0] * ob.Axes[j][0] + ob.Axes[i][1] * ob.Axes[j][1] + ob.Axes[i][2] * ob.Axes[j][2];
                if (!Within(dot, i == j ? 1 : 0, 1e-9)) return Fail($"oriented box: axes {i}.{j} = {dot}");
            }
    }
    // 2. defaults and errors
    using (var cyl = Solid.Cylinder(1, 2))
    {
        var a0 = cyl.OrientedBox(0);
        var aNeg = cyl.OrientedBox(-1);
        var aDef = cyl.OrientedBox(1e-5);
        if (!a0.Half.SequenceEqual(aDef.Half) || !aNeg.Half.SequenceEqual(aDef.Half) || !a0.Centre.SequenceEqual(aDef.Centre)
            || !a0.Axes.Zip(aDef.Axes).All(p => p.First.SequenceEqual(p.Second)))
            return Fail("oriented box: accuracy 0 or -1 is not the default 1e-5");
        var grown = 1 + 3.125e-5 * Math.Sqrt(12);
        if (aDef.Half.Any(h => !Within(h, grown, 1e-12)))
            return Fail($"oriented box: half {string.Join(",", aDef.Half)} is not the grown figure {grown}");
        var nan = Refused(() => cyl.OrientedBox(double.NaN));
        if (!nan.StartsWith("oriented_box: ") || !nan.Contains("is not an accuracy")) return Fail($"oriented box: NaN accuracy gave '{nan}'");
        using var openSheet = Solid.Cuboid(1, 2, 3).FaceSheet(0);
        var open = Refused(() => openSheet.OrientedBox());
        if (!open.StartsWith("oriented_box: ")) return Fail($"oriented box: an open sheet gave '{open}'");
    }
    // 3. edge length
    using (var cyl = Solid.Cylinder(2.5, 4))
    {
        var circles = 0;
        foreach (var edge in cyl.Edges.Where(e => e.Kind == "circle"))
        {
            circles++;
            var len = cyl.EdgeLength(edge.Index, 1e-9);
            if (len.Error < 0 || len.Error > 1e-6 * len.Value || !Within(len.Value, 5 * Math.PI, Math.Max(len.Error, 1e-9)) || !len.AccuracyMet || len.FromPolyline)
                return Fail($"edge length: circle {edge.Index} reads {len}");
        }
        if (circles == 0) return Fail("edge length: the cylinder has no circle edge");
        using var cube = Solid.Cuboid(1, 1, 1);
        var past = Refused(() => cube.EdgeLength(cube.Edges.Count));
        if (!past.StartsWith("edge_length: ")) return Fail($"edge length: an edge past the end gave '{past}'");
    }
    // 4. profile length
    using (var slot = Profile.Slot((0, 0), 8, 1))
    {
        var len = slot.Length(1e-9);
        if (len.Error < 0 || len.Error > 1e-6 * len.Value || !Within(len.Value, 12 + 2 * Math.PI, Math.Max(len.Error, 1e-9)) || !len.AccuracyMet) return Fail($"profile length: the slot reads {len}");
        var nan = Refused(() => slot.Length(double.NaN));
        if (!nan.StartsWith("profile_length: ")) return Fail($"profile length: NaN accuracy gave '{nan}'");
    }
    // 4b. arc-length sampling
    {
        double Dist(double[] a, double[] b) => Math.Sqrt(Enumerable.Range(0, 3).Sum(k => (a[k] - b[k]) * (a[k] - b[k])));
        using (var cyl = Solid.Cylinder(2.5, 4))
        {
            var rims = 0;
            foreach (var edge in cyl.Edges.Where(e => e.Kind == "circle"))
            {
                rims++;
                var c = edge.Curve!;
                var start = cyl.EdgePointAtLength(edge.Index, 0);
                if (start.Parameter != c.T0) return Fail($"point at length: edge {edge.Index} starts at parameter {start.Parameter}, not {c.T0}");
                var q = cyl.EdgePointAtLength(edge.Index, 2.5 * Math.PI / 2);
                if (Math.Abs(q.Parameter - (c.T0 + Math.PI / 2)) > 1e-9) return Fail($"point at length: a quarter turn reads parameter {q.Parameter}");
                if (Math.Abs(Dist(q.Point, c.Origin) - 2.5) > 1e-9) return Fail($"point at length: the quarter point is off the circle: {q}");
                if (Math.Abs(Norm(q.Tangent) - 1) > 1e-12) return Fail($"point at length: the tangent is not unit: {q}");
                if (q.Segment is not null || q.FromPolyline || !(q.Error >= 0) || double.IsInfinity(q.Error)) return Fail($"point at length: segment, polyline or error wrong: {q}");
                var four = cyl.EdgeDivideByCount(edge.Index, 4);
                if (four.Count != 4) return Fail($"divide by count: a rim gave {four.Count} samples");
                for (var k = 0; k < 4; k++)
                    if (Math.Abs(Dist(four[k].Point, four[(k + 1) % 4].Point) - 2.5 * Math.Sqrt(2)) > 1e-9) return Fail($"divide by count: the chord {k} is off");
                if (!Near(four[0].Point, start.Point, 1e-12)) return Fail("divide by count: the first sample is not the start");
                var bylen = cyl.EdgeDivideByLength(edge.Index, 2.5 * Math.PI / 2);
                if (bylen.Count != 4) return Fail($"divide by length: a rim gave {bylen.Count} samples");
            }
            if (rims < 2) return Fail("arc length: the cylinder has fewer than two circle edges");
            var past = Refused(() => cyl.EdgePointAtLength(cyl.Edges.Count, 0));
            if (!past.StartsWith("edge_point_at_length: ")) return Fail($"point at length: an edge past the end gave '{past}'");
            var rim = cyl.Edges.First(e => e.Kind == "circle").Index;
            var negEdge = Refused(() => cyl.EdgePointAtLength(-1, 0));
            if (negEdge == "(no exception)") return Fail("point at length: a negative edge was not refused");
            Console.WriteLine($"arc length: negative edge refused: {negEdge}");
            var neg = Refused(() => cyl.EdgePointAtLength(rim, -1));
            if (!neg.StartsWith("edge_point_at_length: ")) return Fail($"point at length: -1 gave '{neg}'");
            var far = Refused(() => cyl.EdgePointAtLength(rim, 100));
            if (!far.StartsWith("edge_point_at_length: ")) return Fail($"point at length: 100 gave '{far}'");
            var zero = Refused(() => cyl.EdgeDivideByCount(rim, 0));
            if (!zero.StartsWith("edge_divide_by_count: ") || !zero.Contains("not at least 1")) return Fail($"divide by count: 0 gave '{zero}'");
            var huge = Refused(() => cyl.EdgeDivideByCount(rim, 1_000_001));
            if (!huge.StartsWith("edge_divide_by_count: ") || !huge.Contains("not at most 1000000")) return Fail($"divide by count: 1000001 gave '{huge}'");
            var nostep = Refused(() => cyl.EdgeDivideByLength(rim, 0));
            if (!nostep.StartsWith("edge_divide_by_length: ")) return Fail($"divide by length: 0 gave '{nostep}'");
            var nan = Refused(() => cyl.EdgePointAtLength(rim, 1, double.NaN));
            if (!nan.StartsWith("edge_point_at_length: ") || !nan.Contains("is not an accuracy")) return Fail($"point at length: NaN accuracy gave '{nan}'");
        }
        using (var box = Solid.Cuboid(2, 3, 4))
        {
            var line = box.Edges.First(e => e.Kind == "line" && Within(box.EdgeLength(e.Index).Value, 4, 1e-9));
            var c = line.Curve!;
            var five = box.EdgeDivideByCount(line.Index, 4);
            if (five.Count != 5) return Fail($"divide by count: an open edge gave {five.Count} samples");
            for (var k = 0; k < 5; k++)
                if (Math.Abs(Dist(five[k].Point, five[0].Point) - k) > 1e-9) return Fail($"divide by count: sample {k} is not {k} from the start");
            if (five[0].Parameter != c.T0 || five[4].Parameter != c.T1) return Fail("divide by count: the ends' parameters are not the curve's range");
            var by = box.EdgeDivideByLength(line.Index, 1.5);
            if (by.Count != 3) return Fail($"divide by length: an open edge gave {by.Count} samples");
            for (var k = 0; k < 3; k++)
                if (Math.Abs(Dist(by[k].Point, by[0].Point) - 1.5 * k) > 1e-9) return Fail($"divide by length: sample {k} is off");
        }
        using (var slot = Profile.Slot((0, 0), 8, 1))
        {
            var at = slot.PointAtLength(6 + Math.PI / 2);
            if (!Near(at.Point, new double[] { 4, 0, 0 }, 1e-9) || at.Segment != 1u) return Fail($"profile point at length: the slot's far end reads {at}");
            var eight = slot.DivideByCount(8);
            if (eight.Count != 8 || eight.Any(a => a.Segment is null || a.Segment > 4u)) return Fail("profile divide by count: 8 samples, each on a side 0..4");
            var by = slot.DivideByLength(3);
            if (by.Count != (int)Math.Floor((12 + 2 * Math.PI) / 3) + 1) return Fail($"profile divide by length: {by.Count} samples");
            for (var k = 0; k < by.Count; k++)
            {
                var one = slot.PointAtLength(3.0 * k);
                if (!Near(by[k].Point, one.Point, 1e-12) || by[k].Segment != one.Segment) return Fail($"profile divide by length: sample {k} is not the point at {3 * k}");
            }
            if (Dist(by[^1].Point, by[0].Point) <= 0.1) return Fail("profile divide by length: the last sample repeats the start");
            var neg = Refused(() => slot.PointAtLength(-1));
            if (!neg.StartsWith("profile_point_at_length: ")) return Fail($"profile point at length: -1 gave '{neg}'");
            var zero = Refused(() => slot.DivideByCount(0));
            if (!zero.StartsWith("profile_divide_by_count: ")) return Fail($"profile divide by count: 0 gave '{zero}'");
            var badStep = Refused(() => slot.DivideByLength(-1));
            if (!badStep.StartsWith("profile_divide_by_length: ")) return Fail($"profile divide by length: -1 gave '{badStep}'");
            var def = slot.PointAtLength(5);
            foreach (var acc in new[] { 0.0, -1.0 })
            {
                var other = slot.PointAtLength(5, acc);
                if (!Near(other.Point, def.Point, 0) || !Near(other.Tangent, def.Tangent, 0) || other.Parameter != def.Parameter
                    || other.Segment != def.Segment || other.Error != def.Error || other.FromPolyline != def.FromPolyline)
                    return Fail($"profile point at length: accuracy {acc} is not the default");
            }
        }
        Console.WriteLine("arc length: points, divides by count and length, refusals all read back");
    }
    // 4b2. NurbsCurve: Python's test_a_nurbs_curve_* .. test_a_curve_maps_by_its_control_points
    {
        const double Pi = Math.PI;
        double D3((double X, double Y, double Z) a, (double X, double Y, double Z) b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y) + (a.Z - b.Z) * (a.Z - b.Z));
        double Norm3((double X, double Y, double Z) a) => D3(a, (0, 0, 0));
        NurbsCurve Quarter(double r = 2.0) => new(new (double, double, double)[] { (r, 0, 0), (r, r, 0), (0, r, 0) }, 2, new[] { 1.0, Math.Sqrt(0.5), 1.0 });
        NurbsCurve Ring(double r, double z = 0.0)
        {
            var h = Math.Sqrt(0.5);
            return new NurbsCurve(
                new (double, double, double)[] { (r, 0, z), (r, r, z), (0, r, z), (-r, r, z), (-r, 0, z), (-r, -r, z), (0, -r, z), (r, -r, z), (r, 0, z) }, 2,
                new[] { 1, h, 1, h, 1, h, 1, h, 1 },
                new[] { 0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1 });
        }
        bool EndsBlended(NurbsCurve a, NurbsCurve b, List<NurbsCurve> tweens, double tol)
        {
            ((double X, double Y, double Z) Lo, (double X, double Y, double Z) Hi) Ends(NurbsCurve c) => (c.Point(c.Domain.Lo), c.Point(c.Domain.Hi));
            (double X, double Y, double Z) Mix((double X, double Y, double Z) p, (double X, double Y, double Z) q, double f) =>
                (p.X + f * (q.X - p.X), p.Y + f * (q.Y - p.Y), p.Z + f * (q.Z - p.Z));
            var (a0, a1) = Ends(a);
            var (b0, b1) = Ends(b);
            for (var i = 0; i < tweens.Count; i++)
            {
                var f = (i + 1.0) / (tweens.Count + 1);
                var (t0, t1) = Ends(tweens[i]);
                if (D3(t0, Mix(a0, b0, f)) >= tol || D3(t1, Mix(a1, b1, f)) >= tol) return false;
            }
            return true;
        }
        var cubicA = new (double, double, double)[] { (0, 0, 0), (3, 2, 0), (6, -1, 0), (10, 0, 0) };
        var cubicB = new (double, double, double)[] { (0, 1, 5), (4, 4, 5), (7, -3, 6), (10, 1, 5) };

        // 1. reads back what it was built from
        using (var q = Quarter())
        {
            if (q.Degree != 2 || !q.IsRational || q.IsClosed || q.FitError is not null) return Fail($"nurbs curve: the quarter circle reads {q}");
            if (!q.ControlPoints.SequenceEqual(new (double, double, double)[] { (2, 0, 0), (2, 2, 0), (0, 2, 0) })) return Fail("nurbs curve: control points differ from the given ones");
            if (!q.Weights.SequenceEqual(new[] { 1.0, Math.Sqrt(0.5), 1.0 })) return Fail("nurbs curve: weights differ from the given ones");
            if (!q.Knots.SequenceEqual(new[] { 0.0, 0, 0, 1, 1, 1 }) || q.Domain != (0.0, 1.0)) return Fail($"nurbs curve: knots {string.Join(",", q.Knots)} domain {q.Domain}");
            if (Math.Abs(Norm3(q.Point(0.37)) - 2) >= 1e-12) return Fail("nurbs curve: a point is off the circle");
            var k = q.Curvature(0.5);
            if (Math.Abs(k.Kappa - 0.5) >= 1e-12 || k.Centre is not { } centre || Norm3(centre) >= 1e-12) return Fail($"nurbs curve: curvature reads {k}");
            if (Math.Abs(q.Length().Value - Pi) >= 1e-9) return Fail($"nurbs curve: length reads {q.Length()}");
            var at = q.PointAtLength(Pi / 2);
            if (D3((at.Point[0], at.Point[1], at.Point[2]), (Math.Sqrt(2), Math.Sqrt(2), 0)) >= 1e-9 || at.Segment is not null) return Fail($"nurbs curve: point at length reads {at}");
            if (q.DivideByCount(4).Count != 5 || q.DivideByLength(1.0).Count != 4) return Fail("nurbs curve: divide counts");
            var d = q.Derivatives(0.0, 2);
            if (d.Length != 3 || d[0] != (2, 0, 0) || Math.Abs(d[1].X) >= 1e-12 || !(d[1].Y > 0)) return Fail($"nurbs curve: derivatives read {string.Join(" ", d)}");
            if (!q.ToString().StartsWith("NurbsCurve(degree=2")) return Fail($"nurbs curve: ToString reads {q}");
            using var copy = q.Clone();
            if (!copy.ControlPoints.SequenceEqual(q.ControlPoints)) return Fail("nurbs curve: a clone differs");
        }
        using (var straight = new NurbsCurve(new (double, double, double)[] { (0, 0, 0), (1, 0, 0) }, 1))
        {
            var k = straight.Curvature(0.5);
            if (k.Centre is not null || k.Kappa != 0) return Fail($"nurbs curve: a straight curve's curvature reads {k}");
        }

        // 2. through, fit and the edits
        {
            var ringPts = Enumerable.Range(0, 10).Select(i => 2 * Pi * i / 10).Select(a => (Math.Cos(a), Math.Sin(a), 0.2 * Math.Sin(3 * a))).ToArray();
            using var closed = NurbsCurve.Through(ringPts, closed: true);
            if (!closed.IsClosed || closed.DivideByCount(6).Count != 6) return Fail("nurbs curve: a closed ring through points");
            using var c = NurbsCurve.Through(new (double, double, double)[] { (0, 0, 0), (1, 2, 0.5), (3, 1, -0.5), (4, 3, 1), (6, 2, 0) }, startTangent: (0, 0, 5));
            var (lo, hi) = c.Domain;
            var dd = c.Derivatives(lo, 1)[1];
            if (Math.Abs(dd.X) >= 1e-9 || Math.Abs(dd.Y) >= 1e-9 || !(dd.Z > 0)) return Fail($"nurbs curve: the start tangent reads {dd}");
            using var fitted = NurbsCurve.Fit(Enumerable.Range(0, 200).Select(t => (t / 50.0, Math.Sin(t / 50.0), 0.0)).ToArray(), tolerance: 1e-4);
            if (fitted.FitError is not { } fe || fe < 0 || fe > 1e-4) return Fail($"nurbs curve: fit error {fitted.FitError}");
            if (c.FitError is not null || closed.FitError is not null) return Fail("nurbs curve: a plain curve has a fit error");
            using var rev = c.Reversed();
            if (D3(rev.Point(lo), c.Point(hi)) >= 1e-12) return Fail("nurbs curve: reversed does not start at the end");
            var mid = 0.5 * (lo + hi);
            using var cut = c.Trimmed(lo, mid);
            if (cut.Domain != (lo, mid)) return Fail($"nurbs curve: trimmed domain {cut.Domain}");
            using var longer = c.Extended(0.5);
            if (!(longer.Domain.Hi > hi) || D3(longer.Point(hi), c.Point(hi)) >= 1e-9) return Fail("nurbs curve: extended at the end");
            using var before = c.Extended(0.5, atStart: true);
            if (!(before.Domain.Lo < lo)) return Fail("nurbs curve: extended at the start");
            using var up = c.Elevated(2);
            if (up.Degree != 5) return Fail($"nurbs curve: elevated by 2 reads degree {up.Degree}");
        }

        // 3. joined
        {
            using var lead = new NurbsCurve(new (double, double, double)[] { (2, -3, 0), (2, 0, 0) }, 1);
            using var arc = Quarter();
            using var tail = new NurbsCurve(new (double, double, double)[] { (0, 2, 0), (-1, 2.5, 0), (-2, 2, 1), (-3, 3, 0), (-4, 2, 0), (-5, 2, 2) }, 5);
            using var back = arc.Reversed();
            using var j = NurbsCurve.Joined(new[] { lead, back, tail });
            if (j.Degree != 5 || j.Domain != (0.0, 3.0)) return Fail($"nurbs curve: joined reads {j}");
            foreach (var (t, want) in new[] { (0.0, (2.0, -3.0, 0.0)), (1.0, (2.0, 0.0, 0.0)), (2.0, (0.0, 2.0, 0.0)), (3.0, (-5.0, 2.0, 2.0)) })
                if (D3(j.Point(t), want) >= 1e-12) return Fail($"nurbs curve: joined at {t} reads {j.Point(t)}");
            for (var i = 0; i <= 20; i++)
            {
                if (Math.Abs(Norm3(j.Point(1 + i / 20.0)) - 2) >= 1e-12) return Fail("nurbs curve: the joined arc leaves the circle");
                if (D3(j.Point(2 + i / 20.0), tail.Point(i / 20.0)) >= 1e-12) return Fail("nurbs curve: the joined tail differs");
            }
            using var one = NurbsCurve.Joined(new[] { arc });
            if (!one.ControlPoints.SequenceEqual(arc.ControlPoints)) return Fail("nurbs curve: joining one curve changed it");
            var gap = Refused(() => NurbsCurve.Joined(new[] { lead, tail }));
            if (!System.Text.RegularExpressions.Regex.IsMatch(gap, "^nurbs_curve_joined: curve 1 .* curve 0")) return Fail($"nurbs curve: a gap gave '{gap}'");
            var none = Refused(() => NurbsCurve.Joined(Array.Empty<NurbsCurve>()));
            if (!none.StartsWith("nurbs_curve_joined: ")) return Fail($"nurbs curve: joining none gave '{none}'");
        }

        // 4. tween
        {
            using var a = new NurbsCurve(cubicA, 3);
            using var b = new NurbsCurve(cubicB, 3);
            var plain = a.Tween(b, 3, "plain");
            if (plain.Count != 3 || !EndsBlended(a, b, plain, 1e-12)) return Fail("nurbs curve: plain tweens");
            if (D3(plain[1].ControlPoints[1], (3.5, 3, 2.5)) >= 1e-12) return Fail($"nurbs curve: the plain middle tween's control point reads {plain[1].ControlPoints[1]}");
            var matching = a.Tween(b, 2);
            if (matching.Count != 2 || !EndsBlended(a, b, matching, 1e-12)) return Fail("nurbs curve: matching tweens");
            var sampled = a.Tween(b, 4, "sampling", 20);
            if (sampled.Count != 4 || sampled.Any(t => t.Degree != 3) || !EndsBlended(a, b, sampled, 1e-9)) return Fail("nurbs curve: sampling tweens");
            if (a.Tween(b, 1, tolerance: 0.0).Count != 1) return Fail("nurbs curve: tolerance 0 tween");
            using var quad = new NurbsCurve(new (double, double, double)[] { (0, 1, 5), (5, 4, 5), (10, 1, 5) }, 2);
            var notCompatible = Refused(() => a.Tween(quad, 2, "plain"));
            if (!System.Text.RegularExpressions.Regex.IsMatch(notCompatible, "^nurbs_curve_tween: .*compatible")) return Fail($"nurbs curve: plain on a quadratic gave '{notCompatible}'");
            var mixed = a.Tween(quad, 2);
            if (mixed[0].Degree != 3 || !EndsBlended(a, quad, mixed, 1e-12)) return Fail("nurbs curve: matching a quadratic");
            if (!Refused(() => a.Tween(b, 0)).StartsWith("nurbs_curve_tween: ")) return Fail("nurbs curve: a count of 0 was not refused");
            var needs = Refused(() => a.Tween(b, 2, "sampling"));
            if (!needs.Contains("sampling needs samples")) return Fail($"nurbs curve: sampling without samples gave '{needs}'");
            var only = Refused(() => a.Tween(b, 2, "matching", 10));
            if (!only.Contains("samples is read only by sampling")) return Fail($"nurbs curve: matching with samples gave '{only}'");
            var loft = Refused(() => a.Tween(b, 2, "loft"));
            if (!loft.Contains("method must be one of plain, matching, sampling, not 'loft'")) return Fail($"nurbs curve: method loft gave '{loft}'");
            var few = Refused(() => a.Tween(b, 2, "sampling", 1));
            if (!few.StartsWith("nurbs_curve_tween: sampling needs at least")) return Fail($"nurbs curve: one sample gave '{few}'");
            // two circles
            using var small = Ring(2);
            using var big = Ring(4, 6);
            foreach (var (method, samples, tol) in new (string, uint?, double)[] { ("plain", null, 1e-12), ("matching", null, 1e-12), ("sampling", 40, 1e-4) })
            {
                var tw = small.Tween(big, 3, method, samples);
                if (tw.Count != 3) return Fail($"nurbs curve: {method} gave {tw.Count} circles");
                for (var i = 0; i < 3; i++)
                {
                    var f = (i + 1) / 4.0;
                    if (!tw[i].IsClosed) return Fail($"nurbs curve: {method} tween {i} is not closed");
                    var (lo, hi) = tw[i].Domain;
                    for (var k = 0; k < 24; k++)
                    {
                        var (x, y, z) = tw[i].Point(lo + (hi - lo) * k / 24);
                        if (Math.Abs(Math.Sqrt(x * x + y * y) - (2 + 2 * f)) >= tol || Math.Abs(z - 6 * f) >= tol) return Fail($"nurbs curve: {method} tween {i} point {k} is off its circle");
                    }
                }
            }
        }

        // 5. an edge, faces, a plane, a blend and the comb
        {
            using var cyl = Solid.Cylinder(2.5, 4);
            var rims = 0;
            foreach (var edge in cyl.Edges.Where(e => e.Kind == "circle"))
            {
                rims++;
                using var rim = NurbsCurve.FromEdge(cyl, edge);
                using var byIndex = NurbsCurve.FromEdge(cyl, edge.Index);
                var (lo, hi) = rim.Domain;
                foreach (var t in new[] { lo, 0.5 * (lo + hi), hi })
                {
                    var (x, y, _) = rim.Point(t);
                    if (Math.Abs(Math.Sqrt(x * x + y * y) - 2.5) >= 1e-12) return Fail("nurbs curve: a rim leaves its circle");
                }
                if (byIndex.Domain != rim.Domain) return Fail("nurbs curve: from_edge by index differs");
            }
            if (rims < 2) return Fail("nurbs curve: the cylinder has fewer than two circle edges");
            using var sphere = Solid.Sphere(3);
            using var line = new NurbsCurve(new (double, double, double)[] { (-2, 0.5, 10), (2, -0.5, 10) }, 1);
            using var on = line.ProjectedToFace(sphere, 0, (0, 0, -1), 1e-4);
            if (on.FitError is not { } oe || oe > 1e-4) return Fail($"nurbs curve: projected fit error {on.FitError}");
            var (olo, ohi) = on.Domain;
            if (Math.Abs(Norm3(on.Point(0.5 * (olo + ohi))) - 3) >= 1e-4) return Fail("nurbs curve: the projection is off the sphere");
            using var pulled = line.PulledToFace(sphere, 0, 1e-4);
            if (Math.Abs(Norm3(pulled.Point(pulled.Domain.Lo)) - 3) >= 1e-4 || pulled.FitError is null) return Fail("nurbs curve: the pulled curve is off the sphere");
            using var through = new NurbsCurve(new (double, double, double)[] { (-5, 1, 1), (5, 1, 1) }, 1);
            var hits = through.FaceHits(sphere, 0, 1e-6);
            if (hits.Count != 2 || Math.Abs(hits[0].Point[0] + Math.Sqrt(7)) >= 1e-6) return Fail($"nurbs curve: face hits {hits.Count}");
            var crossing = through.PlaneHits((0, 0, 0), (1, 0, 0));
            if (crossing.Count != 1 || D3((crossing[0].Point[0], crossing[0].Point[1], crossing[0].Point[2]), (0, 1, 1)) >= 1e-12) return Fail("nurbs curve: plane hits");
            using var flat = line.ProjectedToPlane((0, 0, 1), (0, 0, 1));
            if (flat.Point(0) != (-2, 0.5, 1)) return Fail($"nurbs curve: projected to a plane reads {flat.Point(0)}");
            using var qc = Quarter();
            using var blend = NurbsCurve.Blend(qc, true, through, false, 2);
            if (blend.Degree != 5 || Math.Abs(blend.Curvature(0).Kappa - 0.5) >= 1e-9) return Fail("nurbs curve: the blend");
            var teeth = qc.Comb(8);
            if (teeth.Count != 9 || teeth.Any(p => Math.Abs(D3(p.From, p.To) - 0.5) >= 1e-9)) return Fail("nurbs curve: the comb");
            if (qc.Comb(0).Count != 2) return Fail("nurbs curve: a comb of 0 steps is not 1 step");
        }

        // 6. refusals name the call
        {
            using var q = Quarter();
            using var cube = Solid.Cuboid(1, 1, 1);
            var pair = new (double, double, double)[] { (0, 0, 0), (1, 0, 0) };
            foreach (var (call, name) in new (Action, string)[]
            {
                (() => new NurbsCurve(pair, 9), "nurbs_curve_new"),
                (() => new NurbsCurve(pair, 1, new[] { 1.0, -1.0 }), "nurbs_curve_new"),
                (() => NurbsCurve.Through(pair, 3), "nurbs_curve_through"),
                (() => NurbsCurve.Fit(pair, 1, -1), "nurbs_curve_fit"),
                (() => NurbsCurve.FromEdge(cube, 999), "nurbs_curve_from_edge"),
                (() => NurbsCurve.Isocurve(cube, 0, true, 0.5), "nurbs_curve_from_face_isocurve"),
                (() => NurbsCurve.Blend(q, true, q, true, 3), "nurbs_curve_blend"),
                (() => q.ProjectedToPlane((0, 0, 0), (0, 0, 1), (1, 0, 0)), "nurbs_curve_projected_to_plane"),
                (() => q.Trimmed(0.5, 0.2), "nurbs_curve_trimmed"),
                (() => q.Extended(0), "nurbs_curve_extended"),
                (() => q.Point(2), "nurbs_curve_point"),
                (() => q.Derivatives(0.5, 9), "nurbs_curve_derivatives"),
                (() => q.DivideByCount(0), "nurbs_curve_divide_by_count"),
                (() => q.PlaneHits((0, 0, 0), (0, 0, 1)), "nurbs_curve_plane_hits"),
            })
            {
                var said = Refused(call);
                if (!said.StartsWith(name + ": ")) return Fail($"nurbs curve: {name} refused as '{said}'");
            }
            var weights = Refused(() => new NurbsCurve(pair, 1, new[] { 1.0, 1.0, 1.0 }));
            if (weights != "nurbs_curve_new: 3 weights for 2 points; give one per point") return Fail($"nurbs curve: three weights for two points gave '{weights}'");
        }

        // 7. maps and values
        {
            using var c = new NurbsCurve(new (double, double, double)[] { (0, 0, 0), (1, 1, 1), (2, 0, 0) }, 2, new[] { 1.0, 0.5, 1.0 });
            using var moved = c.Transformed(Transform.Translation((1, 2, 3)));
            var mp = moved.Point(0.5);
            var w = c.Point(0.5);
            if (D3(mp, (w.X + 1, w.Y + 2, w.Z + 3)) >= 1e-12 || !moved.Weights.SequenceEqual(c.Weights)) return Fail("nurbs curve: a translated curve");
            using var viaRows = c.Transformed(Transform.Translation((1, 2, 3)).Rows);
            if (D3(viaRows.Point(0.5), mp) >= 1e-12) return Fail("nurbs curve: transformed by 16 numbers differs");
            using var seg = new Line((0, 0, 0), (2, 0, 0)).ToNurbs();
            if (seg.Degree != 1 || D3(seg.Point(0.5 * (seg.Domain.Lo + seg.Domain.Hi)), (1, 0, 0)) >= 1e-12) return Fail("nurbs curve: a line value's NURBS");
            using var ring = new Circle(new double[] { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 3).ToNurbs();
            if (!ring.IsRational || !ring.IsClosed) return Fail("nurbs curve: a circle value's NURBS is not a rational closed curve");
            var (rlo, rhi) = ring.Domain;
            for (var k = 0; k < 16; k++)
                if (Math.Abs(Norm3(ring.Point(rlo + (rhi - rlo) * k / 16)) - 3) >= 1e-12) return Fail($"nurbs curve: the circle value's NURBS leaves its circle at {k}");
        }

        // 8. lifetime: what a curve came from may go first
        {
            List<NurbsCurve> tweens;
            using (var a = new NurbsCurve(cubicA, 3))
            using (var b = new NurbsCurve(cubicB, 3))
                tweens = a.Tween(b, 3);
            GC.Collect();
            GC.WaitForPendingFinalizers();
            if (tweens.Any(t => t.Degree != 3 || D3(t.Point(t.Domain.Lo), (0, 0, 0)) > 10)) return Fail("nurbs curve: a tween list after its parents went");
            NurbsCurve rim;
            using (var cyl = Solid.Cylinder(2.5, 4))
                rim = NurbsCurve.FromEdge(cyl, cyl.Edges.First(e => e.Kind == "circle"));
            GC.Collect();
            GC.WaitForPendingFinalizers();
            if (Math.Abs(Norm3((rim.Point(rim.Domain.Lo).X, rim.Point(rim.Domain.Lo).Y, 0)) - 2.5) >= 1e-12) return Fail("nurbs curve: a rim after its solid went");
            foreach (var t in tweens) t.Dispose();
            rim.Dispose();
            rim.Dispose();
            var gone = "(no exception)";
            try { _ = rim.Degree; } catch (ObjectDisposedException e) { gone = e.Message; }
            if (gone != "nurbs_curve: closed (Parameter 'NurbsCurve')" && !gone.StartsWith("nurbs_curve: closed")) return Fail($"nurbs curve: a disposed curve read gave '{gone}'");
        }
        Console.WriteLine("nurbs curve: reads, edits, joins, tweens, faces, refusals, maps, values and lifetimes all read back");
    }
    // 4b3. sheets from curves: Python's test_surfaces_from_curves_are_sheets .. test_fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius
    {
        NurbsCurve CsLine((double, double, double) a, (double, double, double) b) => new(new[] { a, b }, 1);
        (string Type, string Message) CsThrown(Action act)
        {
            try { act(); return ("", "(no exception)"); }
            catch (Exception e) { return (e.GetType().Name, e.Message); }
        }
        double CsDist((double X, double Y, double Z) a, (double X, double Y, double Z) b) =>
            Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y) + (a.Z - b.Z) * (a.Z - b.Z));
        Solid CsRectSheet((double X, double Y, double Z) origin, (double X, double Y, double Z) x, (double X, double Y, double Z) y, double w, double h)
        {
            var z = (x.Y * y.Z - x.Z * y.Y, x.Z * y.X - x.X * y.Z, x.X * y.Y - x.Y * y.X);
            return Solid.Face(Profile.Rect(w, h), new[] { origin.X, origin.Y, origin.Z, x.X, x.Y, x.Z, y.X, y.Y, y.Z, z.Item1, z.Item2, z.Item3 });
        }
        NurbsCurve CsExactCircle((double X, double Y, double Z) c, double r)
        {
            var s = Math.Sqrt(0.5);
            var pts = new (double, double)[] { (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0) }
                .Select(p => (c.X + r * p.Item1, c.Y + r * p.Item2, c.Z)).ToArray();
            return new NurbsCurve(pts, 2, new[] { 1, s, 1, s, 1, s, 1, s, 1 }, new[] { 0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1 });
        }

        // 1. test_surfaces_from_curves_are_sheets
        var csc = new (double X, double Y, double Z)[] { (-1, -1, 1), (1, -1, -1), (1, 1, 1), (-1, 1, -1) };
        using var csRing = NurbsCurve.Through(Enumerable.Range(0, 8).Select(i => (Math.Cos(2 * Math.PI * i / 8), Math.Sin(2 * Math.PI * i / 8), 0.0)).ToArray(), closed: true);
        using var csRail = CsLine((0, 0, 0), (0, 0, 4));
        {
            var edges = new[] { CsLine(csc[0], csc[1]), CsLine(csc[1], csc[2]), CsLine(csc[2], csc[3]), CsLine(csc[3], csc[0]) };
            using var coons = Solid.EdgeSurface(edges, 1e-9);
            if (coons.Faces != 1 || coons.SheetError != 0.0) return Fail($"sheets: edge_surface faces {coons.Faces}, sheet_error {coons.SheetError}");
            foreach (var e in edges) e.Dispose();
            using var l0 = CsLine((0, 0, 0), (2, 0, 0));
            using var l1 = CsLine((0, 1, 1), (2, 1, -1));
            using var loft = Solid.LoftCurves(new[] { l0, l1 });
            if (loft.Faces != 1 || loft.SheetError is not null || loft.PatchReport is not null) return Fail("sheets: loft_curves is not one face with no sheet_error");
            using var tube = Solid.SweepRail(csRail, new[] { csRing }, tolerance: 1e-5);
            if (tube.Faces != 1 || tube.SheetError is not { } te || te < 0 || te > 1e-5) return Fail($"sheets: sweep_rail faces {tube.Faces}, sheet_error {tube.SheetError}");
            using var upright = Solid.SweepRail(csRail, new[] { csRing }, "fixed", (0, 1, 0), 1e-5);
            if (upright.Faces != 1 || upright.SheetError is null) return Fail("sheets: sweep_rail fixed");
            // rmf and fixed carry a section differently along a rail that turns
            using var bend = NurbsCurve.Through(new (double, double, double)[] { (0, 0, 0), (2, 0, 2), (2, 3, 4), (0, 3, 6), (0, 0, 8) }, 3);
            using var rmfSheet = Solid.SweepRail(bend, new[] { csRing }, "rmf", null, 1e-4);
            using var fixedSheet = Solid.SweepRail(bend, new[] { csRing }, "fixed", (0, 0, 1), 1e-4);
            var (ra, rb) = (rmfSheet.Mass().Area, fixedSheet.Mass().Area);
            var rmfLo = rmfSheet.BoundsAt(1e-3);
            var fixLo = fixedSheet.BoundsAt(1e-3);
            if (Near(rmfLo.Min, fixLo.Min, 1e-6) && Near(rmfLo.Max, fixLo.Max, 1e-6) && Math.Abs(ra - rb) < 1e-6)
                return Fail("sheets: sweep_rail rmf and fixed made the same sheet along a turning rail");
            using var ba = CsLine((-1, 0, 0), (-1, 5, 0));
            using var bb = CsLine((1, 0, 0), (1, 5, 0));
            using var bs0 = CsLine((-1, 0, 0), (1, 0, 0));
            using var band = Solid.SweepTwoRails(ba, bb, new[] { bs0 }, 1e-6);
            if (band.Faces != 1 || band.SheetError is null) return Fail("sheets: sweep_two_rails");
            var us = new[] { -1.0, 0.2, 1.0 }.Select(y => CsLine((-1, y, -y), (1, y, y))).ToArray();
            var vs = new[] { -1.0, 0.3, 1.0 }.Select(x => CsLine((x, -1, -x), (x, 1, x))).ToArray();
            using var net = Solid.NetworkSurface(us, vs, 1e-9);
            if (net.Faces != 1 || net.SheetError is not { } ne || ne > 1e-9) return Fail($"sheets: network_surface faces {net.Faces}, sheet_error {net.SheetError}");
            foreach (var c in us.Concat(vs)) c.Dispose();
            using var lone = CsLine((0, 0, 0), (1, 0, 0));
            using var lonev = CsLine((0, 0, 0), (0, 1, 0));
            foreach (var (call, name) in new (Action, string)[]
            {
                (() => Solid.LoftCurves(new[] { csRing }), "loft_curves"),
                (() => Solid.EdgeSurface(new[] { lone }), "edge_surface"),
                (() => Solid.NetworkSurface(new[] { lone }, new[] { lonev }), "network_surface"),
            })
            {
                var (type, msg) = CsThrown(call);
                if (type != nameof(BuildException) || !msg.StartsWith(name + ": ")) return Fail($"sheets: {name} refusal was {type}: {msg}");
            }
            // the three wrapper-side refusals
            var (t1, m1) = CsThrown(() => Solid.SweepRail(csRail, new[] { csRing }, "twisty"));
            if (t1 != nameof(ArgumentException) || m1 != "sweep_rail: frame is 'rmf' or 'fixed', not 'twisty'") return Fail($"sheets: a bad frame gave {t1}: {m1}");
            var (t2, m2) = CsThrown(() => loft.Continuity("w2", loft, "u0"));
            if (t2 != nameof(ArgumentException) || m2 != "a side is 'u0', 'u1', 'v0' or 'v1', not 'w2'") return Fail($"sheets: a bad side gave {t2}: {m2}");
            using var csSheet = CsRectSheet((0, 0, 0), (1, 0, 0), (0, 1, 0), 20, 20);
            using var csCircle = CsExactCircle((0, 0, 0), 5);
            var (t3, m3) = CsThrown(() => csSheet.TrimByCurve(csCircle, "middle"));
            if (t3 != nameof(BuildException) || m3 != "trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not 'middle'") return Fail($"sheets: a bad keep gave {t3}: {m3}");
            // sheet_error is none on a plain solid, patch_report none everywhere but the patch
            using var plain = Solid.Cuboid(1, 1, 1);
            if (plain.SheetError is not null || plain.PatchReport is not null) return Fail("sheets: a plain solid has a sheet_error or a patch_report");
            if (coons.PatchReport is not null || tube.PatchReport is not null || band.PatchReport is not null || net.PatchReport is not null) return Fail("sheets: a fitted sheet has a patch_report");
        }

        // 2. test_a_curve_trims_a_hole_and_an_island_and_they_join_back
        {
            using var csh = CsRectSheet((0, 0, 0), (1, 0, 0), (0, 1, 0), 20, 20);
            using var ring = CsExactCircle((1, -2, 0), 5);
            using var holed = csh.TrimByCurve(ring, "outside", (0, 0, -1), 0.01);
            using var island = csh.TrimByCurve(ring, "inside", null, 0.01);
            if (Math.Abs(island.Mass().Area - 25 * Math.PI) >= 1e-6) return Fail($"trim_by_curve: the island's area is {island.Mass().Area}");
            if (Math.Abs(holed.Mass().Area - (400 - 25 * Math.PI)) >= 1e-6) return Fail($"trim_by_curve: the holed sheet's area is {holed.Mass().Area}");
            using var split = csh.SplitByCurve(ring, null, 0.01);
            if (split.Faces != 2) return Fail($"split_by_curve: {split.Faces} faces, not 2");
            var (back, report) = Solid.JoinSheets(new[] { holed, island });
            using var _b = back;
            if (report.Sewn < 1 || report.NakedAfter != report.NakedBefore - 2 * report.Sewn || report.Closed || back.Faces != 2) return Fail($"join_sheets: {report}");
            if (!report.ToString().Contains("Sewn = ")) return Fail($"join_sheets: the report prints as {report}");
        }

        // 3. test_an_open_curve_keeps_its_left_or_right
        {
            using var csh = CsRectSheet((0, 0, 0), (1, 0, 0), (0, 1, 0), 20, 20);
            using var line = NurbsCurve.Through(new (double, double, double)[] { (-5, 1, 0), (5, 1, 0) }, 1);
            using var left = csh.TrimByCurve(line, "left", (0, 0, 1), 0.01);
            using var right = csh.TrimByCurve(line, "right", (0, 0, 1), 0.01);
            using var inside = csh.TrimByCurve(line, "inside", (0, 0, -1), 0.01);
            if (Math.Abs(left.Mass().Area - 180) >= 1e-9 || Math.Abs(right.Mass().Area - 220) >= 1e-9) return Fail($"trim_by_curve: left {left.Mass().Area}, right {right.Mass().Area}");
            if (Math.Abs(inside.Mass().Area - 220) >= 1e-9) return Fail($"trim_by_curve: inside from below {inside.Mass().Area}");
        }

        // 4. test_six_sheets_join_into_a_box_the_kernel_measures_cuts_and_writes
        {
            (double, double, double) x = (1, 0, 0), y = (0, 1, 0), z = (0, 0, 1);
            var faces = new[]
            {
                CsRectSheet((5, 10, 0), x, y, 10, 20), CsRectSheet((5, 10, 30), x, y, 10, 20),
                CsRectSheet((0, 10, 15), y, z, 20, 30), CsRectSheet((10, 10, 15), y, z, 20, 30),
                CsRectSheet((5, 0, 15), z, x, 30, 10), CsRectSheet((5, 20, 15), x, z, 10, 30),
            };
            var (box, report) = Solid.JoinSheets(faces);
            using var _b = box;
            if ((report.Sewn, report.NakedBefore, report.NakedAfter, report.Turned, report.Closed) != (12, 24, 0, 4, true)) return Fail($"join_sheets: the box joined as {report}");
            var csm = box.Mass();
            if (!csm.Closed || Math.Abs(csm.Volume - 6000) >= 1e-6) return Fail($"join_sheets: the box measures {csm}");
            using var drill0 = Solid.Cylinder(2, 50);
            using var drill = drill0.Translate(5, 10, -10);
            using var bored = box.Cut(drill, 0.01);
            if (Math.Abs(bored.Mass().Volume - (6000 - Math.PI * 4 * 30)) >= 0.05) return Fail($"join_sheets: the bored box has volume {bored.Mass().Volume}");
            if (!box.StepText().Contains("CLOSED_SHELL")) return Fail("join_sheets: the box's STEP has no CLOSED_SHELL");
            using var moved = faces[3].Translate(0, 0, 1e-3);
            var (j0, apart) = Solid.JoinSheets(new[] { faces[1], moved });
            var (j1, loose) = Solid.JoinSheets(new[] { faces[1], moved }, 2e-3);
            j0.Dispose();
            j1.Dispose();
            if (apart.Sewn != 0 || loose.Sewn != 1 || Math.Abs(loose.WorstGap - 1e-3) >= 1e-9) return Fail($"join_sheets: a thousandth apart sewed {apart.Sewn} / {loose.Sewn} gap {loose.WorstGap}");
            foreach (var f in faces) f.Dispose();
        }

        // 5. test_join_sheets_sews_a_t_junction
        {
            Solid Rect(double x0, double y0, double x1, double y1)
            {
                var c = new (double, double, double)[] { (x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0) };
                var sides = Enumerable.Range(0, 4).Select(i => CsLine(c[i], c[(i + 1) % 4])).ToArray();
                try { return Solid.EdgeSurface(sides); }
                finally { foreach (var s in sides) s.Dispose(); }
            }
            using var big = Rect(0, 0, 2, 1);
            using var a = Rect(0, 1, 1, 2);
            using var b = Rect(1, 1, 2, 2);
            var (e0, exact) = Solid.JoinSheets(new[] { big, a, b });
            e0.Dispose();
            if (exact.Sewn != 1) return Fail($"join_sheets: a T-junction at the default tolerance sewed {exact.Sewn}");
            var (shell, report) = Solid.JoinSheets(new[] { big, a, b }, 1e-3);
            using var _s = shell;
            if ((report.Sewn, report.NakedBefore, report.NakedAfter, report.Closed) != (3, 13, 7, false) || shell.Faces != 3) return Fail($"join_sheets: the T-junction joined as {report}, {shell.Faces} faces");
        }

        // 6. test_trim_by_curve_and_join_refuse_by_name
        {
            using var csh = CsRectSheet((0, 0, 0), (1, 0, 0), (0, 1, 0), 20, 20);
            using var ring = CsExactCircle((0, 0, 0), 5);
            using var far = CsExactCircle((100, 0, 0), 5);
            var (t0, m0) = CsThrown(() => csh.TrimByCurve(ring, "middle"));
            if (t0 != nameof(BuildException) || !m0.StartsWith("trim_by_curve: keep must be")) return Fail($"trim_by_curve: a bad keep gave {m0}");
            var (t1, m1) = CsThrown(() => csh.TrimByCurve(far, "inside"));
            if (t1 != nameof(BuildException) || !m1.StartsWith("trim_by_curve: ") || !m1.Contains("nothing of the sheet lies inside")) return Fail($"trim_by_curve: an empty island gave {m1}");
            var (t2, m2) = CsThrown(() => csh.SplitByCurve(ring, (0, 0, 0)));
            if (t2 != nameof(BuildException) || !m2.StartsWith("split_by_curve: ") || !m2.Contains("direction is zero")) return Fail($"split_by_curve: a zero direction gave {m2}");
            var (t3, m3) = CsThrown(() => Solid.JoinSheets(Array.Empty<Solid>()));
            if (t3 != nameof(BuildException) || !m3.StartsWith("join_sheets: no sheets")) return Fail($"join_sheets: no sheets gave {m3}");
            var (t4, m4) = CsThrown(() => Solid.JoinSheets(new[] { csh }, -1));
            if (t4 != nameof(BuildException) || !m4.StartsWith("join_sheets: ") || !m4.Contains("tolerance")) return Fail($"join_sheets: a negative tolerance gave {m4}");
        }

        // 6b. flange and extrude_to: the 20 x 20 square in z = 0 facing +z with a round hole of
        // radius 5 about (1, -2), and the hole's rim edges (Python's _holed_sheet)
        (Solid Holed, Edge[] Rim) CsHoledSheet()
        {
            using var sheet = CsRectSheet((0, 0, 0), (1, 0, 0), (0, 1, 0), 20, 20);
            using var circle = CsExactCircle((1, -2, 0), 5);
            var holed = sheet.TrimByCurve(circle, "outside", (0, 0, -1), 0.01);
            var rim = holed.Edges.Where(e => e.Faces.Length == 1 && e.Segments.All(s => Math.Abs(Math.Sqrt((s.A[0] - 1) * (s.A[0] - 1) + (s.A[1] + 2) * (s.A[1] + 2)) - 5) < 1e-6)).ToArray();
            return (holed, rim);
        }

        // 6c. test_a_flange_turns_a_hole_under_and_carries_it_inward
        {
            var (holed, rim) = CsHoledSheet();
            using var _h = holed;
            if (rim.Length == 0) return Fail("flange: the holed sheet has no rim edges");
            using var under = CsLine((0, 0, 0), (0, -3, 0));
            // turned under 3 along the face's normal (+z): the hole's own cylinder, 3 deep, below the sheet
            using var wall = holed.Flange(rim, under, 1e-3, join: false);
            if (wall.Faces != rim.Length || wall.SheetError is not { } we || we > 1e-3) return Fail($"flange: {wall.Faces} faces for {rim.Length} edges, sheet_error {wall.SheetError}");
            if (Math.Abs(wall.Mass().Area - 2 * Math.PI * 5 * 3) >= 0.05) return Fail($"flange: the wall's area is {wall.Mass().Area}");
            var (lo, hi) = wall.Bounds;
            if (Math.Abs(lo[2] + 3) >= 1e-3 || Math.Abs(hi[2]) >= 1e-3 || Math.Abs(lo[0] - (1 - 5)) >= 1e-2 || Math.Abs(hi[0] - (1 + 5)) >= 1e-2)
                return Fail($"flange: the wall's bounds are ({string.Join(", ", lo)}) .. ({string.Join(", ", hi)})");
            // carried on outward from the face 2: into the hole, an annulus from radius 5 in to 3
            using var on = CsLine((0, 0, 0), (2, 0, 0));
            using var ring = holed.Flange(rim.Select(e => e.Index), on, join: false);
            if (Math.Abs(ring.Mass().Area - Math.PI * (25 - 9)) >= 0.05) return Fail($"flange: the annulus' area is {ring.Mass().Area}");
            // joined, the sheet's faces come first and the flange is sewn on
            using var joined = holed.Flange(rim, under);
            if (joined.Faces != holed.Faces + rim.Length) return Fail($"flange: joined has {joined.Faces} faces, not {holed.Faces + rim.Length}");
            if (Math.Abs(joined.Mass().Area - (holed.Mass().Area + 2 * Math.PI * 5 * 3)) >= 0.05) return Fail($"flange: joined area {joined.Mass().Area}");
            // the rim is sewn all the way round: every edge on the hole's circle borders the sheet and the flange
            var onRim = joined.Edges.Where(e => e.Segments.All(s => Math.Abs(Math.Sqrt((s.A[0] - 1) * (s.A[0] - 1) + (s.A[1] + 2) * (s.A[1] + 2)) - 5) < 1e-3 && Math.Abs(s.A[2]) < 1e-6)).ToArray();
            if (onRim.Length == 0 || !onRim.All(e => e.Faces.OrderBy(f => f).SequenceEqual(new[] { 0, 1 }))) return Fail("flange: the rim is not sewn between the sheet and the flange");
        }

        // 6d. test_a_liner_runs_a_hole_down_to_a_tilted_floor
        {
            var (holed, rim) = CsHoledSheet();
            using var _h = holed;
            // the floor z = -7 + 0.1 x, wide enough to catch every point: the wall is 7 - 0.1 x deep,
            // 6.9 on average round a hole centred at x = 1
            var sides = new[] { CsLine((-20, -20, -9), (20, -20, -5)), CsLine((20, -20, -5), (20, 20, -5)), CsLine((20, 20, -5), (-20, 20, -9)), CsLine((-20, 20, -9), (-20, -20, -9)) };
            using var floor = Solid.EdgeSurface(sides);
            foreach (var s in sides) s.Dispose();
            using var wall = holed.ExtrudeTo(rim, (0, 0, -1), floor, 1e-3, join: false);
            if (wall.Faces != rim.Length || wall.SheetError is not { } we || we > 1e-3) return Fail($"extrude_to: {wall.Faces} faces for {rim.Length} edges, sheet_error {wall.SheetError}");
            if (Math.Abs(wall.Mass().Area - 2 * Math.PI * 5 * 6.9) >= 0.05) return Fail($"extrude_to: the wall's area is {wall.Mass().Area}");
            var (lo, hi) = wall.Bounds;
            if (Math.Abs(lo[2] - (-7 + 0.1 * (1 - 5))) >= 1e-2 || Math.Abs(hi[2]) >= 1e-6) return Fail($"extrude_to: the wall runs z {lo[2]} .. {hi[2]}");
            using var joined = holed.ExtrudeTo(rim, (0, 0, -1), floor);
            if (joined.Faces != holed.Faces + rim.Length) return Fail($"extrude_to: joined has {joined.Faces} faces, not {holed.Faces + rim.Length}");
            if (!joined.StepText().Contains("SURFACE_OF_LINEAR_EXTRUSION")) return Fail("extrude_to: the joined liner's STEP has no SURFACE_OF_LINEAR_EXTRUSION");
        }

        // 6e. test_flange_and_extrude_to_refuse_by_name
        {
            var (holed, rim) = CsHoledSheet();
            using var _h = holed;
            using var under = CsLine((0, 0, 0), (0, -3, 0));
            using var offOrigin = CsLine((1, 0, 0), (1, -3, 0));
            using var box = Solid.Cuboid(10, 10, 10);
            using var flat = CsRectSheet((0, 0, -7), (1, 0, 0), (0, 1, 0), 40, 40);
            foreach (var (call, prefix, needle) in new (Action, string, string)[]
            {
                (() => holed.Flange(rim, offOrigin), "flange: the section starts at", ""),
                (() => holed.Flange(Array.Empty<int>(), under), "flange: no edges given", ""),
                (() => holed.Flange(new[] { 999 }, under), "flange: no edge 999", ""),
                (() => box.Flange(new[] { 0 }, under), "flange: edge 0 borders 2 faces", ""),
                (() => holed.ExtrudeTo(rim, (0, 0, 1), flat), "extrude_to: edge ", "misses the target"),
                (() => holed.ExtrudeTo(rim, (0, 0, 0), flat), "extrude_to: the direction has no length", ""),
                (() => holed.ExtrudeTo(rim, null, flat), "extrude_to: null direction", ""),
            })
            {
                var (type, msg) = CsThrown(call);
                if (type != nameof(BuildException) || !msg.StartsWith(prefix) || !msg.Contains(needle)) return Fail($"flange/extrude_to: expected '{prefix}', got {type}: {msg}");
            }
        }

        // 6b. test_recess_sets_a_window_into_an_arched_sheet (a square window in a flat sheet)
        {
            using var csh = CsRectSheet((0, 0, 0), (1, 0, 0), (0, 1, 0), 20, 20);
            using var square = NurbsCurve.Through(new (double, double, double)[] { (-5, -5, 0), (5, -5, 0), (5, 5, 0), (-5, 5, 0), (-5, -5, 0) }, 1);
            var (window, faces) = csh.Recess(square, 3, 0, 0, true, 0.01);
            using var _w = window;
            if (faces != (1, 0, 4, 1) || window.Faces != 6) return Fail($"recess: the window has faces {faces}, {window.Faces} in all");
        }

        // 7. test_continuity_match_and_blend
        {
            using var a0 = CsLine((-1, 0, 0), (0, 0, 0));
            using var a1 = CsLine((-1, 1, 0), (0, 1, 0));
            using var b0 = CsLine((0, 0, 0), (0, 0, 1));
            using var b1 = CsLine((0, 1, 0), (0, 1, 1));
            using var a = Solid.LoftCurves(new[] { a0, a1 }, 1);
            using var b = Solid.LoftCurves(new[] { b0, b1 }, 1);
            var r = a.Continuity("u1", b, "u0", samples: 32);
            if (r.Gap > 1e-12 || Math.Abs(r.Angle - Math.PI / 2) > 1e-9 || r.Samples < 33) return Fail($"continuity: a right angle read {r}");
            // the figures sit on the shared edge x = 0, z = 0; the gap and the angle are separate fields
            if (Math.Abs(r.GapAt.X) > 1e-9 || Math.Abs(r.GapAt.Z) > 1e-9 || r.GapAt.Y < -1e-9 || r.GapAt.Y > 1 + 1e-9) return Fail($"continuity: gap_at {r.GapAt}");
            if (Math.Abs(r.AngleAt.X) > 1e-9 || Math.Abs(r.AngleAt.Z) > 1e-9 || r.AngleAt.Y < -1e-9 || r.AngleAt.Y > 1 + 1e-9) return Fail($"continuity: angle_at {r.AngleAt}");
            // a seam whose gap grows along it while the normals part most at its other end: the two places differ
            using var t0 = CsLine((0, 0, 0), (0, 0, 1));
            using var t1 = CsLine((0, 1, 0.2), (0.8, 1, 1.2));
            using var tilted = Solid.LoftCurves(new[] { t0, t1 }, 1);
            var rt = a.Continuity("u1", tilted, "u0", samples: 32);
            if (Math.Abs(rt.Gap - 0.19611613513818404) > 1e-6 || Math.Abs(rt.GapAt.Y - 1) > 1e-6 || Math.Abs(rt.AngleAt.Y) > 1e-6 || Math.Abs(rt.Angle - Math.PI / 2) > 1e-9)
                return Fail($"continuity: a seam that opens toward y = 1 read {rt}");
            using var csm = a.Matched("u1", b, "u0", 1);
            var rm = csm.Continuity("u1", b, "u0");
            if (rm.Gap > 1e-10 || rm.Angle > 1e-8) return Fail($"match_side: after matching {rm}");
            using var blend = Solid.BlendSides(a, "u0", b, "u1", 2);
            var rb = blend.Continuity("v0", a, "u0");
            if (rb.Gap > 1e-10 || rb.Angle > 1e-8 || rb.Curvature > 1e-6) return Fail($"blend_sides: {rb}");
            var (t, msg) = CsThrown(() => a.Continuity("w2", b, "u0"));
            if (t != nameof(ArgumentException)) return Fail($"continuity: a bad side gave {t}");
            (t, msg) = CsThrown(() => a.Matched("u1", b, "u0", 3));
            if (t != nameof(BuildException) || !msg.StartsWith("match_side: ")) return Fail($"match_side: level 3 gave {t}: {msg}");
        }

        // 8. test_n_sided_patch_fills_a_pentagon_of_strips
        {
            var cscorners = Enumerable.Range(0, 5)
                .Select(k => 2 * Math.PI * k / 5 + 0.1 * Math.Sin(3 * k))
                .Select(a => (Math.Cos(a), Math.Sin(a), 0.0)).ToArray();
            (double, double, double) Out((double X, double Y, double Z) p) => (1.6 * p.X, 1.6 * p.Y, 0.0);
            var curves = new List<NurbsCurve>();
            Solid Strip(int i)
            {
                var inner = CsLine(cscorners[i], cscorners[(i + 1) % 5]);
                var outer = CsLine(Out(cscorners[i]), Out(cscorners[(i + 1) % 5]));
                curves.Add(inner);
                curves.Add(outer);
                return Solid.LoftCurves(new[] { inner, outer }, 1);
            }
            var strips = Enumerable.Range(0, 5).Select(Strip).ToArray();
            using var edge = CsLine(cscorners[3], cscorners[4]);
            var boundaries = new PatchBoundary[]
            {
                PatchBoundary.OfSide(strips[0], "v0"), PatchBoundary.OfSide(strips[1], "v0", 1),
                PatchBoundary.OfSide(strips[2], "v0", from: 1.0, to: 0.0), edge, PatchBoundary.OfSide(strips[4], "v0", 2, 0),
            };
            using var fill = Solid.NSidedPatch(boundaries, tolerance: 1e-6);
            var r = fill.PatchReport;
            if (r is null || fill.Faces != 5 || r.Faces != 5) return Fail($"n_sided_patch: {fill.Faces} faces, report {r}");
            if (r.Boundary.Gap > 1e-9 || r.Boundary.Angle > 1e-6 || r.Internal.Angle > 1e-6 || r.CornerAngle > 1e-9) return Fail($"n_sided_patch: {r}");
            if (r.Boundary.Samples <= 0 || r.Internal.Samples <= 0) return Fail($"n_sided_patch: samples {r.Boundary.Samples} / {r.Internal.Samples}");
            foreach (var (face, side) in new[] { (0, "v0"), (4, "u1") })
            {
                var k = fill.Continuity(side, strips[0], "v0", face);
                if (k.Gap > 1e-9 || k.Angle > 1e-6) return Fail($"n_sided_patch: face {face} meets strip 0 at {k}");
            }
            var parts = new[] { strips[0], strips[1], strips[2], strips[4], fill };
            var (joined, report) = Solid.JoinSheets(parts, 1e-6);
            using var _j = joined;
            if (report.Refused != 0 || report.NakedAfter != 4 + 2 + 2) return Fail($"n_sided_patch: the ring joined as {report}");
            var (t, msg) = CsThrown(() => Solid.NSidedPatch(boundaries.Take(2)));
            if (t != nameof(BuildException) || !msg.StartsWith("n_sided_patch: ")) return Fail($"n_sided_patch: two sides gave {t}: {msg}");
            // a level is checked by the kernel, not rewritten by the wrapper
            (t, msg) = CsThrown(() => Solid.NSidedPatch(Enumerable.Repeat(PatchBoundary.OfSide(strips[0], "v0", 3), 3)));
            if (t != nameof(BuildException) || !msg.StartsWith("n_sided_patch: ")) return Fail($"n_sided_patch: level 3 gave {t}: {msg}");
            // a strip leaving the plane is met at G0 only: its level reaches the kernel as given
            using var tin = CsLine(cscorners[1], cscorners[2]);
            using var tout = CsLine((1.6 * cscorners[1].Item1, 1.6 * cscorners[1].Item2, 0.8), (1.6 * cscorners[2].Item1, 1.6 * cscorners[2].Item2, 0.8));
            using var tilt = Solid.LoftCurves(new[] { tin, tout }, 1);
            var ring5 = new[] { strips[0], tilt, strips[2], strips[3], strips[4] };
            PatchReport? Level(int lv) { using var q = Solid.NSidedPatch(ring5.Select(x => PatchBoundary.OfSide(x, "v0", x == tilt ? lv : 2)), tolerance: 1e-6); return q.PatchReport; }
            var at0 = Level(0);
            var at1 = Level(1);
            if (at0 is null || at0.Boundary.Gap > 1e-9 || at0.Boundary.Angle > 1e-9 || at1 is null || at1.Boundary.Angle < 0.5)
                return Fail($"n_sided_patch: a tilted strip met at G0 gave {at0?.Boundary.Angle} and at G1 {at1?.Boundary.Angle}");
            // every boundary a sheet's side: the curve's place taken by strip 3
            using var whole = Solid.NSidedPatch(strips.Select(s => PatchBoundary.OfSide(s, "v0")), tolerance: 1e-6);
            if (whole.Faces != 5 || whole.PatchReport is not { } wr || wr.Boundary.Angle > 1e-6 || strips[0].PatchReport is not null) return Fail($"n_sided_patch: five sides gave {whole.Faces} faces");
            foreach (var s in strips) s.Dispose();
            foreach (var c in curves) c.Dispose();
        }

        // 9. test_fillet_surfaces_rolls_a_ball_between_two_sheets (+ the rails outlive the sheets)
        {
            using var f0 = CsLine((0, 0, 0), (4, 0, 0));
            using var f1 = CsLine((0, 3, 0), (4, 3, 0));
            using var w0 = CsLine((0, 0, 0), (0, 3, 0));
            using var w1 = CsLine((0, 0, 4), (0, 3, 4));
            var floor = Solid.LoftCurves(new[] { f0, f1 }, 1);
            var wall = Solid.LoftCurves(new[] { w0, w1 }, 1);
            (Solid, NurbsCurve, NurbsCurve)? found = null;
            foreach (var (fa, fb) in new[] { (false, false), (true, false), (false, true), (true, true) })
            {
                (Solid, NurbsCurve, NurbsCurve) got;
                try { got = Solid.FilletSurfaces(floor, wall, 1.0, flipA: fa, flipB: fb, tolerance: 1e-4); }
                catch (BuildException) { continue; }
                var p = got.Item2.Point(got.Item2.Domain.Lo);
                if (p.X > 0 && Math.Abs(p.Z) <= 1e-9) { found = got; break; }
                got.Item1.Dispose();
                got.Item2.Dispose();
                got.Item3.Dispose();
            }
            if (found is null) return Fail("fillet_surfaces: no side of the pair rolled a ball");
            var (csh, railA, railB) = found.Value;
            if (csh.Faces != 1 || csh.SheetError is not { } fe || fe < 0 || fe > 1e-4) return Fail($"fillet_surfaces: faces {csh.Faces}, sheet_error {csh.SheetError}");
            // the rails belong to the caller: the sheets may go first
            csh.Dispose();
            floor.Dispose();
            wall.Dispose();
            GC.Collect();
            GC.WaitForPendingFinalizers();
            if (Math.Abs(railA.Point(railA.Domain.Lo).X - 1.0) > 1e-4) return Fail($"fillet_surfaces: rail a starts at {railA.Point(railA.Domain.Lo)}");
            if (Math.Abs(railB.Point(railB.Domain.Lo).Z - 1.0) > 1e-4) return Fail($"fillet_surfaces: rail b starts at {railB.Point(railB.Domain.Lo)}");
            railA.Dispose();
            railB.Dispose();
            using var g0 = Solid.LoftCurves(new[] { f0, f1 }, 1);
            using var g1 = Solid.LoftCurves(new[] { w0, w1 }, 1);
            var (t, msg) = CsThrown(() => Solid.FilletSurfaces(g0, g1, 0.0));
            if (t != nameof(BuildException) || !msg.StartsWith("fillet_surfaces: ")) return Fail($"fillet_surfaces: radius 0 gave {t}: {msg}");
        }

        // 10. test_fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius
        {
            const double Length = 400.0;
            var rowsA = new List<NurbsCurve>();
            var rowsB = new List<NurbsCurve>();
            foreach (var y in new[] { 0.0, Length / 3, 2 * Length / 3, Length })
            {
                var s = Math.Sin(Math.PI * y / Length);
                var c = (150.0 + 8.0 * s, y, 6.0 * s);
                rowsA.Add(new NurbsCurve(new (double, double, double)[] { (0.0, y, 10.0), (50.0, y, 14.0), (100.0, y, 12.0), c }, 3));
                rowsB.Add(new NurbsCurve(new (double, double, double)[] { c, (c.Item1 + 14, y, c.Item3 - 60), (c.Item1 + 10, y, c.Item3 - 130), (c.Item1 - 4, y, c.Item3 - 200) }, 3));
            }
            using var fa = Solid.LoftCurves(rowsA, 3, loose: true);
            using var fb = Solid.LoftCurves(rowsB, 3, loose: true);
            var (shell, report) = Solid.JoinSheets(new[] { fa, fb }, 1e-6);
            using var _s = shell;
            if (report.Sewn != 1) return Fail($"fillet: the fender and the door sewed {report.Sewn} edges");
            var crease = shell.Edges.Where(e => e.Faces.Length == 2).ToList();
            if (crease.Count != 1 || crease[0].Kind != "nurbs") return Fail($"fillet: {crease.Count} creases");
            using var constant = shell.Fillet(crease, 12.0, 1e-3);
            using var varying = shell.Fillet(crease, 8.0, 1e-3, 20.0);
            using var same = shell.Fillet(crease, 12.0, 1e-3, 12.0);
            if (constant.Faces != 3 || varying.Faces != 3) return Fail($"fillet: constant {constant.Faces} faces, varying {varying.Faces}");
            double Area(Solid b) => b.Mass(1e-6).Area;
            if (!(Area(varying) < Area(constant) && Area(constant) < Area(shell))) return Fail($"fillet: areas varying {Area(varying)}, constant {Area(constant)}, sharp {Area(shell)}");
            if (Math.Abs(Area(same) - Area(constant)) > 1e-9) return Fail("fillet: radius_end equal to radius is not the constant fillet");
            using var cube = Solid.Cuboid(10, 10, 10);
            var (t, msg) = CsThrown(() => cube.Fillet(new[] { 0 }, 1.0, radiusEnd: 2.0));
            if (t != nameof(BuildException) || !msg.Contains("a varying radius rounds only spline edges")) return Fail($"fillet: a varying radius on a cube gave {t}: {msg}");
            foreach (var c in rowsA.Concat(rowsB)) c.Dispose();
        }
        Console.WriteLine("sheets from curves: lofts, sweeps, patches, trims, joins, fillets, reports and refusals all read back");
    }
    // 4c. the R-tree: Python's test_rtree_*, trimmed to what proves the marshalling (rtree plan 3)
    {
        Box B(double x0, double y0, double z0, double x1, double y1, double z1) => new(new[] { x0, y0, z0 }, new[] { x1, y1, z1 });
        bool Sorted(List<RTreePair> ps) => ps.Zip(ps.Skip(1)).All(q => q.First.A < q.Second.A || (q.First.A == q.Second.A && q.First.B <= q.Second.B));
        string Closed(Action act)
        {
            try { act(); return "(no exception)"; }
            catch (ObjectDisposedException e) { return e.Message; }
        }
        // 1. the grid, packed and inserted one at a time
        var cells = new List<(uint Id, Box Box)>();
        for (var i = 0; i < 10; i++)
            for (var j = 0; j < 10; j++)
                for (var k = 0; k < 10; k++)
                    cells.Add(((uint)(100 * i + 10 * j + k), B(i, j, k, i + 1, j + 1, k + 1)));
        using var packed = RTree.FromBoxes(cells);
        using var grown = new RTree();
        foreach (var (id, box) in Enumerable.Reverse(cells)) grown.Insert(id, box);
        var corner = cells.Select(c => c.Id).Where(id => id / 100 <= 2 && id / 10 % 10 <= 2 && id % 10 <= 2).OrderBy(id => id).ToList();
        var answers = new List<List<RTreePair>>();
        foreach (var (name, tree) in new[] { ("from_boxes", packed), ("insert", grown) })
        {
            if (tree.Count != 1000) return Fail($"rtree {name}: count {tree.Count}");
            var box6 = tree.Bounds;
            if (box6 is null || !Near(box6.Lo, new double[] { 0, 0, 0 }, 0) || !Near(box6.Hi, new double[] { 10, 10, 10 }, 0)) return Fail($"rtree {name}: bounds {box6}");
            var found = tree.Search(B(0, 0, 0, 2, 2, 2));
            if (!found.SequenceEqual(corner)) return Fail($"rtree {name}: search found {string.Join(",", found)}");
            var near = tree.Nearest(new double[] { -1, -1, -1 }, 1);
            if (near.Count != 1 || near[0].Id != 0 || !Within(near[0].Distance, Math.Sqrt(3), 1e-12)) return Fail($"rtree {name}: nearest {string.Join(",", near)}");
            var at = tree.Within(new double[] { 0, 0, 0 }, 0);
            if (at.Count != 1 || at[0] != new RTreeHit(0, 0)) return Fail($"rtree {name}: within 0 {string.Join(",", at)}");
            var four = tree.Within(new double[] { -1, -1, -1 }, 2.5).Select(h => h.Id).ToList();
            if (!four.SequenceEqual(new uint[] { 0, 1, 10, 100 })) return Fail($"rtree {name}: within 2.5 {string.Join(",", four)}");
            var pairs = tree.SelfOverlaps();
            if (pairs.Count != (28 * 28 * 28 - 1000) / 2 || pairs.Any(p => p.A >= p.B) || !Sorted(pairs)) return Fail($"rtree {name}: self overlaps {pairs.Count}, or a pair out of order");
            if (!tree.SelfOverlaps(0.5).SequenceEqual(pairs)) return Fail($"rtree {name}: unit gaps paired at slack 0.5");
            answers.Add(pairs);
        }
        if (!answers[0].SequenceEqual(answers[1])) return Fail("rtree: the packed and the grown trees disagree");
        // 2. two trees, and the same tree twice
        using (var one = RTree.FromBoxes(new[] { (7u, B(4.5, 4.5, 4.5, 5.5, 5.5, 5.5)) }))
        {
            var cross = packed.Overlaps(one);
            var want = new uint[] { 444, 445, 454, 455, 544, 545, 554, 555 }.Select(a => new RTreePair(a, 7)).ToList();
            if (!cross.SequenceEqual(want)) return Fail($"rtree overlaps: {string.Join(",", cross)}");
            var back = one.Overlaps(packed);
            if (!back.SequenceEqual(want.Select(p => new RTreePair(p.B, p.A)))) return Fail($"rtree overlaps: the other way round {string.Join(",", back)}");
        }
        var twice = packed.Overlaps(packed, 0);
        if (twice.Count != 1000 + 2 * 10476 || !Sorted(twice)) return Fail($"rtree overlaps: the grid with itself gave {twice.Count}");
        // 3. points, insert and remove
        using (var pts = RTree.FromPoints(new[] { new double[] { 0, 0, 0 }, new double[] { 5, 0, 0 }, new double[] { 1, 0, 0 }, new double[] { 0, 3, 0 } }))
        {
            if (!pts.Search(B(-0.1, -0.1, -0.1, 1.1, 0.1, 0.1)).SequenceEqual(new uint[] { 0, 2 })) return Fail("rtree from points: ids are not the indices");
            var two = pts.Nearest(new double[] { 4, 0, 0 }, 2);
            if (!two.SequenceEqual(new[] { new RTreeHit(1, 1), new RTreeHit(2, 3) })) return Fail($"rtree from points: nearest {string.Join(",", two)}");
        }
        using (var tree = new RTree())
        {
            var cell = B(3, 3, 3, 4, 4, 4);
            tree.Insert(7, cell);
            tree.Insert(7, cell);
            if (!tree.Search(cell).SequenceEqual(new uint[] { 7, 7 })) return Fail("rtree insert: one (id, box) twice is two entries");
            if (!tree.Remove(7, cell) || !tree.Remove(7, cell) || tree.Remove(7, cell)) return Fail("rtree remove: true, true, then false");
            tree.Insert(7, cell);
            if (tree.Remove(8, cell)) return Fail("rtree remove: another id took the entry out");
            if (tree.Remove(7, B(3, 3, 3, 4, 4, 4.5))) return Fail("rtree remove: another box took the entry out");
            var point = new double[] { 1, 2, 3 };
            tree.Insert(9, point);
            var box6 = tree.Bounds;
            if (tree.Count != 2 || box6 is null || !Near(box6.Lo, point, 0) || !Near(box6.Hi, new double[] { 4, 4, 4 }, 0)) return Fail($"rtree insert: a point, bounds {box6}");
            if (!tree.Remove(9, point) || !tree.Remove(7, cell)) return Fail("rtree remove: the point or the box stayed");
            if (tree.Count != 0 || tree.Bounds is not null) return Fail("rtree remove: emptied, the tree still has bounds");
        }
        // 4. point neighbours against brute force
        {
            ulong state = 5;
            double Next() { state = state * 6364136223846793005UL + 1442695040888963407UL; return (state >> 11) / (double)(1UL << 53); }
            var hay = Enumerable.Range(0, 30).Select(_ => new[] { 10 * Next(), 10 * Next(), 10 * Next() }).ToList();
            var needles = Enumerable.Range(0, 5).Select(_ => new[] { 10 * Next(), 10 * Next(), 10 * Next() }).ToList();
            double Dist(double[] a, double[] b) => Math.Sqrt(Enumerable.Range(0, 3).Sum(k => (a[k] - b[k]) * (a[k] - b[k])));
            List<uint> ByDistance(double[] p) => Enumerable.Range(0, hay.Count).OrderBy(i => Dist(hay[i], p)).ThenBy(i => i).Select(i => (uint)i).ToList();
            var close = Blacksmith.ClosestPoints(hay, needles, 3.0);
            for (var n = 0; n < needles.Count; n++)
                if (!close[n].SequenceEqual(ByDistance(needles[n]).Where(i => Dist(hay[(int)i], needles[n]) <= 3.0))) return Fail($"closest points: needle {n} gave {string.Join(",", close[n])}");
            if (close.Count != 5 || close.All(c => c.Count == 0) || close.All(c => c.Count == hay.Count)) return Fail("closest points: the limit chose nothing or everything");
            var knn = Blacksmith.KNeighbors(hay, needles, 4);
            for (var n = 0; n < needles.Count; n++)
                if (!knn[n].SequenceEqual(ByDistance(needles[n]).Take(4))) return Fail($"k neighbors: needle {n} gave {string.Join(",", knn[n])}");
            var all = Blacksmith.KNeighbors(hay, needles.Take(2), 500);
            if (all.Count != 2 || !all[1].SequenceEqual(ByDistance(needles[1]))) return Fail("k neighbors: k over the hay count is not every point");
            if (Blacksmith.KNeighbors(new List<double[]>(), needles.Take(2), 3).Any(c => c.Count != 0)) return Fail("k neighbors: an empty hay found something");
        }
        // 5. refusals, by the call's name
        using (var tree = new RTree())
        {
            var nanBox = Refused(() => tree.Insert(1, B(0, 0, 0, double.NaN, 1, 1)));
            if (!nanBox.StartsWith("rtree_insert: ") || !nanBox.EndsWith("is not a box")) return Fail($"rtree insert: a NaN box gave '{nanBox}'");
            var inverted = Refused(() => tree.Insert(1, B(1, 0, 0, 0, 1, 1)));
            if (!inverted.StartsWith("rtree_insert: ") || !inverted.EndsWith("is not a box")) return Fail($"rtree insert: an inverted box gave '{inverted}'");
            var infPoint = Refused(() => tree.Insert(1, new[] { double.PositiveInfinity, 0, 0 }));
            if (!infPoint.StartsWith("rtree_insert_point: ") || !infPoint.EndsWith("is not finite")) return Fail($"rtree insert: an infinite point gave '{infPoint}'");
            if (tree.Count != 0) return Fail("rtree insert: a refused insert changed the tree");
            var badRemove = Refused(() => tree.Remove(1, B(1, 0, 0, 0, 1, 1)));
            if (!badRemove.StartsWith("rtree_remove: ")) return Fail($"rtree remove: an inverted box gave '{badRemove}'");
            if (tree.Remove(1, B(0, 0, 0, 1, 1, 1))) return Fail("rtree remove: absent right after a refusal read true");
            var nanWithin = Refused(() => tree.Within(new[] { double.NaN, 0, 0 }, 1));
            if (!nanWithin.StartsWith("rtree_within: ") || !nanWithin.EndsWith("is not finite")) return Fail($"rtree within: a NaN point gave '{nanWithin}'");
            var nanNearest = Refused(() => tree.Nearest(new[] { double.NaN, 0, 0 }, 1));
            if (!nanNearest.StartsWith("rtree_nearest: ") || !nanNearest.EndsWith("is not finite")) return Fail($"rtree nearest: a NaN point gave '{nanNearest}'");
            var radius = Refused(() => tree.Within(new double[] { 0, 0, 0 }, -1));
            if (radius != "rtree_within: radius -1 is not a distance") return Fail($"rtree within: radius -1 gave '{radius}'");
            var slack = Refused(() => tree.SelfOverlaps(double.NaN));
            if (slack != "rtree_self_overlaps: slack NaN is not a distance") return Fail($"rtree self overlaps: slack NaN gave '{slack}'");
            var negSlack = Refused(() => tree.Overlaps(tree, -0.5));
            if (!negSlack.StartsWith("rtree_overlaps: ")) return Fail($"rtree overlaps: slack -0.5 gave '{negSlack}'");
            var k = Refused(() => tree.Nearest(new double[] { 0, 0, 0 }, 1_000_001));
            if (k != "rtree_nearest: k 1000001 is not at most 1000000") return Fail($"rtree nearest: k 1000001 gave '{k}'");
            var twoNumbers = Refused(() => tree.Within(new double[] { 0, 0 }, 1));
            if (!twoNumbers.StartsWith("rtree_within: ")) return Fail($"rtree within: two numbers gave '{twoNumbers}'");
        }
        var entry = Refused(() => RTree.FromBoxes(new[] { (1u, B(0, 0, 0, 1, 1, 1)), (2u, B(2, 0, 0, 1, 1, 1)) }).Dispose());
        if (!entry.StartsWith("rtree_from_boxes: entry 1")) return Fail($"rtree from boxes: a bad entry 1 gave '{entry}'");
        var badPoint = Refused(() => RTree.FromPoints(new[] { new double[] { 0, 0, 0 }, new[] { 0, double.NaN, 0 } }).Dispose());
        if (badPoint != "rtree_from_points: point 1 is not finite") return Fail($"rtree from points: a NaN point 1 gave '{badPoint}'");
        var limit = Refused(() => Blacksmith.ClosestPoints(new[] { new double[] { 0, 0, 0 } }, new[] { new double[] { 0, 0, 0 } }, -1));
        if (limit != "closest_points: limit -1 is not a distance") return Fail($"closest points: limit -1 gave '{limit}'");
        // The limit as Rust's `{}` prints an f64: the shortest round-trip digits, never an exponent.
        foreach (var (bad, shown) in new[] {
            (-1e-7, "-0.0000001"), (-1e20, "-100000000000000000000"), (-1.5, "-1.5"), (-(0.1 + 0.2), "-0.30000000000000004"),
            (double.NaN, "NaN"), (double.NegativeInfinity, "-inf"), (-5e-324, "-0." + new string('0', 323) + "5"),
            (-1e-323, "-0." + new string('0', 322) + "1"), (-1e16, "-10000000000000000"), (-1.2345678901234568e17, "-123456789012345680"),
            (-1e21, "-1000000000000000000000"), (-0.000123, "-0.000123"), (-2.5e-5, "-0.000025") })
        {
            var said = Refused(() => Blacksmith.ClosestPoints(new[] { new double[] { 0, 0, 0 } }, new[] { new double[] { 0, 0, 0 } }, bad));
            if (said != $"closest_points: limit {shown} is not a distance") return Fail($"closest points: limit {bad:R} gave '{said}'");
        }
        var needle = Refused(() => Blacksmith.ClosestPoints(new[] { new double[] { 0, 0, 0 } }, new[] { new[] { double.NaN, 0, 0 } }, 1));
        if (needle != "closest_points: needle point 0 is not finite") return Fail($"closest points: a NaN needle gave '{needle}'");
        var hayNan = Refused(() => Blacksmith.KNeighbors(new[] { new double[] { 0, 0, 0 }, new[] { double.PositiveInfinity, 0, 0 } }, new[] { new double[] { 0, 0, 0 } }, 1_000_001));
        if (hayNan != "k_neighbors: hay point 1 is not finite") return Fail($"k neighbors: an infinite hay point before a bad k gave '{hayNan}'");
        var bigK = Refused(() => Blacksmith.KNeighbors(new[] { new double[] { 0, 0, 0 } }, new[] { new double[] { 0, 0, 0 } }, 1_000_001));
        if (bigK != "k_neighbors: k 1000001 is not at most 1000000") return Fail($"k neighbors: k 1000001 gave '{bigK}'");
        // 6. lifetime: an empty tree answers nothing; a disposed one refuses
        var empty = new RTree();
        if (empty.Count != 0 || empty.Bounds is not null || empty.Search(B(0, 0, 0, 1, 1, 1)).Count != 0
            || empty.Within(new double[] { 0, 0, 0 }, 10).Count != 0 || empty.Nearest(new double[] { 0, 0, 0 }, 3).Count != 0
            || empty.SelfOverlaps().Count != 0 || empty.Overlaps(packed).Count != 0)
            return Fail("rtree: an empty tree answered something");
        empty.Dispose();
        empty.Dispose();
        foreach (var (name, call) in new (string, Action)[] {
            ("count", () => _ = empty.Count), ("bounds", () => _ = empty.Bounds), ("insert", () => empty.Insert(1, new double[] { 0, 0, 0 })),
            ("search", () => empty.Search(B(0, 0, 0, 1, 1, 1))), ("nearest", () => empty.Nearest(new double[] { 0, 0, 0 }, 1)),
            ("self overlaps", () => empty.SelfOverlaps()), ("overlaps", () => packed.Overlaps(empty)) })
        {
            var said = Closed(call);
            if (!said.StartsWith("rtree: closed")) return Fail($"rtree {name}: a disposed tree gave '{said}'");
        }
        var rayClosed = Closed(() => empty.Ray(new double[] { 0, 0, 0 }, new double[] { 1, 0, 0 }));
        if (!rayClosed.StartsWith("rtree: closed")) return Fail($"rtree ray: a disposed tree gave '{rayClosed}'");
        Console.WriteLine($"rtree: grid of {packed.Count}, {answers[0].Count} self pairs, points, neighbours, refusals and lifetime all read back");
        // 7. rays, triangle trees and a solid's face tree (rtree plan 6)
        string Hits(List<RTreeHit> hs) => string.Join(",", hs);
        using (var row = RTree.FromBoxes(Enumerable.Range(0, 10).Select(i => ((uint)i, B(i, 0, 0, i + 1, 1, 1)))))
        {
            var along = row.Ray(new double[] { -1, 0.5, 0.5 }, new double[] { 1, 0, 0 });
            if (!along.SequenceEqual(Enumerable.Range(0, 10).Select(i => new RTreeHit((uint)i, i + 1.0)))) return Fail($"rtree ray: the row gave {Hits(along)}");
            var scaled = row.Ray(new double[] { -1, 0.5, 0.5 }, new double[] { 2, 0, 0 }, 1.0);
            if (!scaled.SequenceEqual(new[] { new RTreeHit(0, 0.5), new RTreeHit(1, 1.0) })) return Fail($"rtree ray: t is not in units of the direction: {Hits(scaled)}");
            var cut = row.Ray(new double[] { -1, 0.5, 0.5 }, new double[] { 1, 0, 0 }, 3);
            if (!cut.SequenceEqual(new[] { new RTreeHit(0, 1), new RTreeHit(1, 2), new RTreeHit(2, 3) })) return Fail($"rtree ray: max_t 3 gave {Hits(cut)}");
            var inside = row.Ray(new double[] { 2.5, 0.5, 0.5 }, new double[] { 1, 0, 0 }, 1);
            if (!inside.SequenceEqual(new[] { new RTreeHit(2, 0), new RTreeHit(3, 0.5) })) return Fail($"rtree ray: from inside gave {Hits(inside)}");
            var back = row.Ray(new double[] { 11, 0.5, 0.5 }, new double[] { -1, 0, 0 }, 2);
            if (!back.SequenceEqual(new[] { new RTreeHit(9, 1), new RTreeHit(8, 2) })) return Fail($"rtree ray: backwards gave {Hits(back)}");
            if (row.Ray(new double[] { -1, 1, 0.5 }, new double[] { 1, 0, 0 }).Count != 10) return Fail("rtree ray: grazing the top face missed");
            if (row.Ray(new double[] { -1, 1 + 1e-12, 0.5 }, new double[] { 1, 0, 0 }).Count != 0) return Fail("rtree ray: a ray above the row met it");
            var zero = Refused(() => row.Ray(new double[] { 0, 0, 0 }, new double[] { 0, 0, 0 }));
            if (zero != "rtree_ray: direction (0, 0, 0) is not a direction") return Fail($"rtree ray: a zero direction gave '{zero}'");
            var negative = Refused(() => row.Ray(new double[] { 0, 0, 0 }, new double[] { 1, 0, 0 }, -1));
            if (negative != "rtree_ray: max_t -1 is not a distance") return Fail($"rtree ray: max_t -1 gave '{negative}'");
            var nanT = Refused(() => row.Ray(new double[] { 0, 0, 0 }, new double[] { 1, 0, 0 }, double.NaN));
            if (nanT != "rtree_ray: max_t NaN is not a distance") return Fail($"rtree ray: max_t NaN gave '{nanT}'");
            var nanOrigin = Refused(() => row.Ray(new[] { double.NaN, 0, 0 }, new double[] { 1, 0, 0 }));
            if (nanOrigin != "rtree_ray: origin (NaN, 0, 0) is not finite") return Fail($"rtree ray: a NaN origin gave '{nanOrigin}'");
            var shortOrigin = Refused(() => row.Ray(new double[] { 0, 0 }, new double[] { 1, 0, 0 }));
            if (!shortOrigin.StartsWith("rtree_ray: ")) return Fail($"rtree ray: two numbers gave '{shortOrigin}'");
        }
        var positions = new[] { new double[] { 0, 0, 0 }, new double[] { 2, 0, 0 }, new double[] { 0, 3, 0 }, new[] { double.NaN, 0, 0 }, new double[] { 5, 1, 4 } };
        using (var tris = RTree.FromTriangles(positions, new[] { (0u, 1u, 2u), (1u, 4u, 1u) }))
        {
            var box6 = tris.Bounds;
            if (tris.Count != 2 || box6 is null || !Near(box6.Lo, new double[] { 0, 0, 0 }, 0) || !Near(box6.Hi, new double[] { 5, 3, 4 }, 0)) return Fail($"rtree from triangles: count {tris.Count}, bounds {box6}");
            if (!tris.Search(B(1, 1, 0, 1, 1, 0)).SequenceEqual(new uint[] { 0 }) || !tris.Search(B(4, 0.5, 2, 4, 0.5, 2)).SequenceEqual(new uint[] { 1 })) return Fail("rtree from triangles: ids are not the triangle indices");
            var through = tris.Ray(new double[] { -1, 0.5, 0 }, new double[] { 1, 0, 0 });
            if (!through.SequenceEqual(new[] { new RTreeHit(0, 1), new RTreeHit(1, 3) })) return Fail($"rtree from triangles: a ray gave {Hits(through)}");
        }
        using (var none = RTree.FromTriangles(new List<double[]>(), new List<(uint, uint, uint)>()))
            if (none.Count != 0) return Fail("rtree from triangles: none gave entries");
        var past = Refused(() => RTree.FromTriangles(Enumerable.Repeat(new double[] { 0, 0, 0 }, 4), new[] { (0u, 1u, 2u), (0u, 4u, 1u) }).Dispose());
        if (past != "rtree_from_triangles: triangle 1 names point 4 of 4") return Fail($"rtree from triangles: an index past the points gave '{past}'");
        var infCorner = Refused(() => RTree.FromTriangles(new[] { new double[] { 0, 0, 0 }, new[] { 0, double.PositiveInfinity, 0 } }, new[] { (0u, 1u, 0u) }).Dispose());
        if (infCorner != "rtree_from_triangles: triangle 0 point 1 is not finite") return Fail($"rtree from triangles: an infinite corner gave '{infCorner}'");
        var shortPoint = Refused(() => RTree.FromTriangles(new[] { new double[] { 0, 0, 0 }, new double[] { 1, 1 } }, new[] { (0u, 0u, 0u) }).Dispose());
        if (!shortPoint.StartsWith("rtree_from_triangles: point 1")) return Fail($"rtree from triangles: two numbers gave '{shortPoint}'");
        using (var cuboid = Solid.Cuboid(3, 4, 5))
        using (var faces = cuboid.FaceTree())
        {
            var grow = 5 * 1e-3;
            var fb = faces.Bounds;
            if (faces.Count != 6 || fb is null || !Near(fb.Lo, new[] { -1.5 - grow, -2 - grow, -2.5 - grow }, 1e-9) || !Near(fb.Hi, new[] { 1.5 + grow, 2 + grow, 2.5 + grow }, 1e-9)) return Fail($"face tree: count {faces.Count}, bounds {fb}");
            if (faces.Search(B(1.4, 1.9, 2.4, 1.6, 2.1, 2.6)).Count != 3) return Fail("face tree: a corner is not three faces");
            var shot = faces.Ray(new double[] { 10, 0, 0 }, new double[] { -1, 0, 0 });
            if (shot.Count != 2 || !Within(shot[0].Distance, 8.5 - grow, 1e-9) || !Within(shot[1].Distance, 11.5 - grow, 1e-9)) return Fail($"face tree: a ray gave {Hits(shot)}");
            if (!Near(cuboid.FaceFrame((int)shot[0].Id)[9..12], new double[] { 1, 0, 0 }, 1e-9)) return Fail("face tree: the first face met is not the +x face");
        }
        Console.WriteLine("rtree: rays, triangle trees and a cuboid's face tree all read back");
    }
    // 4d. the interpolator: Python's test_interpolator_*, trimmed to what proves the marshalling
    {
        var squares = new double[] { 0, 1, 4, 9, 16 };
        var modes = Enum.GetValues<InterpolatorMode>();
        bool One(double[] v, double want) => v.Length == 1 && Within(v[0], want, 1e-12);
        bool All(double[] v, double[] want) => v.Length == want.Length && Near(v, want, 1e-12);
        string Disposed(Action act)
        {
            try { act(); return "(no exception)"; }
            catch (ObjectDisposedException e) { return e.Message; }
        }
        // 1. closed forms on the squares
        using (var sq = new Interpolator(squares))
        {
            if (sq.Count != 5 || sq.Dimension != 1 || sq.Cyclic) return Fail($"interpolator: the squares read {sq}");
            if (modes.Length != 5) return Fail("interpolator: not five modes");
            foreach (var mode in modes)
            {
                for (var k = 0; k < squares.Length; k++)
                    if (!One(sq.At(k, mode), squares[k])) return Fail($"interpolator {mode}: t {k} gave {sq.At(k, mode)[0]}, not {squares[k]}");
                if (!One(sq.At(-2, mode), 0) || !One(sq.At(7, mode), 16)) return Fail($"interpolator {mode}: an open list is not clamped to its end samples");
            }
            if (sq.Nearest(1.5)[0] != 4 || sq.Nearest(1.49)[0] != 1) return Fail("interpolator: nearest 1.5 / 1.49");
            if (!One(sq.Linear(1.5), 2.5)) return Fail($"interpolator: linear 1.5 gave {sq.Linear(1.5)[0]}");
            if (!One(sq.Cosine(1.5), 2.5) || !One(sq.Cosine(1.25), 1 + 3 * (1 - Math.Cos(Math.PI / 4)) / 2)) return Fail("interpolator: cosine 1.5 / 1.25");
            if (!One(sq.Cubic(1.5), 2.0)) return Fail($"interpolator: cubic 1.5 gave {sq.Cubic(1.5)[0]}");
            if (!One(sq.CatmullRom(1.5), 2.25)) return Fail($"interpolator: catmull-rom 1.5 gave {sq.CatmullRom(1.5)[0]}");
            if (sq.At(1.5)[0] != sq.Linear(1.5)[0]) return Fail("interpolator: at is not linear by default");
        }
        using (var ring = new Interpolator(squares, cyclic: true))
        {
            if (!ring.Cyclic) return Fail("interpolator: a cyclic list reads open");
            if (!One(ring.CatmullRom(5), ring.CatmullRom(0)[0])) return Fail("interpolator: cyclic catmull-rom 5 is not 0");
            if (!One(ring.Linear(-0.5), 8.0)) return Fail($"interpolator: cyclic linear -0.5 gave {ring.Linear(-0.5)[0]}");
        }
        // 2. points, and sample a loop of at
        var helix = Enumerable.Range(0, 9).Select(k => new[] { Math.Cos(0.7 * k), Math.Sin(0.7 * k), 0.3 * k }).ToList();
        using (var h = new Interpolator(helix))
        {
            if (h.Count != 9 || h.Dimension != 3) return Fail($"interpolator: the helix reads {h}");
            if (!All(h.At(2), helix[2])) return Fail("interpolator: the helix at 2 is not sample 2");
            if (h.CatmullRom(2.5).Length != 3) return Fail("interpolator: a 3D catmull-rom is not 3 numbers");
            var ts = Enumerable.Range(0, 50).Select(k => -1.0 + 10.0 * k / 49).ToArray();
            foreach (var mode in modes)
            {
                var all = h.Sample(ts, mode);
                if (all.Length != ts.Length || ts.Select((t, k) => All(all[k], h.At(t, mode))).Any(ok => !ok)) return Fail($"interpolator {mode}: sample is not a loop of at");
            }
            if (h.Sample(Array.Empty<double>()).Length != 0) return Fail("interpolator: sample of nothing is not empty");
        }
        var squareCorners = new[] { new double[] { 0, 0 }, new double[] { 1, 0 }, new double[] { 1, 1 }, new double[] { 0, 1 } };
        using (var square = new Interpolator(squareCorners, cyclic: true))
        {
            if (!All(square.Linear(-0.5), new double[] { 0, 0.5 })) return Fail("interpolator: the square at -0.5");
            var two = square.Sample(new[] { 0.5, 1.5 });
            if (two.Length != 2 || !All(two[0], new double[] { 0.5, 0 }) || !All(two[1], new double[] { 1, 0.5 })) return Fail("interpolator: the square sampled at 0.5, 1.5");
        }
        // 3. refusals
        var none = Refused(() => new Interpolator(Array.Empty<double>()).Dispose());
        if (!none.StartsWith("interpolator_new: no samples")) return Fail($"interpolator: no samples gave '{none}'");
        var noRows = Refused(() => new Interpolator(new List<double[]>()).Dispose());
        if (!noRows.StartsWith("interpolator_new: no samples")) return Fail($"interpolator: no rows gave '{noRows}'");
        var nan = Refused(() => new Interpolator(new[] { 0.0, 1.0, double.NaN }).Dispose());
        if (!nan.StartsWith("interpolator_new: sample 2 is not finite")) return Fail($"interpolator: a NaN sample gave '{nan}'");
        try { new Interpolator(new[] { new double[] { 0, 1 }, new double[] { 2, 3, 4 } }).Dispose(); return Fail("interpolator: rows of unequal length were taken"); }
        catch (ArgumentException e) when (e.Message.StartsWith("interpolator: samples differ in length")) { }
        using (var sq = new Interpolator(squares))
        {
            var nanT = Refused(() => sq.Linear(double.NaN));
            if (!nanT.StartsWith("interpolator_at: t NaN is not finite")) return Fail($"interpolator: t NaN gave '{nanT}'");
            var infT = Refused(() => sq.Sample(new[] { 0.0, double.PositiveInfinity }));
            if (!infT.StartsWith("interpolator_sample: t 1 (inf) is not finite")) return Fail($"interpolator: sample of an infinity gave '{infT}'");
            var badMode = Refused(() => sq.At(1, (InterpolatorMode)7));
            if (!badMode.StartsWith("interpolator_at: mode 7 is not a mode")) return Fail($"interpolator: mode 7 gave '{badMode}'");
            sq.Dispose();
            sq.Dispose();
            foreach (var (name, call) in new (string, Action)[] {
                ("count", () => _ = sq.Count), ("dimension", () => _ = sq.Dimension), ("cyclic", () => _ = sq.Cyclic),
                ("at", () => sq.At(1)), ("sample", () => sq.Sample(Array.Empty<double>())), ("catmull-rom", () => sq.CatmullRom(1)) })
            {
                var said = Disposed(call);
                if (!said.StartsWith("interpolator: closed")) return Fail($"interpolator {name}: a disposed one gave '{said}'");
            }
        }
        Console.WriteLine("interpolator: the squares' closed forms, points, sample, refusals and lifetime all read back");
    }
    // 4e. the circumscribed polygon: Python's test_circumscribed_polygon_touches_its_circle
    {
        const double r = 5;
        const int n = 6;
        using var hex = Profile.CircumscribedPolygon((2, -1), r, n, 0.3);
        var perimeter = hex.Length(1e-12).Value;
        var want = 2 * n * r * Math.Tan(Math.PI / n);
        if (Math.Abs(perimeter - want) > 1e-9 * want) return Fail($"circumscribed polygon: perimeter {perimeter}, not {want}");
        var marks = hex.DivideByCount(2 * n, 1e-12);
        if (marks.Count != 2 * n) return Fail($"circumscribed polygon: {marks.Count} marks, not {2 * n}");
        for (var k = 0; k < 2 * n; k++)
        {
            var from = Math.Sqrt((marks[k].Point[0] - 2) * (marks[k].Point[0] - 2) + (marks[k].Point[1] + 1) * (marks[k].Point[1] + 1));
            var expected = k % 2 == 0 ? r / Math.Cos(Math.PI / n) : r;
            if (Math.Abs(from - expected) > 1e-6 * expected) return Fail($"circumscribed polygon: mark {k} is {from} from the centre, not {expected}");
        }
        var two = Refused(() => Profile.CircumscribedPolygon((0, 0), 10, 2).Dispose());
        if (two != "profile_circumscribed_polygon: a polygon has at least 3 sides, not 2") return Fail($"circumscribed polygon: 2 sides gave '{two}'");
        var negative = Refused(() => Profile.CircumscribedPolygon((0, 0), 10, -1).Dispose());
        if (!negative.StartsWith("profile_circumscribed_polygon: a polygon has at least 3 sides")) return Fail($"circumscribed polygon: -1 sides gave '{negative}'");
        Console.WriteLine($"circumscribed polygon: perimeter {perimeter:G10}, corners and midpoints on their circles, refusals read back");
    }
    // 4f. merge and regions: Python's test_merge_* and test_a_merged_body_is_refused_*
    {
        const double tol = 1e-6;
        using var a = Solid.Cuboid(1, 1, 1);
        using var moved = a.Translate(0.5, 0.5, 0.5);
        using var merged = a.Merge(moved, tol);
        if (merged.Faces != 18) return Fail($"merge: two cubes at a corner gave {merged.Faces} faces, not 18");
        var regions = merged.Regions();
        if (!regions.Select(g => g.Index).SequenceEqual(new[] { 0, 1, 2, 3 })) return Fail($"regions: indices {string.Join(",", regions.Select(g => g.Index))}");
        if (regions[0].Finite || regions.Skip(1).Any(g => !g.Finite)) return Fail("regions: region 0 is not the one infinite region");
        if (regions.Any(g => g.Shells != 1)) return Fail($"regions: shells {string.Join(",", regions.Select(g => g.Shells))}");
        if (regions.Any(g => g.Sides.Any(s => s.Sense != 1 && s.Sense != -1))) return Fail("regions: a sense neither +1 nor -1");
        if (regions.Sum(g => g.Sides.Count) != 2 * merged.Faces) return Fail($"regions: {regions.Sum(g => g.Sides.Count)} sides, not each face's two");
        if (!regions.Skip(1).SelectMany(g => g.Sides.Select(s => s.Face)).Distinct().OrderBy(f => f).SequenceEqual(Enumerable.Range(0, merged.Faces)))
            return Fail("regions: the finite regions' faces do not cover every face");
        if (regions.Any(g => !g.Sides.Zip(g.Sides.Skip(1)).All(p => p.First.Face < p.Second.Face || (p.First.Face == p.Second.Face && p.First.Sense < p.Second.Sense))))
            return Fail("regions: sides are not ascending by face then sense");
        var volumes = new Dictionary<int, double>();
        foreach (var g in regions.Skip(1))
        {
            using var cell = merged.RegionSolid(g.Index);
            volumes[g.Index] = cell.Mass().Volume;
        }
        var sorted = volumes.Values.OrderBy(v => v).ToArray();
        if (!Near(sorted, new[] { 0.125, 0.875, 0.875 }, 1e-6)) return Fail($"region solids: volumes {string.Join(",", sorted)}");
        var small = regions[volumes.First(p => Math.Abs(p.Value - 0.125) < 1e-6).Key];
        if (small.Sides.Count != 6 || small.Sides.Any(s => s.Sense != -1)) return Fail($"regions: the overlap has sides {string.Join(",", small.Sides)}");
        if (!Near(small.Box.Lo, new double[] { 0, 0, 0 }, 1e-6) || !Near(small.Box.Hi, new[] { 0.5, 0.5, 0.5 }, 1e-6)) return Fail($"regions: the overlap's box is {small.Box}");
        var again = merged.Regions();
        if (!again.SequenceEqual(regions)) return Fail("regions: twice are not equal by value");
        if (regions[1] == regions[2]) return Fail("regions: two different regions are equal");
        // a ball merged into the cube
        using (var ball = Solid.Sphere(0.3))
        using (var holed = a.Merge(ball, tol))
        {
            var cells = holed.Regions();
            if (cells.Count != 3) return Fail($"merge: a ball in a box gave {cells.Count} regions, not 3");
            var ballVolume = 4.0 / 3.0 * Math.PI * 0.3 * 0.3 * 0.3;
            var vols = cells.Skip(1).Select(g => { using var s = holed.RegionSolid(g.Index); return (g, v: s.Mass().Volume); }).OrderByDescending(p => p.v).ToArray();
            if (!Within(vols[0].v, 1 - ballVolume, 1e-6) || !Within(vols[1].v, ballVolume, 1e-6)) return Fail($"merge: a ball in a box measures {vols[0].v}, {vols[1].v}");
            if (vols[0].g.Shells != 2 || vols[1].g.Shells != 1) return Fail($"merge: the box cell has {vols[0].g.Shells} shells, the ball {vols[1].g.Shells}");
        }
        // refusals
        var join = Refused(() => merged.Join(a, tol).Dispose());
        if (!join.StartsWith("join: the join needs a manifold solid, and this one has edges of three or more faces")) return Fail($"merge: join of the merge gave '{join}'");
        var mass = Refused(() => merged.Mass());
        if (!mass.StartsWith("mass_properties: the mass needs a manifold solid")) return Fail($"merge: the merge's mass gave '{mass}'");
        var zero = Refused(() => merged.RegionSolid(0).Dispose());
        if (zero != "region_solid: region 0 is the infinite region") return Fail($"region solid: 0 gave '{zero}'");
        var four = Refused(() => merged.RegionSolid(4).Dispose());
        if (four != "region_solid: region 4 is not below 4") return Fail($"region solid: 4 gave '{four}'");
        try { merged.RegionSolid(-1).Dispose(); return Fail("region solid: -1 was taken"); }
        catch (ArgumentOutOfRangeException e) when (e.Message.StartsWith("region_solid: region is out of range: -1")) { }
        var flat = Refused(() => a.Merge(a, -1.0).Dispose());
        if (!flat.StartsWith("merge: tolerance must be positive and finite")) return Fail($"merge: tolerance -1 gave '{flat}'");
        using (var cell = merged.RegionSolid(1))
        using (var joined = cell.Join(a, tol))
            if (joined.Faces == 0) return Fail("region solid: a cell joined to the cube has no faces");
        var plain = a.Regions();
        if (plain.Count != 2 || plain[0].Sides.Any(s => s.Sense != 1) || plain[1].Sides.Any(s => s.Sense != -1)) return Fail("regions: an ordinary cube is not outside +1, inside -1");
        Console.WriteLine($"merge: {merged.Faces} faces, {regions.Count} regions, cells {string.Join(", ", sorted.Select(v => v.ToString("G6")))}; ball in a box, refusals read back");
    }
    // 5. containment, one-shot and classifier
    using (var box = Solid.Cuboid(2, 3, 4))
    {
        if (box.Contains(new double[] { 0, 0, 0 }) != "inside" || box.Contains(new double[] { 5, 0, 0 }) != "outside"
            || box.Contains(new double[] { 0, 0, 2 }) != "on")
            return Fail("contains: the box's inside, outside and on points read wrong");
        using var cls = box.Classifier();
        foreach (var p in new[] { new double[] { 0, 0, 0 }, new double[] { 0.99, 0, 0 }, new double[] { 1, 0, 0 }, new double[] { 1.2, 0, 0 },
                                  new double[] { 0, 1.6, 0 }, new double[] { 0, 0, -2 } })
            if (cls.Contains(p) != box.Contains(p)) return Fail($"classifier: disagrees with contains at {string.Join(",", p)}");
    }
    using (var ball = Solid.Sphere(1.5))
    {
        using var cls = ball.Classifier(1e-3);
        var xs = new[] { -2.0, -1.4, -0.5, 0, 0.5, 1.4, 2 };
        var expected = new[] { "outside", "inside", "inside", "inside", "inside", "inside", "outside" };
        for (var i = 0; i < xs.Length; i++)
            if (cls.Contains(new[] { xs[i], 0, 0 }) != expected[i]) return Fail($"classifier: sphere at x={xs[i]} reads {cls.Contains(new[] { xs[i], 0, 0 })}");
        if (cls.Contains(new[] { 1.5, 0, 0 }) != "on" || cls.Contains(new[] { 0, 0, -1.5 }) != "on") return Fail("classifier: the sphere's surface does not read on");
    }
    // 6. the classifier outlives its solid
    Classifier orphan;
    {
        var ball = Solid.Sphere(1.0);
        orphan = ball.Classifier(1e-3);
        ball.Dispose();
        GC.Collect();
        GC.WaitForPendingFinalizers();
    }
    if (orphan.Contains(new double[] { 0, 0, 0 }) != "inside" || orphan.Contains(new double[] { 2, 0, 0 }) != "outside"
        || orphan.Contains(new double[] { 1, 0, 0 }) != "on")
        return Fail("classifier: it stopped answering once its solid was freed");
    // 7. containment errors, and a closed classifier
    using (var box = Solid.Cuboid(2, 3, 4))
    {
        var nanPoint = new[] { double.NaN, 0, 0 };
        var e1 = Refused(() => box.Contains(nanPoint));
        if (!e1.StartsWith("contains: ") || !e1.Contains("not finite")) return Fail($"contains: a NaN point gave '{e1}'");
        var e2 = Refused(() => orphan.Contains(nanPoint));
        if (!e2.StartsWith("classifier_contains: ") || !e2.Contains("not finite")) return Fail($"classifier: a NaN point gave '{e2}'");
        var e3 = Refused(() => box.Contains(new double[] { 0, 0, 0 }, -1));
        if (!e3.StartsWith("contains: ") || !e3.Contains("positive and finite")) return Fail($"contains: tolerance -1 gave '{e3}'");
        var e4 = Refused(() => box.Classifier(-1));
        if (!e4.StartsWith("classifier_new: ") || !e4.Contains("positive and finite")) return Fail($"classifier: tolerance -1 gave '{e4}'");
    }
    orphan.Dispose();
    orphan.Dispose();
    try { orphan.Contains(new double[] { 0, 0, 0 }); return Fail("classifier: a closed classifier answered"); }
    catch (ObjectDisposedException) { }
    // 8. the closest points of two spheres
    using (var s1 = Solid.Sphere(1))
    using (var s2 = Solid.Sphere(1).Translate(5, 0, 0))
    {
        var c = s1.Closest(s2, 1e-3);
        if (!Within(c.Distance, 3, 6e-9) || !c.Refined) return Fail($"closest: the spheres read {c}");
        if (c.KindA != "face" || c.KindB != "face" || c.EdgeA is not null || c.EdgeB is not null) return Fail($"closest: the spheres' kinds or edges read {c}");
        if (!Near(c.OnA, new double[] { 1, 0, 0 }, 1e-6) || !Near(c.OnB, new double[] { 4, 0, 0 }, 1e-6)) return Fail($"closest: the spheres' points read {c}");
        var back = s2.Closest(s1, 1e-3);
        if (!Near(back.OnA, c.OnB, 1e-9) || !Near(back.OnB, c.OnA, 1e-9) || !Within(back.Distance, c.Distance, 1e-12))
            return Fail($"closest: swapping the solids did not swap the points: {back}");
    }
    // 9. a filletable edge
    using (var box = Solid.Cuboid(2, 3, 4))
    using (var ball = Solid.Sphere(1).Translate(3, 0, 4))
    {
        var c = box.Closest(ball, 1e-3);
        if (!Within(c.Distance, 2 * Math.Sqrt(2) - 1, 2e-3)) return Fail($"closest: the box and ball read {c}");
        if (c.KindA != "edge" || c.EdgeA is null || c.KindB != "face" || c.EdgeB is not null) return Fail($"closest: the box and ball name {c}");
        using var edgeRounded = box.Fillet(new[] { (int)c.EdgeA.Value }, 0.2);
        if (edgeRounded.Faces != box.Faces + 1) return Fail($"closest: filleting the named edge gave {edgeRounded.Faces} faces from {box.Faces}");
    }
    // 10. closest errors
    using (var s1 = Solid.Sphere(1))
    using (var s2 = Solid.Sphere(1).Translate(5, 0, 0))
    {
        var zero = Refused(() => s1.Closest(s2, -1));
        if (!zero.StartsWith("closest: ")) return Fail($"closest: tolerance -1 gave '{zero}'");
    }
    Console.WriteLine("measure: oriented box, lengths, containment and closest points all read back");
}

// Tolerances: hole2.3dm (a root sample, scripts/link-samples.py) declares an absolute 0.01 and one
// degree; a boolean given a null tolerance works at the inputs' effective one, declares nothing
// for built primitives, and is the explicit-effective boolean.
{
    var tolHole2 = System.IO.Path.GetFullPath(System.IO.Path.Combine(SmokeSourceDir(), "..", "..", "..", "..", "..", "hole2.3dm"));
    if (System.IO.File.Exists(tolHole2))
    {
        using var tolDeclared = Cadaclysm.Cadaclysm.Open(tolHole2);
        if (tolDeclared.Tolerances != new Tolerances(0.01, 0.017453292519943295)) return Fail($"hole2.3dm declares {tolDeclared.Tolerances}");
    }
    else if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("CADACLYSM_SAMPLES_OPTIONAL")))
        return Fail($"{tolHole2} is missing: run scripts/link-samples.py");
    string TolRefused(Action act) { try { act(); return ""; } catch (BuildException e) { return e.Message; } }
    if (path.EndsWith("cube.scad") && scene.Tolerances != new Tolerances(null, null)) return Fail($"{path} declares {scene.Tolerances}");
    using var tolBlock = Solid.Cuboid(10, 10, 10);
    using var tolPin0 = Solid.Cylinder(3, 20);
    using var tolPin = tolPin0.Translate(0, 0, -5);
    var tolAt = Blacksmith.EffectiveTolerance(tolBlock, tolPin);
    if (!(Math.Abs(tolAt - 1e-4 * 20) < 1e-3)) return Fail($"effective_tolerance reads {tolAt}");
    using var tolUnset = tolBlock.Cut(tolPin, tolerance: null);
    using var tolExplicit = tolBlock.Cut(tolPin, tolAt);
    if (tolUnset.Tolerances != new Tolerances(null, null)) return Fail($"an unset cut declares {tolUnset.Tolerances}");
    if (tolUnset.Mass(1e-7).Volume != tolExplicit.Mass(1e-7).Volume)
        return Fail($"unset cut volume {tolUnset.Mass(1e-7).Volume} against the explicit {tolExplicit.Mass(1e-7).Volume}");
    var tolMeshAt = Blacksmith.EffectiveTolerance(tolExplicit);
    if (tolUnset.Mesh(tolerance: null).TriangleCount != tolExplicit.Mesh(tolMeshAt).TriangleCount || tolBlock.Mesh(tolerance: null).Tolerance is not double.NaN)
        return Fail("an unset mesh is not the explicit-effective one");
    using var tolLoose = tolBlock.WithTolerances(0.1);
    if (tolLoose.Tolerances != new Tolerances(0.1, null) || Blacksmith.EffectiveTolerance(tolLoose, tolPin) != 0.1) return Fail("with_tolerances: 0.1 is not declared");
    using var tolLooseCut = tolLoose.Cut(tolPin, tolerance: null);
    if (tolLooseCut.Tolerances.Absolute != 0.1) return Fail("a cut does not inherit the loosest declaration");
    if (tolBlock.VertexTolerance(new[] { 5.0, 5.0, 5.0 }) is not null) return Fail("a built cuboid records a vertex tolerance");
    if (!TolRefused(() => tolBlock.WithTolerances(-1)).StartsWith("solid_with_tolerances: ")) return Fail("with_tolerances: -1 is not refused");
    if (Blacksmith.EffectiveTolerance() != 0) return Fail("effective_tolerance of nothing is not 0");
    Console.WriteLine($"tolerances: effective {tolAt:G}, an unset cut is the explicit one");
}
// The document: a node graph with parameters, undo and branches, its JSON text read with
// System.Text.Json; Python's document tests, every assert this shape can make.
if (DocumentChecks() is string documentWhy) return Fail(documentWhy);
return 0;

static int Fail(string why) { Console.Error.WriteLine(why); return 1; }
// This source file's own folder, from the compiler: the repository's fixtures are found from it,
// never from the working directory.
static string SmokeSourceDir([System.Runtime.CompilerServices.CallerFilePath] string path = "") => System.IO.Path.GetDirectoryName(path)!;
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
// The document checks: null when every one passes, else the first failure. Each check is one of
// Python's document tests (test_cadaclysm_blacksmith.py, `plate_document` to the bim tests),
// asserted on the JSON text through System.Text.Json.
static string? DocumentChecks()
{
    try
    {
        DocumentResults();
        DocumentSaveLoad();
        DocumentUndoRedo();
        DocumentRefusals();
        DocumentValues();
        DocumentParams();
        DocumentBranches();
        DocumentBatchPreview();
        DocumentResultTypes();
        DocumentHeld();
        DocumentBim();
        DocumentLifetime();
        return null;
    }
    catch (DocCheckFailed e) { return $"document: {e.Message}"; }
    catch (Exception e) { return $"document: unexpected {e.GetType().Name}: {e.Message}"; }
}
static void Must(bool ok, string why) { if (!ok) throw new DocCheckFailed(why); }
static System.Text.Json.JsonElement Js(string text) => System.Text.Json.JsonDocument.Parse(text).RootElement.Clone();
static string DocRefused(Action act)
{
    try { act(); }
    catch (BuildException e) { return e.Message; }
    return "";
}
static bool Approx(double a, double b, double rel = 1e-9) => Math.Abs(a - b) <= rel * Math.Max(1.0, Math.Abs(b));
static string Op(string kind, string fields) => $"{{\"op\": \"add\", \"node\": {{\"kind\": \"{kind}\", {fields}}}}}";
// `add` through `apply`: the id the changed set names.
static string DocAdd(Document doc, string kind, string fields, string? message = null) =>
    Js(doc.Apply(Op(kind, fields), message)).GetProperty("added")[0].GetString()!;
static string DocSet(string id, string fields) => $"{{\"op\": \"set\", \"id\": \"{id}\", \"fields\": {{{fields}}}}}";
// Python's `plate_document`: a 10 x 10 rectangle `r1` and its 10 mm extrusion `x1`.
static Document Plate()
{
    var doc = new Document("mm");
    Must(DocAdd(doc, "profile.rect", "\"id\": \"r1\", \"w\": 10, \"h\": 10") == "r1", "plate: r1 is not r1");
    Must(DocAdd(doc, "solid.extrude", "\"id\": \"x1\", \"profile\": \"r1\", \"frame\": \"xy\", \"distance\": 10") == "x1", "plate: x1 is not x1");
    return doc;
}
static double Volume(Document doc, string id)
{
    using var solid = doc.ResultSolid(id);
    return solid.Mass().Volume;
}
static bool Has(Document doc, string id) => doc.ResultKind(id) != "none";
static string[] States(string status) => Js(status).EnumerateArray().Select(r => r.GetProperty("state").GetString()!).ToArray();
static string[] Ids(string commits) => Js(commits).EnumerateArray().Select(c => c.GetProperty("id").GetString()!).ToArray();
static string[] Parents(System.Text.Json.JsonElement commit) => commit.GetProperty("parents").EnumerateArray().Select(p => p.GetString()!).ToArray();
static string? Message(System.Text.Json.JsonElement commit) =>
    commit.TryGetProperty("message", out var m) && m.ValueKind == System.Text.Json.JsonValueKind.String ? m.GetString() : null;
static System.Text.Json.JsonElement BranchList(Document doc) => Js(doc.Branches());
static bool CanUndo(Document doc) => BranchList(doc).GetProperty("can_undo").GetBoolean();
static bool CanRedo(Document doc) => BranchList(doc).GetProperty("can_redo").GetBoolean();
static string? CurrentBranch(Document doc) => BranchList(doc).GetProperty("branch").GetString();
static string Head(Document doc) => BranchList(doc).GetProperty("head").GetString()!;
static Dictionary<string, string> BranchTips(Document doc) =>
    BranchList(doc).GetProperty("branches").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!);

// 1. Evaluate and results.
static void DocumentResults()
{
    using var doc = Plate();
    Must(States(doc.Evaluate()).SequenceEqual(new[] { "ok", "ok" }), "results: the plate does not evaluate to two ok rows");
    Must(Js(doc.Errors()).GetArrayLength() == 0, "results: errors is not []");
    using var solid = doc.ResultSolid("x1");
    Must(solid.Faces == 6, $"results: x1 has {solid.Faces} faces");
    using var profile = doc.ResultProfile("r1");
    Must(doc.ResultKind("r1") == "profile" && doc.ResultKind("x1") == "solid", "results: the kinds are not profile and solid");
    Must(doc.ResultKind("nope") == "none", "results: a missing node is not none");
    Must(DocRefused(() => doc.Value("nope")).StartsWith("document_value: "), "results: value of a missing node is not refused");
    // A result is a handle of its own: it outlives the edit that replaced it.
    doc.Apply(DocSet("x1", "\"distance\": 20"));
    Must(solid.Faces == 6 && Approx(solid.Mass().Volume, 1000), "results: the old result changed with the edit");
    Must(Approx(Volume(doc, "x1"), 2000), $"results: x1 at distance 20 reads {Volume(doc, "x1")}");
    Console.WriteLine("document: evaluates, results outlive an edit");
}

// 2. Save, load, open, refusals.
static void DocumentSaveLoad()
{
    using var doc = Plate();
    var first = doc.Save();
    using (var loaded = Document.Load(first))
    {
        Must(loaded.Save() == first, "save: save -> load -> save differs");
        Must(States(loaded.Evaluate()).SequenceEqual(new[] { "ok", "ok" }), "save: the loaded plate does not evaluate");
        using var solid = loaded.ResultSolid("x1");
        Must(solid.Faces == 6, "save: the loaded x1 has not 6 faces");
    }
    var file = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"cadaclysm-smoke-doc-{Guid.NewGuid():N}.json");
    try
    {
        File.WriteAllText(file, first, new UTF8Encoding(false));
        using var opened = Document.Open(file);
        Must(opened.Save() == first, "save: open of the written file differs");
    }
    finally { File.Delete(file); }
    Must(DocRefused(() => Document.Load("not a document")).StartsWith("document_load: "), "save: bad text is not refused by document_load");
    Must(DocRefused(() => new Document("furlongs")).StartsWith("document_new: "), "save: furlongs is not refused by document_new");
    Console.WriteLine("document: save, load and open agree; refusals read back");
}

// 3. Undo takes the node away and redo puts it back.
static void DocumentUndoRedo()
{
    using var doc = Plate();
    Must(CanUndo(doc) && !CanRedo(doc), "undo: a fresh plate's can_undo/can_redo");
    Must(doc.Undo(), "undo: undo answered false");
    Must(!Has(doc, "x1") && Has(doc, "r1"), "undo: x1 is still there, or r1 is gone");
    Must(CanRedo(doc), "undo: nothing to redo after an undo");
    Must(doc.Redo(), "undo: redo answered false");
    Must(Has(doc, "x1"), "undo: redo did not put x1 back");
    // Nothing more to redo: false, not a failure.
    Must(!doc.Redo() && !CanRedo(doc), "undo: a redo with nothing to redo answered true");
    Must(doc.Undo() && doc.Undo(), "undo: two undos");
    Must(!CanUndo(doc), "undo: can_undo at the root");
    Must(!doc.Undo(), "undo: an undo at the root answered true");
    Must(Js(doc.Evaluate()).GetArrayLength() == 0 && CanRedo(doc), "undo: back at the root: no nodes, both commits to redo");
    Console.WriteLine("document: undo and redo");
}

// 4. A refusal leaves the document unchanged.
static void DocumentRefusals()
{
    using var doc = Plate();
    var (before, log) = (doc.Save(), doc.Log());
    var why = DocRefused(() => doc.Apply("{\"op\": \"remove\", \"id\": \"r1\"}"));
    Must(why == "document_apply: r1 is read by x1", $"refusals: removing r1 reads '{why}'");
    Must(doc.Save() == before && doc.Log() == log, "refusals: the refused op changed the document");
    Must(DocRefused(() => doc.Apply(Op("no.such.kind", "\"id\": \"q\""))).StartsWith("document_apply: "), "refusals: an unknown kind is not refused");
    // `cascade` takes the readers away with it, as one commit.
    doc.Apply("{\"op\": \"remove\", \"id\": \"r1\", \"cascade\": true}");
    Must(!Has(doc, "r1") && !Has(doc, "x1"), "refusals: the cascade left r1 or x1");
    Must(Js(doc.Log()).GetArrayLength() == Js(log).GetArrayLength() + 1, "refusals: the cascade is not one commit");
    Must(DocRefused(() => doc.Apply("{not json")).StartsWith("document_apply: "), "refusals: bad op text is not refused");
    Console.WriteLine("document: a refused op changes nothing");
}

// 5. Values, lists and kinds.
static void DocumentValues()
{
    using (var doc = Plate())
    {
        var m = DocAdd(doc, "measure.mass", "\"solid\": \"x1\"");
        Must(Approx(Js(doc.Value(m)).GetProperty("volume").GetDouble(), 1000, 1e-9), "values: the mass node's volume is not 1000");
    }
    using (var doc = new Document())
    {
        DocAdd(doc, "value", "\"id\": \"w\", \"value\": \"=range(10, 40, 10)\"");
        DocAdd(doc, "solid.cuboid", "\"id\": \"c\", \"x\": \"=w\", \"y\": \"=[1, 2]\", \"z\": 1");
        DocAdd(doc, "solid.cuboid", "\"id\": \"x\", \"x\": \"=w\", \"y\": \"=[1, 2]\", \"z\": 1, \"lacing\": \"cross\"");
        Must(Js(doc.Value("w")).EnumerateArray().Select(v => v.GetDouble()).SequenceEqual(new[] { 10.0, 20.0, 30.0 }), $"values: w reads {doc.Value("w")}");
        Must(doc.ResultKind("c") == "list" && Js(doc.Value("c")).GetArrayLength() == 3, "values: c is not a list of 3 (longest lacing)");
        var c = Enumerable.Range(0, 3).Select(i => Volume(doc, $"c#{i}")).ToArray();
        Must(c.Zip(new[] { 10.0, 40, 60 }).All(p => Approx(p.First, p.Second, 1e-6)), $"values: c's volumes are {string.Join(", ", c)}");
        Must(doc.ResultKind("c#1") == "solid", "values: c#1 is not a solid");
        var n = Js(doc.Value("x")).GetArrayLength();
        var x = Enumerable.Range(0, n).Select(i => Volume(doc, $"x#{i}")).ToArray();
        Must(x.Length == 6 && x.Zip(new[] { 10.0, 20, 30, 20, 40, 60 }).All(p => Approx(p.First, p.Second, 1e-6)), $"values: x's volumes are {string.Join(", ", x)}");
        using var back = Document.Load(doc.Save());
        Must(back.Save() == doc.Save(), "values: the laced document does not save, load and save the same");
    }
    var kinds = Js(Document.Kinds());
    var names = kinds.EnumerateArray().Select(k => k.GetProperty("name").GetString()).ToHashSet();
    Must(kinds.GetArrayLength() > 100 && names.IsSupersetOf(new[] { "profile.rect", "solid.extrude", "measure.mass" }), "values: kinds lacks rows");
    using (var doc = new Document())
    {
        doc.Apply("{\"op\": \"param\", \"name\": \"k\", \"value\": -5}");
        DocAdd(doc, "profile.rect", "\"id\": \"bad\", \"w\": \"=k\", \"h\": 1");
        var errors = Js(doc.Errors());
        Must(errors.GetArrayLength() == 1 && errors[0].GetProperty("id").GetString() == "bad" && errors[0].GetProperty("state").GetString() == "error"
             && errors[0].GetProperty("message").GetString()!.Length > 0, $"values: errors reads {doc.Errors()}");
        Must(Js(doc.Evaluate(cheapOnly: true))[0].GetProperty("id").GetString() == "bad", "values: evaluate(cheap_only) does not name bad");
    }
    Console.WriteLine("document: values, laced lists, kinds and errors");
}

// 6. Parameters.
static void DocumentParams()
{
    using var doc = new Document();
    Must(Js(doc.Params()).EnumerateObject().Count() == 0, "params: a new document has parameters");
    doc.Apply("{\"op\": \"param\", \"name\": \"w\", \"value\": 200}");
    Must(Js(doc.Params()).GetProperty("w").GetDouble() == 200, $"params: w reads {doc.Params()}");
    var rect = DocAdd(doc, "profile.rect", "\"w\": \"=w\", \"h\": 100");
    var ext = DocAdd(doc, "solid.extrude", $"\"profile\": \"{rect}\", \"frame\": \"xy\", \"distance\": 10");
    Must(Approx(Volume(doc, ext), 200 * 100 * 10, 1e-9), "params: the extrusion is not 200 x 100 x 10");
    doc.Apply("{\"op\": \"param\", \"name\": \"w\", \"value\": 300}");
    Must(Approx(Volume(doc, ext), 300 * 100 * 10, 1e-9), "params: the extrusion did not follow w to 300");
    var op = Js(doc.Log())[0].GetProperty("ops")[0];
    Must(op.GetProperty("op").GetString() == "param" && op.GetProperty("name").GetString() == "w" && op.GetProperty("value").GetDouble() == 300,
         "params: the head commit is not the param op");
    // A parameter a node reads cannot be deleted: a refusal, and the document is unchanged.
    var before = doc.Save();
    Must(DocRefused(() => doc.Apply("{\"op\": \"param\", \"name\": \"w\", \"value\": null}")).StartsWith("document_apply: "), "params: deleting a read parameter is not refused");
    Must(doc.Save() == before && Js(doc.Params()).GetProperty("w").GetDouble() == 300, "params: the refused delete changed the document");
    Console.WriteLine("document: parameters drive the extrusion");
}

// 7. Branches and the log.
static void DocumentBranches()
{
    using (var doc = Plate())
    {
        Must(CurrentBranch(doc) == "main", "branches: not on main");
        var tips = BranchTips(doc);
        Must(tips.Count == 1 && tips["main"] == Head(doc) && Head(doc) == Ids(doc.Log())[0], "branches: main is not the head");
        doc.BranchNew("idea");
        Must(CurrentBranch(doc) == "idea" && BranchTips(doc).Keys.ToHashSet().SetEquals(new[] { "main", "idea" }), "branches: branch_new did not switch onto idea");
        Must(BranchTips(doc)["idea"] == BranchTips(doc)["main"], "branches: idea does not start at main");
        Must(Ids(doc.Log("main")).SequenceEqual(Ids(doc.Log())), "branches: log(main) is not the head's line");
        doc.Switch("main");
        doc.BranchRename("idea", "plan");
        Must(BranchTips(doc).Keys.ToHashSet().SetEquals(new[] { "main", "plan" }), "branches: the rename");
        doc.BranchDelete("plan");
        Must(BranchTips(doc).Keys.SequenceEqual(new[] { "main" }), "branches: the delete");
        Must(DocRefused(() => doc.BranchDelete("plan")).StartsWith("document_branch_delete: "), "branches: deleting a missing branch");
        Must(DocRefused(() => doc.BranchDelete("main")).StartsWith("document_branch_delete: "), "branches: deleting the current branch");
        Must(DocRefused(() => doc.Log("plan")).StartsWith("document_log: "), "branches: the log of a missing branch");
        Must(DocRefused(() => doc.Switch("nowhere")).StartsWith("document_branch_switch: "), "branches: switching nowhere");
        Must(Js(doc.Tips()).GetArrayLength() == 0, "branches: tips are not []");
        var root = Ids(doc.Log())[^1];
        doc.BranchNew("early", root);   // with `at` the head stays where it is
        Must(BranchTips(doc)["early"] == root && CurrentBranch(doc) == "main", "branches: branch_new at the root moved the head or missed the root");
    }
    // The log's order and messages.
    using (var doc = new Document())
    {
        DocAdd(doc, "profile.rect", "\"id\": \"r1\", \"w\": 1, \"h\": 1", "first");
        DocAdd(doc, "profile.rect", "\"id\": \"r2\", \"w\": 2, \"h\": 2");
        DocAdd(doc, "profile.rect", "\"id\": \"r3\", \"w\": 3, \"h\": 3", "third");
        var log = Js(doc.Log()).EnumerateArray().ToArray();
        Must(log.Select(Message).SequenceEqual(new[] { "third", null, "first", null }), "log: the messages, newest first, the root last");
        Must(log.Take(3).Select(c => c.GetProperty("ops")[0].GetProperty("node").GetProperty("id").GetString()).SequenceEqual(new[] { "r3", "r2", "r1" }), "log: the ops");
        Must(log[0].GetProperty("id").GetString() == Head(doc) && Parents(log[0]).SequenceEqual(new[] { log[1].GetProperty("id").GetString() })
             && Parents(log[3]).Length == 0, "log: the head and the parents");
    }
    // Switching by name and by commit id.
    using (var doc = Plate())
    {
        var first = Ids(doc.Log())[1];   // the commit that added r1
        doc.BranchNew("side");
        DocAdd(doc, "profile.circle", "\"id\": \"c1\", \"r\": 2");
        Must(CurrentBranch(doc) == "side" && Has(doc, "c1"), "switch: c1 is not on side");
        doc.Switch("main");
        Must(CurrentBranch(doc) == "main" && !Has(doc, "c1") && Has(doc, "x1"), "switch: main has c1, or lost x1");
        doc.Switch("side");
        Must(Has(doc, "c1"), "switch: side lost c1");
        // A commit id detaches the head.
        doc.Switch(first);
        Must(CurrentBranch(doc) is null && Head(doc) == first, "switch: a commit id did not detach the head");
        Must(Has(doc, "r1") && !Has(doc, "x1") && !Has(doc, "c1"), "switch: the nodes did not follow the commit");
        Must(BranchTips(doc)["main"] != first && !CanRedo(doc), "switch: no branch to redo along");
        doc.Switch("main");
        Must(CurrentBranch(doc) == "main" && Has(doc, "x1"), "switch: back on main");
    }
    // The tips after an undo and an edit.
    using (var doc = Plate())
    {
        Must(Js(doc.Tips()).GetArrayLength() == 0, "tips: a plate has tips");
        var old = Js(doc.Log())[0];
        var oldId = old.GetProperty("id").GetString()!;
        Must(doc.Undo(), "tips: the undo");
        DocAdd(doc, "profile.circle", "\"id\": \"c1\", \"r\": 2", "other way");
        var tips = Js(doc.Tips()).EnumerateArray().ToArray();
        Must(tips.Select(t => t.GetProperty("id").GetString()).SequenceEqual(new[] { oldId }), "tips: the abandoned commit is not the one tip");
        Must(tips[0].GetProperty("ops")[0].GetProperty("node").GetProperty("id").GetString() == "x1", "tips: a tip is not a whole commit");
        Must(Parents(tips[0]).SequenceEqual(new[] { Ids(doc.Log())[1] }) && Parents(tips[0]).SequenceEqual(Parents(old)), "tips: the tip's parents");
        Must(Message(Js(doc.Log())[0]) == "other way" && Head(doc) != oldId, "tips: the head");
        // The abandoned line is still reachable by its commit id.
        doc.Switch(oldId);
        Must(Has(doc, "x1") && !Has(doc, "c1"), "tips: switching to the tip");
        doc.Switch("main");
        doc.BranchNew("kept", oldId);   // naming the line takes it off the tips
        Must(Js(doc.Tips()).GetArrayLength() == 0, "tips: a named line is still a tip");
    }
    Console.WriteLine("document: branches, the log, switching and tips");
}

// 8. Batch and preview, and the drag.
static void DocumentBatchPreview()
{
    using (var doc = Plate())
    {
        var before = Js(doc.Log()).GetArrayLength();
        var live = false;
        doc.Batch("slot and fillet", () =>
        {
            DocAdd(doc, "profile.circle", "\"id\": \"c1\", \"r\": 2");
            DocAdd(doc, "profile.circle", "\"id\": \"c2\", \"r\": 3");
            live = Has(doc, "c2");
        });
        Must(live, "batch: the ops are not live inside the batch");
        var log = Js(doc.Log());
        Must(log.GetArrayLength() == before + 1 && Message(log[0]) == "slot and fillet" && log[0].GetProperty("ops").GetArrayLength() == 2, "batch: not one commit with the message");
        Must(doc.Undo() && !Has(doc, "c1") && !Has(doc, "c2"), "batch: one undo does not take the batch back");
        doc.Batch(() => { });
        Must(Js(doc.Log()).GetArrayLength() == before, "batch: an empty batch recorded something");
    }
    using (var doc = Plate())
    {
        var (before, log) = (doc.Save(), doc.Log());
        var thrown = false;
        try
        {
            doc.Batch("never", () =>
            {
                DocAdd(doc, "profile.circle", "\"id\": \"c1\", \"r\": 2");
                doc.Apply(DocSet("r1", "\"w\": 20"));
                throw new DivideByZeroException();
            });
        }
        catch (DivideByZeroException) { thrown = true; }
        Must(thrown, "batch: the body's exception did not come out");
        Must(doc.Save() == before && doc.Log() == log, "batch: the exception did not roll the batch back");
        Must(!Has(doc, "c1") && Approx(Volume(doc, "x1"), 1000), "batch: c1 or the wider r1 survived the rollback");
        // A refusal inside a batch is the same: it propagates, and the batch is undone.
        var refused = DocRefused(() => doc.Batch(() =>
        {
            DocAdd(doc, "profile.circle", "\"id\": \"c1\", \"r\": 2");
            doc.Apply("{\"op\": \"remove\", \"id\": \"r1\"}");
        }));
        Must(refused.StartsWith("document_apply: ") && doc.Save() == before, "batch: a refusal inside did not roll back");
        // The batch is closed, so a new one opens.
        doc.Batch("again", () => DocAdd(doc, "profile.circle", "\"id\": \"c1\", \"r\": 2"));
        Must(Message(Js(doc.Log())[0]) == "again", "batch: a batch after a rollback");
        // The body's exception is the one reported, even when the clean-up is refused.
        Exception? got = null;
        try { doc.Batch(() => { doc.Dispose(); throw new DivideByZeroException(); }); }
        catch (Exception e) { got = e; }
        Must(got is DivideByZeroException, $"batch: a refused clean-up replaced the body's exception with {got?.GetType().Name}: {got?.Message}");
    }
    using (var doc = Plate())
    {
        var nested = "";
        doc.Batch(() => nested = DocRefused(() => doc.Batch(() => { })));
        Must(nested.StartsWith("document_batch_begin: "), $"batch: a nested batch reads '{nested}'");
    }
    using (var doc = Plate())
    {
        var (before, log) = (doc.Save(), doc.Log());
        var (inside, circle) = (0.0, false);
        doc.Preview(() =>
        {
            doc.Apply(DocSet("r1", "\"w\": 30"));
            DocAdd(doc, "profile.circle", "\"id\": \"c1\", \"r\": 2");
            inside = Volume(doc, "x1");
            circle = Has(doc, "c1");
        });
        Must(Approx(inside, 30 * 10 * 10) && circle, $"preview: inside, x1 reads {inside}");
        Must(doc.Save() == before && doc.Log() == log, "preview: the preview was recorded");
        Must(Approx(Volume(doc, "x1"), 1000) && !Has(doc, "c1"), "preview: the preview was not taken back");
        var thrown = false;
        try { doc.Preview(() => { doc.Apply(DocSet("r1", "\"w\": 40")); throw new KeyNotFoundException("drag cancelled"); }); }
        catch (KeyNotFoundException) { thrown = true; }
        Must(thrown && doc.Save() == before && Approx(Volume(doc, "x1"), 1000), "preview: an exception did not take the preview back");
        Must(CanUndo(doc), "preview: the preview touched the history");
        Exception? got = null;
        try { doc.Preview(() => { doc.Dispose(); throw new KeyNotFoundException("drag cancelled"); }); }
        catch (Exception e) { got = e; }
        Must(got is KeyNotFoundException, $"preview: a refused clean-up replaced the body's exception with {got?.GetType().Name}");
    }
    using (var doc = Plate())
    {
        var nested = "";
        doc.Preview(() => nested = DocRefused(() => doc.Preview(() => { })));
        Must(nested.StartsWith("document_preview_begin: "), $"preview: a nested preview reads '{nested}'");
    }
    // The drag: each frame replaces the one before, relative to the state before the drag.
    using (var doc = Plate())
    {
        var (before, log) = (doc.Save(), doc.Log());
        doc.PreviewFrame(DocSet("r1", "\"w\": 30"));
        Must(Approx(Volume(doc, "x1"), 3000), $"drag: the first frame reads {Volume(doc, "x1")}");
        doc.PreviewFrame(DocSet("r1", "\"w\": 40"));
        Must(Approx(Volume(doc, "x1"), 4000), $"drag: the second frame reads {Volume(doc, "x1")} (frames stacked?)");
        doc.EndPreview();
        Must(Approx(Volume(doc, "x1"), 1000), $"drag: end_preview left {Volume(doc, "x1")}");
        Must(doc.Save() == before && doc.Log() == log, "drag: the drag was recorded");
    }
    Console.WriteLine("document: batch, preview and the drag");
}

// 9. Result types.
static void DocumentResultTypes()
{
    using var doc = new Document();
    DocAdd(doc, "profile.rect", "\"id\": \"r\", \"w\": 40, \"h\": 30");
    DocAdd(doc, "profile.circle", "\"id\": \"c\", \"r\": 5");
    DocAdd(doc, "profile.translate", "\"id\": \"m\", \"profile\": \"c\", \"by\": [20, 0]");
    DocAdd(doc, "profile.pieces", "\"id\": \"pieces\", \"profile\": \"r\", \"cutters\": [\"m\"]");
    DocAdd(doc, "curve.nurbs", "\"id\": \"k\", \"points\": [[0, 0, 0], [10, 5, 0], [20, -5, 0], [30, 0, 0]]");
    DocAdd(doc, "subd.cuboid", "\"id\": \"cage\", \"size\": [20, 10, 5], \"segments\": [2, 1, 1]");
    var plate = DocAdd(doc, "solid.extrude", "\"profile\": \"r\", \"frame\": \"xy\", \"distance\": 2");
    DocAdd(doc, "measure.mass", $"\"id\": \"mass\", \"solid\": \"{plate}\"");
    Must(States(doc.Evaluate()).Count(s => s == "ok") == 8, "types: not eight ok rows");
    Must(doc.ResultKind("r") == "profile", "types: r is not a profile");
    using (var r = doc.ResultProfile("r")) { }
    Must(doc.ResultKind("pieces") == "profiles", "types: pieces is not profiles");
    var pieces = doc.ResultProfiles("pieces");
    Must(pieces.Count >= 2, $"types: {pieces.Count} pieces");
    foreach (var p in pieces) p.Dispose();
    Must(doc.ResultKind("k") == "nurbs", "types: k is not nurbs");
    using (var curve = doc.ResultNurbsCurve("k")) Must(curve.Degree == 3, $"types: k has degree {curve.Degree}");
    Must(doc.ResultKind("cage") == "subd", "types: cage is not a subd");
    using (var cage = doc.ResultSubd("cage")) Must(cage.Positions.Length > 0, "types: the cage has no vertices");
    DocAdd(doc, "curve.polyline", "\"id\": \"outline\", \"points\": [[0, 0], [10, 0], [10, 5], [3, 9]], \"closed\": true");
    Must(doc.ResultKind("outline") == "curve", "types: outline is not a curve");
    var outline = Js(doc.Value("outline"));
    Must(outline.GetProperty("type").GetString() == "curve" && outline.GetProperty("closed").GetBoolean() && outline.EnumerateObject().Count() == 2,
         $"types: a plane curve's value reads {doc.Value("outline")}");
    Must(doc.ResultKind("mass") == "value" && Js(doc.Value("mass")).ValueKind == System.Text.Json.JsonValueKind.Object, "types: mass is not a value record");
    Must(doc.ResultKind("missing") == "none", "types: a missing node is not none");
    var why = DocRefused(() => doc.ResultProfiles(plate));
    Must(why.StartsWith("document_result_profile_count: "), $"types: result_profiles on a solid reads '{why}'");
    Console.WriteLine("document: profiles, a NURBS curve, a cage, a curve and a value");
}

// 10. Held geometry: a solid and a profile the caller already has, colours and all.
static void DocumentHeld()
{
    using var cutter0 = Solid.Cylinder(5, 60);
    using var cutter = cutter0.Translate(0, 0, -20);
    using var block = Solid.Cuboid(40, 30, 20);
    using var part = block.Cut(cutter);
    using var slot0 = Profile.Slot((0, 0), 30, 5);
    using var hole = Profile.Circle(2);
    using var slot = slot0.WithHole(hole);
    using var doc = new Document();
    var held = doc.AddSolid(part);
    var outline = doc.AddProfile(slot);
    DocAdd(doc, "solid.extrude", $"\"id\": \"x\", \"profile\": \"{outline}\", \"distance\": 4");
    DocAdd(doc, "solid.cut", $"\"id\": \"c\", \"target\": \"{held}\", \"tool\": \"x\"");
    Must(Js(doc.Errors()).GetArrayLength() == 0, $"held: errors {doc.Errors()}");
    // The very body: the same tables, every number to the bit.
    using (var back = doc.ResultSolid(held))
    {
        Must(back.DocumentBody() == part.DocumentBody(), "held: the body text differs");
        Must(back.Mass().Volume == part.Mass().Volume, "held: the volume differs to the bit");
    }
    // The profile is its segments, not a polyline: two arcs and the hole's circle.
    var path = slot.DocumentPath();
    var segments = Js(path).GetProperty("segments").EnumerateArray().Select(s => s.GetProperty("type").GetString()).ToArray();
    Must(segments.Count(t => t == "arc") == 2 && Js(path).GetProperty("holes").GetArrayLength() == 1, $"held: the path reads {path}");
    using (var back = doc.ResultProfile(outline)) Must(back.DocumentPath() == path, "held: the path text differs");
    using (var want = Workplane.Xy().Extrude(slot, 4).Solid())
        Must(Approx(Volume(doc, "x"), want.Mass().Volume, 1e-9), "held: the extruded slot's volume");
    Must(Volume(doc, "c") < part.Mass().Volume, "held: the cut did not cut");
    var text = doc.Save();
    using (var loaded = Document.Load(text))
    {
        Must(loaded.Save() == text, "held: save -> load -> save differs");
        using var back = loaded.ResultSolid(held);
        Must(back.Faces == part.Faces, "held: the loaded body's faces");
    }
    using (var square = Profile.Rect(10, 10))
    using (var face = Solid.Face(square, Frame.Xy()))
    {
        var sheet = doc.AddSolid(face, sheet: true);
        Must(doc.ResultKind(sheet) == "sheet", $"held: a sheet goes in as {doc.ResultKind(sheet)}");
        using var back = doc.ResultSolid(sheet);
        Must(back.Faces == 1, "held: the sheet has not one face");
    }
    Must(DocRefused(() => doc.Apply(Op("solid.body", "\"body\": \"not a body\""))).Contains("must be a body"), "held: a bad body is not refused");
    // Colours, through save and load.
    double[] red = { 1, 0, 0 }, green = { 0, 0.5, 0 }, blue = { 0, 0, 1 }, yellow = { 1, 1, 0 }, grey = { 0.25, 0.5, 0.75 };
    using var cube = Solid.Cuboid(1, 1, 1);
    using var c1 = cube.Coloured(1, 0, 0);
    using var c2 = c1.Coloured(0, 0.5, 0, face: 2);
    using var c3 = c2.EdgesColoured(0, 0, 1);
    using var painted = c3.EdgesColoured(1, 1, 0, edges: new[] { 3 });
    using var greySlot = slot0.Coloured(0.25, 0.5, 0.75);
    using var plain = Profile.Rect(2, 1);
    using var paints = new Document();
    var heldPaint = paints.AddSolid(painted);
    var greyId = paints.AddProfile(greySlot);
    var plainId = paints.AddProfile(plain);
    using var reread = Document.Load(paints.Save());
    using (var got = reread.ResultSolid(heldPaint))
    {
        Must(got.Colour!.SequenceEqual(red) && got.FaceColour(2)!.SequenceEqual(green) && got.FaceColour(0)!.SequenceEqual(red), "held: the face colours");
        Must(got.EdgeColour(3)!.SequenceEqual(yellow) && got.EdgeColour(0)!.SequenceEqual(blue), "held: the edge colours");
        Must(got.DocumentBody() == painted.DocumentBody(), "held: the painted body text");
    }
    using (var got = reread.ResultProfile(greyId)) Must(got.Colour!.SequenceEqual(grey), "held: the profile's colour");
    using (var got = reread.ResultProfile(plainId)) Must(got.Colour is null, "held: an uncoloured profile came back coloured");
    // A body written without colours (an older document's) is uncoloured.
    var bare = System.Text.Json.Nodes.JsonNode.Parse(painted.DocumentBody())!.AsObject();
    foreach (var key in new[] { "colour", "face_colours", "edges_colour", "edge_colours" }) bare.Remove(key);
    var bareId = DocAdd(reread, "solid.body", $"\"body\": {bare.ToJsonString()}");
    using (var got = reread.ResultSolid(bareId)) Must(got.Colour is null, "held: a body without colours came back coloured");
    Console.WriteLine("document: held solids, sheets and profiles, colours and all");
}

// 11. Building documents.
static Document BimWall()
{
    var doc = Document.NewBim("mm");
    doc.Apply("""
        {"op": "batch", "ops": [
            {"op": "add", "node": {"id": "l0", "kind": "bim.level", "name": "Ground"}},
            {"op": "add", "node": {"id": "part", "kind": "bim.wall_type", "name": "Partition",
                                   "layers": [{"material": "block", "thickness": 100, "function": "structure"}]}},
            {"op": "add", "node": {"id": "w1", "kind": "bim.wall", "level": "l0", "type": "part", "a": [0, 0], "b": [4000, 0]}}
        ]}
        """);
    return doc;
}
static void DocumentBim()
{
    const string ifc2x3 = "{\"schema\": \"IFC2X3\", \"timestamp\": 0}";
    using (var doc = BimWall())
    {
        var text = doc.ExportIfc(ifc2x3);
        Must(text.Contains("IFCWALLSTANDARDCASE("), "bim: the IFC2X3 export has no IFCWALLSTANDARDCASE");
        var file = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"cadaclysm-smoke-bim-{Guid.NewGuid():N}.json");
        try
        {
            File.WriteAllText(file, doc.Save(), new UTF8Encoding(false));
            using var opened = Document.OpenBim(file);
            Must(opened.ExportIfc(ifc2x3) == text, "bim: open_bim exports differently");
        }
        finally { File.Delete(file); }
        using (var loaded = Document.LoadBim(doc.Save())) Must(loaded.ExportIfc(ifc2x3) == text, "bim: load_bim exports differently");
        var exact = doc.ExportIfc("{\"geometry\": \"exact\", \"timestamp\": 0, \"name\": \"Wall\"}");
        Must(exact.Contains("IFCPROJECT(") && exact.Contains("'Wall'") && exact != text, "bim: the exact export");
        DocAdd(doc, "bim.door_type", "\"id\": \"d900\", \"width\": 900, \"height\": 2100");
        DocAdd(doc, "bim.door", "\"id\": \"o1\", \"host\": \"w1\", \"type\": \"d900\", \"joins\": [], \"offset\": 3900");
        var why = DocRefused(() => doc.ExportIfc("{\"timestamp\": 0}"));
        const string prefix = "bim_document_export_ifc: ";
        Must(why.StartsWith(prefix), $"bim: the door outside its wall reads '{why}'");
        Must(Js(why[prefix.Length..]).GetProperty("refusals")[0].GetProperty("node").GetString() == "o1", $"bim: the refusal does not name o1: '{why}'");
        Must(DocRefused(() => doc.ExportIfc("{\"schema\": \"IFC5\"}")).Contains("IFC4 or IFC2X3"), "bim: IFC5 is not refused");
    }
    using (var plain = new Document())
    {
        var why = DocRefused(() => plain.ExportIfc());
        Must(why.Contains("not a BIM document"), $"bim: a plain document's export reads '{why}'");
    }
    var names = Js(Document.BimKinds()).EnumerateArray().Select(k => k.GetProperty("name").GetString()).ToHashSet();
    Must(names.IsSupersetOf(new[] { "bim.project", "bim.wall", "solid.extrude" }), "bim: bim_kinds lacks rows");
    static string Guid4(Document doc) => Js(doc.Save()).GetProperty("nodes").EnumerateArray()
        .First(n => n.GetProperty("kind").GetString() == "bim.project").GetProperty("guid").GetString()!;
    using var a = Document.NewBim();
    using var b = Document.NewBim();
    var (ga, gb) = (Guid4(a), Guid4(b));
    Must(ga.Length == 36 && ga[14] == '4' && ga != gb, $"bim: project guids {ga}, {gb}");
    Console.WriteLine("document: building documents export IFC; refusals by node");
}

// 12. Lifetime: results outlive the document; a closed document refuses.
static void DocumentLifetime()
{
    var doc = Plate();
    DocAdd(doc, "curve.nurbs", "\"id\": \"k\", \"points\": [[0, 0, 0], [10, 5, 0], [20, -5, 0], [30, 0, 0]]");
    DocAdd(doc, "subd.cuboid", "\"id\": \"cage\", \"size\": [20, 10, 5], \"segments\": [2, 1, 1]");
    using var solid = doc.ResultSolid("x1");
    using var profile = doc.ResultProfile("r1");
    using var curve = doc.ResultNurbsCurve("k");
    using var cage = doc.ResultSubd("cage");
    doc.Dispose();
    GC.Collect();
    GC.WaitForPendingFinalizers();
    Must(solid.Faces == 6 && Approx(solid.Mass().Volume, 1000), "lifetime: the solid died with its document");
    Must(profile.DocumentPath().Contains("segments") && curve.Degree == 3 && cage.Positions.Length > 0, "lifetime: a result died with its document");
    Must(doc.Closed, "lifetime: a disposed document is not closed");
    string closed = "";
    try { doc.Save(); }
    catch (ObjectDisposedException e) { closed = e.Message; }
    Must(closed.StartsWith("document: closed"), $"lifetime: a closed document's save reads '{closed}'");
    doc.Dispose();   // twice is fine
    Must(doc.ToString() == "Document(closed)", "lifetime: a closed document's name");
    Console.WriteLine("document: results outlive their document; a closed one refuses");
}

/// <summary>A document check that failed, with what it found.</summary>
sealed class DocCheckFailed : Exception
{
    public DocCheckFailed(string why) : base(why)
    {
    }
}
