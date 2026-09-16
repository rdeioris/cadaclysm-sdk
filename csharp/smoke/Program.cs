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
// solid is "solid", not "mesh" -- confirmed by probing it directly, and noted in the report.
var matched = scene.Query("class == solid");
Console.WriteLine($"query: {matched.Count} node(s)");
Console.WriteLine($"diagnostics: {scene.Diagnostics.Count}");
using (var again = Cadaclysm.Cadaclysm.OpenMemory(File.ReadAllBytes(path), System.IO.Path.GetFileName(path)))
    if (again.Bounds.Max[2] != bounds.Max[2]) return Fail("open_memory disagrees with open");
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
if (!rounded.IsWatertight()) return Fail("the filleted part is not watertight");
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
var step = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cadaclysm-smoke.stp");
rounded.Step(step);
using (var back = Cadaclysm.Cadaclysm.Open(step))
{
    var b = back.Bounds;
    Console.WriteLine($"step read back: bounds max=({b.Max[0]},{b.Max[1]},{b.Max[2]})");
    // The plate is 80 x 40 x 6, `Profile.Rect` centring it on the origin, and the pin adds 10.
    if (Math.Abs(b.Max[2] - 16) > 0.01 || Math.Abs(b.Max[0] - 40) > 0.01) return Fail("the STEP did not read back as the plate with its pin");
}
return 0;

static int Fail(string why) { Console.Error.WriteLine(why); return 1; }
