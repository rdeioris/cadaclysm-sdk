// Open one file through the C# binding and check what comes back; then build the
// blacksmith's plate and read it back through the reader. Exit code is the verdict.
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
    Console.WriteLine($"sheet verbs: face, trim ({holed.Faces}+{disc.Faces}), face_sheet, drop_faces, round ({slab.Faces} faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, spline: ok");
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
var first = rounded.Mesh(0.05);
var triangles0 = first.TriangleCount;
rounded.Mesh(0.5);
rounded.Mesh(0.05);
try
{
    _ = first.Positions;
    return Fail("a stale mesh view read freed memory after meshing at 0.05, 0.5, 0.05");
}
catch (InvalidOperationException)
{
}
Console.WriteLine($"mesh at 0.05: {triangles0} triangles; the first view is stale after 0.05, 0.5, 0.05");
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
return 0;

static int Fail(string why) { Console.Error.WriteLine(why); return 1; }
