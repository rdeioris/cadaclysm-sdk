# C#

`Cad.cs` is the whole binding: add it to your project (`<Compile Include="Cad.cs" />`)
and ship the library beside your executable, or put it in `../lib/` while
developing here. `CADACLYSM_LIBRARY` (the file or its directory) overrides the
search. `smoke/` is a complete console program:

    dotnet run --project csharp/smoke -- samples/cube.scad path/to/cadaclysm.lic

Coverage: the viewer subset of the C API (opening, walking, meshing, colours,
attributes) plus the license calls; the exact count is in each release's
notes, and `include/cadaclysm.h` is the reference for adding a `[DllImport]`.
