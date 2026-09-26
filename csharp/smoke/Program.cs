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
if (path.EndsWith("cube.scad") && (scene.Links.Count != 0 || scene.Joints.Count != 0)) return Fail("the cube scene has links or joints");
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
    Console.WriteLine($"sheet verbs: face, trim ({holed.Faces}+{disc.Faces}), face_sheet, drop_faces, round ({slab.Faces} faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, star, text, spline, parabola: ok");
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
// A mesh view is tied to one filling of the solid's cache: meshing at another tolerance and
// back again replaces that memory, and the first view must refuse to read it.
var firstMesh = rounded.Mesh(0.05);
var triangles0 = firstMesh.TriangleCount;
rounded.Mesh(0.5);
rounded.Mesh(0.05);
try
{
    _ = firstMesh.Positions;
    return Fail("a stale mesh view read freed memory after meshing at 0.05, 0.5, 0.05");
}
catch (InvalidOperationException)
{
}
Console.WriteLine($"mesh at 0.05: {triangles0} triangles; the first view is stale after 0.05, 0.5, 0.05");
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
        if (!femMesh.Watertight || femMesh.OpenEdges.Count != 0 || femMesh.FoldedEdges.Count != 0)
            return Fail($"fem: the closed cube reads {femMesh.OpenEdges.Count} cracks and {femMesh.FoldedEdges.Count} folds");
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
                      + " a freed mesh refuses all seventeen reads");
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
    if (fem.OpenEdges.Count != 0 || fem.FoldedEdges.Count != 0) return Fail($"kernel fem: a watertight solid reads {fem.OpenEdges.Count} cracks");
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
                 () => { _ = freed.FoldedEdges; }, () => { _ = freed.Watertight; }, () => { _ = freed.FromMesh; },
                 () => { _ = freed.MinAngle; }, () => { _ = freed.WorstTriangle; }, () => { _ = freed.LongestEdge; },
                 () => freed.MshText(), () => freed.SaveMsh(kernelMshPath),
             })
    {
        try { read(); return Fail("kernel fem: a freed mesh read anyway"); }
        catch (BuildException e) when (e.Message.Contains("freed")) { }
    }
    Console.WriteLine("kernel fem: a freed mesh refuses all seventeen reads");
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
Console.WriteLine("svg: scene and node text, file written, fov=200 refused");

var solidSvgText = rounded.SvgText();
if (!solidSvgText.StartsWith("<svg") || !solidSvgText.Contains("<path")) return Fail("solid SVG text did not look like an SVG wireframe");
var solidSvgPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke-solid.svg");
rounded.Svg(solidSvgPath);
if (new FileInfo(solidSvgPath).Length == 0) return Fail("Solid.Svg wrote an empty file");
try { rounded.SvgText(new Cadaclysm.Blacksmith.SvgOptions { Fov = 200 }); return Fail("blacksmith svg: fov=200 was accepted"); }
catch (BuildException) { }
Console.WriteLine("blacksmith svg: solid text, file written, fov=200 refused");

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
return 0;

static int Fail(string why) { Console.Error.WriteLine(why); return 1; }
static double Norm(double[] v) => Math.Sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
static int CountOf(string haystack, string needle) => (haystack.Length - haystack.Replace(needle, "").Length) / needle.Length;
