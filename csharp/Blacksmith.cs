// The cadaclysm_blacksmith C ABI, as C# objects: this file is the whole kernel binding.
//
//     using Cadaclysm.Blacksmith;
//     using var outline = Profile.Rect(80, 40).WithHole(Profile.Circle(4));
//     using var plate = Workplane.Xy().Extrude(outline, 6).Solid();
//     using var pin = Workplane.FromSolid(plate)
//         .Faces(Selector.Max(Axis.Z)).OnFace()           // Python's .workplane()
//         .Cylinder(5, 10).Solid();                       // seated over the hole, on material
//     using var part = plate.Join(pin);
//     var corners = part.Edges.Where(e => e.IsLine && Math.Abs(e.Direction![2]) > 0.99
//                                         && e.Faces.All(f => part.FaceKind(f) == "plane"));
//     using var rounded = part.Fillet(corners, 1.0);
//     rounded.Step("plate.stp");
//     var mesh = rounded.Mesh(tolerance: 0.05);
//
// Declared by hand from the published header `include/cadaclysm_blacksmith.h`, on the object
// model of `cadaclysm_blacksmith.py` -- the same names, arguments and defaults, member for
// member -- the way any .NET program would: no generated interop, no Rust, no build system.
// It finds its library the way `cadaclysm_blacksmith.py` does: point
// `CADACLYSM_BLACKSMITH_LIBRARY` at the library or the directory holding it if it is not
// where the loader looks by default (see `BlacksmithLoader`). `CADACLYSM_LIBRARY` is the
// reader's, as it is in Python.
//
// ## Every array borrows from its solid
//
// `Solid.Mesh` and `Solid.EdgePolylines` hand back `ReadOnlySpan<T>` views into the library's
// own cache rather than copies, as the reader's `Mesh` does. Two things invalidate a view:
// disposing the solid, which frees the handle; and meshing the same solid again (through
// `Mesh`, `EdgePolylines` or `BoundsAt`) at a *different* tolerance, which replaces the cache
// the earlier views point into -- and going back to the first tolerance does not bring the
// old memory back. Python reads freed memory in either case; here the view remembers which
// filling of the cache it was cut from and throws instead. Call `Copy()` on any view that
// must outlive either. Strings are copied on the way out and are always safe.
//
// `FemMesh` is the one array product that is **not** the solid's. `Solid.FemMesh(..)` hands back a
// handle of its own, and its spans belong to that handle: neither the solid's dispose nor meshing
// it again touches them, and only `FemMesh.Free()` — or the `using` that runs it — invalidates
// them. The guard is weaker than `Solid.Mesh`'s, and deliberately so: a span **asked for** after
// that throws, while one already in hand goes on reading the freed block and hands back plausible
// numbers, a `ReadOnlySpan<T>` having nothing left to check once it is made. `ToArray()` anything
// that must outlive the handle.
//
// ## The chain mirrors the Rust `Workplane`
//
// A build call (`Cuboid`, `Cylinder`, `Extrude`, `ExtrudeTapered`, `Revolve`, `Sweep`,
// `Loft`) makes a fresh `Solid`; combining two solids is explicit -- build the pin as its own
// solid, then `plate.Join(pin)`. Every step throws `BuildException` at once with the library's
// own text, rather than latching the first error until some final call.
//
// `Join`/`Cut`/`Common` default their `tolerance` to `0.05`, not the tighter `1e-6` `Fillet`,
// `Chamfer` and `Shell` use, for cost: a boolean meshes both solids at its tolerance, and a
// curved solid at `1e-6` is hundreds of thousands of triangles. `0.05` is what the crate's own
// boolean tests run at; a tighter one is as correct, only slower.
//
// ## Ownership
//
// `Profile`, `Path`, `SweepPath` and `Solid` own a C handle, held in a `SafeHandle` (see
// `CadaclysmHandle` in `Cad.cs`): dispose them (a `using`), or let the runtime free them.
// Every entry point takes the `SafeHandle` itself, so the marshaller keeps an operand alive
// for the length of the call it is read in -- `Solid.Cuboid(..).Join(Solid.Cylinder(..))` is
// safe with the cylinder nobody's. `Workplane`, `Selector`, `Slant`, `Edge` and `Axis` are
// plain values. A call on a disposed object throws `ObjectDisposedException`. Python's
// `Solid.close()`/`SweepPath.close()` are `Dispose()` here. The progress callbacks Python's
// `join`/`cut`/`common`/`split_sheet`/`fillet`/`shell` accept are not offered: a C# delegate
// over the C callback is out of this binding's scope, and every call runs silent.
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace Cadaclysm.Blacksmith;

/// <summary>What the library refused, in its own words (`cadaclysm_blacksmith_last_error`).
/// </summary>
public sealed class BuildException : Exception
{
    public BuildException(string message) : base(message)
    {
    }
}

// ---- SVG ---------------------------------------------------------------------------------

/// <summary>One of the seven camera angles <see cref="SvgOptions.View"/> understands -- the
/// same table the reader's `Cadaclysm.SvgView` gives, kept separate because this file is the
/// whole kernel binding on its own.</summary>
public enum SvgView
{
    /// <summary>Azimuth -90, elevation 0 -- looks from -Y.</summary>
    Front,
    /// <summary>Azimuth 90, elevation 0 -- looks from +Y.</summary>
    Back,
    /// <summary>Azimuth 180, elevation 0 -- looks from -X.</summary>
    Left,
    /// <summary>Azimuth 0, elevation 0 -- looks from +X.</summary>
    Right,
    /// <summary>Azimuth -90, elevation 90 -- looks from +Z, straight down.</summary>
    Top,
    /// <summary>Azimuth -90, elevation -90 -- looks from -Z, straight up.</summary>
    Bottom,
    /// <summary>Azimuth -50, elevation 28 -- the viewer's own default.</summary>
    Iso,
}

/// <summary>Degrees (azimuth, elevation) for each <see cref="SvgView"/>.</summary>
public static class SvgViewAngles
{
    private static readonly Dictionary<SvgView, (double Azimuth, double Elevation)> Table = new()
    {
        [SvgView.Front] = (-90.0, 0.0),
        [SvgView.Back] = (90.0, 0.0),
        [SvgView.Left] = (180.0, 0.0),
        [SvgView.Right] = (0.0, 0.0),
        [SvgView.Top] = (-90.0, 90.0),
        [SvgView.Bottom] = (-90.0, -90.0),
        [SvgView.Iso] = (-50.0, 28.0),
    };

    /// <summary>This view's (azimuth, elevation) in degrees.</summary>
    public static (double Azimuth, double Elevation) For(SvgView view) => Table[view];
}

/// <summary>How an SVG drawing is made -- the camera in the viewer's words, the page, the pen
/// and which line sets. Mirrors `CadaclysmBlacksmithSvgOptions`, defaulted the way
/// `cadaclysm_blacksmith_svg_options_init` defaults the struct, with <see cref="View"/>
/// supplying <see cref="Azimuth"/>/<see cref="Elevation"/> unless they are set directly.
/// </summary>
/// <remarks>Passed to <see cref="Blacksmith.WriteSvgText"/>, <see
/// cref="Blacksmith.WriteSvg"/> and <see cref="Solid.SvgText"/>/<see cref="Solid.Svg"/>. A
/// refused option (an out-of-range <see cref="Fov"/>, say) throws <see cref="BuildException"/>
/// naming the field, worded by the library itself. No scene convention to default <see
/// cref="Up"/> from here -- a solid's own frame is Z up unless <see cref="Up"/> says
/// otherwise.</remarks>
public sealed class SvgOptions
{
    /// <summary>front back left right top bottom iso -- fills <see cref="Azimuth"/>/<see
    /// cref="Elevation"/> unless they are set directly. Default Iso.</summary>
    public SvgView View { get; set; } = SvgView.Iso;

    /// <summary>Degrees about the up axis from +X, overriding <see cref="View"/>'s. -90 looks
    /// from -Y, the front.</summary>
    public double? Azimuth { get; set; }

    /// <summary>Degrees above the horizon, overriding <see cref="View"/>'s.</summary>
    public double? Elevation { get; set; }

    /// <summary>"y" or "z"; default "z", a solid carrying no convention of its own.</summary>
    public string? Up { get; set; }

    /// <summary>Vertical field of view in degrees; 0 (the default) is orthographic.</summary>
    public double Fov { get; set; } = 0.0;

    /// <summary>The page's viewBox width, page units. Default 1000.</summary>
    public double Width { get; set; } = 1000.0;

    /// <summary>The page's viewBox height, page units. Default 1000.</summary>
    public double Height { get; set; } = 1000.0;

    /// <summary>Fraction of the content's extent left each side. Default 0.05.</summary>
    public double Margin { get; set; } = 0.05;

    /// <summary>How far a written curve may stray, in page units. Default 0.1.</summary>
    public double Tolerance { get; set; } = 0.1;

    /// <summary>The pen colour, `'#rrggbb'`. Default black.</summary>
    public string Stroke { get; set; } = "#000000";

    /// <summary>The pen's width, page units. Default 1.</summary>
    public double StrokeWidth { get; set; } = 1.0;

    /// <summary>`0xRRGGBB`, or null (the default) for no `&lt;rect&gt;` behind the drawing.
    /// </summary>
    public uint? Background { get; set; }

    /// <summary>Each shape's feature edges. Default true.</summary>
    public bool Edges { get; set; } = true;

    /// <summary>A solid has no free curves of its own; accepted and ignored. Default false.
    /// </summary>
    public bool Curves { get; set; } = false;

    /// <summary>A solid has no isocurves of its own either; accepted and ignored. Default
    /// false.</summary>
    public bool Isocurves { get; set; } = false;

    /// <summary>Write every line as straight segments within <see cref="Tolerance"/>, instead
    /// of being fitted back to cubic Béziers. Default false.</summary>
    public bool Polylines { get; set; } = false;
}

// ---- the structs the ABI returns by value ----------------------------------------------
//
// These four are transcribed from `cadaclysm_blacksmith.h` by hand, in the header's field
// order, and `tests/bindings.rs` pins them against it, by field order and by whether each
// field is a pointer, as it pins the reader's structs in `Cad.cs`. A field left out or
// reordered still compiles and reads every later field from the wrong offset; the pin is
// what catches it.

/// <summary>`CadaclysmBlacksmithMesh`: a solid's triangles, borrowed from it.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithMesh
{
    public IntPtr Positions;
    public IntPtr Normals;
    public IntPtr Indices;
    public uint VertexCount;
    public uint IndexCount;
}

/// <summary>`CadaclysmBlacksmithMesh64`: the same tessellation as <see
/// cref="RawBlacksmithMesh"/> (the index pointer is the very one the library's f32 call
/// gives), positions and normals unnarrowed.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithMesh64
{
    public IntPtr Positions;
    public IntPtr Normals;
    public IntPtr Indices;
    public uint VertexCount;
    public uint IndexCount;
}

/// <summary>`CadaclysmBlacksmithPolylines`: polyline `i` is `Points[Offsets[i] ..
/// Offsets[i + 1]]`, three floats a point; `Offsets` has `PolylineCount + 1` entries.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithPolylines
{
    public IntPtr Points;
    public IntPtr Offsets;
    public uint PointCount;
    public uint PolylineCount;
}

/// <summary>`CadaclysmBlacksmithColours`: one colour per edge polyline, three doubles each
/// (`-1` where the polyline is on no coloured edge); `Rgb` null and `Count` 0 where the solid
/// has no edge paint.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithColours
{
    public IntPtr Rgb;
    public uint Count;
}

/// <summary>`CadaclysmBlacksmithFaceTriangles`: triangles per face, in face order, over the
/// solid's mesh at the same tolerance.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithFaceTriangles
{
    public IntPtr Counts;
    public uint FaceCount;
}

/// <summary>`CadaclysmBlacksmithEdge`: one edge, borrowed from its solid. The C struct has
/// four bytes of padding after each count, which sequential layout reproduces on its own.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithEdge
{
    public IntPtr Kind;
    public IntPtr Faces;
    public uint FaceCount;
    public IntPtr Segments;
    public uint SegmentCount;
}

/// <summary>`CadaclysmBlacksmithPoint`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithPoint
{
    public double X;
    public double Y;
    public double Z;
}

/// <summary>`CadaclysmBlacksmithSpot`: four bytes of padding after `Face`, which sequential
/// layout reproduces.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithSpot
{
    public uint LoopIndex;
    public uint Segment;
    public double T;
    public uint Face;
    public double U;
    public double V;
}

/// <summary>`CadaclysmBlacksmithHit`, copied out by value: six bytes of padding after the two
/// one-byte bools, which sequential layout reproduces.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithHit
{
    [MarshalAs(UnmanagedType.I1)] public bool Run;
    [MarshalAs(UnmanagedType.I1)] public bool Touch;
    public RawBlacksmithPoint Start;
    public RawBlacksmithPoint End;
    public RawBlacksmithSpot AStart;
    public RawBlacksmithSpot AEnd;
    public RawBlacksmithSpot BStart;
    public RawBlacksmithSpot BEnd;
}

/// <summary>`CadaclysmBlacksmithCurve`: one edge's exact curve, borrowed from its solid. Four
/// bytes of padding after `Degree` and after each count, which sequential layout reproduces.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithCurve
{
    public IntPtr Kind;
    public RawBlacksmithPoint Origin;
    public RawBlacksmithPoint X;
    public RawBlacksmithPoint Y;
    public RawBlacksmithPoint Z;
    public double Radius;
    public double Radius2;
    public double T0;
    public double T1;
    public uint Degree;
    public IntPtr Knots;
    public uint KnotCount;
    public IntPtr Poles;
    public uint PoleCount;
    public IntPtr Weights;
}

/// <summary>`CadaclysmBlacksmithChain`: one branch of one face pair's crossing, borrowed from
/// the intersection result. One byte of padding after `HasCurve`, which sequential layout
/// reproduces.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithChain
{
    public IntPtr Points;
    public uint PointCount;
    public uint FaceA;
    public uint FaceB;
    [MarshalAs(UnmanagedType.I1)] public bool Closed;
    [MarshalAs(UnmanagedType.I1)] public bool Tangent;
    [MarshalAs(UnmanagedType.I1)] public bool HasCurve;
}

/// <summary>`CadaclysmBlacksmithOverlap`: a coincident face pair's shared region, borrowed
/// from the intersection result.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithOverlap
{
    public uint FaceA;
    public uint FaceB;
    public IntPtr Points;
    public IntPtr LoopOffsets;
    public uint PointCount;
    public uint LoopCount;
}

/// <summary>`CadaclysmBlacksmithSvgOptions`. Field order and `Size` are the contract, as the
/// four structs above: `cadaclysm_blacksmith_svg_options_init` fills the library's whole
/// struct, so this must match the header field for field and may never reorder.
/// `tests/bindings.rs` pins it against `cadaclysm_blacksmith.h`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithSvgOptions
{
    public uint Size;
    public uint Up;
    public double Azimuth;
    public double Elevation;
    public double Fov;
    public double Width;
    public double Height;
    public double Margin;
    public double Tolerance;
    public double StrokeWidth;
    public uint Stroke;
    public uint Background;
    public uint Flags;
}

/// <summary>`CadaclysmBlacksmithFemOptions`. Field order and `Size` are the whole contract, as
/// <see cref="RawBlacksmithSvgOptions"/> above: `cadaclysm_blacksmith_fem_options_init` fills the
/// library's <em>whole</em> struct, so this must match the header field for field and may never
/// reorder. A field the library has and this one does not is written past what <see
/// cref="Solid.FemMesh"/> allocated. `tests/bindings.rs` pins it against
/// `cadaclysm_blacksmith.h`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithFemOptions
{
    public nuint Size;
    public double Tolerance;
    public double MaxSize;
}

/// <summary>`CadaclysmBlacksmithFemMeshView`: every pointer borrowed from the FEM handle and dead
/// with it, the counts in elements (`Nodes` holds `NodeCount * 3` doubles). Pinned against the
/// header by `cadaclysm-capi/tests/bindings.rs`, which is the only thing between a missing field
/// here and reading `MinAngle` out of `Watertight`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithFemMeshView
{
    public IntPtr Nodes;
    public uint NodeCount;
    public IntPtr Triangles;
    public uint TriangleCount;
    public IntPtr TriangleFace;
    public IntPtr NodeKind;
    public IntPtr NodeEntity;
    public uint FaceCount;
    public uint EdgeCount;
    public uint VertexCount;
    public uint OpenEdgeCount;
    public uint FoldedEdgeCount;
    // One byte in C, four in C# unless it is told otherwise -- and `MinAngle` below is what a
    // missing hint would be read out of.
    [MarshalAs(UnmanagedType.I1)] public bool Watertight;
    [MarshalAs(UnmanagedType.I1)] public bool FromMesh;
    public double MinAngle;
    public uint WorstTriangle;
    public double LongestEdge;
}

/// <summary>`CadaclysmBlacksmithFemEdge`: one B-rep edge's node chain. Pinned by
/// `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithFemEdge
{
    public uint Id;
    public IntPtr Nodes;
    public uint NodeCount;
    public IntPtr Runs;
    public uint RunCount;
    public uint FaceA;
    public uint FaceB;
    public uint EndA;
    public uint EndB;
    [MarshalAs(UnmanagedType.I1)] public bool Closed;
    [MarshalAs(UnmanagedType.I1)] public bool Seam;
}

/// <summary>`CadaclysmBlacksmithFemVertex`. `Point` is three doubles in the struct, not a pointer.
/// Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithFemVertex
{
    public uint Node;
    public fixed double Point[3];
    [MarshalAs(UnmanagedType.I1)] public bool HasPosition;
}

// ---- the handles the ABI hands out ------------------------------------------------------
//
// One `SafeHandle` a kind, each knowing its own free. `Path`'s is the one the library can
// consume (`path_end`), after which the handle is marked invalid so no free follows.

/// <summary>`CadaclysmBlacksmithProfile *`.</summary>
internal sealed class ProfileHandle : CadaclysmHandle
{
    public ProfileHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_profile_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithHits *`.</summary>
internal sealed class HitsHandle : CadaclysmHandle
{
    public HitsHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_hits_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithIntersection *`.</summary>
internal sealed class IntersectionHandle : CadaclysmHandle
{
    public IntersectionHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_intersection_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithProfileList *`.</summary>
internal sealed class ProfileListHandle : CadaclysmHandle
{
    public ProfileListHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_profile_list_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithPath *`.</summary>
internal sealed class PathHandle : CadaclysmHandle
{
    public PathHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_path_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithSweepPath *`.</summary>
internal sealed class SweepPathHandle : CadaclysmHandle
{
    public SweepPathHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_sweep_path_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithSolid *`.</summary>
internal sealed class SolidHandle : CadaclysmHandle
{
    public SolidHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_solid_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithAssembly *`. Freeing it does **not** free what is placed inside
/// it: the C ABI's own note, since a placed assembly shares its data (`Arc`) rather than being
/// copied, so a sub-assembly placed under two parents outlives either one's handle.</summary>
internal sealed class AssemblyHandle : CadaclysmHandle
{
    public AssemblyHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_assembly_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithFemMesh *`, freed by `cadaclysm_blacksmith_fem_mesh_free`. The
/// `.msh` texts are not freed with it: each is an owned string this binding has already released.
/// </summary>
internal sealed class FemMeshHandle : CadaclysmHandle
{
    public FemMeshHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_fem_mesh_free(handle);
        return true;
    }
}

// ---- the library ----------------------------------------------------------------------

/// <summary>Finds and loads the kernel library by `cadaclysm_blacksmith.py`'s own rule,
/// `library_path()`: `CADACLYSM_BLACKSMITH_LIBRARY` (the library, or a directory holding it)
/// and nothing else if it is set; else beside this assembly; else `lib/` in any ancestor (the
/// SDK layout); else `target/release` or `target/debug` in any ancestor (this repository's).
/// Nothing found is a <see cref="BuildException"/> naming every place looked, as Python's
/// `BuildError` does -- never the operating system's own search, which would load whatever
/// copy happens to be on the path.</summary>
internal static class BlacksmithLoader
{
    private static string LibraryName =>
        RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "cadaclysm_blacksmith.dll"
        : RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "libcadaclysm_blacksmith.dylib"
        : "libcadaclysm_blacksmith.so";

    public static IntPtr Load() => NativeLibrary.Load(LibraryPath());

    private static string LibraryPath()
    {
        var name = LibraryName;
        var over = Environment.GetEnvironmentVariable("CADACLYSM_BLACKSMITH_LIBRARY");
        if (!string.IsNullOrEmpty(over))
        {
            // A directory or the library itself, since both are things to point at.
            var candidate = Directory.Exists(over) ? System.IO.Path.Combine(over, name) : over;
            if (File.Exists(candidate)) return candidate;
            throw new BuildException($"CADACLYSM_BLACKSMITH_LIBRARY={over} names nothing that exists");
        }

        var here = System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        var ancestors = new List<string>();
        for (var dir = here; !string.IsNullOrEmpty(dir); dir = System.IO.Path.GetDirectoryName(dir))
            ancestors.Add(dir);
        var searched = new List<string>();
        if (!string.IsNullOrEmpty(here)) searched.Add(System.IO.Path.Combine(here, name));
        // Walking up from this assembly: an SDK checkout keeps the library in `lib/` beside
        // the wrappers; the repository this example ships in keeps it in `target/release`
        // (or `target/debug`, a fallback for a machine that only built that).
        searched.AddRange(ancestors.Select(a => System.IO.Path.Combine(a, "lib", name)));
        foreach (var a in ancestors)
        {
            searched.Add(System.IO.Path.Combine(a, "target", "release", name));
            searched.Add(System.IO.Path.Combine(a, "target", "debug", name));
        }
        foreach (var candidate in searched)
            if (File.Exists(candidate)) return candidate;
        throw new BuildException(
            $"{name} not found. Looked in:\n"
            + string.Concat(searched.Select(c => $"    {c}\n"))
            + "Build it with:\n    cargo build --release -p cadaclysm-blacksmith-capi\n"
            + "or run fetch.py in an SDK checkout, or point CADACLYSM_BLACKSMITH_LIBRARY at it.");
    }
}

/// <summary>Every entry point in `include/cadaclysm_blacksmith.h` this binding declares -- the
/// same 70 Python's `cadaclysm_blacksmith.py` does, no more and no less; `tests/bindings.rs`
/// compares the two sets by name and holds C# to Python's.</summary>
/// <remarks>Every `const double *` the header takes is a `double[]` here, pinned for the call
/// by the marshaller; a `[Out] double[]` is one the library writes. The progress callback
/// parameters are `IntPtr` and always passed null.</remarks>
internal static class BlacksmithNative
{
    private const string Lib = "cadaclysm_blacksmith";

