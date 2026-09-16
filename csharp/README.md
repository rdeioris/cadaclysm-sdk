# C#

`Cad.cs` is the whole binding: add it to your project (`<Compile Include="Cad.cs" />`)
and ship the library beside your executable, or put it in `../lib/` while
developing here. `CADACLYSM_LIBRARY` (the file or its directory) overrides the
search. `smoke/` is a complete console program:

    dotnet run --project csharp/smoke -- samples/cube.scad path/to/cadaclysm.lic

Coverage: the viewer subset of the C API (opening, walking, meshing, colours,
attributes) plus the license calls; the exact count is in each release's
notes, and `include/cadaclysm.h` is the reference for adding a `[DllImport]`.

## The kernel

`Blacksmith.cs` binds the exact-geometry kernel the same way: add it beside
`Cad.cs` (`smoke/smoke.csproj` already compiles both). It keeps its own
license state, so a process using both libraries licenses each one:

    using var rect = Profile.Rect(80, 40);
    using var hole = Profile.Circle(4);
    using var outline = rect.WithHole(hole);
    using var plate = Workplane.Xy().Extrude(outline, 6).Solid();
    using var pin = Workplane.FromSolid(plate).Faces(Selector.Max(Axis.Z)).OnFace().Cylinder(5, 10).Solid();
    using var part = plate.Join(pin);
    using var rounded = part.Fillet(corners, 1.0);
    rounded.Step("part.stp");

A mesh or a polyline is a view onto the solid's own cache, not a copy: it
dies when the solid is disposed, and it goes stale in place too -- meshing
the solid again at a different tolerance frees the memory an earlier view
still points at, so reading that view throws `InvalidOperationException`
even after re-meshing back at the tolerance it was taken at.

Coverage: the exact-geometry subset of the blacksmith C API (profiles,
workplanes, booleans, fillets, meshing, STEP) plus its own license calls;
the exact count is in each release's notes, and
`include/cadaclysm_blacksmith.h` is the reference for adding a `[DllImport]`.
