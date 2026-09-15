// Open one file through the C# binding and check what comes back. Exit code is the
// verdict: the release pipeline runs this against every library it ships.
using Cadaclysm;

var path = args.Length > 0 ? args[0] : "samples/cube.scad";
var license = args.Length > 1 ? args[1] : null;
if (license is not null && !Scene.LicenseSet(license))
    return Fail($"license: {Scene.LastError()}");
Console.WriteLine($"cadaclysm {Scene.Version()} built {Scene.BuildDate()}");
Console.WriteLine($"license: {Scene.LicenseInfo() ?? "none (" + Scene.LastError() + ")"}");

using var scene = Scene.Open(path, null);
if (scene is null) return Fail($"{path}: {Scene.LastError()}");
var (min, max) = scene.Bounds();
Console.WriteLine($"bounds min=({min[0]},{min[1]},{min[2]}) max=({max[0]},{max[1]},{max[2]})");
uint triangles = 0;
for (uint node = 0; node < scene.NodeCount; node++)
{
    if (!scene.CanMesh(node)) continue;
    var mesh = scene.Mesh(node);
    if (mesh is null) continue;
    triangles += (uint)(mesh.Value.Indices.Length / 3);
}
Console.WriteLine($"triangles={triangles}");
// All six bounds, not just two corners of them: a bug on the Y axis alone would
// otherwise print wrong numbers and still exit 0.
if (path.EndsWith("cube.scad") &&
    (!min.SequenceEqual(new float[] { 0, 0, 0 }) || !max.SequenceEqual(new float[] { 20, 20, 20 }) || triangles != 12))
    return Fail("the cube did not come back as a 20-unit cube of 12 triangles");
return 0;

static int Fail(string why) { Console.Error.WriteLine(why); return 1; }