    static BlacksmithNative()
    {
        Loader.Kernel = BlacksmithLoader.Load;
        Loader.Register();
    }

    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_last_error();
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_license_set([MarshalAs(UnmanagedType.LPUTF8Str)] string textOrPath);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_license_info();
    [DllImport(Lib)] internal static extern ulong cadaclysm_blacksmith_license_notice_count();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_build_date();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_version();
    // The frees take the raw pointer: they are what each handle's `ReleaseHandle` calls.
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_solid_free(IntPtr solid);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_profile_free(IntPtr profile);
    // `named` returns a new solid, like every other single-source build call; `solid_name`
    // returns a **borrowed** name (good until `solid` is freed) or null, unlike the always-owned
    // text this library otherwise hands back -- `Solid.Name` reads it directly rather than
    // through `Text`, which maps null to "" and would lose the distinction from an empty name.
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_named(SolidHandle solid,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_solid_name(SolidHandle solid);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_rect(double w, double h);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_circle(double r);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_slot(double cx, double cy, double length, double r);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_polygon(double[] xy, nuint count);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_regular_polygon(double cx, double cy, double radius, uint sides,
        double angle);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_star(double cx, double cy, double outer, double inner, uint points,
        double angle);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_spline(double[] xy, nuint count, uint degree, double[]? weights,
        [MarshalAs(UnmanagedType.I1)] bool closed);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_with_hole(ProfileHandle outer, ProfileHandle hole);
    [DllImport(Lib)] internal static extern HitsHandle cadaclysm_blacksmith_profile_hits(ProfileHandle a, ProfileHandle b, double tolerance);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_hits_free(IntPtr hits);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_hit_count(HitsHandle hits);
    [DllImport(Lib)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_hit(HitsHandle hits, uint i, out RawBlacksmithHit outHit);
    [DllImport(Lib)] internal static extern HitsHandle cadaclysm_blacksmith_solid_profile_hits(SolidHandle solid, ProfileHandle profile,
        double[] frame, double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_hits_piece_count(HitsHandle hits);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_hits_piece(HitsHandle hits, uint i, [MarshalAs(UnmanagedType.I1)] out bool inside,
        out RawBlacksmithSpot start, out RawBlacksmithSpot end);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_hits_piece_profile(HitsHandle hits, uint i);
    [DllImport(Lib)] internal static extern ProfileListHandle cadaclysm_blacksmith_profile_common(ProfileHandle a, ProfileHandle b, double tolerance);
    [DllImport(Lib)] internal static extern ProfileListHandle cadaclysm_blacksmith_profile_text(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string text, double size, [MarshalAs(UnmanagedType.LPUTF8Str)] string font,
        byte[]? fontBytes, nuint fontLen, [MarshalAs(UnmanagedType.LPUTF8Str)] string halign,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string valign, double spacing, [MarshalAs(UnmanagedType.LPUTF8Str)] string direction);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_profile_list_count(ProfileListHandle list);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_list_get(ProfileListHandle list, uint i);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_profile_list_free(IntPtr list);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_translate_profile(ProfileHandle profile, double dx, double dy);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_round(ProfileHandle profile, double radius, uint[]? corners,
        nuint count, [MarshalAs(UnmanagedType.I1)] bool open);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_close_loop(ProfileHandle profile);
    [DllImport(Lib)] internal static extern RawBlacksmithPolylines cadaclysm_blacksmith_profile_polylines(ProfileHandle profile, double tolerance);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_coloured(ProfileHandle profile, double r, double g, double b);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_profile_colour(ProfileHandle profile, [Out] double[] outRgb);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_chain(IntPtr[] pieces, nuint count,
        double tolerance);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_from_loops(IntPtr[] loops, nuint count);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_profile_piece_count(ProfileHandle profile, IntPtr[] cutters, nuint count, double tolerance);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_piece(ProfileHandle profile, IntPtr[] cutters, nuint count, uint index, double tolerance);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_profile_trim_count(ProfileHandle profile, IntPtr[] cutters, nuint count, uint piece, double tolerance);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_trim_chain(ProfileHandle profile, IntPtr[] cutters, nuint count, uint piece, uint index, double tolerance);
    [DllImport(Lib)] internal static extern PathHandle cadaclysm_blacksmith_path_begin(double x, double y);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_path_line_to(PathHandle p, double x, double y);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_path_arc_to(PathHandle p, double x, double y, double cx, double cy,
        [MarshalAs(UnmanagedType.I1)] bool ccw);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_path_bezier_to(PathHandle p, double c1x, double c1y, double c2x, double c2y,
        double x, double y);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_path_conic_to(PathHandle p, double x, double y, double cx, double cy, double weight);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_path_parabola_by_vertex(PathHandle p, double x, double y, double vx, double vy);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_path_parabola_by_focus(PathHandle p, double x, double y, double fx, double fy);
    [DllImport(Lib)] internal static extern PathHandle cadaclysm_blacksmith_path_parabola(double vx, double vy, double ax, double ay,
        double focal, double from, double to);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_path_nurbs_to(PathHandle p, double[] controlXy, nuint controlCount,
        double[]? weights, double[] knots, nuint knotCount, uint degree);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_path_end(PathHandle p);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_path_end_open(PathHandle p);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_path_free(IntPtr p);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_cuboid(double x, double y, double z);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_cylinder(double r, double h);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_cone(double r, double h);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_sphere(double r);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_torus(double major, double minor);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_wedge(double x, double y, double z, double topX);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude(ProfileHandle profile, double[] frame, double height);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude_open(ProfileHandle profile, double[] frame, double height);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude_tapered(ProfileHandle profile, double[] frame, double height,
        double taper);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude_open_tapered(ProfileHandle profile, double[] frame,
        double height, double taper);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude_between(ProfileHandle profile, double[] frame,
        double[] bottom, double[] top);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude_open_between(ProfileHandle profile, double[] frame,
        double[] bottom, double[] top);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_frame_midplane(double[] a, double[] b, [Out] double[] outFrame);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_frame_through(double[] p, double[] q, double[] r, [Out] double[] outFrame);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_slant_of_plane(double[] frame, double[] point, double[] normal,
        [Out] double[] outSlant);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_loft(ProfileHandle a, double[] frameA, ProfileHandle b,
        double[] frameB);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_loft_open(ProfileHandle a, double[] frameA, ProfileHandle b,
        double[] frameB);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_loft_through(IntPtr[] profiles, double[] frames, nuint count);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_loft_through_open(IntPtr[] profiles, double[] frames, nuint count);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_revolve(ProfileHandle profile, double[] axis, double angle);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_revolve_open(ProfileHandle profile, double[] axis, double angle);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_coil(ProfileHandle profile, double[] axis, double pitch, double turns);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_revolve_in_plane(ProfileHandle profile, double[] frame,
        double[] axis, double angle);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_revolve_open_in_plane(ProfileHandle profile, double[] frame,
        double[] axis, double angle);
    [DllImport(Lib)] internal static extern SweepPathHandle cadaclysm_blacksmith_sweep_path_begin(double x, double y, double z);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sweep_path_line_to(SweepPathHandle p, double x, double y, double z);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sweep_path_arc(SweepPathHandle p, double cx, double cy, double cz, double ax,
        double ay, double az, double angle);
    [DllImport(Lib)] internal static extern SweepPathHandle cadaclysm_blacksmith_sweep_path_along(ProfileHandle curve, double[] frame,
        double tolerance, [MarshalAs(UnmanagedType.I1)] bool open);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_sweep_path_free(IntPtr p);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_sweep(ProfileHandle profile, double[] frame, SweepPathHandle path);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_sweep_open(ProfileHandle profile, double[] frame,
        SweepPathHandle path);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_pipe(SweepPathHandle path, double radius, double thickness);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude_faces(SolidHandle sheet, double height);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_face(ProfileHandle profile, double[] frame);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_face_sheet(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_drop_faces(SolidHandle solid, uint[] faces, nuint count);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_place(SolidHandle solid, double[] frame);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_translate(SolidHandle solid, double dx, double dy, double dz);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_scaled(SolidHandle solid, double factor);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_rotate(SolidHandle solid, double[] axis, double radians);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_mirror(SolidHandle solid, double[] plane);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_join(SolidHandle a, SolidHandle b, double tolerance,
        IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_cut(SolidHandle a, SolidHandle b, double tolerance,
        IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_common(SolidHandle a, SolidHandle b, double tolerance,
        IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_split_sheet(SolidHandle sheet, SolidHandle tool,
        double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_trim(SolidHandle sheet, SolidHandle tool,
        [MarshalAs(UnmanagedType.I1)] bool keepInside, double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_fillet(SolidHandle solid, uint[] edges, nuint count,
        double radius, double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_chamfer(SolidHandle solid, uint[] edges, nuint count,
        double distance, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_shell(SolidHandle solid, double thickness, uint[] openFaces,
        nuint count, double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_thicken(SolidHandle solid, double thickness, double tolerance,
        IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_push_pull(SolidHandle solid, uint face, double distance,
        double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_push_pull_faces(SolidHandle solid, uint[] faces, nuint count,
        double distance, double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_merge_flush(SolidHandle solid);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_refillet(SolidHandle solid, uint face, double radius, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_unfillet(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_rechamfer(SolidHandle solid, uint face, double distance, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_unchamfer(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_split(SolidHandle solid, SolidHandle tool, double tolerance,
        IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_split_by_plane(SolidHandle solid, double[] plane,
        double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_lump_count(SolidHandle solid);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_lump(SolidHandle solid, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_face_count(SolidHandle solid);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_select_face(SolidHandle solid, uint kind, double[]? v, uint index);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_face_frame(SolidHandle solid, uint face, [Out] double[] outFrame);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_face_ref(SolidHandle solid, uint face, [Out] double[] outRef);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_find_face(SolidHandle solid, double[] faceRef, int hint, double tolerance);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_face_kind(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_coloured(SolidHandle solid, uint face, double r, double g, double b);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_colour(SolidHandle solid, uint face, [Out] double[] outRgb);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_edges_coloured(SolidHandle solid, uint[]? edges, nuint count, double r, double g, double b);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge_colour(SolidHandle solid, uint edge, [Out] double[] outRgb);
    [DllImport(Lib)] internal static extern RawBlacksmithColours cadaclysm_blacksmith_edge_polyline_colours(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_edge_count(SolidHandle solid);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge(SolidHandle solid, uint i, out RawBlacksmithEdge outEdge);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge_curve(SolidHandle solid, uint i, out RawBlacksmithCurve outCurve);
    [DllImport(Lib)] internal static extern IntersectionHandle cadaclysm_blacksmith_intersect(SolidHandle a, SolidHandle b,
        double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_intersection_free(IntPtr intersection);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_intersection_chain_count(IntersectionHandle intersection);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_intersection_chain(IntersectionHandle intersection, uint i, out RawBlacksmithChain outChain);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_intersection_curve(IntersectionHandle intersection, uint i, out RawBlacksmithCurve outCurve);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_intersection_overlap_count(IntersectionHandle intersection);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_intersection_overlap(IntersectionHandle intersection, uint i, out RawBlacksmithOverlap outOverlap);
    [DllImport(Lib)] internal static extern RawBlacksmithMesh cadaclysm_blacksmith_mesh(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern RawBlacksmithMesh64 cadaclysm_blacksmith_mesh64(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern RawBlacksmithFaceTriangles cadaclysm_blacksmith_mesh_face_triangles(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern RawBlacksmithPolylines cadaclysm_blacksmith_edge_polylines(SolidHandle solid, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_bounds(SolidHandle solid, double tolerance, [Out] double[] min, [Out] double[] max);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_bounds64(SolidHandle solid, double tolerance, [Out] double[] min, [Out] double[] max);
    // The FEM surface mesh: one handle per meshed solid, freed by the caller. `progress` and
    // `user` are always null here, as every other progress-taking entry point in this binding is
    // (see the file header). `msh_text` returns an **owned** `char *`, released with
    // `cadaclysm_blacksmith_string_free` -- the opposite of the reader library's borrowed slot.
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_fem_options_init(ref RawBlacksmithFemOptions options);
    [DllImport(Lib)] internal static extern FemMeshHandle cadaclysm_blacksmith_fem_mesh(SolidHandle solid,
        double[]? placement, ref RawBlacksmithFemOptions options, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_fem_mesh_free(IntPtr mesh);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_fem_mesh_view(FemMeshHandle mesh, ref RawBlacksmithFemMeshView outView);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_fem_mesh_edge(FemMeshHandle mesh, uint index, ref RawBlacksmithFemEdge outEdge);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_fem_mesh_vertex(FemMeshHandle mesh, uint index, ref RawBlacksmithFemVertex outVertex);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_fem_mesh_open_edge(FemMeshHandle mesh, uint index,
        out uint outA, out uint outB, out uint outBrepEdge);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_fem_mesh_folded_edge(FemMeshHandle mesh, uint index,
        out uint outA, out uint outB, out uint outBrepEdge);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_fem_mesh_msh_text(FemMeshHandle mesh);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_fem_mesh_save_msh(FemMeshHandle mesh,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_leaked_edges(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_unpaired_edges(SolidHandle solid, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_manifold(SolidHandle solid, [Out] uint[] outRow);
    // The one array of handles the ABI takes: the marshaller cannot ref-count an array of
    // SafeHandles, so `WriteStepText` passes the raw pointers and keeps the owners alive
    // itself, across the call, with `GC.KeepAlive`.
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_step(IntPtr[] solids, nuint count,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? schema, uint unit);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sat_text(IntPtr[] solids, nuint count, uint unit);
    [DllImport(Lib)] internal static extern bool cadaclysm_blacksmith_sat(IntPtr[] solids, nuint count,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, uint unit);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_brep_text(IntPtr[] solids, nuint count);
    [DllImport(Lib)] internal static extern bool cadaclysm_blacksmith_brep(IntPtr[] solids, nuint count,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_string_free(IntPtr s);
    // `assembly_name` is **borrowed**, like `solid_name`, but never null (an assembly always has
    // the name it was made with) -- read through `Text`, as `version`/`license_info` are.
    // `assembly_place_solid`/`assembly_place_assembly` and `assembly_step` return **owned**
    // text, freed with `cadaclysm_blacksmith_string_free` like `step`'s.
    [DllImport(Lib)] internal static extern AssemblyHandle cadaclysm_blacksmith_assembly_new(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_assembly_free(IntPtr assembly);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_assembly_name(AssemblyHandle assembly);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_assembly_place_solid(AssemblyHandle assembly,
        SolidHandle solid, double[] frame, [MarshalAs(UnmanagedType.LPUTF8Str)] string? name);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_assembly_place_assembly(AssemblyHandle assembly,
        AssemblyHandle placed, double[] frame, [MarshalAs(UnmanagedType.LPUTF8Str)] string? name);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_assembly_step(AssemblyHandle assembly,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? schema, uint unit);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_svg_options_init(ref RawBlacksmithSvgOptions options);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_svg_text(IntPtr[] solids, nuint count, ref RawBlacksmithSvgOptions options);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_svg(IntPtr[] solids, nuint count,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref RawBlacksmithSvgOptions options);
    // The drawing pair widens `svg_text`/`svg` to profiles as well as solids; either
    // count may be 0 (null array), both 0 is refused, and every refusal is worded
    // exactly as the pair above's, so `WriteSvgText`/`WriteSvg` call only this pair now
    // -- one code path, a solids-only drawing included.
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_drawing_svg_text(IntPtr[] solids, nuint solidCount,
        IntPtr[] profiles, nuint profileCount, ref RawBlacksmithSvgOptions options);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_drawing_svg(IntPtr[] solids, nuint solidCount,
        IntPtr[] profiles, nuint profileCount,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref RawBlacksmithSvgOptions options);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_from_brep(BrepHandle brep,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string layoutId);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_brep_layout_id();
}

/// <summary>The module-level entry points: the library's version and licensing, the default
/// schema, and writing several solids as one STEP file.</summary>
public static class Blacksmith
{
    /// <summary>`CADACLYSM_BLACKSMITH_NONE`: what a lookup that found nothing returns.</summary>
    internal const uint None = uint.MaxValue;

    private static readonly Dictionary<string, uint> Units = new(StringComparer.Ordinal)
    {
        ["m"] = 0, ["mm"] = 1, ["in"] = 2,
    };

    /// <summary>"m"/"mm"/"in" as the library's own unit code, for anything that writes STEP --
    /// shared with <see cref="Assembly.StepText"/> so both read the one table.</summary>
    internal static uint UnitCode(string unit)
    {
        if (!Units.TryGetValue(unit, out var unitCode))
            throw new BuildException($"unit must be one of {string.Join(", ", Units.Keys.OrderBy(k => k, StringComparer.Ordinal))}");
        return unitCode;
    }

    /// <summary>The version of the library actually loaded, which is the one worth reporting.
    /// </summary>
    public static string Version() => Text(BlacksmithNative.cadaclysm_blacksmith_version());

    /// <summary>When the loaded library was built, YYYY-MM-DD.</summary>
    public static string BuildDate() => Text(BlacksmithNative.cadaclysm_blacksmith_build_date());

    /// <summary>Load a license: the certificate text, or the path of a file holding it (see
    /// <see cref="global::Cadaclysm.Cadaclysm.License"/>). Throws with the library's reason
    /// when the text does not verify; the previous license, if any, stays in use.</summary>
    public static void License(string textOrPath)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_license_set(textOrPath)) throw Failure("license refused");
    }

    /// <summary>One line about the license the library is running under. Never null: the
    /// license line, or, without one, "unlicensed" ("unlicensed -- &lt;reason&gt;" when a
    /// license was found but did not verify).</summary>
    public static string LicenseInfo()
    {
        var info = Text(BlacksmithNative.cadaclysm_blacksmith_license_info());
        return info.Length > 0 ? info : "unlicensed";
    }

    /// <summary>How many unlicensed notices this library has printed to stderr in this
    /// process.</summary>
    public static ulong LicenseNoticeCount() => BlacksmithNative.cadaclysm_blacksmith_license_notice_count();

    /// <summary>`schemas/ap203.exp`: `CADACLYSM_SCHEMAS/ap203.exp` if set, else the
    /// repository's, found by walking up from this assembly the way the loader finds the
    /// library.
    ///
    /// The `ap203.exp` file this finds is no longer needed: the kernel writes against its
    /// built-in AP203 when no schema is given. This method stays for compatibility and the
    /// parity gates; nothing here calls it to write STEP any more.</summary>
    public static string DefaultSchema()
    {
        var candidates = new List<string>();
        var env = Environment.GetEnvironmentVariable("CADACLYSM_SCHEMAS");
        if (!string.IsNullOrEmpty(env)) candidates.Add(System.IO.Path.Combine(env, "ap203.exp"));
        // Python takes the repository root as a fixed number of parents above its own file;
        // this assembly sits under a bin/ directory of varying depth, so every ancestor is
        // tried -- the SDK layout and this repository's both keep `schemas/` at the top.
        var assembly = System.Reflection.Assembly.GetExecutingAssembly().Location;
        for (var dir = System.IO.Path.GetDirectoryName(assembly); dir is not null; dir = System.IO.Path.GetDirectoryName(dir))
            candidates.Add(System.IO.Path.Combine(dir, "schemas", "ap203.exp"));
        foreach (var candidate in candidates)
            if (File.Exists(candidate)) return candidate;
        throw new BuildException("ap203.exp not found (none is needed to write STEP: leave schema out for the "
            + "built-in AP203, or pass a schema name, a .exp path or EXPRESS text)");
    }

    /// <summary>Several solids as one part file's text, each its own body.</summary>
    /// <param name="schema">One of four things: null (the kernel's built-in AP203); the
    /// path of a schema file (no newline in it, naming an existing file), read and sent as
    /// EXPRESS text; the bare name of a built-in schema (case-insensitive, e.g.
    /// `"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"` -- an unknown name throws
    /// <see cref="BuildException"/>); or a custom schema's own EXPRESS text.</param>
    /// <param name="unit">What the solids' lengths are: "m", "mm" or "in".</param>
    public static string WriteStepText(IEnumerable<Solid> solids, string? schema = null, string unit = "mm")
    {
        if (!Units.TryGetValue(unit, out var unitCode))
            throw new BuildException($"unit must be one of {string.Join(", ", Units.Keys.OrderBy(k => k, StringComparer.Ordinal))}");
        // An array of raw pointers, the one call shape the marshaller cannot ref-count for
        // us: the owners are kept reachable, and their handles with them, until the call has
        // returned -- `GC.KeepAlive` is that fence.
        var owners = solids.ToArray();
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var raw = BlacksmithNative.cadaclysm_blacksmith_step(handles, (nuint)handles.Length, SchemaText(schema), unitCode);
        GC.KeepAlive(owners);
        if (raw == IntPtr.Zero) throw Failure("step");
        try
        {
            return Marshal.PtrToStringUTF8(raw) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
        }
    }

    /// <summary>One STEP file (AP203 unless <paramref name="schema"/> names another), each solid its own body.</summary>
    public static void WriteStep(string path, IEnumerable<Solid> solids, string? schema = null, string unit = "mm") =>
        File.WriteAllText(path, WriteStepText(solids, schema, unit), new UTF8Encoding(false));

    /// <summary>Several solids as one ACIS SAT file's text, each its own body: analytic
    /// surfaces as their own records, splines and swept surfaces as exact NURBS.</summary>
    /// <param name="unit">What the solids' lengths are: "m", "mm" or "in".</param>
    public static string WriteSatText(IEnumerable<Solid> solids, string unit = "mm")
    {
        if (!Units.TryGetValue(unit, out var unitCode))
            throw new BuildException($"unit must be one of {string.Join(", ", Units.Keys.OrderBy(k => k, StringComparer.Ordinal))}");
        var owners = solids.ToArray();
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var raw = BlacksmithNative.cadaclysm_blacksmith_sat_text(handles, (nuint)handles.Length, unitCode);
        GC.KeepAlive(owners);
        if (raw == IntPtr.Zero) throw Failure("sat_text");
        try
        {
            return Marshal.PtrToStringUTF8(raw) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
        }
    }

    /// <summary><see cref="WriteSatText"/> written to <paramref name="path"/> by the library
    /// itself, which names the file in its refusal when it cannot.</summary>
    public static void WriteSat(string path, IEnumerable<Solid> solids, string unit = "mm")
    {
        if (!Units.TryGetValue(unit, out var unitCode))
            throw new BuildException($"unit must be one of {string.Join(", ", Units.Keys.OrderBy(k => k, StringComparer.Ordinal))}");
        var owners = solids.ToArray();
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var ok = BlacksmithNative.cadaclysm_blacksmith_sat(handles, (nuint)handles.Length, path, unitCode);
        GC.KeepAlive(owners);
        if (!ok) throw Failure("sat");
    }

    /// <summary>Several solids as one OCCT `.brep`, each its own solid under one
    /// compound (one solid is the file's root): the exact surfaces and curves, with a
    /// curve in each face's own parameters for every edge, so OCCT's `BRepTools::Read`
    /// gives a shape `BRepCheck_Analyzer` finds valid. No unit is declared -- a `.brep`
    /// carries none -- so the numbers are the numbers.</summary>
    public static string WriteBrepText(IEnumerable<Solid> solids)
    {
        var owners = solids.ToArray();
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var raw = BlacksmithNative.cadaclysm_blacksmith_brep_text(handles, (nuint)handles.Length);
        GC.KeepAlive(owners);
        if (raw == IntPtr.Zero) throw Failure("brep_text");
        try
        {
            return Marshal.PtrToStringUTF8(raw) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
        }
    }

    /// <summary><see cref="WriteBrepText"/> written to `path` by the library itself.</summary>
    public static void WriteBrep(string path, IEnumerable<Solid> solids)
    {
        var owners = solids.ToArray();
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var ok = BlacksmithNative.cadaclysm_blacksmith_brep(handles, (nuint)handles.Length, path);
        GC.KeepAlive(owners);
        if (!ok) throw Failure("brep");
    }

    /// <summary>Several solids' wireframe as one SVG's text, each its own `&lt;g&gt;` -- see
    /// <see cref="SvgOptions"/>. Owned by this call, decoded and released before it returns.
    /// Delegates to <see cref="WriteSvgText(IEnumerable{Solid}, IEnumerable{Profile}, SvgOptions?)"/>
    /// with no profiles -- the drawing pair refuses in exactly the words the solids-only pair
    /// always has, so there is nothing to gain from keeping two routes to the same drawing.
    /// </summary>
    public static string WriteSvgText(IEnumerable<Solid> solids, SvgOptions? options = null) =>
        WriteSvgText(solids, Array.Empty<Profile>(), options);

    /// <summary><see cref="WriteSvgText(IEnumerable{Solid}, SvgOptions?)"/> written to
    /// <paramref name="path"/> by the library itself.</summary>
    public static void WriteSvg(string path, IEnumerable<Solid> solids, SvgOptions? options = null) =>
        WriteSvg(path, solids, Array.Empty<Profile>(), options);

    /// <summary>Several solids' and profiles' wireframe as one SVG's text: a `&lt;g
    /// id="solid-N"&gt;` per solid then a `&lt;g id="profile-N"&gt;` per profile, each its
    /// own colour where it carries one and the options' <see cref="SvgOptions.Stroke"/>
    /// otherwise. Either list may be empty; both empty is refused. See <see
    /// cref="SvgOptions"/>. Owned by this call, decoded and released before it returns.
    /// </summary>
    public static string WriteSvgText(IEnumerable<Solid> solids, IEnumerable<Profile> profiles, SvgOptions? options = null)
    {
        var solidOwners = solids.ToArray();
        var solidHandles = solidOwners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var profileOwners = profiles.ToArray();
        var profileHandles = profileOwners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var raw = BuildSvgOptions(options);
        var ptr = BlacksmithNative.cadaclysm_blacksmith_drawing_svg_text(solidHandles, (nuint)solidHandles.Length,
            profileHandles, (nuint)profileHandles.Length, ref raw);
        GC.KeepAlive(solidOwners);
        GC.KeepAlive(profileOwners);
        if (ptr == IntPtr.Zero) throw Failure("svg_text");
        try
        {
            return Marshal.PtrToStringUTF8(ptr) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(ptr);
        }
    }

    /// <summary><see cref="WriteSvgText(IEnumerable{Solid}, IEnumerable{Profile}, SvgOptions?)"/>
    /// written to <paramref name="path"/> by the library itself.</summary>
    public static void WriteSvg(string path, IEnumerable<Solid> solids, IEnumerable<Profile> profiles, SvgOptions? options = null)
    {
        var solidOwners = solids.ToArray();
        var solidHandles = solidOwners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var profileOwners = profiles.ToArray();
        var profileHandles = profileOwners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var raw = BuildSvgOptions(options);
        var ok = BlacksmithNative.cadaclysm_blacksmith_drawing_svg(solidHandles, (nuint)solidHandles.Length,
            profileHandles, (nuint)profileHandles.Length, path, ref raw);
        GC.KeepAlive(solidOwners);
        GC.KeepAlive(profileOwners);
        if (!ok) throw Failure("svg");
    }

    /// <summary><see cref="SvgOptions"/>, packed into `RawBlacksmithSvgOptions`: `View` fills
    /// `Azimuth`/`Elevation` unless they are set directly, `Up` defaults to "z" (a solid
    /// carries no convention of its own), colours are `'#rrggbb'` -- as the reader's own
    /// `Cadaclysm.BuildSvgOptions`, but with no scene to default `Up` from.</summary>
    private static RawBlacksmithSvgOptions BuildSvgOptions(SvgOptions? options)
    {
        var o = options ?? new SvgOptions();
        var raw = new RawBlacksmithSvgOptions();
        BlacksmithNative.cadaclysm_blacksmith_svg_options_init(ref raw);
        var (baseAzimuth, baseElevation) = SvgViewAngles.For(o.View);
        raw.Up = string.Equals(o.Up ?? "z", "y", StringComparison.OrdinalIgnoreCase) ? 1u : 0u;
        raw.Azimuth = o.Azimuth ?? baseAzimuth;
        raw.Elevation = o.Elevation ?? baseElevation;
        raw.Fov = o.Fov;
        raw.Width = o.Width;
        raw.Height = o.Height;
        raw.Margin = o.Margin;
        raw.Tolerance = o.Tolerance;
        raw.StrokeWidth = o.StrokeWidth;
        raw.Stroke = ParseColour(o.Stroke);
        raw.Background = o.Background ?? 0xFFFFFFFFu; // CADACLYSM_BLACKSMITH_SVG_TRANSPARENT
        raw.Flags = (o.Edges ? 1u : 0u) | (o.Curves ? 2u : 0u) | (o.Isocurves ? 4u : 0u) | (o.Polylines ? 8u : 0u);
        return raw;
    }

    /// <summary>A colour as the ABI's packed `0xRRGGBB`: `'#rrggbb'`, the leading `#` optional.
    /// </summary>
    private static uint ParseColour(string colour)
    {
        var hex = colour.StartsWith('#') ? colour[1..] : colour;
        if (hex.Length != 6 || !uint.TryParse(hex, System.Globalization.NumberStyles.HexNumber,
                System.Globalization.CultureInfo.InvariantCulture, out var value))
            throw new BuildException($"colour {colour}: expected '#rrggbb'");
        return value;
    }

    /// <summary>`schema` is null (the built-in AP203), the path of a schema file, a
    /// built-in schema's name, or a custom schema's own EXPRESS text -- see
    /// <see cref="WriteStepText"/> and <see cref="Assembly.StepText"/>.</summary>
    internal static string? SchemaText(string? schema)
    {
        if (schema is null) return null;
        if (!schema.Contains('\n') && File.Exists(schema)) return File.ReadAllText(schema);
        return schema;
    }

    // ---- shared helpers ------------------------------------------------------------------

    internal static string Text(IntPtr raw) => raw == IntPtr.Zero ? "" : Marshal.PtrToStringUTF8(raw) ?? "";

    /// <summary>The library's own reason for the last failure, or "" if it left none.</summary>
    internal static string LastError() => Text(BlacksmithNative.cadaclysm_blacksmith_last_error());

    /// <summary>The library's own reason, or `what` if it left none.</summary>
    internal static BuildException Failure(string what)
    {
        var reason = LastError();
        return new BuildException(reason.Length > 0 ? reason : what);
    }

    /// <summary>The handle a build call returned, or the library's reason it returned none.
    /// (A null handle is an invalid `SafeHandle`, which the runtime never frees.)</summary>
    /// <summary>`count` xyz triples at `at`, copied out as one array a point.</summary>
    internal static unsafe double[][] PointsAt(IntPtr at, uint count)
    {
        var flat = at == IntPtr.Zero ? ReadOnlySpan<double>.Empty : new ReadOnlySpan<double>((void*)at, 3 * (int)count);
        var points = new double[flat.Length / 3][];
        for (var k = 0; k < points.Length; k++) points[k] = flat.Slice(3 * k, 3).ToArray();
        return points;
    }

    internal static T Checked<T>(T handle, string what) where T : CadaclysmHandle =>
        !handle.IsInvalid ? handle : throw Failure(what);

    private static double[] Doubles(double[]? values, int count, string what)
    {
        var got = values?.Length ?? 0;
        if (values is null || got != count) throw new BuildException($"{what}: expected {count} numbers, got {got}");
        return values;
    }

    /// <summary>How the loaded library lays a brep out in memory: its compiler, target and
    /// source. `Solid.FromNode` works only where this equals the reader library's
    /// <see cref="global::Cadaclysm.Brep.LayoutId"/> -- the two from the same release.</summary>
    public static string BrepLayoutId() => Text(BlacksmithNative.cadaclysm_blacksmith_brep_layout_id());

    /// <summary>Twelve numbers: origin, x, y, z.</summary>
    internal static double[] Frame(double[] frame) => Doubles(frame, 12, "frame");

    /// <summary>Six numbers: a point and a direction.</summary>
    internal static double[] AxisOf(double[] axis) => Doubles(axis, 6, "axis");
}

// ---- profiles ---------------------------------------------------------------------------

/// <summary>A closed outline with holes, in its own x/y. Immutable; every method returns a
/// new one. Owns a handle: dispose it once done.</summary>
public sealed class Profile : IDisposable
{
    private readonly ProfileHandle _handle;

    internal Profile(ProfileHandle handle)
    {
        _handle = Blacksmith.Checked(handle, "profile");
    }

    internal ProfileHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Profile));

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the profile back. Idempotent; the runtime does it for a profile never
    /// disposed.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>A rectangle `w` by `h` centred on the origin.</summary>
    public static Profile Rect(double w, double h) => new(BlacksmithNative.cadaclysm_blacksmith_profile_rect(w, h));

    /// <summary>A circle of radius `r` about the origin: two semicircular arcs.</summary>
    public static Profile Circle(double r) => new(BlacksmithNative.cadaclysm_blacksmith_profile_circle(r));

    /// <summary>A stadium: a `length`-long slot of end radius `r`, centred at `centre`,
    /// running along x.</summary>
    public static Profile Slot((double X, double Y) centre, double length, double r) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_slot(centre.X, centre.Y, length, r));

    /// <summary>A closed polygon through `points`, in order, its side back to the first
    /// point a segment of its own.</summary>
    public static Profile Polygon(IEnumerable<(double X, double Y)> points)
    {
        var flat = points.SelectMany(p => new[] { p.X, p.Y }).ToArray();
        return new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_polygon(flat, (nuint)(flat.Length / 2)));
    }

    /// <summary>A regular polygon of `sides` sides (at least 3) on the circle of `radius` about
    /// `centre`, its first corner at `angle` radians from the sketch's x axis, the rest
    /// counter-clockwise.</summary>
    public static Profile RegularPolygon((double X, double Y) centre, double radius, int sides, double angle = 0) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_regular_polygon(centre.X, centre.Y, radius, (uint)Math.Max(0, sides), angle));

    /// <summary>A star of `points` tips (at least 3) on the circle of `outer` about `centre`, its
    /// inner corners on the circle of `inner` (positive, under `outer`), alternating: the first
    /// tip at `angle` radians from the sketch's x axis, the rest counter-clockwise.</summary>
    public static Profile Star((double X, double Y) centre, double outer, double inner, int points, double angle = 0) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_star(centre.X, centre.Y, outer, inner, (uint)Math.Max(0, points), angle));

    /// <summary>A spline of `degree` through the control polygon `points` (`weights` one per
    /// point, or null). Open, it starts on the first point and ends on the last -- an open
    /// chain; `closed`, it is periodic, smooth through its own start -- a closed profile. The
    /// degree is lowered to fit the points.</summary>
    public static Profile Spline(IEnumerable<(double X, double Y)> points, int degree = 3, IEnumerable<double>? weights = null, bool closed = false)
    {
        var flat = points.SelectMany(p => new[] { p.X, p.Y }).ToArray();
        var w = weights?.ToArray();
        // The library reads exactly one weight per point, whatever the array holds.
        if (w != null && w.Length != flat.Length / 2)
            throw new BuildException($"spline: {w.Length} weights for {flat.Length / 2} points; give one per point");
        return new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_spline(flat, (nuint)(flat.Length / 2), (uint)Math.Max(0, degree),
            w, closed));
    }

    /// <summary>Start drawing an outline at `start`, a segment at a time (the `Path` builder).
    /// </summary>
    public static Path Path((double X, double Y) start) => new(start);

    /// <summary>Start drawing on the arc of the parabola with `vertex`, axis direction `axis`
    /// and focal length `focal`, over the across-axis coordinates `from`..`to`: the path
    /// begins at the arc's first point and holds the arc -- a reflector from rim to rim,
    /// `Profile.Parabola((0, 0), (0, 1), 20, -50, 50)` a dish 100 wide opening up.</summary>
    public static Path Parabola((double X, double Y) vertex, (double X, double Y) axis, double focal, double from, double to) =>
        new(BlacksmithNative.cadaclysm_blacksmith_path_parabola(vertex.X, vertex.Y, axis.X, axis.Y, focal, from, to), "path_parabola");

    /// <summary>Open profiles joined end to end into one -- the forge's merge. The pieces
    /// may come in any order and either way round: each next one is the first of the rest
    /// with an end within `tolerance` of either end of the chain so far, reversed where
    /// that makes it meet. Every segment is kept exactly. Closed where the chain's two
    /// ends meet, otherwise an open chain. Throws for no pieces, a piece empty, with holes
    /// or closed on its own, or one that meets none of the others.</summary>
    public static Profile Chain(IEnumerable<Profile> pieces, double tolerance = 1e-6)
    {
        // Raw pointers, as WriteStepText passes its solids: the owners kept reachable
        // until the call has returned.
        var owners = pieces.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var chained = BlacksmithNative.cadaclysm_blacksmith_profile_chain(handles, (nuint)handles.Length, tolerance);
        GC.KeepAlive(owners);
        return new Profile(chained);
    }

    /// <summary>Closed loops, in any order, as one profile: the loop enclosing the most area
    /// is the boundary and every other a hole in it, in the order given -- a sketch's
    /// rectangle and the circles drawn inside it. Each loop is closed, with no holes of its
    /// own, wound either way. Throws, naming loops by their index, for a loop that is open,
    /// empty or of no area, loops that cross or touch, a hole outside the boundary or inside
    /// another hole.</summary>
    public static Profile FromLoops(IEnumerable<Profile> loops)
    {
        var owners = loops.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var made = BlacksmithNative.cadaclysm_blacksmith_profile_from_loops(handles, (nuint)handles.Length);
        GC.KeepAlive(owners);
        return new Profile(made);
    }

    /// <summary>This curve cut where the <paramref name="cutters"/> cross, touch or run along
    /// it -- the sketch trim's pieces, Python's <c>pieces</c>: in order along the curve from its
    /// start, each an open profile of portions of this one's own segments (a line's stretch a
    /// line, an arc's an arc, a spline's the same spline over part of its domain). One piece,
    /// this curve, where nothing cuts it; a closed curve's piece round its start is one piece.
    /// Cuts closer than <paramref name="tolerance"/> to each other fold onto one.</summary>
    public IReadOnlyList<Profile> Pieces(IEnumerable<Profile> cutters, double tolerance = 1e-6)
    {
        var owners = cutters.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var n = BlacksmithNative.cadaclysm_blacksmith_profile_piece_count(Handle, handles, (nuint)handles.Length, tolerance);
        if (n == 0) throw Blacksmith.Failure("profile_piece_count");
        var found = new List<Profile>((int)n);
        for (uint i = 0; i < n; i++) found.Add(new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_piece(Handle, handles, (nuint)handles.Length, i, tolerance)));
        GC.KeepAlive(owners);
        return found;
    }

    /// <summary>This curve with piece <paramref name="piece"/> of <see cref="Pieces"/> taken
    /// away -- the sketch trim, Python's <c>trim</c>: what is left, as open profiles. One for a
    /// closed curve (its other pieces run together from where the removed one ended), the
    /// stretches before and after for an open one, none where the piece was the whole curve.
    /// Throws for a piece the curve does not have.</summary>
    public IReadOnlyList<Profile> Trim(IEnumerable<Profile> cutters, uint piece, double tolerance = 1e-6)
    {
        var owners = cutters.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var n = BlacksmithNative.cadaclysm_blacksmith_profile_trim_count(Handle, handles, (nuint)handles.Length, piece, tolerance);
        if (n == 0 && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("profile_trim_count");
        var found = new List<Profile>((int)n);
        for (uint i = 0; i < n; i++) found.Add(new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_trim_chain(Handle, handles, (nuint)handles.Length, piece, i, tolerance)));
        GC.KeepAlive(owners);
        return found;
    }

    /// <summary>This profile closed -- Python's <c>close_loop</c>, the forge's sketch "close":
    /// where its last segment stops short of its start (a path ended open), a straight segment
    /// back to it; where it already comes back within 1e-9 of its extent, its last segment made
    /// to land on the start exactly. A closed profile comes back as it is; holes are closed the
    /// same way. (Not <c>Close</c>: that name frees a handle.)</summary>
    public Profile CloseLoop() => new(BlacksmithNative.cadaclysm_blacksmith_profile_close_loop(Handle));

    /// <summary>This outline with `hole` cut from it, as a new profile; both inputs are
    /// untouched.</summary>
    public Profile WithHole(Profile hole) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_with_hole(Handle, hole.Handle));

    /// <summary>Where this profile's curves cross, touch or run along <paramref name="other"/>'s,
    /// both read in one plane, as <see cref="Hit"/> values ordered along this profile. Points
    /// closer than `tolerance` merge; two curves within `tolerance` of each other for longer
    /// than it are one run when they part only where one ends or the stretch is flat -- one curve
    /// following the other, offset within `tolerance` or tilted by under about half of it, even
    /// where it leaves mid-both; a tangency or a shallow crossing is one point. A loop that stops
    /// short of its start is an open chain.</summary>
    public IReadOnlyList<Hit> Hits(Profile other, double tolerance = 1e-6)
    {
        using var hits = Blacksmith.Checked(
            BlacksmithNative.cadaclysm_blacksmith_profile_hits(Handle, other.Handle, tolerance), "profile_hits");
        var n = BlacksmithNative.cadaclysm_blacksmith_hit_count(hits);
        var found = new List<Hit>((int)n);
        for (uint i = 0; i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_hit(hits, i, out var raw)) throw Blacksmith.Failure("hit");
            found.Add(new Hit(raw));
        }
        return found;
    }

    /// <summary>The region this profile and <paramref name="other"/> share, both read in one
    /// plane, as zero or more profiles -- each boundary counter-clockwise, each hole clockwise,
    /// arcs and splines kept exact. Both must be closed and simple. No shared area is an empty
    /// list. Throws <see cref="BuildException"/> for a `tolerance` not positive and finite, or
    /// a profile open or crossing itself.</summary>
    public IReadOnlyList<Profile> Common(Profile other, double tolerance = 1e-6) =>
        ProfileList(BlacksmithNative.cadaclysm_blacksmith_profile_common(Handle, other.Handle, tolerance), "profile_common");

    /// <summary>`text` set in a font, one profile per closed shape -- a letter with its counters
    /// as holes (`o` one, `8` two; `i` is two profiles) -- on the sketch plane, the baseline
    /// along x from the origin, each outline counter-clockwise and its holes clockwise, a curved
    /// side the font's own cubic Bezier kept exactly: an extruded `O` has curved walls. `size`
    /// is roughly the height of a capital. `font` is a family, optionally with a style
    /// (`"Liberation Sans:style=Bold"`), a font file's path, or empty for the bundled Liberation
    /// Sans Regular -- which also serves when the family is not found; `fontBytes` a font file's
    /// bytes, used instead of `font` when given. `halign` is "left", "center" or "right";
    /// `valign` "baseline", "bottom", "center" or "top"; `spacing` multiplies the gap between
    /// glyphs; `direction` "ltr" or "rtl". Empty text is an empty list. Throws
    /// <see cref="BuildException"/> for a size or spacing not positive and finite, an alignment
    /// or direction not one of those words, font bytes that are not a font.</summary>
    public static IReadOnlyList<Profile> Text(string text, double size = 10, string font = "", string halign = "left",
                                              string valign = "baseline", double spacing = 1, string direction = "ltr",
                                              byte[]? fontBytes = null) =>
        ProfileList(BlacksmithNative.cadaclysm_blacksmith_profile_text(text, size, font, fontBytes, (nuint)(fontBytes?.Length ?? 0),
                                                                       halign, valign, spacing, direction), "profile_text");

    /// <summary>The profiles of a list the library handed back (null: throw), each a handle of
    /// its own, the list freed.</summary>
    private static IReadOnlyList<Profile> ProfileList(ProfileListHandle handle, string what)
    {
        using var list = Blacksmith.Checked(handle, what);
        var n = BlacksmithNative.cadaclysm_blacksmith_profile_list_count(list);
        var found = new List<Profile>((int)n);
        for (uint i = 0; i < n; i++) found.Add(new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_list_get(list, i)));
        return found;
    }

    /// <summary>This outline shifted by (`dx`, `dy`) in its own plane.</summary>
    public Profile Translate(double dx, double dy) =>
        new(BlacksmithNative.cadaclysm_blacksmith_translate_profile(Handle, dx, dy));

    /// <summary>This outline coloured (`r`, `g`, `b`), each in 0..1: how it is drawn. The verbs
    /// that make a profile from one carry it; a solid made from it takes nothing.</summary>
    public Profile Coloured(double r, double g, double b) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_coloured(Handle, r, g, b));

    /// <summary>The outline's colour as { r, g, b } in 0..1, or null.</summary>
    public double[]? Colour
    {
        get
        {
            var rgb = new double[3];
            if (BlacksmithNative.cadaclysm_blacksmith_profile_colour(Handle, rgb)) return rgb;
            if (Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("profile_colour");
            return null;
        }
    }

    /// <summary>This profile with its corners rounded by `radius`: where two straight segments
    /// meet, both are cut back and an exact arc tangent to both put between them. `corners`
    /// null rounds every such corner, the holes' too; otherwise it picks corners of the
    /// boundary -- corner `k` is where segment `k` ends. `open` reads the profile as an open
    /// chain whose two ends stay square; closed, the corner at the start is rounded too.
    /// Throws <see cref="BuildException"/> naming the corner the radius does not fit.</summary>
    public Profile Round(double radius, IEnumerable<int>? corners = null, bool open = false)
    {
        var picked = corners?.Select(k => (uint)k).ToArray();
        return new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_round(Handle, radius, picked,
            (nuint)(picked?.Length ?? 0), open));
    }

    /// <summary>This profile's own loops as SVG text, from directly above by default -- a
    /// sketch lies in z = 0, so its own plane already is the page, unlike a solid's <see
    /// cref="Solid.SvgText"/> (<see cref="SvgView.Iso"/>), which has no plane of its own to
    /// prefer. Passing <paramref name="options"/> at all -- even one left at its own defaults
    /// -- opts out of the top default and uses <see cref="SvgOptions.View"/> as given, the
    /// same way a caller of <see cref="SvgOptions"/> controls a solid's view. See <see
    /// cref="Blacksmith.WriteSvgText(IEnumerable{Solid}, IEnumerable{Profile}, SvgOptions?)"/>.
    /// </summary>
    public string SvgText(SvgOptions? options = null) =>
        Blacksmith.WriteSvgText(Array.Empty<Solid>(), new[] { this }, options ?? new SvgOptions { View = SvgView.Top });

    /// <summary>This profile written as an SVG file by the library itself; see <see
    /// cref="SvgText"/> for the top default.</summary>
    public void Svg(string path, SvgOptions? options = null) =>
        Blacksmith.WriteSvg(path, Array.Empty<Solid>(), new[] { this }, options ?? new SvgOptions { View = SvgView.Top });
}

/// <summary>An outline drawn a segment at a time; <see cref="End"/> closes it into a
/// <see cref="Profile"/> and consumes the builder. Named as Python names it, so it shadows
/// `System.IO.Path` in a file that imports this namespace -- qualify that one.</summary>
public sealed class Path : IDisposable
{
    private readonly PathHandle _handle;

    internal Path((double X, double Y) start)
    {
        _handle = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_path_begin(start.X, start.Y), "path_begin");
    }

    /// <summary>Wraps a handle another entry point (`path_parabola`) already returned.
    /// </summary>
    internal Path(PathHandle handle, string what)
    {
        _handle = Blacksmith.Checked(handle, what);
    }

    /// <summary>The live handle; a path already ended (or disposed) has none.</summary>
    private PathHandle Live => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Path), "path: already ended");

    public bool Closed => _handle.IsClosed;

    /// <summary>Release a path that was never ended; a no-op after <see cref="End"/> or
    /// <see cref="EndOpen"/>, which consume the builder.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>`end` consumes the path: the library frees it whether or not the profile
    /// came out, so the handle is marked invalid -- closed, and never freed from here -- once
    /// the call returns, and the builder is consumed either way.</summary>
    private Profile Consumed(Func<PathHandle, ProfileHandle> end)
    {
        var handle = Live;
        ProfileHandle profile;
        try
        {
            profile = end(handle);
        }
        finally
        {
            handle.SetHandleAsInvalid();
        }
        return new Profile(profile);
    }

    private Path Step(bool ok, string what) => ok ? this : throw Blacksmith.Failure(what);

    /// <summary>A straight segment to (`x`, `y`).</summary>
    public Path LineTo(double x, double y) => Step(BlacksmithNative.cadaclysm_blacksmith_path_line_to(Live, x, y), "path_line_to");

    /// <summary>A circular arc to (`x`, `y`) about `centre`, counter-clockwise if `ccw`.
    /// </summary>
    public Path ArcTo(double x, double y, (double X, double Y) centre, bool ccw = true) =>
        Step(BlacksmithNative.cadaclysm_blacksmith_path_arc_to(Live, x, y, centre.X, centre.Y, ccw), "path_arc_to");

    /// <summary>A cubic Bezier to `to` with interior control points `c1` and `c2`; the first
    /// control point is the current point.</summary>
    public Path BezierTo((double X, double Y) c1, (double X, double Y) c2, (double X, double Y) to) =>
        Step(BlacksmithNative.cadaclysm_blacksmith_path_bezier_to(Live, c1.X, c1.Y, c2.X, c2.Y, to.X, to.Y), "path_bezier_to");

    /// <summary>A conic arc to (`x`, `y`) through the control point `control` with middle
    /// weight `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola -- the
    /// rational quadratic Bezier, kept exact.</summary>
    public Path ConicTo(double x, double y, (double X, double Y) control, double weight) =>
        Step(BlacksmithNative.cadaclysm_blacksmith_path_conic_to(Live, x, y, control.X, control.Y, weight), "path_conic_to");

    /// <summary>A parabolic arc to (`x`, `y`) whose end tangents meet at `control`:
    /// <see cref="ConicTo"/> with weight 1.</summary>
    public Path ParabolaTo(double x, double y, (double X, double Y) control) => ConicTo(x, y, control, 1.0);

    /// <summary>A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1.
    /// </summary>
    public Path HyperbolaTo(double x, double y, (double X, double Y) control, double weight)
    {
        if (!(weight > 1.0))
            throw new BuildException("hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)");
        return ConicTo(x, y, control, weight);
    }

    /// <summary>The parabolic arc to (`x`, `y`) with `vertex`: its axis and focal length
    /// solved from the two ends. Throws when no parabola with that vertex passes through
    /// both.</summary>
    public Path ParabolaByVertex(double x, double y, (double X, double Y) vertex) =>
        Step(BlacksmithNative.cadaclysm_blacksmith_path_parabola_by_vertex(Live, x, y, vertex.X, vertex.Y), "path_parabola_by_vertex");

    /// <summary>The parabolic arc to (`x`, `y`) with `focus`: of the two through the ends,
    /// the one whose vertex lies between the ends' projections, then the one whose arc cups
    /// the focus (the focus between the arc and its chord), then the more symmetric; with
    /// the focus beyond the chord that is the arch over the ends, not the shallow dish --
    /// draw that one with <see cref="Profile.Parabola"/>.</summary>
    public Path ParabolaByFocus(double x, double y, (double X, double Y) focus) =>
        Step(BlacksmithNative.cadaclysm_blacksmith_path_parabola_by_focus(Live, x, y, focus.X, focus.Y), "path_parabola_by_focus");

    /// <summary>A NURBS segment. `control`: every control point after the current one, the
    /// endpoint last; `weights`: one per control point <em>including</em> the current one, or
    /// null; `knots`: the full repeated knot vector.</summary>
    public Path NurbsTo(IEnumerable<(double X, double Y)> control, IEnumerable<double> knots, uint degree,
        IEnumerable<double>? weights = null)
    {
        var flat = control.SelectMany(p => new[] { p.X, p.Y }).ToArray();
        var k = knots.ToArray();
        var w = weights?.ToArray();
        // The library reads one weight per control point plus the current point's.
        var n = flat.Length / 2;
        if (w != null && w.Length != n + 1)
            throw new BuildException($"nurbs_to: {w.Length} weights for {n + 1} control points "
                + $"(the current point and {n} given); give one per point");
        var ok = BlacksmithNative.cadaclysm_blacksmith_path_nurbs_to(Live, flat, (nuint)(flat.Length / 2), w, k, (nuint)k.Length, degree);
        return Step(ok, "path_nurbs_to");
    }

    /// <summary>The path as it stands, without closing it: an open chain for
    /// <see cref="Solid.ExtrudeOpen"/>, <see cref="Solid.SweepOpen"/> or
    /// <see cref="Solid.LoftOpen"/> (a closed sweep closes it with a straight side). Consumes
    /// the builder as <see cref="End"/> does.</summary>
    public Profile EndOpen() => Consumed(BlacksmithNative.cadaclysm_blacksmith_path_end_open);

    /// <summary>Close the path into a profile. The builder is consumed whether or not this
    /// succeeds.</summary>
    public Profile End() => Consumed(BlacksmithNative.cadaclysm_blacksmith_path_end);
}

/// <summary>A 3D path a profile is carried along -- lines and arcs, a point at a time -- for
/// <see cref="Solid.Sweep"/>/<see cref="Solid.SweepOpen"/>. Named apart from <see cref="Path"/>
/// (the 2D outline builder) because it plays a different role: a sweep path has no closing
/// rule of its own, so a sweep only <em>borrows</em> it rather than consuming it -- the same
/// path can be swept more than once, open or closed. Dispose it once done.</summary>
public sealed class SweepPath : IDisposable
{
    private readonly SweepPathHandle _handle;

    internal SweepPath((double X, double Y, double Z) at)
    {
        _handle = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_sweep_path_begin(at.X, at.Y, at.Z), "sweep_path_begin");
    }

    private SweepPath(SweepPathHandle handle, string what)
    {
        _handle = Blacksmith.Checked(handle, what);
    }

    /// <summary>The path the 2D chain `curve` (usually from <see cref="Path.EndOpen"/>) draws
    /// on `frame`: a line a straight piece, an arc a circular one, a Bezier or spline fitted
    /// with biarcs -- arcs tangent to each other and to the curve -- within `tolerance`.
    /// `open` false closes the path back to its start along the side a profile leaves
    /// implicit.</summary>
    public static SweepPath Along(Profile curve, double[] frame, double tolerance = 0.05, bool open = true) =>
        new(BlacksmithNative.cadaclysm_blacksmith_sweep_path_along(curve.Handle, Blacksmith.Frame(frame), tolerance, open),
            "sweep_path_along");

    internal SweepPathHandle Live =>
        !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(SweepPath), "sweep_path: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Start a sweep path at `point`.</summary>
    public static SweepPath At((double X, double Y, double Z) point) => new(point);

    /// <summary>Python's `close()`. Idempotent; the runtime does it for a path never
    /// disposed.</summary>
    public void Dispose() => _handle.Dispose();

    private SweepPath Step(bool ok, string what) => ok ? this : throw Blacksmith.Failure(what);

    /// <summary>A straight piece to `point`.</summary>
    public SweepPath LineTo((double X, double Y, double Z) point) =>
        Step(BlacksmithNative.cadaclysm_blacksmith_sweep_path_line_to(Live, point.X, point.Y, point.Z), "sweep_path_line_to");

    /// <summary>Turn `angle` radians about the axis through `centre` with direction `axis`
    /// (need not be unit); `angle` must be in `(0, 2*pi]`.</summary>
    public SweepPath Arc((double X, double Y, double Z) centre, (double X, double Y, double Z) axis, double angle)
    {
        var ok = BlacksmithNative.cadaclysm_blacksmith_sweep_path_arc(Live, centre.X, centre.Y, centre.Z, axis.X, axis.Y, axis.Z, angle);
        return Step(ok, "sweep_path_arc");
    }
}

/// <summary>A plane a sweep starts or ends on, read as a height over the sketch plane at each
/// point: `At + Grad · p`. Flat (`Grad` zero) for <see cref="Solid.Extrude"/>'s own caps;
/// sloped for a mitre -- the mitred end of a sweep's straight piece, where it meets the plane
/// bisecting its corner with the next.</summary>
public readonly struct Slant
{
    public double At { get; }
    public (double X, double Y) Grad { get; }

    public Slant(double at, (double X, double Y) grad = default)
    {
        At = at;
        Grad = grad;
    }

    public static Slant Flat(double at) => new(at);

    /// <summary>The plane through `point` square to `normal`, read as heights over `frame`.
    /// Throws <see cref="BuildException"/> when the plane holds the sweep direction itself
    /// (`normal` square to `frame`'s z), so no height is on it.</summary>
    public static Slant OfPlane(double[] frame, (double X, double Y, double Z) point, (double X, double Y, double Z) normal)
    {
        var raw = new double[3];
        var ok = BlacksmithNative.cadaclysm_blacksmith_slant_of_plane(Blacksmith.Frame(frame),
            new[] { point.X, point.Y, point.Z }, new[] { normal.X, normal.Y, normal.Z }, raw);
        if (!ok) throw Blacksmith.Failure("slant_of_plane");
        return new Slant(raw[0], (raw[1], raw[2]));
    }

    /// <summary>A bare number is `Flat(number)`, as Python's `extrude_between` reads one.
    /// </summary>
    public static implicit operator Slant(double at) => Flat(at);

    internal double[] Raw() => new[] { At, Grad.X, Grad.Y };

    public override string ToString() => $"Slant({At}, ({Grad.X}, {Grad.Y}))";
}

// ---- solids -----------------------------------------------------------------------------

/// <summary>The same triangles in memory of our own, safe to outlive the solid.</summary>
public sealed record BlacksmithMeshData(float[] Positions, float[] Normals, uint[] Indices);

/// <summary>A solid's triangles -- views over the library's own cache at one tolerance, valid
/// until the solid is disposed or meshed again at another tolerance (see the file header).
/// </summary>
/// <remarks><see cref="Positions"/> and <see cref="Normals"/> are `(VertexCount * 3)` floats,
/// <see cref="Indices"/> is `(IndexCount)`, three to a triangle.</remarks>
public sealed class BlacksmithMesh
{
    private readonly RawBlacksmithMesh _raw;

    /// <summary>The solid this borrows from.</summary>
    public Solid Solid { get; }

    /// <summary>The tolerance this was meshed at.</summary>
    public double Tolerance { get; }

    /// <summary>Which filling of the solid's cache this reads -- see <see cref="Solid.CheckCache"/>.
    /// </summary>
    private readonly int _generation;

    internal BlacksmithMesh(Solid solid, double tolerance, int generation, RawBlacksmithMesh raw)
    {
        Solid = solid;
        Tolerance = tolerance;
        _generation = generation;
        _raw = raw;
    }

    public int VertexCount => (int)_raw.VertexCount;
    public int IndexCount => (int)_raw.IndexCount;
    public int TriangleCount => (int)(_raw.IndexCount / 3);

    public unsafe ReadOnlySpan<float> Positions
    {
        get
        {
            Solid.CheckCache(_generation);
            return _raw.Positions == IntPtr.Zero
                ? ReadOnlySpan<float>.Empty
                : new ReadOnlySpan<float>((void*)_raw.Positions, (int)(_raw.VertexCount * 3));
        }
    }

    public unsafe ReadOnlySpan<float> Normals
    {
        get
        {
            Solid.CheckCache(_generation);
            return _raw.Normals == IntPtr.Zero
                ? ReadOnlySpan<float>.Empty
                : new ReadOnlySpan<float>((void*)_raw.Normals, (int)(_raw.VertexCount * 3));
        }
    }

    public unsafe ReadOnlySpan<uint> Indices
    {
        get
        {
            Solid.CheckCache(_generation);
            return _raw.Indices == IntPtr.Zero
                ? ReadOnlySpan<uint>.Empty
                : new ReadOnlySpan<uint>((void*)_raw.Indices, (int)_raw.IndexCount);
        }
    }

    /// <summary>The same triangles in memory of our own, safe to outlive the solid.</summary>
    public BlacksmithMeshData Copy() => new(Positions.ToArray(), Normals.ToArray(), Indices.ToArray());
}

/// <summary>A <see cref="BlacksmithMesh64"/> in memory of your own.</summary>
public sealed record BlacksmithMeshData64(double[] Positions, double[] Normals, uint[] Indices);

/// <summary>[`cadaclysm_blacksmith_mesh64`]: the same tessellation as <see
/// cref="BlacksmithMesh"/>, from the same cache -- meshing at another tolerance (through
/// <see cref="Solid.Mesh"/>, <see cref="Solid.Mesh64"/>, <see cref="Solid.EdgePolylines"/>,
/// <see cref="Solid.BoundsAt"/> or <see cref="Solid.BoundsAt64"/>) invalidates this the same
/// way it invalidates <see cref="BlacksmithMesh"/>.</summary>
/// <remarks><see cref="Positions"/> and <see cref="Normals"/> are `(VertexCount * 3)`
/// doubles, <see cref="Indices"/> is `(IndexCount)`, the very pointer <see
/// cref="BlacksmithMesh"/> gives.</remarks>
public sealed class BlacksmithMesh64
{
    private readonly RawBlacksmithMesh64 _raw;

    /// <summary>The solid this borrows from.</summary>
    public Solid Solid { get; }

    /// <summary>The tolerance this was meshed at.</summary>
    public double Tolerance { get; }

    /// <summary>Which filling of the solid's cache this reads -- see <see cref="Solid.CheckCache"/>.
    /// </summary>
    private readonly int _generation;

    internal BlacksmithMesh64(Solid solid, double tolerance, int generation, RawBlacksmithMesh64 raw)
    {
        Solid = solid;
        Tolerance = tolerance;
        _generation = generation;
        _raw = raw;
    }

    public int VertexCount => (int)_raw.VertexCount;
    public int IndexCount => (int)_raw.IndexCount;
    public int TriangleCount => (int)(_raw.IndexCount / 3);

    public unsafe ReadOnlySpan<double> Positions
    {
        get
        {
            Solid.CheckCache(_generation);
            return _raw.Positions == IntPtr.Zero
                ? ReadOnlySpan<double>.Empty
                : new ReadOnlySpan<double>((void*)_raw.Positions, (int)(_raw.VertexCount * 3));
        }
    }

    public unsafe ReadOnlySpan<double> Normals
    {
        get
        {
            Solid.CheckCache(_generation);
            return _raw.Normals == IntPtr.Zero
                ? ReadOnlySpan<double>.Empty
                : new ReadOnlySpan<double>((void*)_raw.Normals, (int)(_raw.VertexCount * 3));
        }
    }

    public unsafe ReadOnlySpan<uint> Indices
    {
        get
        {
            Solid.CheckCache(_generation);
            return _raw.Indices == IntPtr.Zero
                ? ReadOnlySpan<uint>.Empty
                : new ReadOnlySpan<uint>((void*)_raw.Indices, (int)_raw.IndexCount);
        }
    }

    /// <summary>The same triangles in memory of our own, safe to outlive the solid.</summary>
    public BlacksmithMeshData64 Copy() => new(Positions.ToArray(), Normals.ToArray(), Indices.ToArray());
}

/// <summary>A solid's feature edges as polylines -- views over the library's own cache at one
/// tolerance, under the same lifetime rule as <see cref="BlacksmithMesh"/>. Polyline `i` is
/// `Points[Offsets[i] * 3 .. Offsets[i + 1] * 3]`, three floats a point.</summary>
public sealed class BlacksmithPolylines
{
    private readonly RawBlacksmithPolylines _raw;

    public Solid Solid { get; }
    public double Tolerance { get; }
    private readonly int _generation;

    internal BlacksmithPolylines(Solid solid, double tolerance, int generation, RawBlacksmithPolylines raw)
    {
        Solid = solid;
        Tolerance = tolerance;
        _generation = generation;
        _raw = raw;
    }

    public int PointCount => (int)_raw.PointCount;
    public int PolylineCount => (int)_raw.PolylineCount;

    /// <summary>`(PointCount * 3)` floats, the polylines end to end.</summary>
    public unsafe ReadOnlySpan<float> Points
    {
        get
        {
            Solid.CheckCache(_generation);
            return _raw.Points == IntPtr.Zero
                ? ReadOnlySpan<float>.Empty
                : new ReadOnlySpan<float>((void*)_raw.Points, (int)(_raw.PointCount * 3));
        }
    }

    /// <summary>`(PolylineCount + 1)` point offsets; the last equals <see cref="PointCount"/>.
    /// </summary>
    public unsafe ReadOnlySpan<uint> Offsets
    {
        get
        {
            Solid.CheckCache(_generation);
            return _raw.Offsets == IntPtr.Zero
                ? ReadOnlySpan<uint>.Empty
                : new ReadOnlySpan<uint>((void*)_raw.Offsets, (int)(_raw.PolylineCount + 1));
        }
    }

    /// <summary>Polyline `i`'s points, three floats each -- what Python's list holds at `i`.
    /// </summary>
    public ReadOnlySpan<float> Polyline(int i)
    {
        var offsets = Offsets;
        var from = (int)offsets[i] * 3;
        var to = (int)offsets[i + 1] * 3;
        return Points.Slice(from, to - from);
    }

    /// <summary>Every polyline in memory of our own, one `(k * 3)` array each, safe to outlive
    /// the solid.</summary>
    public float[][] Copy()
    {
        var polylines = new float[PolylineCount][];
        for (var i = 0; i < polylines.Length; i++) polylines[i] = Polyline(i).ToArray();
        return polylines;
    }
}

/// <summary>One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain
/// breaks. Plain data, copied out of the handle -- a C# `ReadOnlySpan&lt;T&gt;` cannot be a field
/// of a class, so these two arrays are yours where <see cref="FemMesh.Nodes"/> and its siblings
/// are borrowed.</summary>
public sealed class FemEdge
{
    internal FemEdge(uint id, uint[] nodes, uint[] runs, (uint A, uint B) faces, (uint A, uint B) ends,
                     bool closed, bool seam)
    {
        Id = id;
        Nodes = nodes;
        Runs = runs;
        Faces = faces;
        Ends = ends;
        Closed = closed;
        Seam = seam;
    }

    /// <summary>The <strong>solid's own</strong> B-rep edge id, not this mesh's edge index.
    /// </summary>
    /// <remarks><see cref="FemMesh.Edges"/> is a densely renumbered subset of the solid's edges,
    /// ascending by id, with every edge collapsed to a point left out -- so a sphere, whose two
    /// pole runs collapse, reports its seam as edge 0 with an id of 1. Everything else that names
    /// an edge means the <em>index</em>: a <see cref="FemMesh.NodeKind"/> of 1 read through <see
    /// cref="FemMesh.NodeEntity"/>, the third number of a <see cref="FemMesh.OpenEdges"/> or <see
    /// cref="FemMesh.FoldedEdges"/> row, and the `edge_&lt;i&gt;` physical group of <see
    /// cref="FemMesh.MshText"/>. It is not a row of <see cref="Solid.Edges"/> either, that table
    /// being the solid's edges grouped by geometry; the id names the topological edge.</remarks>
    public uint Id { get; }

    /// <summary>This mesh's node indices in order along the edge, its end vertices included; a
    /// closed edge repeats no node.</summary>
    public uint[] Nodes { get; }

    /// <summary>Where each connected run of <see cref="Nodes"/> begins; `[0]` for one chain along
    /// the whole edge.</summary>
    /// <remarks><strong>Read `Nodes[Runs[i]..Runs[i + 1]]` (the last run to the end) as one
    /// polyline and join nothing across a boundary.</strong> The two ends either side of one are
    /// two points of the edge with no mesh edge between them. One run is the ordinary answer, and a
    /// caller reading <see cref="Nodes"/> as one polyline without looking here silently jumps the
    /// gap.</remarks>
    public uint[] Runs { get; }

    /// <summary>The two faces it bounds, `B` being `uint.MaxValue` on an open sheet's rim --
    /// <strong>`0` is a real face, not a sentinel.</strong></summary>
    /// <remarks>These number the solid's faces as <see cref="Solid.FaceKind"/> does.</remarks>
    public (uint A, uint B) Faces { get; }

    /// <summary>The two B-rep vertices its chain ends at, as <see cref="FemMesh.Vertices"/>
    /// indexes them, `B` being `uint.MaxValue` where both ends are one vertex -- a closed edge, a
    /// circle's rim, a full-turn seam. <strong>`0` is a real vertex, not a sentinel.</strong>
    /// Which end is `A` is the first trim's direction and means nothing else.</summary>
    public (uint A, uint B) Ends { get; }

    /// <summary>The nodes make one loop. False wherever <see cref="Runs"/> is longer than one.
    /// </summary>
    public bool Closed { get; }

    /// <summary>Bounded twice by one face: a closed surface's seam rather than a real boundary.
    /// <see cref="Faces"/>'s two are then that same face.</summary>
    public bool Seam { get; }

    public override string ToString() =>
        $"FemEdge(id={Id}, nodes={Nodes.Length}, runs={Runs.Length}, faces=({Faces.A},{Faces.B}), " +
        $"ends=({Ends.A},{Ends.B}), closed={Closed}, seam={Seam})";
}

/// <summary>One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where the
/// topology says it is, if that is known. Plain data, copied out of the handle.</summary>
public sealed class FemVertex
{
    internal FemVertex(uint node, double[] point, bool hasPosition)
    {
        Node = node;
        Point = point;
        HasPosition = hasPosition;
    }

    /// <summary>The mesh node at this vertex, or `uint.MaxValue` where the mesh has none there --
    /// <strong>ordinary rather than a fault</strong>: the analysis rebuilds a vertex wherever two
    /// trims meet, and a pole's polyline runs give a sphere 48 of them where the mesh has 2 points,
    /// so a caller walking these skips the sentinel rather than treating it as a gap.</summary>
    public uint Node { get; }

    /// <summary>Where the vertex is -- three doubles, in the same space and under the same
    /// placement as <see cref="FemMesh.Nodes"/>. <strong>Meaningless unless <see
    /// cref="HasPosition"/></strong>: it is all zeros then, a point no geometry has and one a
    /// solver would take for a node at the origin.</summary>
    public double[] Point { get; }

    /// <summary><see cref="Point"/> was placed.</summary>
    public bool HasPosition { get; }

    public override string ToString() =>
        $"FemVertex(node={Node}, point=({Point[0]},{Point[1]},{Point[2]}), hasPosition={HasPosition})";
}

/// <summary>One solid meshed for a solver: nodes welded by bits, triangles wound outward, every
/// node tagged with the lowest-dimension B-rep entity it lies on, and every crack reported rather
/// than closed. What <see cref="Solid.FemMesh"/> returns, and <strong>owned by you</strong>:
/// dispose it (a `using`), or <see cref="Free"/> it.</summary>
/// <remarks>A handle rather than a snapshot, as a <see cref="Solid"/> is, and its big arrays are
/// `ReadOnlySpan&lt;T&gt;` views into the library's own memory, as <see cref="BlacksmithMesh"/>'s
/// are and for the same reason: a solver mesh is megabytes.
///
/// <para><strong>The owner of these views is this object, not the solid.</strong> <see
/// cref="Solid.Dispose"/> does not free a FEM mesh, and meshing the solid again at another
/// tolerance does not stale one -- so this class carries none of the generation machinery <see
/// cref="BlacksmithMesh"/> has (see <see cref="Solid.CheckCache"/>): a FEM view's pointers are
/// built with the handle and never move.</para>
///
/// <para><strong>What the guard does and does not do.</strong> Every accessor below asks the
/// handle first, so a span <em>asked for</em> after <see cref="Free"/> throws. A span already in
/// hand is not protected and cannot be: a `ReadOnlySpan&lt;T&gt;` is a bare pointer and a length,
/// with nothing left to check by the time it is indexed -- it goes on reading the freed block and
/// hands back numbers that look like the mesh. <see cref="BlacksmithMesh"/>'s generation check is
/// no different in this respect, and neither is the reader's. So call `ToArray()` on any span that
/// must outlive the handle, and read the rest inside the `using`.</para>
///
/// <para>It is <see cref="Free"/> here where a <see cref="Solid"/> has <see
/// cref="Solid.Dispose"/>: this follows the reader library's `FemMesh` and `Meshlets`, so one FEM
/// mesh is released the same way on both sides of the ABI.</para></remarks>
public sealed class FemMesh : IDisposable
{
    internal FemMeshHandle Handle { get; }

    /// <summary>The view, read once in the constructor: every pointer in it is built with the
    /// handle and good until it is freed, nothing in this ABI being built lazily.</summary>
    private readonly RawBlacksmithFemMeshView _raw;

    internal FemMesh(FemMeshHandle handle)
    {
        Handle = Blacksmith.Checked(handle, "fem_mesh");
        var raw = new RawBlacksmithFemMeshView();
        if (!BlacksmithNative.cadaclysm_blacksmith_fem_mesh_view(Handle, ref raw))
        {
            var why = Blacksmith.Failure("fem_mesh_view");
            Handle.Dispose();
            throw why;
        }
        _raw = raw;
    }

    /// <summary>The handle, refusing a freed one: every pointer in the cached view is the
    /// handle's, and a freed handle's point at nothing.</summary>
    private FemMeshHandle Live => Handle.IsClosed ? throw new BuildException("fem mesh: freed") : Handle;

    /// <summary>The cached view, the handle checked first. Every read below goes through this.
    /// </summary>
    private RawBlacksmithFemMeshView Raw
    {
        get
        {
            _ = Live;
            return _raw;
        }
    }

    public bool Freed => Handle.IsClosed;

    /// <summary>A span over the FEM handle's own memory, the owner checked first. No generation
    /// check: unlike the solid's tessellation cache, a FEM view's pointers never move.</summary>
    private unsafe ReadOnlySpan<T> View<T>(IntPtr at, uint length)
    {
        _ = Live;
        return at == IntPtr.Zero ? ReadOnlySpan<T>.Empty : new ReadOnlySpan<T>((void*)at, (int)length);
    }

    /// <summary>Every node's position, three doubles each: placed by <see cref="Solid.FemMesh"/>'s
    /// placement, in the solid's own coordinates otherwise.</summary>
    public ReadOnlySpan<double> Nodes => View<double>(_raw.Nodes, _raw.NodeCount * 3);

    /// <summary>Three node indices a triangle, wound outward -- a mirroring placement is wound
    /// back.</summary>
    public ReadOnlySpan<uint> Triangles => View<uint>(_raw.Triangles, _raw.TriangleCount * 3);

    /// <summary>The face each triangle lies on, one per triangle: the same faces <see
    /// cref="Solid.FaceKind"/> names.</summary>
    public ReadOnlySpan<uint> TriangleFace => View<uint>(_raw.TriangleFace, _raw.TriangleCount);

    /// <summary>What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per
    /// node: the lowest-dimension entity it lies on, which is the `.msh` format's own
    /// classification rule. <see cref="NodeEntity"/> says which entity of that kind.</summary>
    public ReadOnlySpan<uint> NodeKind => View<uint>(_raw.NodeKind, _raw.NodeCount);

    /// <summary>Which vertex, edge or face each node lies on, read by the matching <see
    /// cref="NodeKind"/>: an index into <see cref="Vertices"/>, into <see cref="Edges"/>, or into
    /// the solid's faces. One per node.</summary>
    public ReadOnlySpan<uint> NodeEntity => View<uint>(_raw.NodeEntity, _raw.NodeCount);

    /// <summary>The solid's faces -- the same faces <see cref="Solid.Faces"/> counts.</summary>
    public uint FaceCount => Raw.FaceCount;

    /// <summary>One <see cref="FemEdge"/> per B-rep edge, in the order a <see cref="NodeKind"/> of
    /// `1` indexes them. <strong>Not <see cref="Solid.Edges"/>' numbering</strong>, and not the
    /// solid's own edge ids either -- each <see cref="FemEdge.Id"/> carries that.</summary>
    public IReadOnlyList<FemEdge> Edges
    {
        get
        {
            var handle = Live;
            var edges = new List<FemEdge>((int)_raw.EdgeCount);
            for (var i = 0u; i < _raw.EdgeCount; i++)
            {
                var raw = new RawBlacksmithFemEdge();
                if (!BlacksmithNative.cadaclysm_blacksmith_fem_mesh_edge(handle, i, ref raw))
                    throw Blacksmith.Failure($"fem_mesh_edge {i}");
                edges.Add(new FemEdge(raw.Id, Uints(raw.Nodes, raw.NodeCount), Uints(raw.Runs, raw.RunCount),
                    (raw.FaceA, raw.FaceB), (raw.EndA, raw.EndB), raw.Closed, raw.Seam));
            }
            return edges;
        }
    }

    /// <summary>One <see cref="FemVertex"/> per B-rep vertex, in the order a <see
    /// cref="NodeKind"/> of `0` indexes them.</summary>
    public IReadOnlyList<FemVertex> Vertices
    {
        get
        {
            var handle = Live;
            var vertices = new List<FemVertex>((int)_raw.VertexCount);
            for (var i = 0u; i < _raw.VertexCount; i++)
            {
                var raw = new RawBlacksmithFemVertex();
                if (!BlacksmithNative.cadaclysm_blacksmith_fem_mesh_vertex(handle, i, ref raw))
                    throw Blacksmith.Failure($"fem_mesh_vertex {i}");
                vertices.Add(new FemVertex(raw.Node, PointOf(raw), raw.HasPosition));
            }
            return vertices;
        }
    }

    /// <summary>Every crack, as `(A, B, BrepEdge)`: a directed mesh edge `(A, B)` with no `(B, A)`,
    /// and the B-rep edge both nodes lie on or `uint.MaxValue` where they share none.</summary>
    /// <remarks><strong>Empty unless the solid's topology is closed</strong>, whose mesh is
    /// otherwise not asked about at all -- an open sheet from <see cref="Solid.Face"/>, <see
    /// cref="Solid.FaceSheet"/>, <see cref="Solid.DropFaces"/> or <see cref="Solid.ExtrudeOpen"/>
    /// reports <see cref="Watertight"/> false with this and <see cref="FoldedEdges"/> <em>both</em>
    /// empty, and that trio together says "not asked", not "nothing found".</remarks>
    public IReadOnlyList<(uint A, uint B, uint BrepEdge)> OpenEdges =>
        Census(BlacksmithNative.cadaclysm_blacksmith_fem_mesh_open_edge, Raw.OpenEdgeCount, "fem_mesh_open_edge");

    /// <summary>Every fold, as <see cref="OpenEdges"/> reports a crack: a directed mesh edge used
    /// by more than one triangle.</summary>
    /// <remarks><strong>A solid can be folded without being open</strong> -- one no thicker than a
    /// line leaves no hole for an open edge to find -- so a caller that checks <see
    /// cref="OpenEdges"/> alone calls such a body sound.</remarks>
    public IReadOnlyList<(uint A, uint B, uint BrepEdge)> FoldedEdges =>
        Census(BlacksmithNative.cadaclysm_blacksmith_fem_mesh_folded_edge, Raw.FoldedEdgeCount, "fem_mesh_folded_edge");

    /// <summary>The library's two census readers have one shape, so the two lists cannot drift.
    /// </summary>
    private delegate bool CensusRow(FemMeshHandle mesh, uint index, out uint a, out uint b, out uint brepEdge);

    private IReadOnlyList<(uint A, uint B, uint BrepEdge)> Census(CensusRow row, uint count, string what)
    {
        var handle = Live;
        var rows = new List<(uint, uint, uint)>((int)count);
        for (var i = 0u; i < count; i++)
        {
            if (!row(handle, i, out var a, out var b, out var brepEdge)) throw Blacksmith.Failure($"{what} {i}");
            rows.Add((a, b, brepEdge));
        }
        return rows;
    }

    /// <summary>The topology is closed and the welded mesh is too. <strong>False for every solid
    /// whose topology is not closed</strong>; see <see cref="OpenEdges"/> for what an empty census
    /// beside a false here does and does not mean.</summary>
    public bool Watertight => Raw.Watertight;

    /// <summary><strong>Always false here</strong>, and kept so the two ABIs' views are one struct:
    /// a <see cref="Solid"/> always has a brep behind it, so this library has no mesh-only body to
    /// report.</summary>
    /// <remarks>The reader library's `Node.FemMesh` sets it for a node with no brep (a JT, an STL,
    /// an OpenSCAD body), where it also says which space the mesh is in -- here there is only one
    /// space, the solid's own under the placement -- and where a true one means the census speaks
    /// from the triangles alone rather than from a topology. <strong>That second difference cannot
    /// arise here</strong>, so <see cref="OpenEdges"/>' "empty unless the topology is closed" holds
    /// without exception on this side of the ABI.</remarks>
    public bool FromMesh => Raw.FromMesh;

    /// <summary>The smallest interior angle of any triangle, in degrees. There is always one: a
    /// solid that meshed to no triangles is a refusal, not a mesh.</summary>
    public double MinAngle => Raw.MinAngle;

    /// <summary>The triangle with that angle, as an index into <see cref="Triangles"/> by triple.
    /// </summary>
    public uint WorstTriangle => Raw.WorstTriangle;

    /// <summary>The longest triangle edge, placed.</summary>
    /// <remarks><strong>The figure to check against <see cref="Solid.FemMesh"/>'s `maxSize`, and
    /// the only one that says what the mesh actually is.</strong> `maxSize` bounds the boundary
    /// segments and merely <em>targets</em> the interior: measured at 1.03 x `maxSize` on a face
    /// whose parameters run unevenly. One small enough beside the solid to reach the mesher's own
    /// piece and station ceilings is not honoured at all.</remarks>
    public double LongestEdge => Raw.LongestEdge;

    /// <summary>The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face,
    /// a volume where the solid closes, and a physical group naming each.</summary>
    /// <remarks><strong>The library's text is owned and released here</strong> with
    /// `cadaclysm_blacksmith_string_free`, as every other text this library hands over (<see
    /// cref="Solid.StepText"/>, <see cref="Solid.SatText"/>, <see cref="Solid.BrepText"/>, <see
    /// cref="Solid.SvgText"/>). Two asks give two independent texts, and neither dies with the
    /// handle. The reader library's `FemMesh.MshText` is the other way round -- it borrows from a
    /// slot on its own handle and must not be freed -- so a reader porting one side's reasoning
    /// onto the other leaks or double-frees.
    ///
    /// <para><strong>The unlicensed notice is printed here</strong>, on this writer and on <see
    /// cref="SaveMsh"/>, and <em>not</em> by <see cref="Solid.FemMesh"/>: meshing is not a licensed
    /// output and the `.msh` file is, which is where <see cref="Solid.SatText"/> and <see
    /// cref="Solid.BrepText"/> put theirs too. The reader library notices in its builder instead
    /// and on neither `.msh` call; each matches its own siblings, so moving the call to look like
    /// the other side breaks a convention.</para>
    ///
    /// <para>Throws <see cref="BuildException"/> for a mesh the writer refuses, naming the field it
    /// cannot honour, and for a freed handle.</para></remarks>
    public string MshText()
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_fem_mesh_msh_text(Live);
        if (raw == IntPtr.Zero) throw Blacksmith.Failure("fem_mesh_msh_text");
        try
        {
            return Marshal.PtrToStringUTF8(raw) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
        }
    }

    /// <summary><see cref="MshText"/> written to <paramref name="path"/>, replacing any file there,
    /// by the library itself. Throws for a mesh the writer refuses or a file it cannot write,
    /// naming the path. Prints the unlicensed notice; see <see cref="MshText"/>.</summary>
    public void SaveMsh(string path)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_fem_mesh_save_msh(Live, path))
            throw Blacksmith.Failure($"fem_mesh_save_msh: {path}");
    }

    /// <summary>Give the mesh back, and with it every span taken from it. Idempotent. The `.msh`
    /// texts are not freed with it: each is already a `string` of yours.</summary>
    public void Free() => Handle.Dispose();

    public void Dispose() => Free();

    /// <summary>A vertex's own three doubles, out of the fixed buffer the struct holds them in --
    /// the one read here that needs `unsafe`, kept off <see cref="Vertices"/>'s own signature.
    /// </summary>
    private static unsafe double[] PointOf(RawBlacksmithFemVertex raw) =>
        new[] { raw.Point[0], raw.Point[1], raw.Point[2] };

    /// <summary>`count` uint32s at `at`, copied out: a <see cref="FemEdge"/>'s chain cannot hold a
    /// span, so those two are copies where the mesh's own arrays are views.</summary>
    private static unsafe uint[] Uints(IntPtr at, uint count) =>
        at == IntPtr.Zero ? Array.Empty<uint>() : new ReadOnlySpan<uint>((void*)at, (int)count).ToArray();

    public override string ToString() =>
        Freed ? "FemMesh(freed)"
            : $"FemMesh(nodes={_raw.NodeCount}, triangles={_raw.TriangleCount}, " +
              $"watertight={_raw.Watertight}, fromMesh={_raw.FromMesh})";
}

/// <summary>An exact B-rep solid (or open sheet). Immutable; every operation returns a new
/// one. Dispose it to free it; the runtime does so otherwise, through its handle.</summary>
public sealed class Solid : IDisposable
{
    private readonly SolidHandle _handle;

    /// <summary>The tolerance the library's tessellation cache was last filled at (null before
    /// any of <see cref="Mesh"/>, <see cref="EdgePolylines"/> and <see cref="BoundsAt"/> ran),
    /// and how many times it has been filled. The library replaces the cache whole whenever it
    /// is asked for a tolerance other than the one it holds, so a view is tied to a
    /// <em>filling</em>, not a tolerance: after 0.05, 0.5, 0.05 the first view's memory is
    /// gone even though the cache is back at its tolerance. A view checks the generation it
    /// was cut from, never the tolerance.</summary>
    private double? _cacheTolerance;
    private int _cacheGeneration;

    /// <summary>Record that a call just tessellated at `tolerance`: a new filling if it differs
    /// from the one the cache held. Returns the generation a view made now belongs to.</summary>
    private int Filled(double tolerance)
    {
        if (_cacheTolerance != tolerance)
        {
            _cacheTolerance = tolerance;
            _cacheGeneration++;
        }
        return _cacheGeneration;
    }

    internal Solid(SolidHandle handle)
    {
        _handle = Blacksmith.Checked(handle, "solid");
    }

    /// <summary>The handle, refusing to hand over a disposed one, so a use-after-dispose
    /// throws at the call site instead of passing a dangling pointer into the library. (The
    /// marshaller would refuse it too; this keeps the message the binding's own.)</summary>
    internal SolidHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Solid), "solid: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the solid back. Idempotent. Every <see cref="BlacksmithMesh"/> and
    /// <see cref="BlacksmithPolylines"/> still held throws on its next read.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>A view cut from filling `generation` may read only while that filling is the
    /// one the solid holds; a disposed solid has none.</summary>
    internal void CheckCache(int generation)
    {
        _ = Handle;
        if (_cacheGeneration != generation)
            throw new InvalidOperationException(
                $"the view is stale: the solid's tessellation has been replaced since (now at tolerance {_cacheTolerance})");
    }

    // -- building

    /// <summary>A box `x` by `y` by `z`, centred on the origin.</summary>
    public static Solid Cuboid(double x, double y, double z) => new(BlacksmithNative.cadaclysm_blacksmith_cuboid(x, y, z));

    /// <summary>A cylinder of radius `r`, height `h`, based on z=0 and rising along +z.</summary>
    public static Solid Cylinder(double r, double h) => new(BlacksmithNative.cadaclysm_blacksmith_cylinder(r, h));

    /// <summary>A cone of base radius `r` and height `h`, apex up.</summary>
    public static Solid Cone(double r, double h) => new(BlacksmithNative.cadaclysm_blacksmith_cone(r, h));

    /// <summary>A sphere of radius `r` about the origin.</summary>
    public static Solid Sphere(double r) => new(BlacksmithNative.cadaclysm_blacksmith_sphere(r));

    /// <summary>A torus of ring radius `major` and tube radius `minor`, about z.</summary>
    public static Solid Torus(double major, double minor) => new(BlacksmithNative.cadaclysm_blacksmith_torus(major, minor));

    /// <summary>A box `x` by `y` by `z` whose top face is narrowed to `topX` along x.</summary>
    public static Solid Wedge(double x, double y, double z, double topX) =>
        new(BlacksmithNative.cadaclysm_blacksmith_wedge(x, y, z, topX));

    /// <summary>`profile` swept `height` along the frame's z, closed with two caps.</summary>
    public static Solid Extrude(Profile profile, double[] frame, double height) =>
        new(BlacksmithNative.cadaclysm_blacksmith_extrude(profile.Handle, Blacksmith.Frame(frame), height));

    /// <summary><see cref="Extrude"/> without the caps: an open sheet of walls.</summary>
    public static Solid ExtrudeOpen(Profile profile, double[] frame, double height) =>
        new(BlacksmithNative.cadaclysm_blacksmith_extrude_open(profile.Handle, Blacksmith.Frame(frame), height));

    /// <summary><see cref="Extrude"/> with a draft: the walls lean out by `taper` radians as
    /// they rise (in, when negative), every wall exact -- a plane off a line, a cone off an
    /// arc. A taper of zero is <see cref="Extrude"/>.</summary>
    public static Solid ExtrudeTapered(Profile profile, double[] frame, double height, double taper) =>
        new(BlacksmithNative.cadaclysm_blacksmith_extrude_tapered(profile.Handle, Blacksmith.Frame(frame), height, taper));

    public static Solid ExtrudeOpenTapered(Profile profile, double[] frame, double height, double taper) =>
        new(BlacksmithNative.cadaclysm_blacksmith_extrude_open_tapered(profile.Handle, Blacksmith.Frame(frame), height, taper));

    /// <summary><see cref="Extrude"/> between two planes instead of two heights: `bottom` and
    /// `top` are each a <see cref="Slant"/> (a bare number converts to `Slant.Flat(number)`).
    /// The profile's walls run from where `bottom` cuts them to where `top` does, the caps
    /// lying on those planes. With both flat this <em>is</em> <see cref="Extrude"/> (bit for
    /// bit); with a slope it is the mitred end of a sweep's straight piece. Throws
    /// <see cref="BuildException"/> where the top plane comes down to or through the bottom
    /// across the profile.</summary>
    public static Solid ExtrudeBetween(Profile profile, double[] frame, Slant bottom, Slant top) =>
        new(BlacksmithNative.cadaclysm_blacksmith_extrude_between(profile.Handle, Blacksmith.Frame(frame), bottom.Raw(), top.Raw()));

    /// <summary><see cref="ExtrudeBetween"/> without the caps: an open sheet of walls running
    /// from `bottom` to `top`, as <see cref="ExtrudeOpen"/> is to <see cref="Extrude"/>.
    /// </summary>
    public static Solid ExtrudeOpenBetween(Profile profile, double[] frame, Slant bottom, Slant top) =>
        new(BlacksmithNative.cadaclysm_blacksmith_extrude_open_between(profile.Handle, Blacksmith.Frame(frame), bottom.Raw(), top.Raw()));

    /// <summary>The solid between `a` on `frameA` and `b` on `frameB`: ruled walls between
    /// matching sides (the profiles must have the same number of sides, and no holes), capped
    /// by the two profiles.</summary>
    public static Solid Loft(Profile a, double[] frameA, Profile b, double[] frameB) =>
        new(BlacksmithNative.cadaclysm_blacksmith_loft(a.Handle, Blacksmith.Frame(frameA), b.Handle, Blacksmith.Frame(frameB)));

    /// <summary><see cref="Loft"/> without the caps: the sheet ruled between the two curves.
    /// </summary>
    public static Solid LoftOpen(Profile a, double[] frameA, Profile b, double[] frameB) =>
        new(BlacksmithNative.cadaclysm_blacksmith_loft_open(a.Handle, Blacksmith.Frame(frameA), b.Handle, Blacksmith.Frame(frameB)));

    /// <summary>The solid smooth through every section -- a profile on its frame, in order:
    /// each wall interpolates its side across all the profiles (cubic through four or more,
    /// quadratic through three, <see cref="Loft"/> through two), capped by the first and the
    /// last. The profiles must have the same number of sides and no holes.</summary>
    public static Solid LoftThrough(IEnumerable<(Profile Profile, double[] Frame)> sections) =>
        LoftedThrough(sections, true);

    /// <summary><see cref="LoftThrough"/> without the caps: the sheet through the curves.</summary>
    public static Solid LoftThroughOpen(IEnumerable<(Profile Profile, double[] Frame)> sections) =>
        LoftedThrough(sections, false);

    private static Solid LoftedThrough(IEnumerable<(Profile Profile, double[] Frame)> sections, bool solid)
    {
        var all = sections.ToArray();
        var handles = all.Select(s => s.Profile.Handle.DangerousGetHandle()).ToArray();
        var frames = all.SelectMany(s => Blacksmith.Frame(s.Frame)).ToArray();
        var made = solid
            ? BlacksmithNative.cadaclysm_blacksmith_loft_through(handles, frames, (nuint)handles.Length)
            : BlacksmithNative.cadaclysm_blacksmith_loft_through_open(handles, frames, (nuint)handles.Length);
        GC.KeepAlive(all);
        return new Solid(made);
    }

    /// <summary>`profile` swung `angle` radians about `axis` (six numbers: a point and a
    /// direction).</summary>
    public static Solid Revolve(Profile profile, double[] axis, double angle) =>
        new(BlacksmithNative.cadaclysm_blacksmith_revolve(profile.Handle, Blacksmith.AxisOf(axis), angle));

    public static Solid RevolveOpen(Profile profile, double[] axis, double angle) =>
        new(BlacksmithNative.cadaclysm_blacksmith_revolve_open(profile.Handle, Blacksmith.AxisOf(axis), angle));

    /// <summary>`profile` coiled about `axis` (six numbers: a point and a direction): read as
    /// <see cref="Revolve"/> reads it -- x the distance from the axis, y along it -- and turned
    /// `turns` times while climbing `pitch` along the axis each turn: a spring, a thread. The
    /// two ends are the profile itself, flat; from a full turn up the pitch must be taller
    /// than the profile.</summary>
    public static Solid Coil(Profile profile, double[] axis, double pitch, double turns) =>
        new(BlacksmithNative.cadaclysm_blacksmith_coil(profile.Handle, Blacksmith.AxisOf(axis), pitch, turns));

    /// <summary>`profile`, drawn on `frame`, swung `angle` radians about the axis through the
    /// sketch points `a` and `b` (on the frame) -- the profile and its axis drawn together,
    /// where <see cref="Revolve"/> reads the profile as (radius, height). The profile may lie
    /// on either side of the axis and touch it, not cross it; the sweep starts where it is
    /// drawn and turns right-handed about `b - a`.</summary>
    public static Solid RevolveInPlane(Profile profile, double[] frame, (double X, double Y) a, (double X, double Y) b, double angle) =>
        new(BlacksmithNative.cadaclysm_blacksmith_revolve_in_plane(profile.Handle, Blacksmith.Frame(frame), new[] { a.X, a.Y, b.X, b.Y }, angle));

    /// <summary><see cref="RevolveInPlane"/> for a curve: its segments swung into a sheet.</summary>
    public static Solid RevolveOpenInPlane(Profile profile, double[] frame, (double X, double Y) a, (double X, double Y) b, double angle) =>
        new(BlacksmithNative.cadaclysm_blacksmith_revolve_open_in_plane(profile.Handle, Blacksmith.Frame(frame), new[] { a.X, a.Y, b.X, b.Y }, angle));

    /// <summary>`profile`, drawn on `frame`, carried along `path` into a closed solid: a
    /// straight piece of the path is an extrusion, a circular piece a revolution about the
    /// arc's axis, so nothing is approximated -- a circle along an arc is an exact torus wall.
    /// `path` is only borrowed, not consumed; sweep it again, open or closed, as often as
    /// needed.</summary>
    public static Solid Sweep(Profile profile, double[] frame, SweepPath path) =>
        new(BlacksmithNative.cadaclysm_blacksmith_sweep(profile.Handle, Blacksmith.Frame(frame), path.Live));

    /// <summary><see cref="Sweep"/> for a curve rather than a face: one wall per segment per
    /// piece, no caps -- an open sheet, the way <see cref="ExtrudeOpen"/> is to
    /// <see cref="Extrude"/>.</summary>
    public static Solid SweepOpen(Profile profile, double[] frame, SweepPath path) =>
        new(BlacksmithNative.cadaclysm_blacksmith_sweep_open(profile.Handle, Blacksmith.Frame(frame), path.Live));

    /// <summary>A circle of `radius` swept along `path`, square to its start: a rod, or with a positive `thickness` a tube whose walls are that thick. `path`
    /// is only borrowed, as by <see cref="Sweep"/>.</summary>
    public static Solid Pipe(SweepPath path, double radius, double thickness = 0.0) =>
        new(BlacksmithNative.cadaclysm_blacksmith_pipe(path.Live, radius, thickness));

    /// <summary>Every face of this sheet pushed `height` along its own normal, walled and
    /// closed: the sheet as a solid of that thickness.</summary>
    public Solid ExtrudeFaces(double height) => new(BlacksmithNative.cadaclysm_blacksmith_extrude_faces(Handle, height));

    /// <summary>The flat sheet `profile` bounds on `frame`: one planar face, each hole a hole
    /// through it, its normal `frame`'s z, every edge the exact line, arc or spline its segment
    /// is. An open sheet -- raise it with <see cref="ExtrudeFaces"/>, cut it with
    /// <see cref="Trim"/>.</summary>
    public static Solid Face(Profile profile, double[] frame) =>
        new(BlacksmithNative.cadaclysm_blacksmith_face(profile.Handle, Blacksmith.Frame(frame)));

    /// <summary>Face `face` alone, as an open sheet: its surface, loops and exact edge curves,
    /// the rest of the solid left behind.</summary>
    public Solid FaceSheet(int face) => new(BlacksmithNative.cadaclysm_blacksmith_face_sheet(Handle, (uint)face));

    /// <summary>This solid without the faces at `faces`: the rest keep their order, so an index
    /// into the result is this one's with the dropped ones closed up.</summary>
    public Solid DropFaces(IEnumerable<int> faces)
    {
        var which = faces.Select(f => (uint)f).ToArray();
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_drop_faces(Handle, which, (nuint)which.Length));
    }

    /// <summary>This solid, built about the origin, moved onto `frame`.</summary>
    public Solid Place(double[] frame) => new(BlacksmithNative.cadaclysm_blacksmith_place(Handle, Blacksmith.Frame(frame)));

    public Solid Translate(double dx, double dy, double dz) =>
        new(BlacksmithNative.cadaclysm_blacksmith_translate(Handle, dx, dy, dz));

    /// <summary>This solid scaled by <paramref name="factor"/> about the origin: every length times it, exactly.</summary>
    public Solid Scaled(double factor) =>
        new(BlacksmithNative.cadaclysm_blacksmith_scaled(Handle, factor));

    /// <summary>This solid turned `radians` about `axis` (six numbers: a point and a
    /// direction).</summary>
    public Solid Rotate(double[] axis, double radians) =>
        new(BlacksmithNative.cadaclysm_blacksmith_rotate(Handle, Blacksmith.AxisOf(axis), radians));

    /// <summary>This solid reflected across `plane` (a frame; its z is the plane's normal).
    /// </summary>
    public Solid Mirror(double[] plane) => new(BlacksmithNative.cadaclysm_blacksmith_mirror(Handle, Blacksmith.Frame(plane)));

    // -- combining

    /// <summary>This solid and `other` as one. `merge` merges the flush faces the join leaves
    /// (<see cref="MergeFlush"/>), off by default, so face and edge numbers
    /// stay as they were.</summary>
    public Solid Join(Solid other, double tolerance = 0.05, bool merge = false) =>
        Merged(new(BlacksmithNative.cadaclysm_blacksmith_join(Handle, other.Handle, tolerance, IntPtr.Zero, IntPtr.Zero)), merge);

    /// <summary>This solid with `other` removed; `merge` as <see cref="Join"/>'s.</summary>
    public Solid Cut(Solid other, double tolerance = 0.05, bool merge = false) =>
        Merged(new(BlacksmithNative.cadaclysm_blacksmith_cut(Handle, other.Handle, tolerance, IntPtr.Zero, IntPtr.Zero)), merge);

    /// <summary>What this solid and `other` share; `merge` as <see cref="Join"/>'s.</summary>
    public Solid Common(Solid other, double tolerance = 0.05, bool merge = false) =>
        Merged(new(BlacksmithNative.cadaclysm_blacksmith_common(Handle, other.Handle, tolerance, IntPtr.Zero, IntPtr.Zero)), merge);

    /// <summary>`solid`, its flush faces merged when `merge`; the unmerged one disposed.</summary>
    private static Solid Merged(Solid solid, bool merge)
    {
        if (!merge) return solid;
        using (solid) return solid.MergeFlush();
    }

    /// <summary>This solid (a sheet or a solid) cut along `tool`'s boundary, nothing removed:
    /// every face comes back in its pieces outside `tool` and its pieces inside, each piece a
    /// face, in this solid's own face order with each face's outside pieces before its inside
    /// pieces. `tool` must be a closed solid. Keep or discard pieces with
    /// <see cref="DropFaces"/>; <see cref="Trim"/> is the split with one side dropped.</summary>
    public Solid SplitSheet(Solid tool, double tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_split_sheet(Handle, tool.Handle, tolerance, IntPtr.Zero, IntPtr.Zero));

    /// <summary>This sheet (or solid) cut along the closed `tool`'s boundary and the pieces on
    /// one side thrown away: `keep` "outside" keeps what lies outside the tool (a hole punched
    /// through), "inside" what lies within it.</summary>
    public Solid Trim(Solid tool, string keep = "outside", double tolerance = 0.05)
    {
        if (keep != "outside" && keep != "inside")
            throw new BuildException($"trim: keep must be 'outside' or 'inside', not '{keep}'");
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_trim(Handle, tool.Handle, keep == "inside", tolerance,
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary>Where this solid's faces cross or coincide with `other`'s, at `tolerance`, as an
    /// <see cref="Intersection"/>: <see cref="Intersection.Chains"/> along the curves the faces
    /// meet on and <see cref="Intersection.Overlaps"/> where a face pair coincides. Neither
    /// solid is changed; either may be an open sheet. No crossing is an empty result, never an
    /// error.
    ///
    /// Each <see cref="Chain"/>'s points are within `tolerance` of both faces' exact surfaces;
    /// there is one chain per face pair per branch -- chains are not joined across a face
    /// boundary or a closed curve's seam, so join them by matching ends. A chain's
    /// <see cref="Chain.Curve"/> is its exact curve where the kernel found one every point lies
    /// within `tolerance` of, else null; <see cref="Chain.Tangent"/> is set where the surfaces
    /// are near-tangent along the chain or the snap did not settle (the points are then the best
    /// estimate) -- a closed chain that does not go once round its own curve (a sliver where two
    /// surfaces barely cross) has no curve, `Tangent` still true. An <see cref="Overlap"/> is a
    /// coincident face pair with the shared region's rings (outer first, holes after), which may
    /// be empty for a partial overlap whose outlines cross. Known limit: a crossing narrower than
    /// `tolerance` -- two surfaces passing within it without their meshes crossing -- can be
    /// missed; near-tangent contact is where this bites.
    ///
    /// Throws <see cref="BuildException"/> for a `tolerance` not positive and finite, a solid
    /// with no faces, or one that meshes to nothing.</summary>
    public Intersection Intersect(Solid other, double tolerance = 0.05)
    {
        using var found = Blacksmith.Checked(
            BlacksmithNative.cadaclysm_blacksmith_intersect(Handle, other.Handle, tolerance, IntPtr.Zero, IntPtr.Zero), "intersect");
        var n = BlacksmithNative.cadaclysm_blacksmith_intersection_chain_count(found);
        var chains = new List<Chain>((int)n);
        for (uint i = 0; i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_intersection_chain(found, i, out var raw)) throw Blacksmith.Failure("intersection_chain");
            Curve? curve = null;
            if (raw.HasCurve)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_intersection_curve(found, i, out var rawCurve)) throw Blacksmith.Failure("intersection_curve");
                curve = new Curve(rawCurve);
            }
            chains.Add(new Chain(raw, curve));
        }
        n = BlacksmithNative.cadaclysm_blacksmith_intersection_overlap_count(found);
        var overlaps = new List<Overlap>((int)n);
        for (uint i = 0; i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_intersection_overlap(found, i, out var raw)) throw Blacksmith.Failure("intersection_overlap");
            overlaps.Add(new Overlap(raw));
        }
        return new Intersection(chains, overlaps);
    }

    /// <summary>Where <paramref name="profile"/>, placed on <paramref name="frame"/>, pierces this
    /// solid's faces, and the pieces its loops cut into, as a <see cref="SolidHits"/>. Neither is
    /// changed.
    ///
    /// A point hit lies within `tolerance` of the segment's exact curve and of the face's exact
    /// surface, inside the face's trim; its profile spot (<see cref="Hit.AStart"/>: loop, segment,
    /// t) and face spot (<see cref="Hit.BStart"/>: face, u, v) evaluate to the point within
    /// `tolerance`; <see cref="Hit.Touch"/> where the curve's tangent lies within 1e-3 (sine) of
    /// the surface's tangent plane there (a graze), false at a crossing. A run is a stretch of one
    /// segment lying within `tolerance` of one face and inside it, longer than `tolerance`. Hits
    /// within `tolerance` of each other merge (a hit at a segment join reported once, as
    /// `(k, t = 1)`; a closed loop's closing join reads `(0, 0)`). Every point is in
    /// world space (the frame applied).
    ///
    /// Pieces only for a closed body -- an open body has none -- in loop order, covering every
    /// loop exactly; a piece's spots read a segment join as the next segment's start `(k + 1, 0)`,
    /// and an open chain runs from `(0, 0)` to `(n - 1, 1)`; a loop no hit cuts is one closed
    /// piece. <see cref="Piece.Inside"/> by the piece middle's winding number over the body's
    /// mesh; a piece lying on the surface is inside. Known limit: a segment passing within
    /// `tolerance` of a face without crossing its mesh can be missed (near-tangent grazes).
    ///
    /// Throws <see cref="BuildException"/> for a `tolerance` not positive and finite, a solid with
    /// no faces or that meshes to nothing, a profile with no segments, or a free-form segment that
    /// is not an evaluable NURBS curve.</summary>
    public SolidHits Hits(Profile profile, double[] frame, double tolerance = 0.05)
    {
        using var found = Blacksmith.Checked(
            BlacksmithNative.cadaclysm_blacksmith_solid_profile_hits(Handle, profile.Handle, Blacksmith.Frame(frame), tolerance,
                IntPtr.Zero, IntPtr.Zero), "solid_profile_hits");
        var n = BlacksmithNative.cadaclysm_blacksmith_hit_count(found);
        var hits = new List<Hit>((int)n);
        for (uint i = 0; i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_hit(found, i, out var raw)) throw Blacksmith.Failure("hit");
            hits.Add(new Hit(raw));
        }
        n = BlacksmithNative.cadaclysm_blacksmith_hits_piece_count(found);
        var pieces = new List<Piece>((int)n);
        for (uint i = 0; i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_hits_piece(found, i, out var inside, out var start, out var end))
                throw Blacksmith.Failure("hits_piece");
            var own = new Profile(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_hits_piece_profile(found, i), "hits_piece_profile"));
            pieces.Add(new Piece(inside, new Spot(start), new Spot(end), own));
        }
        return new SolidHits(hits, pieces);
    }

    // -- asking

    /// <summary>How many faces, in the solid's own order; a face index runs to this.</summary>
    public int Faces
    {
        get
        {
            var n = BlacksmithNative.cadaclysm_blacksmith_face_count(Handle);
            if (n == 0 && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("face_count");
            return (int)n;
        }
    }

    /// <summary>The face's surface kind: "plane", "cylinder", "cone", "sphere", "torus",
    /// "nurbs", "revolution", "extrusion", "other", or "none" for a face without a surface.
    /// </summary>
    public string FaceKind(int face)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_face_kind(Handle, Index(face));
        if (raw == IntPtr.Zero) throw Blacksmith.Failure("face_kind");
        return Blacksmith.Text(raw);
    }

    /// <summary><see cref="BoundsAt"/> at tolerance 0.05.</summary>
    public (double[] Min, double[] Max) Bounds => BoundsAt(0.05);

    /// <summary>The solid's axis-aligned bounds, over the positions of its cached
    /// tessellation at `tolerance` (the same cache <see cref="Mesh"/> fills and reuses, so a
    /// second call at the same tolerance is free).</summary>
    public (double[] Min, double[] Max) BoundsAt(double tolerance)
    {
        double[] lo = new double[3], hi = new double[3];
        if (!BlacksmithNative.cadaclysm_blacksmith_bounds(Handle, tolerance, lo, hi)) throw Blacksmith.Failure("bounds");
        Filled(tolerance);
        return (lo, hi);
    }

    /// <summary><see cref="BoundsAt64"/> at tolerance 0.05.</summary>
    public (double[] Min, double[] Max) Bounds64 => BoundsAt64(0.05);

    /// <summary><see cref="BoundsAt"/>, from the same tessellation's unnarrowed positions:
    /// exact far from the origin, where <see cref="BoundsAt"/>'s widened `float` positions
    /// are not.</summary>
    public (double[] Min, double[] Max) BoundsAt64(double tolerance)
    {
        double[] lo = new double[3], hi = new double[3];
        if (!BlacksmithNative.cadaclysm_blacksmith_bounds64(Handle, tolerance, lo, hi)) throw Blacksmith.Failure("bounds64");
        Filled(tolerance);
        return (lo, hi);
    }

    /// <summary>How many edges of the mesh at `tolerance` are bound by anything other than
    /// exactly two triangles -- zero for a closed solid. A seam two solids share along a line
    /// (four triangles, two pairs) does <em>not</em> count here; a genuine hole or a fold does.
    /// </summary>
    public int LeakedEdges(double tolerance = 0.05)
    {
        var n = BlacksmithNative.cadaclysm_blacksmith_leaked_edges(Handle, tolerance);
        if (n == Blacksmith.None) throw Blacksmith.Failure("leaked_edges");
        return (int)n;
    }

    /// <summary>How many edges of the mesh at `tolerance` have directed triangle uses that do
    /// not cancel out -- zero for a closed, consistently oriented solid. Where
    /// <see cref="LeakedEdges"/> asks for exactly two triangles on an edge, this asks that
    /// they run opposite ways: a shared seam pairs off and is <em>not</em> counted, a fold --
    /// two triangles running the same way -- is.</summary>
    public int UnpairedEdges(double tolerance = 0.05)
    {
        var n = BlacksmithNative.cadaclysm_blacksmith_unpaired_edges(Handle, tolerance);
        if (n == Blacksmith.None) throw Blacksmith.Failure("unpaired_edges");
        return (int)n;
    }

    /// <summary>`LeakedEdges(tolerance) == 0`.</summary>
    public bool IsWatertight(double tolerance = 0.05) => LeakedEdges(tolerance) == 0;

    /// <summary>Whether the faces make a manifold -- every edge bordered by one face or two, the
    /// faces round every vertex one fan -- and whether it is closed. Read off the solid's
    /// topology, not a mesh, so it takes no tolerance; whether the faces all face out is
    /// <see cref="UnpairedEdges"/>'s question.</summary>
    public Manifold Manifold
    {
        get
        {
            var row = new uint[8];
            if (!BlacksmithNative.cadaclysm_blacksmith_manifold(Handle, row)) throw Blacksmith.Failure("manifold");
            return new Manifold(row);
        }
    }

    // -- naming

    /// <summary>This solid, named <paramref name="name"/>. The name rides through an operation
    /// with exactly one source solid (<see cref="Place"/>, <see cref="Translate"/>,
    /// <see cref="Coloured"/>, <see cref="Fillet"/>, ...) and is dropped by one with two or more
    /// (<see cref="Join"/>, <see cref="Cut"/>, <see cref="Common"/>, ...) and by a fresh
    /// primitive or sweep -- see <see cref="Name"/>. It is what <see cref="Assembly.Place"/>
    /// defaults a placement's own name to, and the product name a lone named solid gets when
    /// written to STEP (<see cref="Step"/>/<see cref="StepText"/>). Refused for an empty name.
    /// </summary>
    public Solid Named(string name) => new(BlacksmithNative.cadaclysm_blacksmith_named(Handle, name));

    /// <summary>This solid's name, or null if it has none -- what <see cref="Named"/> set, kept
    /// or dropped by whatever built this solid (see <see cref="Named"/>). The library's borrowed
    /// pointer is null for both "no name" and a failure, so this never consults `last_error` --
    /// same as Python's own `name` -- and it reads the pointer itself rather than through
    /// <see cref="Blacksmith.Text"/>, which maps null to "" and would erase the distinction.
    /// </summary>
    public string? Name
    {
        get
        {
            var raw = BlacksmithNative.cadaclysm_blacksmith_solid_name(Handle);
            var result = raw == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(raw);
            GC.KeepAlive(this);
            return result;
        }
    }

    // -- out

    /// <summary>The triangles at `tolerance`, as views into the solid's cache. See the file
    /// header for what invalidates them.</summary>
    public BlacksmithMesh Mesh(double tolerance = 0.05)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_mesh(Handle, tolerance);
        if (raw.Positions == IntPtr.Zero) throw Blacksmith.Failure("mesh");
        return new BlacksmithMesh(this, tolerance, Filled(tolerance), raw);
    }

    /// <summary><see cref="Mesh"/> in `double`, from the same cache: valid until the solid is
    /// disposed or meshed again at a different tolerance -- through <see cref="Mesh"/> as much
    /// as through this.</summary>
    public BlacksmithMesh64 Mesh64(double tolerance = 0.05)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_mesh64(Handle, tolerance);
        if (raw.Positions == IntPtr.Zero) throw Blacksmith.Failure("mesh64");
        return new BlacksmithMesh64(this, tolerance, Filled(tolerance), raw);
    }

    /// <summary>This solid meshed for a solver, as a <see cref="Cadaclysm.Blacksmith.FemMesh"/>:
    /// nodes welded by bits, triangles wound outward, each node tagged with the lowest-dimension
    /// B-rep entity it lies on, and every crack reported rather than closed. Owned by the caller --
    /// dispose it. <strong>Not a view into this solid's tessellation cache</strong>: a handle of its
    /// own, which meshing this solid again does not touch.</summary>
    /// <param name="tolerance">The chordal tolerance in model units, finite and above zero.
    /// <strong>It alone governs how closely the mesh follows the geometry.</strong></param>
    /// <param name="maxSize">A size ceiling in model units, finite and zero or more, `0` being no
    /// ceiling (curvature alone). <strong>It bounds the boundary segments and merely targets the
    /// interior</strong>, which is not a longest-element-edge guarantee: it adds nodes without
    /// refining boundary geometry, and <see cref="Cadaclysm.Blacksmith.FemMesh.LongestEdge"/> is
    /// what the mesh actually came to -- the figure to check against this.</param>
    /// <param name="placement">Twelve numbers -- origin, x, y, z, as every frame in this binding
    /// (<see cref="Frame.ToArray"/>) -- or null for the identity, applied in `double` throughout.
    /// This is the one frame argument here that may be left out, a solid meshed in its own
    /// coordinates being the common case. The reader library's `Node.FemMesh` takes
    /// <strong>sixteen</strong>, column-major, so a caller moving between the two reformats the
    /// placement.</param>
    /// <remarks>Those two defaults are `FemOptions::default()`'s own, restated here so that the
    /// signature says what a caller gets; the library's struct is still filled by
    /// `cadaclysm_blacksmith_fem_options_init` first, so a field added to it later defaults without
    /// this line being touched.
    ///
    /// <para>The library's two progress phases ("meshing" and "welding") are not offered here, as
    /// no progress callback in this binding is -- see the file header. Every call runs silent.</para>
    ///
    /// <para><strong>A cracked solid is not a failure</strong>: it comes back with <see
    /// cref="Cadaclysm.Blacksmith.FemMesh.Watertight"/> false and its cracks in <see
    /// cref="Cadaclysm.Blacksmith.FemMesh.OpenEdges"/> and <see
    /// cref="Cadaclysm.Blacksmith.FemMesh.FoldedEdges"/> -- <em>both</em> -- and nothing is welded
    /// shut to make it look sound. Throws <see cref="BuildException"/> for a tolerance or `maxSize`
    /// the mesher refuses, a placement that is not twelve finite numbers or is not invertible, a
    /// closed solid this library cannot mesh, and a solid that meshes to no triangles -- carrying
    /// the library's own words for it.</para>
    ///
    /// <para><strong>No unlicensed notice here</strong>: <see
    /// cref="Cadaclysm.Blacksmith.FemMesh.MshText"/> and <see
    /// cref="Cadaclysm.Blacksmith.FemMesh.SaveMsh"/> print it, this library noticing on its writers
    /// rather than on its builders -- where the reader library notices in its own builder and on
    /// neither `.msh` call.</para></remarks>
    public FemMesh FemMesh(double tolerance = 0.01, double maxSize = 0.0, double[]? placement = null)
    {
        var frame = placement is null ? null : Blacksmith.Frame(placement);
        var options = new RawBlacksmithFemOptions();
        // `init` writes `sizeof(CadaclysmBlacksmithFemOptions)` bytes as the *library* knows that
        // type, into the struct `RawBlacksmithFemOptions` declares -- which is why
        // `cadaclysm-capi/tests/bindings.rs` pins the two field for field. `Size` is then this
        // binding's own sizeof, which is what the growth rule asks of a caller.
        BlacksmithNative.cadaclysm_blacksmith_fem_options_init(ref options);
        options.Size = (nuint)Marshal.SizeOf<RawBlacksmithFemOptions>();
        options.Tolerance = tolerance;
        options.MaxSize = maxSize;
        return new FemMesh(BlacksmithNative.cadaclysm_blacksmith_fem_mesh(Handle, frame, ref options,
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary>The feature edges as polylines, views into the same cache as
    /// <see cref="Mesh"/>.</summary>
    public BlacksmithPolylines EdgePolylines(double tolerance = 0.05)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_edge_polylines(Handle, tolerance);
        if (raw.Offsets == IntPtr.Zero) throw Blacksmith.Failure("edge_polylines");
        return new BlacksmithPolylines(this, tolerance, Filled(tolerance), raw);
    }

    /// <summary>This solid as STEP text (AP203 unless <paramref name="schema"/> names another); see <see cref="Blacksmith.WriteStepText"/>.
    /// </summary>
    public string StepText(string? schema = null, string unit = "mm") => Blacksmith.WriteStepText(new[] { this }, schema, unit);

    /// <summary>This solid written as a STEP file (AP203 unless <paramref name="schema"/> names another).</summary>
    public void Step(string path, string? schema = null, string unit = "mm") =>
        File.WriteAllText(path, StepText(schema, unit), new UTF8Encoding(false));

    /// <summary>This solid as ACIS SAT text; see <see cref="Blacksmith.WriteSatText"/>.</summary>
    public string SatText(string unit = "mm") => Blacksmith.WriteSatText(new[] { this }, unit);

    /// <summary>This solid written as an ACIS SAT file by the library itself.</summary>
    public void Sat(string path, string unit = "mm") => Blacksmith.WriteSat(path, new[] { this }, unit);

    /// <summary>This solid as OCCT `.brep` text; see <see cref="Blacksmith.WriteBrepText"/>.
    /// </summary>
    public string BrepText() => Blacksmith.WriteBrepText(new[] { this });

    /// <summary>This solid written as a `.brep` file, by the library itself.</summary>
    public void Brep(string path) => Blacksmith.WriteBrep(path, new[] { this });

    /// <summary>This solid's wireframe as SVG text, from the camera <paramref name="options"/>
    /// describes -- the library's own camera, not a viewer. See <see cref="Blacksmith.WriteSvgText"/>.
    /// </summary>
    public string SvgText(SvgOptions? options = null) => Blacksmith.WriteSvgText(new[] { this }, options);

    /// <summary>This solid written as an SVG file by the library itself.</summary>
    public void Svg(string path, SvgOptions? options = null) => Blacksmith.WriteSvg(path, new[] { this }, options);

    // -- selecting and edges

    /// <summary>The face `selector` picks; throws when none does.</summary>
    public int SelectFace(Selector selector)
    {
        var (kind, v, index) = selector.Raw();
        var i = BlacksmithNative.cadaclysm_blacksmith_select_face(Handle, kind, v, index);
        if (i == Blacksmith.None) throw Blacksmith.Failure("select_face");
        return (int)i;
    }

    /// <summary>Twelve doubles: origin, x, y, z of the workplane on `face`.</summary>
    public double[] FaceFrame(int face)
    {
        var frame = new double[12];
        if (!BlacksmithNative.cadaclysm_blacksmith_face_frame(Handle, Index(face), frame)) throw Blacksmith.Failure("face_frame");
        return frame;
    }

    /// <summary>Face `face` by what it is, eight doubles: the surface's kind (plane 0, cylinder 1,
    /// cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8), a point on the
    /// surface at the face's middle (x y z), the outward normal there (x y z), and the face's
    /// extent -- what a feature made on the face keeps, to find the face again with
    /// <see cref="FindFace"/> when the solid has been rebuilt with its faces moved, split or
    /// renumbered. Take it before any move you apply to the solid, and look it up on the
    /// unmoved one.</summary>
    public double[] FaceRef(int face)
    {
        var r = new double[8];
        if (!BlacksmithNative.cadaclysm_blacksmith_face_ref(Handle, Index(face), r)) throw Blacksmith.Failure("face_ref");
        return r;
    }

    /// <summary>The face `faceRef` (from <see cref="FaceRef"/>) refers to: among the faces of that
    /// kind whose surface passes through the point, facing the same way, the one the point lies
    /// in -- or, where it lies in none, the one whose boundary comes nearest. `hint` is the index
    /// the face had, preferred among faces that fit equally well; `tolerance` how far the point
    /// may sit off a surface to still be on it. Null where the face is gone.</summary>
    public int? FindFace(double[] faceRef, int? hint = null, double tolerance = 1e-3)
    {
        if (faceRef.Length != 8) throw new BuildException("find_face: a face reference is eight numbers");
        var found = BlacksmithNative.cadaclysm_blacksmith_find_face(Handle, faceRef, hint ?? -1, tolerance);
        if (found == -2) throw Blacksmith.Failure("find_face");
        return found < 0 ? null : found;
    }

    // -- colour

    /// <summary>This solid coloured (`r`, `g`, `b`), each in 0..1 -- or with `face` just that
    /// face, whose colour then wins over the solid's. What is made from a coloured solid
    /// inherits: a move keeps every colour; a boolean, fillet, chamfer or shell gives each face
    /// the colour of the face it lies on (a cut's bore the tool's), and a new face the
    /// solid's.</summary>
    public Solid Coloured(double r, double g, double b, int? face = null) =>
        new(BlacksmithNative.cadaclysm_blacksmith_coloured(Handle, face is int f ? Index(f) : Blacksmith.None, r, g, b));

    /// <summary>The solid's colour as { r, g, b } in 0..1, or null.</summary>
    public double[]? Colour => ColourOf(Blacksmith.None);

    /// <summary>`face`'s colour as drawn -- its own, else the solid's -- or null.</summary>
    public double[]? FaceColour(int face) => ColourOf(Index(face));

    private double[]? ColourOf(uint face)
    {
        var rgb = new double[3];
        if (BlacksmithNative.cadaclysm_blacksmith_colour(Handle, face, rgb)) return rgb;
        if (Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("colour");
        return null;
    }

    /// <summary>This solid with its edges coloured (`r`, `g`, `b`): every edge, or with
    /// <paramref name="edges"/> just those (by index, as <see cref="Fillet(IEnumerable{int}, double, double)"/>
    /// takes them), whose colour then wins over the all-edges one. An empty list colours no edge.
    /// Inherited as face colours are.</summary>
    public Solid EdgesColoured(double r, double g, double b, IEnumerable<int>? edges = null)
    {
        if (edges is null) return new Solid(BlacksmithNative.cadaclysm_blacksmith_edges_coloured(Handle, null, 0, r, g, b));
        var which = Indices(edges);
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_edges_coloured(Handle, which, (nuint)which.Length, r, g, b));
    }

    /// <summary><see cref="EdgesColoured(double, double, double, IEnumerable{int})"/> by <see cref="Edge"/>.</summary>
    public Solid EdgesColoured(IEnumerable<Edge> edges, double r, double g, double b) =>
        EdgesColoured(r, g, b, edges.Select(e => e.Index));

    /// <summary>Edge `edge`'s colour as drawn -- its own, else the solid's edge colour -- or null.</summary>
    public double[]? EdgeColour(int edge)
    {
        var rgb = new double[3];
        if (BlacksmithNative.cadaclysm_blacksmith_edge_colour(Handle, Index(edge), rgb)) return rgb;
        if (Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("edge_colour");
        return null;
    }

    /// <summary>A colour per polyline of <see cref="EdgePolylines"/> at the same tolerance, as
    /// drawn: { r, g, b }, or null for a polyline on no coloured edge; an empty array where the
    /// solid has no edge paint at all. Copied out.</summary>
    public unsafe double[]?[] EdgePolylineColours(double tolerance = 0.05)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_edge_polyline_colours(Handle, tolerance);
        if (raw.Rgb == IntPtr.Zero && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("edge_polyline_colours");
        // This call tessellates like every other cache reader, even to report "no paint": it
        // can replace the cache a view taken earlier is still borrowing, so it must bump the
        // generation those views check, even though this method copies its own result out and
        // keeps nothing borrowed itself.
        Filled(tolerance);
        if (raw.Rgb == IntPtr.Zero) return Array.Empty<double[]?>();
        var values = new ReadOnlySpan<double>((void*)raw.Rgb, 3 * (int)raw.Count);
        var outColours = new double[]?[raw.Count];
        for (var i = 0; i < outColours.Length; i++)
            outColours[i] = values[3 * i] < 0 ? null : new[] { values[3 * i], values[3 * i + 1], values[3 * i + 2] };
        return outColours;
    }

    /// <summary>The edges a fillet indexes, as <see cref="Edge"/> records (copied; safe to
    /// keep).</summary>
    public unsafe IReadOnlyList<Edge> Edges
    {
        get
        {
            var h = Handle;
            var n = BlacksmithNative.cadaclysm_blacksmith_edge_count(h);
            if (n == 0 && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("edge_count");
            var found = new List<Edge>((int)n);
            for (uint i = 0; i < n; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_edge(h, i, out var raw)) throw Blacksmith.Failure("edge");
                var faces = new int[raw.FaceCount];
                if (raw.Faces != IntPtr.Zero)
                {
                    var ids = new ReadOnlySpan<uint>((void*)raw.Faces, faces.Length);
                    for (var f = 0; f < faces.Length; f++) faces[f] = (int)ids[f];
                }
                var segments = new (double[] A, double[] B)[raw.SegmentCount];
                if (raw.Segments != IntPtr.Zero)
                {
                    var flat = new ReadOnlySpan<double>((void*)raw.Segments, (int)(6 * raw.SegmentCount));
                    for (var s = 0; s < segments.Length; s++)
                        segments[s] = (flat.Slice(6 * s, 3).ToArray(), flat.Slice(6 * s + 3, 3).ToArray());
                }
                found.Add(new Edge((int)i, Blacksmith.Text(raw.Kind), faces, segments, EdgeCurve(h, i)));
            }
            return found;
        }
    }

    /// <summary>Edge `i`'s exact curve copied out, or null for an edge with none (the
    /// library's "has no exact curve"); any other refusal throws.</summary>
    private static Curve? EdgeCurve(SolidHandle h, uint i)
    {
        if (BlacksmithNative.cadaclysm_blacksmith_edge_curve(h, i, out var raw)) return new Curve(raw);
        if (Blacksmith.LastError().Contains("has no exact curve")) return null;
        throw Blacksmith.Failure("edge_curve");
    }

    /// <summary>Face and edge indices are `int` on this surface, as Python's are, and the C
    /// ABI's `uint32_t` at the boundary; a negative one is refused rather than wrapped.
    /// </summary>
    internal static uint Index(int index) =>
        index >= 0 ? (uint)index : throw new BuildException($"index {index} is negative");

    private static uint[] Indices(IEnumerable<int> indices) => indices.Select(Index).ToArray();

    /// <summary>This solid with `edges` rounded to `radius`.</summary>
    public Solid Fillet(IEnumerable<Edge> edges, double radius, double tolerance = 1e-6) =>
        Fillet(edges.Select(e => e.Index), radius, tolerance);

    /// <summary><see cref="Fillet(IEnumerable{Edge}, double, double)"/> by edge index.</summary>
    public Solid Fillet(IEnumerable<int> edges, double radius, double tolerance = 1e-6)
    {
        var which = Indices(edges);
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_fillet(Handle, which, (nuint)which.Length, radius, tolerance,
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary><see cref="Fillet(IEnumerable{Edge}, double, double)"/> with a flat bevel:
    /// each edge cut back `distance` along both its faces.</summary>
    public Solid Chamfer(IEnumerable<Edge> edges, double distance, double tolerance = 1e-6) =>
        Chamfer(edges.Select(e => e.Index), distance, tolerance);

    public Solid Chamfer(IEnumerable<int> edges, double distance, double tolerance = 1e-6)
    {
        var which = Indices(edges);
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_chamfer(Handle, which, (nuint)which.Length, distance, tolerance));
    }

    /// <summary>Face `face` pushed out by `distance` along its outward normal (pulled in,
    /// negative) as a face extrude does it: the prism over it joined on (cut
    /// out), and the flush faces merged -- a box's top raised is one taller box of six faces.
    /// A face on a cylinder, a cone, a sphere or a torus moves out along its normal instead,
    /// the surface a step out (a boss fatter, a bore or a countersink narrower, a dome fuller),
    /// the flat faces beside it carried along; any other curved face is refused.</summary>
    public Solid PushPull(int face, double distance, double tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_push_pull(Handle, Index(face), distance, tolerance, IntPtr.Zero, IntPtr.Zero));

    /// <summary>Faces `faces` pushed out by `distance` together -- a press-pull on a
    /// selection: each by <see cref="PushPull(int, double, double)"/>'s rule for it, one after
    /// another, each found again after the pushes before it renumbered the faces. A box's top
    /// and a side pushed 5 is the box 5 taller and 5 wider; a face on the same curved surface
    /// as one before it, and joined to it, moved with that one and is not pushed twice.</summary>
    public Solid PushPull(IEnumerable<int> faces, double distance, double tolerance = 0.05)
    {
        var which = Indices(faces);
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_push_pull_faces(Handle, which, (nuint)which.Length, distance, tolerance,
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary>This solid split by `tool` into bodies: a closed
    /// `tool` gives the parts outside it, then the parts inside; a flat sheet splits by the
    /// whole plane it lies on. Each connected part is a body of its own.</summary>
    public IReadOnlyList<Solid> Split(Solid tool, double tolerance = 0.05)
    {
        using var all = new Solid(BlacksmithNative.cadaclysm_blacksmith_split(Handle, tool.Handle, tolerance, IntPtr.Zero, IntPtr.Zero));
        return all.Lumps();
    }

    /// <summary>This solid split by the plane through `plane`'s origin, square to its z (a
    /// frame, twelve numbers): the bodies in front of it first, then those behind.</summary>
    public IReadOnlyList<Solid> SplitByPlane(double[] plane, double tolerance = 0.05)
    {
        using var all = new Solid(BlacksmithNative.cadaclysm_blacksmith_split_by_plane(Handle, Blacksmith.Frame(plane), tolerance, IntPtr.Zero, IntPtr.Zero));
        return all.Lumps();
    }

    /// <summary>This solid's connected bodies, each a solid of its own -- faces sharing an
    /// edge are one body -- in the order of their first faces.</summary>
    public IReadOnlyList<Solid> Lumps()
    {
        var n = BlacksmithNative.cadaclysm_blacksmith_lump_count(Handle);
        if (n == 0) throw Blacksmith.Failure("lump_count");
        var found = new List<Solid>((int)n);
        for (uint i = 0; i < n; i++) found.Add(new Solid(BlacksmithNative.cadaclysm_blacksmith_lump(Handle, i)));
        return found;
    }

    /// <summary>This solid with its flush faces merged: flat faces on one plane, facing one
    /// way and meeting, made one face, and the vertices left mid-way along a straight edge
    /// taken out -- the seams a <see cref="Join"/> leaves where two parts are flush.</summary>
    public Solid MergeFlush() => new(BlacksmithNative.cadaclysm_blacksmith_merge_flush(Handle));

    /// <summary>The round `face` belongs to -- a fillet's bands, balls and rim bands joined to
    /// that face -- made again at `radius`, as a press-pull on a fillet face: taken back to
    /// the sharp edges it replaced, and those rounded again.</summary>
    public Solid Refillet(int face, double radius, double tolerance = 1e-6) =>
        new(BlacksmithNative.cadaclysm_blacksmith_refillet(Handle, Index(face), radius, tolerance));

    /// <summary>The round `face` belongs to taken off, the faces beside it sharp again --
    /// the delete of a fillet face.</summary>
    public Solid Unfillet(int face) => new(BlacksmithNative.cadaclysm_blacksmith_unfillet(Handle, Index(face)));

    /// <summary>The chamfer `face` belongs to -- its bevels, flat or round a rim, and the corner
    /// triangles joined to that face -- cut again at `distance`, as a press-pull on a chamfer
    /// face: taken back to the sharp edges it cut, and those bevelled again.</summary>
    public Solid Rechamfer(int face, double distance, double tolerance = 1e-6) =>
        new(BlacksmithNative.cadaclysm_blacksmith_rechamfer(Handle, Index(face), distance, tolerance));

    /// <summary>The chamfer `face` belongs to taken off, the faces beside it sharp again --
    /// the delete of a chamfer face.</summary>
    public Solid Unchamfer(int face) => new(BlacksmithNative.cadaclysm_blacksmith_unchamfer(Handle, Index(face)));

    /// <summary>This solid hollowed to a wall `thickness` thick (inward for a positive
    /// thickness, outward for a negative one), with the faces at `open` removed so the hollow
    /// is reachable.</summary>
    public Solid Shell(double thickness, IEnumerable<int>? open = null, double tolerance = 1e-6)
    {
        var which = Indices(open ?? Array.Empty<int>());
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_shell(Handle, thickness, which, (nuint)which.Length, tolerance,
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary>This sheet made a solid `thickness` thick: its faces, their
    /// twins moved `thickness` along the faces' normals (against them for a negative thickness),
    /// and a wall round every open edge. A closed sheet thickens to a hollow.</summary>
    public Solid Thicken(double thickness, double tolerance = 1e-6) =>
        new(BlacksmithNative.cadaclysm_blacksmith_thicken(Handle, thickness, tolerance, IntPtr.Zero, IntPtr.Zero));

    // -- from files

    /// <summary>The body `node` of a reader <see cref="Scene"/> draws, as a solid -- sharing
    /// the reader's brep, not copying it. The scene can be disposed before the solid is.
    /// `placed` puts it where the node's <see cref="Node.Transform"/> does, which is where
    /// its mesh draws; a node at the identity stays shared, a moved one is a moved copy. In
    /// the file's own units and axes. Needs the reader's library from the same release as
    /// this one's: the brep is handed across by pointer and the two layouts are compared
    /// first. What a solid from a file can then do: see <see cref="Open"/>.</summary>
    public static Solid FromNode(Scene scene, Node node, bool placed = true)
    {
        var solid = FromBrep(node, $"from_node: node {node.Index} ({Label(node)})")
            ?? throw new BuildException($"from_node: node {node.Index} ({Label(node)}) has no brep: only a B-rep body " +
                "has one (STEP, ACIS, Rhino, OCCT .brep, IGES, IFC), not a mesh, a curve or a CSG body");
        if (!placed) return solid;
        if (scene.Convention != Convention.Native && !IsIdentity(node.Transform))
            throw new BuildException("from_node: placed=True needs the scene opened with Convention.Native -- the " +
                "brep is in the file's own axes and the node's transform is not; open Native, or pass placed: false");
        return solid.Placed(node.Transform, "from_node");
    }

    /// <summary><see cref="FromNode(Scene, Node, bool)"/> by node index.</summary>
    public static Solid FromNode(Scene scene, uint node, bool placed = true) =>
        FromNode(scene, scene.Nodes[(int)node], placed);

    /// <summary>The body a CAD file holds, as a solid: a STEP (AP203/214/242), ACIS `.sat`,
    /// Rhino `.3dm`, OCCT `.brep`, IGES or IFC file, read where it draws, in the file's own
    /// units and axes. A file drawing several bodies needs `body` (0-based, in drawing order)
    /// or <see cref="OpenAll"/>. Fillet and chamfer want line and circle edges; booleans take
    /// any surface, but the new edges they trace on a free-form (NURBS) face are not always
    /// writable back to STEP; and every verb meshes its operands first, so its cost grows with
    /// the body's face count.</summary>
    public static Solid Open(string path, int? body = null)
    {
        var solids = OpenAll(path);
        var name = System.IO.Path.GetFileName(path);
        if (body is null && solids.Count == 1) return solids[0];
        if (body is null || body < 0 || body >= solids.Count)
        {
            foreach (var s in solids) s.Dispose();
            throw new BuildException(body is null
                ? $"open: {name} holds {solids.Count} bodies: pass body= (0 to {solids.Count - 1}), or use Solid.OpenAll"
                : $"open: {name} has no body {body}: it holds {solids.Count}");
        }
        for (var i = 0; i < solids.Count; i++)
            if (i != body) solids[i].Dispose();
        return solids[body.Value];
    }

    /// <summary>Every body a CAD file draws, as solids placed where it draws them: one per
    /// placement, so a part placed twice is two solids. See <see cref="Open"/>.</summary>
    public static IReadOnlyList<Solid> OpenAll(string path)
    {
        Scene scene;
        try
        {
            scene = global::Cadaclysm.Cadaclysm.Open(path);
        }
        catch (CadaclysmException e)
        {
            throw new BuildException($"open: {e.Message}");
        }
        var solids = new List<Solid>();
        using (scene)
        {
            try
            {
                foreach (var placement in scene.Placements)
                {
                    var node = placement.Geometry;
                    var what = $"open: {Label(node)}";
                    var solid = FromBrep(node, what);
                    if (solid is not null) solids.Add(solid.Placed(placement.Transform, what));
                }
            }
            catch
            {
                foreach (var s in solids) s.Dispose();
                throw;
            }
        }
        if (solids.Count == 0)
        {
            var extension = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
            throw new BuildException($"open: the .{extension} file draws no B-rep body -- only a STEP, ACIS, Rhino, " +
                "OCCT .brep, IGES or IFC body can be a solid, not a mesh, a curve or a CSG body");
        }
        return solids;
    }

    private static string Label(Node node) =>
        node.Name.Length > 0 ? node.Name : node.Kind.Length > 0 ? node.Kind : node.Index.ToString();

    /// <summary>The node's brep as a solid, shared, or null where it has none.</summary>
    private static Solid? FromBrep(Node node, string what)
    {
        using var brep = node.Brep;
        if (brep is null) return null;
        return new Solid(Blacksmith.Checked(
            // Qualified: inside `Solid`, `Brep` is also the method that writes a `.brep`.
            BlacksmithNative.cadaclysm_blacksmith_from_brep(brep.Handle, global::Cadaclysm.Brep.LayoutId), what));
    }

    private static bool IsIdentity(double[,] m)
    {
        for (var i = 0; i < 4; i++)
            for (var j = 0; j < 4; j++)
                if (m[i, j] != (i == j ? 1.0 : 0.0)) return false;
        return true;
    }

    /// <summary>This solid moved by a row-major 4x4 placement: itself at the identity, a moved
    /// copy for a rigid move (a mirror included), refused for a scale or shear, which a brep
    /// cannot follow exactly (a cylinder's radius is a number, not a point).</summary>
    private Solid Placed(double[,] m, string what)
    {
        if (IsIdentity(m)) return this;
        for (var a = 0; a < 3; a++)
            for (var b = 0; b < 3; b++)
            {
                var dot = m[0, a] * m[0, b] + m[1, a] * m[1, b] + m[2, a] * m[2, b];
                if (Math.Abs(dot - (a == b ? 1.0 : 0.0)) > 1e-9)
                    throw new BuildException($"{what}: the placement scales or shears, which a brep cannot follow");
            }
        var frame = new[] { m[0, 3], m[1, 3], m[2, 3], m[0, 0], m[1, 0], m[2, 0], m[0, 1], m[1, 1], m[2, 1], m[0, 2], m[1, 2], m[2, 2] };
        using (this) return Place(frame);
    }

    /// <summary>This solid as a reader <see cref="Scene"/>, through STEP text and
    /// <see cref="global::Cadaclysm.Cadaclysm.OpenMemory"/> -- the door to the viewer and the
    /// tree walk. Needs the reader's library built beside this one.</summary>
    /// <param name="schema">As <see cref="StepText"/> takes it; the reader is given the
    /// schema's path only when it names an existing file, since it carries every built-in
    /// schema itself and there is no file here to read a `FILE_SCHEMA` line out of.</param>
    public Scene ToScene(string? schema = null)
    {
        var schemaPath = schema is not null && !schema.Contains('\n') && File.Exists(schema) ? schema : null;
        var bytes = Encoding.UTF8.GetBytes(StepText(schema));
        return global::Cadaclysm.Cadaclysm.OpenMemory(bytes, "solid.stp", "stp", schema: schemaPath);
    }
}

// ---- assemblies ---------------------------------------------------------------------------

/// <summary>A mutable tree of placements: a name, and zero or more solids or other assemblies
/// placed in it at a frame. <see cref="Place"/> returns the placement's name (<paramref
/// name="name"/>, or a default -- see its own doc) so a caller can keep it. Unlike
/// <see cref="Solid"/>, placing shares rather than copies: placing one assembly under another
/// does not snapshot it, so a later <see cref="Place"/> on the shared one shows up wherever it
/// already sits (see <see cref="Place"/>'s own note on cycles). <see cref="Dispose"/> frees this
/// handle now; the garbage collector does otherwise -- it does <em>not</em> free what was placed
/// here if that is still reachable from somewhere else (an assembly's data is shared, per the C
/// ABI's own doc).</summary>
public sealed class Assembly : IDisposable
{
    private readonly AssemblyHandle _handle;

    public Assembly(string name)
    {
        _handle = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_assembly_new(name), "assembly");
    }

    /// <summary>The handle, refusing to hand over a disposed one, so a use-after-dispose throws
    /// at the call site instead of passing a dangling pointer into the library.</summary>
    internal AssemblyHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Assembly), "assembly: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the assembly back. Idempotent. Does not free what was placed in it.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>This assembly's own name, given when it was made. Never null: the library's
    /// borrowed pointer is read through <see cref="Blacksmith.Text"/>, unlike <see
    /// cref="Solid.Name"/>, since an assembly always has the name it was constructed with.
    /// </summary>
    public string Name
    {
        get
        {
            var result = Blacksmith.Text(BlacksmithNative.cadaclysm_blacksmith_assembly_name(Handle));
            GC.KeepAlive(this);
            return result;
        }
    }

    /// <summary>Place <paramref name="solid"/> at <paramref name="frame"/> (twelve numbers,
    /// right-handed and orthonormal) in this assembly, called <paramref name="name"/> -- or,
    /// left null, <paramref name="solid"/>'s own name (<see cref="Solid.Name"/>, or "part" for
    /// an unnamed one), numbered past any already taken here ("bolt", "bolt 2", ...). An
    /// explicit name already taken here throws. Returns the placement's name.</summary>
    public string Place(Solid solid, double[] frame, string? name = null)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_assembly_place_solid(Handle, solid.Handle, Blacksmith.Frame(frame), name);
        if (raw == IntPtr.Zero) throw Blacksmith.Failure("assembly_place_solid");
        try
        {
            return Marshal.PtrToStringUTF8(raw) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
        }
    }

    /// <summary>Place another assembly, <paramref name="placed"/>, sharing it rather than
    /// copying it, as <see cref="Place(Solid,double[],string?)"/> places a solid -- <paramref
    /// name="name"/> defaults to <paramref name="placed"/>'s own <see cref="Name"/>. Placing
    /// <paramref name="placed"/> as itself, or anywhere above this assembly in the tree
    /// already, throws (naming the cycle), since writing that out would never terminate.
    /// Returns the placement's name.</summary>
    public string Place(Assembly placed, double[] frame, string? name = null)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_assembly_place_assembly(Handle, placed.Handle, Blacksmith.Frame(frame), name);
        if (raw == IntPtr.Zero) throw Blacksmith.Failure("assembly_place_assembly");
        try
        {
            return Marshal.PtrToStringUTF8(raw) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
        }
    }

    /// <summary>This assembly, and everything placed under it, as one STEP file: this assembly
    /// the root product, each sub-assembly and each distinct part (the same solid with the same
    /// paint and name) written once, each placement an occurrence named as it was placed. See
    /// <see cref="Blacksmith.WriteStepText"/> for <paramref name="schema"/> and <paramref
    /// name="unit"/>. Throws where this assembly, or a sub-assembly reachable from it, places
    /// nothing -- a reader would never show it.</summary>
    public string StepText(string? schema = null, string unit = "mm")
    {
        var unitCode = Blacksmith.UnitCode(unit);
        var raw = BlacksmithNative.cadaclysm_blacksmith_assembly_step(Handle, Blacksmith.SchemaText(schema), unitCode);
        if (raw == IntPtr.Zero) throw Blacksmith.Failure("assembly_step");
        try
        {
            return Marshal.PtrToStringUTF8(raw) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
        }
    }

    /// <summary><see cref="StepText"/> written to a file.</summary>
    public void Step(string path, string? schema = null, string unit = "mm") =>
        File.WriteAllText(path, StepText(schema, unit), new UTF8Encoding(false));

    /// <summary>This assembly as a reader <see cref="Scene"/>, through STEP text and <see
    /// cref="global::Cadaclysm.Cadaclysm.OpenMemory"/> -- <see cref="Solid.ToScene"/>'s own
    /// door, over the whole tree instead of one solid. Needs the reader's library built beside
    /// this one.</summary>
    public Scene ToScene(string? schema = null)
    {
        var schemaPath = schema is not null && !schema.Contains('\n') && File.Exists(schema) ? schema : null;
        var bytes = Encoding.UTF8.GetBytes(StepText(schema));
        return global::Cadaclysm.Cadaclysm.OpenMemory(bytes, "assembly.stp", "stp", schema: schemaPath);
    }
}

public enum Axis
{
    X = 0,
    Y = 1,
    Z = 2,
}

/// <summary>Which face: furthest along an axis, furthest against it, by outward normal, or by
/// index -- `Selector::Max/Min/Normal/Index` in the crate.</summary>
public readonly struct Selector
{
    private readonly uint _kind;
    private readonly double[]? _v;
    private readonly uint _index;

    private Selector(uint kind, double[]? v, uint index)
    {
        _kind = kind;
        _v = v;
        _index = index;
    }

    public static Selector Max(Axis axis) => new(0, null, (uint)axis);

    public static Selector Min(Axis axis) => new(1, null, (uint)axis);

    /// <summary>The face whose outward normal is nearest `direction` (need not be unit).
    /// </summary>
    public static Selector Normal((double X, double Y, double Z) direction) =>
        new(2, new[] { direction.X, direction.Y, direction.Z }, 0);

    /// <summary>The face at `i` in the solid's own order.</summary>
    public static Selector Index(int i) => new(3, null, Solid.Index(i));

    /// <summary>What `cadaclysm_blacksmith_select_face` takes: the kind, the direction (read
    /// only for a normal), the index (read only for an axis or an index).</summary>
    internal (uint Kind, double[]? V, uint Index) Raw() => (_kind, _v, _index);
}

/// <summary>One edge's, or one intersection chain's, exact curve as plain data copied out
/// (<see cref="Edge.Curve"/>, <see cref="Chain.Curve"/>): <see cref="Kind"/> is "line",
/// "circle", "ellipse", "parabola", "hyperbola" or "nurbs".
///
/// `t0..t1` is the edge's parameter range on its own curve: a line's fraction (0..1 over
/// `origin -> origin + x`, where `x` is the full `to - from`, NOT unit -- so
/// `point(t) = origin + x*t`); a circle's or ellipse's angle in radians about `origin` in the
/// `x, y` plane (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`, `radius2 = radius`
/// for a circle); a NURBS's knot parameter (`knots[degree] &lt;= t0 &lt; t1 &lt;= knots[n]`). Frame
/// vectors `x, y, z` are unit for conics; for a line `x` is the direction with length = the
/// line's length and `y, z` are zero.
///
/// For a NURBS the frame is zero and so are the radii; for a conic or a line <see cref="Degree"/>
/// is 0 and <see cref="Knots"/>, <see cref="Poles"/> are empty. <see cref="Poles"/> is three
/// doubles a control point (`Knots.Length == Poles.Length / 3 + Degree + 1`); <see cref="Weights"/>
/// is one per pole, or null for a non-rational (plain B-spline) curve, a conic or a line.</summary>
public sealed class Curve
{
    public string Kind { get; }

    /// <summary>Three doubles each.</summary>
    public double[] Origin { get; }
    public double[] X { get; }
    public double[] Y { get; }
    public double[] Z { get; }

    public double Radius { get; }
    public double Radius2 { get; }
    public double T0 { get; }
    public double T1 { get; }
    public int Degree { get; }
    public double[] Knots { get; }

    /// <summary>Three doubles per control point.</summary>
    public double[] Poles { get; }
    public double[]? Weights { get; }

    internal unsafe Curve(RawBlacksmithCurve raw)
    {
        Kind = Blacksmith.Text(raw.Kind);
        Origin = new[] { raw.Origin.X, raw.Origin.Y, raw.Origin.Z };
        X = new[] { raw.X.X, raw.X.Y, raw.X.Z };
        Y = new[] { raw.Y.X, raw.Y.Y, raw.Y.Z };
        Z = new[] { raw.Z.X, raw.Z.Y, raw.Z.Z };
        Radius = raw.Radius;
        Radius2 = raw.Radius2;
        T0 = raw.T0;
        T1 = raw.T1;
        Degree = (int)raw.Degree;
        Knots = Doubles(raw.Knots, raw.KnotCount);
        Poles = Doubles(raw.Poles, 3 * raw.PoleCount);
        Weights = raw.Weights == IntPtr.Zero ? null : Doubles(raw.Weights, raw.PoleCount);
    }

    private static unsafe double[] Doubles(IntPtr at, uint count) =>
        at == IntPtr.Zero ? Array.Empty<double>() : new ReadOnlySpan<double>((void*)at, (int)count).ToArray();

    public override string ToString() => Kind == "nurbs"
        ? $"Curve(\"nurbs\", degree={Degree}, poles={Poles.Length / 3}, rational={Weights != null}, t0={T0}, t1={T1})"
        : $"Curve(\"{Kind}\", origin=({string.Join(", ", Origin)}), radius={Radius}, t0={T0}, t1={T1})";
}

/// <summary>One edge of a solid, as plain data: its index (what <see cref="Solid.Fillet"/>
/// takes), the curve kind, the faces meeting on it, its segments' ends, and its exact
/// <see cref="Curve"/> (null for an edge with no exact curve, kind "other").</summary>
public readonly struct Edge
{
    public int Index { get; }

    /// <summary>"line", "circle", "ellipse", "parabola", "hyperbola", "nurbs" or "other".</summary>
    public string Kind { get; }

    /// <summary>The faces that meet on it, in the solid's face order.</summary>
    public int[] Faces { get; }

    /// <summary>The two ends of each trim piece of the edge, three doubles each.</summary>
    public (double[] A, double[] B)[] Segments { get; }

    /// <summary>The edge's exact curve, or null for an edge with none.</summary>
    public Curve? Curve { get; }

    public Edge(int index, string kind, int[] faces, (double[] A, double[] B)[] segments, Curve? curve = null)
    {
        Index = index;
        Kind = kind;
        Faces = faces;
        Segments = segments;
        Curve = curve;
    }

    public bool IsLine => Kind == "line";

    /// <summary>Unit direction of a line edge (from its first segment), else null.</summary>
    public double[]? Direction
    {
        get
        {
            if (!IsLine || Segments.Length == 0) return null;
            var (a, b) = Segments[0];
            var d = new[] { b[0] - a[0], b[1] - a[1], b[2] - a[2] };
            var n = Math.Sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
            return n > 0 ? new[] { d[0] / n, d[1] / n, d[2] / n } : null;
        }
    }

    public override string ToString() => $"Edge({Index}, \"{Kind}\", faces=({string.Join(", ", Faces)}))";
}

/// <summary>Where a hit lands on one side: a profile's <see cref="LoopIndex"/> (0 the boundary
/// or the open chain, then the holes in the order they were added), <see cref="Segment"/>, and
/// <see cref="T"/> from 0 to 1 along it, with <see cref="Face"/> NONE
/// (<c>uint.MaxValue</c>) -- or a solid's face at (<see cref="U"/>, <see cref="V"/>), with the
/// loop and segment NONE.</summary>
public readonly struct Spot
{
    public uint LoopIndex { get; }
    public uint Segment { get; }
    public double T { get; }
    public uint Face { get; }
    public double U { get; }
    public double V { get; }

    internal Spot(RawBlacksmithSpot raw)
    {
        LoopIndex = raw.LoopIndex;
        Segment = raw.Segment;
        T = raw.T;
        Face = raw.Face;
        U = raw.U;
        V = raw.V;
    }

    public override string ToString() =>
        $"Spot(loop_index={LoopIndex}, segment={Segment}, t={T}, face={Face}, u={U}, v={V})";
}

/// <summary>What <see cref="Solid.Intersect"/> found, copied out: <see cref="Chains"/> (one per
/// face pair per branch) and <see cref="Overlaps"/> (one per coincident face pair). Both empty
/// where the solids do not meet.</summary>
public sealed class Intersection
{
    public IReadOnlyList<Chain> Chains { get; }
    public IReadOnlyList<Overlap> Overlaps { get; }

    internal Intersection(IReadOnlyList<Chain> chains, IReadOnlyList<Overlap> overlaps)
    {
        Chains = chains;
        Overlaps = overlaps;
    }

    public override string ToString() => $"Intersection(chains={Chains.Count}, overlaps={Overlaps.Count})";
}

/// <summary>One branch of one face pair's crossing (<see cref="Intersection.Chains"/>):
/// <see cref="Points"/> (three doubles each, in walk order; a closed chain does not repeat its
/// first point), <see cref="Closed"/>, the faces (<see cref="FaceA"/> in the first solid,
/// <see cref="FaceB"/> in the second), <see cref="Tangent"/> (the surfaces near-tangent along
/// it, or the snap unsettled -- the points their best estimate) and <see cref="Curve"/>, its
/// exact curve over the chain's own `t0..t1`, or null where the kernel found none. A chain
/// may stop at a face boundary or a closed curve's seam and continue as another: join chains
/// by matching ends.</summary>
public sealed class Chain
{
    /// <summary>Three doubles each.</summary>
    public double[][] Points { get; }
    public bool Closed { get; }
    public int FaceA { get; }
    public int FaceB { get; }
    public bool Tangent { get; }
    public Curve? Curve { get; }

    internal unsafe Chain(RawBlacksmithChain raw, Curve? curve)
    {
        Points = Blacksmith.PointsAt(raw.Points, raw.PointCount);
        Closed = raw.Closed;
        FaceA = (int)raw.FaceA;
        FaceB = (int)raw.FaceB;
        Tangent = raw.Tangent;
        Curve = curve;
    }

    public override string ToString() =>
        $"Chain(points={Points.Length}, closed={Closed}, faces=({FaceA}, {FaceB}), tangent={Tangent}, curve={Curve?.ToString() ?? "null"})";
}

/// <summary>A face of the first solid and a face of the second that coincide
/// (<see cref="Intersection.Overlaps"/>): the faces (<see cref="FaceA"/>, <see cref="FaceB"/>)
/// and <see cref="Loops"/>, the shared region's rings as arrays of points (outer first, holes
/// after; each ring closed without repeating its first point) -- empty for a partial overlap
/// whose outlines cross.</summary>
public sealed class Overlap
{
    public int FaceA { get; }
    public int FaceB { get; }

    /// <summary>Each ring an array of points, three doubles each.</summary>
    public double[][][] Loops { get; }

    internal unsafe Overlap(RawBlacksmithOverlap raw)
    {
        FaceA = (int)raw.FaceA;
        FaceB = (int)raw.FaceB;
        var points = Blacksmith.PointsAt(raw.Points, raw.PointCount);
        var starts = raw.LoopOffsets == IntPtr.Zero || raw.LoopCount == 0
            ? Array.Empty<uint>()
            : new ReadOnlySpan<uint>((void*)raw.LoopOffsets, (int)raw.LoopCount).ToArray();
        Loops = new double[starts.Length][][];
        for (var r = 0; r < starts.Length; r++)
        {
            var end = r + 1 < starts.Length ? starts[r + 1] : raw.PointCount;
            Loops[r] = points[(int)starts[r]..(int)end];
        }
    }

    public override string ToString() => $"Overlap(faces=({FaceA}, {FaceB}), loops={Loops.Length})";
}

/// <summary>What <see cref="Solid.Hits"/> found, copied out: <see cref="Hits"/> (ordered along
/// the profile; <see cref="Hit.AStart"/>/<see cref="Hit.AEnd"/> on the profile,
/// <see cref="Hit.BStart"/>/<see cref="Hit.BEnd"/> on the solid's faces: a face at (u, v)) and
/// <see cref="Pieces"/> (empty for an open body).</summary>
public sealed class SolidHits
{
    public IReadOnlyList<Hit> Hits { get; }
    public IReadOnlyList<Piece> Pieces { get; }

    internal SolidHits(IReadOnlyList<Hit> hits, IReadOnlyList<Piece> pieces)
    {
        Hits = hits;
        Pieces = pieces;
    }

    public override string ToString() => $"SolidHits(hits={Hits.Count}, pieces={Pieces.Count})";
}

/// <summary>One stretch of a profile loop between two cuts (<see cref="SolidHits.Pieces"/>):
/// <see cref="Inside"/> (by its middle's winding number over the body; a piece lying on the
/// surface is inside), <see cref="Start"/>/<see cref="End"/> (profile spots -- a segment join
/// reads as the next segment's start `(k + 1, 0)`, an open chain runs from `(0, 0)` to
/// `(n - 1, 1)`; a loop no hit cuts is one closed piece) and <see cref="Profile"/>, the piece's
/// own open chain (what <see cref="SweepPath.Along"/> with `open` sweeps).</summary>
public sealed class Piece
{
    public bool Inside { get; }
    public Spot Start { get; }
    public Spot End { get; }
    public Profile Profile { get; }

    internal Piece(bool inside, Spot start, Spot end, Profile profile)
    {
        Inside = inside;
        Start = start;
        End = end;
        Profile = profile;
    }

    public override string ToString() => $"Piece(inside={Inside}, start={Start}, end={End})";
}

/// <summary>One place two curves meet, copied out. A point (<see cref="Run"/> false):
/// <see cref="Start"/> equals <see cref="End"/>, and <see cref="Touch"/> is true where the
/// curves are tangent rather than crossing. A run (<see cref="Run"/> true): they coincide from
/// <see cref="Start"/> to <see cref="End"/>. <see cref="AStart"/>/<see cref="AEnd"/> are where
/// on the first curve, <see cref="BStart"/>/<see cref="BEnd"/> where on the second.</summary>
public readonly struct Hit
{
    public bool Run { get; }
    public bool Touch { get; }

    /// <summary>Three doubles.</summary>
    public double[] Start { get; }

    /// <summary>Three doubles.</summary>
    public double[] End { get; }

    public Spot AStart { get; }
    public Spot AEnd { get; }
    public Spot BStart { get; }
    public Spot BEnd { get; }

    internal Hit(RawBlacksmithHit raw)
    {
        Run = raw.Run;
        Touch = raw.Touch;
        Start = new[] { raw.Start.X, raw.Start.Y, raw.Start.Z };
        End = new[] { raw.End.X, raw.End.Y, raw.End.Z };
        AStart = new Spot(raw.AStart);
        AEnd = new Spot(raw.AEnd);
        BStart = new Spot(raw.BStart);
        BEnd = new Spot(raw.BEnd);
    }

    public override string ToString() =>
        $"Hit(run={Run}, touch={Touch}, start=({string.Join(", ", Start)}), end=({string.Join(", ", End)}))";
}

/// <summary>An origin and three unit axes, square to each other and right-handed (z = x × y):
/// the plane a profile is drawn on (its x/y) and the direction it is built along (its z).
/// Converts to the twelve numbers every call taking a `frame` reads, so pass it wherever one
/// goes. Immutable. The constructor normalises the axes and throws
/// <see cref="BuildException"/> when they are not square or not right-handed.</summary>
public sealed class Frame : IEquatable<Frame>
{
    /// <summary>How far from square the axes may be (the cosine between two of them).</summary>
    private const double Square = 1e-6;

    private readonly double[] _v;

    public Frame((double X, double Y, double Z) origin, (double X, double Y, double Z) x,
        (double X, double Y, double Z) y, (double X, double Y, double Z) z)
    {
        if (!double.IsFinite(origin.X) || !double.IsFinite(origin.Y) || !double.IsFinite(origin.Z))
            throw new BuildException("Frame: origin must be three finite numbers");
        x = Unit(x, "Frame: x");
        y = Unit(y, "Frame: y");
        z = Unit(z, "Frame: z");
        if (Math.Max(Math.Abs(Dot(x, y)), Math.Max(Math.Abs(Dot(y, z)), Math.Abs(Dot(z, x)))) > Square)
            throw new BuildException("Frame: the axes are not square to each other");
        if (Dot(Cross(x, y), z) < 0)
            throw new BuildException("Frame: the axes are left-handed (z must be x × y)");
        _v = new[] { origin.X, origin.Y, origin.Z, x.X, x.Y, x.Z, y.X, y.Y, y.Z, z.X, z.Y, z.Z };
        for (var i = 0; i < _v.Length; i++) _v[i] += 0.0; // no -0.0 to print or compare
    }

    /// <summary>Twelve numbers -- what <see cref="Solid.FaceFrame"/> and
    /// <see cref="Workplane.Frame"/> hand back -- checked as the constructor checks.</summary>
    public static Frame Of(double[] frame)
    {
        var v = Blacksmith.Frame(frame);
        return new Frame((v[0], v[1], v[2]), (v[3], v[4], v[5]), (v[6], v[7], v[8]), (v[9], v[10], v[11]));
    }

    /// <summary>The world XY plane through `origin`: z up, as <see cref="Workplane.Xy"/>.</summary>
    public static Frame Xy((double X, double Y, double Z) origin = default) => new(origin, (1, 0, 0), (0, 1, 0), (0, 0, 1));

    /// <summary>The world XZ plane through `origin`: x along X, y along Z, so z is -Y, as
    /// <see cref="Workplane.Xz"/>.</summary>
    public static Frame Xz((double X, double Y, double Z) origin = default) => new(origin, (1, 0, 0), (0, 0, 1), (0, -1, 0));

    /// <summary>The world YZ plane through `origin`: x along Y, y along Z, so z is +X, as
    /// <see cref="Workplane.Yz"/>.</summary>
    public static Frame Yz((double X, double Y, double Z) origin = default) => new(origin, (0, 1, 0), (0, 0, 1), (1, 0, 0));

    /// <summary>The plane through `origin` square to `normal` (the frame's z). Its x axis is `x`
    /// laid onto that plane; with none, world X laid onto it, or world Y when the normal is
    /// within about 25° of X -- the axes <see cref="Solid.FaceFrame"/> gives a face facing
    /// `normal`. So a normal along +Z, -Y or +X gives exactly <see cref="Xy"/>,
    /// <see cref="Xz"/> or <see cref="Yz"/>.</summary>
    public static Frame At((double X, double Y, double Z) origin, (double X, double Y, double Z) normal,
        (double X, double Y, double Z)? x = null)
    {
        var z = Unit(normal, "Frame.At: normal");
        var hint = Unit(x ?? (Math.Abs(z.X) <= 0.9 ? (1.0, 0.0, 0.0) : (0.0, 1.0, 0.0)), "Frame.At: x");
        var d = Dot(hint, z);
        if (Math.Abs(d) > 1 - Square) throw new BuildException("Frame.At: x lies along the normal");
        var ax = Unit((hint.X - d * z.X, hint.Y - d * z.Y, hint.Z - d * z.Z), "Frame.At: x");
        return new Frame(origin, ax, Cross(z, ax), z);
    }

    /// <summary>The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line.</summary>
    public static Frame Midplane(Frame a, Frame b)
    {
        var raw = new double[12];
        if (!BlacksmithNative.cadaclysm_blacksmith_frame_midplane(a.ToArray(), b.ToArray(), raw)) throw Blacksmith.Failure("frame_midplane");
        return Of(raw);
    }

    /// <summary>The plane through three points: its origin p, its x towards q, its z the normal they turn about counter-clockwise. Throws <see cref="BuildException"/> for three points
    /// on one line.</summary>
    public static Frame Through((double X, double Y, double Z) p, (double X, double Y, double Z) q, (double X, double Y, double Z) r)
    {
        var raw = new double[12];
        if (!BlacksmithNative.cadaclysm_blacksmith_frame_through(new[] { p.X, p.Y, p.Z }, new[] { q.X, q.Y, q.Z }, new[] { r.X, r.Y, r.Z }, raw))
            throw Blacksmith.Failure("frame_through");
        return Of(raw);
    }

    public (double X, double Y, double Z) Origin => (_v[0], _v[1], _v[2]);
    public (double X, double Y, double Z) X => (_v[3], _v[4], _v[5]);
    public (double X, double Y, double Z) Y => (_v[6], _v[7], _v[8]);
    public (double X, double Y, double Z) Z => (_v[9], _v[10], _v[11]);

    /// <summary>This frame moved by (`dx`, `dy`, `dz`) in world coordinates.</summary>
    public Frame Translate(double dx, double dy, double dz) =>
        new((_v[0] + dx, _v[1] + dy, _v[2] + dz), X, Y, Z);

    /// <summary>This frame moved `distance` along its own z.</summary>
    public Frame Offset(double distance) => Translate(distance * _v[9], distance * _v[10], distance * _v[11]);

    /// <summary>The twelve numbers: origin, x, y, z -- a copy.</summary>
    public double[] ToArray() => (double[])_v.Clone();

    /// <summary>A frame goes wherever twelve numbers do.</summary>
    public static implicit operator double[](Frame frame) => frame?.ToArray()!;

    public bool Equals(Frame? other) => other is not null && _v.AsSpan().SequenceEqual(other._v);
    public override bool Equals(object? obj) => Equals(obj as Frame);
    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var v in _v) h.Add(v);
        return h.ToHashCode();
    }

    public override string ToString() => $"Frame(origin={Origin}, x={X}, y={Y}, z={Z})";

    private static double Dot((double X, double Y, double Z) a, (double X, double Y, double Z) b) =>
        a.X * b.X + a.Y * b.Y + a.Z * b.Z;

    private static (double X, double Y, double Z) Cross((double X, double Y, double Z) a, (double X, double Y, double Z) b) =>
        (a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X);

    private static (double X, double Y, double Z) Unit((double X, double Y, double Z) v, string what)
    {
        var n = Math.Sqrt(Dot(v, v));
        if (!(n > 1e-12 && double.IsFinite(n))) throw new BuildException($"{what} has no direction");
        return (v.X / n, v.Y / n, v.Z / n);
    }
}

/// <summary>The fluent chain, mirroring the Rust `Workplane`: a frame, the solid built so
/// far, and the face last picked. A build call <em>replaces</em> the solid (as
/// `Workplane::set_brep` does); combine solids explicitly with <see cref="Solid.Join"/>.
/// Every step throws <see cref="BuildException"/> at once rather than latching it. Owns no
/// handle: the solids it makes are the caller's to dispose, through <see cref="Solid()"/>.
/// </summary>
/// <remarks>Two of Python's names could not cross over. `workplane()` -- adopt the picked
/// face's frame -- is <see cref="OnFace"/>, because C# forbids a member named after its own
/// type. And inside this class the method <see cref="Solid()"/> shadows the `Solid` type in
/// expressions, so the build calls below spell the type out in full.</remarks>
public sealed class Workplane
{
    private static readonly double[] XyFrame = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    private static readonly double[] XzFrame = { 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0 };
    private static readonly double[] YzFrame = { 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 };

    private double[] _frame;
    private Solid? _solid;
    private int? _selected;

    /// <summary>A chain on `frame` (twelve numbers), holding `solid` if given -- what
    /// <see cref="On"/> and <see cref="FromSolid"/> build.</summary>
    public Workplane(double[] frame, Solid? solid = null)
    {
        _frame = (double[])Blacksmith.Frame(frame).Clone();
        _solid = solid;
        _selected = null;
    }

    /// <summary>Twelve numbers: origin, x, y, z -- the plane the next build call sketches on.
    /// Settable, as Python's `frame` is; the copy in and out keeps the chain's own array from
    /// being edited underneath it. Setting it leaves the solid and the picked face alone, as
    /// <see cref="OnFace"/> does.</summary>
    public double[] Frame
    {
        get => (double[])_frame.Clone();
        set => _frame = (double[])Blacksmith.Frame(value).Clone();
    }

    public static Workplane Xy() => new(XyFrame, null);

    public static Workplane Xz() => new(XzFrame, null);

    public static Workplane Yz() => new(YzFrame, null);

    public static Workplane On(double[] frame) => new(frame, null);

    public static Workplane FromSolid(Solid solid) => new(XyFrame, solid);

    private Workplane Set(Solid solid)
    {
        _solid = solid;
        _selected = null;
        return this;
    }

    public Workplane Cuboid(double x, double y, double z)
    {
        // The primitive is built about the origin and then placed; the unplaced one is
        // nobody's, so it is freed here rather than left to the finalizer.
        using var raw = global::Cadaclysm.Blacksmith.Solid.Cuboid(x, y, z);
        return Set(raw.Place(_frame));
    }

    public Workplane Cylinder(double r, double h)
    {
        using var raw = global::Cadaclysm.Blacksmith.Solid.Cylinder(r, h);
        return Set(raw.Place(_frame));
    }

    public Workplane Extrude(Profile profile, double height) =>
        Set(global::Cadaclysm.Blacksmith.Solid.Extrude(profile, _frame, height));

    /// <summary>The flat sheet `profile` bounds on this workplane's frame.</summary>
    public Workplane Face(Profile profile) => Set(global::Cadaclysm.Blacksmith.Solid.Face(profile, _frame));

    /// <summary>About this workplane's own y axis through its origin, as the Rust chain.
    /// </summary>
    public Workplane Revolve(Profile profile, double angle)
    {
        var axis = new[] { _frame[0], _frame[1], _frame[2], _frame[6], _frame[7], _frame[8] };
        return Set(global::Cadaclysm.Blacksmith.Solid.Revolve(profile, axis, angle));
    }

    /// <summary>Slide the current solid. Unlike a build call, this keeps <see cref="Faces"/>'s
    /// selection: a rigid translation carries every face along at the same index, exactly as
    /// Rust's `Workplane::translate` writes the moved solid back without touching `selected`.
    /// Rust's is a silent no-op on an empty workplane; this throws at once, like every other
    /// step in the chain.</summary>
    public Workplane Translate(double dx, double dy, double dz)
    {
        if (_solid is null) throw new BuildException("translate: the workplane holds no solid (BuildError::Empty)");
        _solid = _solid.Translate(dx, dy, dz);
        return this;
    }

    public Workplane Faces(Selector selector)
    {
        if (_solid is null) throw new BuildException("faces: the workplane holds no solid (BuildError::Empty)");
        _selected = _solid.SelectFace(selector);
        return this;
    }

    /// <summary>Adopt the frame on the face last picked; a no-op if none is. Python's
    /// `workplane()`, under the one name C# allows (see the class remarks).</summary>
    public Workplane OnFace()
    {
        if (_solid is not null && _selected is not null) _frame = _solid.FaceFrame(_selected.Value);
        return this;
    }

    /// <summary>The solid built so far -- the caller's to dispose.</summary>
    public Solid Solid()
    {
        if (_solid is null) throw new BuildException("solid: nothing was built (BuildError::Empty)");
        return _solid;
    }
}
