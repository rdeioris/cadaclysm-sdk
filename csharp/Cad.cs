// The cadaclysm C ABI, as C# objects: this file is the whole binding.
//
//     using Cadaclysm;
//     using var scene = Cadaclysm.Cadaclysm.Open("part.stp");
//     Console.WriteLine($"{scene.Version} {scene.Schema} {scene.MetresPerUnit}");
//     foreach (var root in scene.Roots) Walk(root);
//
// Declared by hand from the published header, the way any .NET program would — no generated
// interop, no Rust, no build system. Point CADACLYSM_LIBRARY at the shared library if it is
// not in the place the loader looks by default.
//
// ## Everything borrows from the scene
//
// Every pointer this ABI hands back — names, ids, attribute text, vertex and index arrays —
// points into the open document and dies with it. `Mesh`, `Polylines` and `Surfaces` hand
// back `ReadOnlySpan<T>` views straight over the library's own memory rather than copies: an
// assembly with tens of millions of triangles makes a defensive copy of every mesh a cost
// most callers never asked for, most meshes being uploaded to a GPU and dropped. Call
// `Mesh.Copy()` for an array that must outlive the scene, or read the span before
// `Scene.Dispose()` (or `Scene.Close()`) runs: a view asked for after that throws the scene's
// own "closed" exception, as the kernel's views refuse a stale cache, rather than handing
// out a span over freed memory.
//
// Strings are the easy half: every `char *` this ABI returns is marshalled into a copied
// `string` on the way out, so `Node.Name` and friends outlive anything.
//
// `FemMesh` is the one borrowed view whose owner is **not** the scene. It is a handle of your
// own (`Node.FemMesh(..)`, disposed by a `using`), and its spans belong to that handle: closing
// the scene neither frees nor stales one, and only `FemMesh.Free()` — or the `using` that runs
// it — invalidates them. The guard is the same one the scene's views have, and no stronger: a
// span **asked for** after that throws, while one already in hand goes on reading the freed
// block and hands back plausible numbers. So `ToArray()` anything that must outlive the
// handle, exactly as `Mesh.Copy()` is for the scene.
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace Cadaclysm;

/// <summary>The coordinate space to open a file into — the header's CadaclysmConvention.
/// </summary>
/// <remarks>The library converts on the way out, so nothing here rotates anything: a caller
/// names the space it draws in and reads geometry already in it. Native keeps the file's own
/// axes and units, which is what every caller got before the parameter existed and what this
/// binding still defaults to.</remarks>
public enum Convention : uint
{
    /// <summary>The file's own axes and its own units.</summary>
    Native = 0,
    /// <summary>Z up, left-handed, centimetres.</summary>
    Unreal = 1,
    /// <summary>Y up, left-handed, metres.</summary>
    Unity = 2,
    /// <summary>Y up, right-handed, metres — glTF, three.js, Bevy, wgpu.</summary>
    YUp = 3,
    /// <summary>Z up, right-handed, metres. Native's axes at Blender's unit, which is the
    /// only difference between the two.</summary>
    Blender = 4,
}

/// <summary>The bits that OR into a <see cref="Convention"/>'s packed uint.</summary>
public static class ConventionFlag
{
    /// <summary>Keep the preset's axes but the file's own units.</summary>
    /// <remarks>A packing of this binding's own now, not the ABI's: the library takes
    /// `file_units` as a field of `CadaclysmOpenOptions`, and <see cref="Cadaclysm.Open"/>
    /// unpacks this bit into it. It survives because a caller parsing "unreal+file-units"
    /// expects that to keep working.</remarks>
    public const uint FileUnits = 0x100;

    /// <summary>CADACLYSM_UV_WORLD: ask for texture coordinates at world scale, at the cost
    /// of eight bytes a vertex on every mesh in the scene.</summary>
    /// <remarks>Off by default in the library and here. What it turns on is <em>generating</em>
    /// coordinates from a surface's own parameters; a format that stores them is not gated by
    /// it — see <see cref="Mesh.Uvs"/>.</remarks>
    public const uint UvWorld = 0x200;
}

/// <summary>A call into the library failed, carrying what it said about it.</summary>
public sealed class CadaclysmException : Exception
{
    public CadaclysmException(string message) : base(message)
    {
    }
}

/// <summary>Which field of an <see cref="Attribute"/> holds its value.</summary>
/// <remarks>One-based, with zero meaning the attribute was not there — see
/// `include/cadaclysm.h`. A zero-based reading of this enum is off by one for every kind.
/// </remarks>
public enum ValueKind
{
    None = 0,
    Text = 1,
    Integer = 2,
    Real = 3,
    Boolean = 4,
    /// <summary>The flat C struct cannot hold a list's elements, so the text carries a
    /// `[a, b, c]` rendering of them.</summary>
    List = 5,
    /// <summary>Another entity, with the id the file gave (`#4`) as the text. Its own kind
    /// rather than Text so a consumer can follow it instead of showing it as prose.</summary>
    Reference = 6,
}

// ---- SVG ---------------------------------------------------------------------------------

/// <summary>One of the seven camera angles <see cref="SvgOptions.View"/> understands -- the
/// same table `cadaclysm_viewer.VIEWS` gives Python's `show()` and `svg()` both.</summary>
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
/// and which line sets. Mirrors `CadaclysmSvgOptions`, defaulted the way
/// `cadaclysm_svg_options_init` defaults the struct, with <see cref="View"/> supplying <see
/// cref="Azimuth"/>/<see cref="Elevation"/> unless they are set directly.</summary>
/// <remarks>Passed to <see cref="Scene.SvgText"/>, <see cref="Scene.Svg"/>, <see
/// cref="Node.SvgText"/> and <see cref="Node.Svg"/>. A refused option (an out-of-range
/// <see cref="Fov"/>, say) throws <see cref="CadaclysmException"/> naming the field, worded by
/// the library itself.</remarks>
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

    /// <summary>"y" or "z"; null keeps the scene's own convention -- <see cref="Convention.Unity"/>
    /// and <see cref="Convention.YUp"/> default to "y", every other convention to "z".</summary>
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

    /// <summary>`0xRRGGBB`, or null (the default) for no `&lt;rect&gt;` behind the drawing --
    /// the page left to whatever the viewer composites it onto.</summary>
    public uint? Background { get; set; }

    /// <summary>Each shape's feature edges -- the exact curves the flattened polylines are
    /// drawn from. Default true.</summary>
    public bool Edges { get; set; } = true;

    /// <summary>Each shape's free curves -- the ones that are not the edge of any face.
    /// Default false.</summary>
    public bool Curves { get; set; } = false;

    /// <summary>Each shape's isocurves -- the constant-parameter lines across a curved face.
    /// Default false.</summary>
    public bool Isocurves { get; set; } = false;

    /// <summary>Write every line as straight segments within <see cref="Tolerance"/>, instead
    /// of being fitted back to cubic Béziers. Default false.</summary>
    public bool Polylines { get; set; } = false;
}

// ---- the structs the ABI returns by value ----------------------------------------------

[StructLayout(LayoutKind.Sequential)]
internal struct RawBounds
{
    public float MinX, MinY, MinZ;
    public float MaxX, MaxY, MaxZ;
}

/// <summary>`CadaclysmBounds64` in the same flattened shape as <see cref="RawBounds"/> --
/// not pinned by bindings.rs, exactly as `RawBounds` is not: the header's `double min[3]`
/// is one array field, and flattening it to six named doubles is this binding's own choice
/// for callers, not a layout the field-order pin can check.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBounds64
{
    public double MinX, MinY, MinZ;
    public double MaxX, MaxY, MaxZ;
}

// Field order must match the header's CadaclysmMesh exactly. Uvs sits between Normals and
// Indices, which is where the header puts it; a copy that leaves it out still compiles and
// still runs, and reads the null Uvs as Indices and the two halves of the real indices
// pointer as VertexCount and IndexCount.
//
// cadaclysm-capi/tests/bindings.rs pins this against the header, by field order and by
// whether each field is a pointer. It does not pin the exact type, so float becoming double
// is still yours to get right.
[StructLayout(LayoutKind.Sequential)]
internal struct RawMesh
{
    public IntPtr Positions;
    public IntPtr Normals;
    public IntPtr Uvs;
    /// <summary>Four floats a vertex, RGBA — or null, which is the common case. Only a body
    /// the file painted in more than one colour, opened asking for them, carries any.
    /// </summary>
    public IntPtr Colors;
    public IntPtr Indices;
    public uint VertexCount;
    public uint IndexCount;
}

// Field order must match the header's CadaclysmMesh64 exactly (positions, normals, uvs in
// double; colors stays float; indices; the two counts) -- pinned by bindings.rs, as RawMesh
// is.
[StructLayout(LayoutKind.Sequential)]
internal struct RawMesh64
{
    public IntPtr Positions;
    public IntPtr Normals;
    public IntPtr Uvs;
    /// <summary>Still four floats a vertex -- RGBA in 0..1 needs no more precision.</summary>
    public IntPtr Colors;
    public IntPtr Indices;
    public uint VertexCount;
    public uint IndexCount;
}

/// <summary>`CadaclysmOpenOptions`. `Size` is the contract for `cadaclysm_open`: the library
/// reads only the fields that fit inside it and defaults the rest. But <see
/// cref="Cadaclysm.Open"/> has `cadaclysm_open_options_init` fill the defaults, and init
/// writes the <em>whole</em> struct the library was built with, so this must be at least as
/// long as the header's — and it may never reorder. `tests/bindings.rs` pins it against the
/// header.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawOpenOptions
{
    public nuint Size;
    public uint Convention;
    public IntPtr Spec;
    // One byte in C, four in C# unless it is told otherwise. Every field after this one
    // would land at the wrong offset without the marshalling hint.
    [MarshalAs(UnmanagedType.I1)] public bool FileUnits;
    public uint Uvs;
    public uint Colors;
    // The header's spelling, not this file's house style: the pin in tests/bindings.rs
    // matches names letter for letter.
    public double SourceMetersPerUnit;
    public IntPtr Schemas;
    public nuint SchemaCount;
    public IntPtr SchemaText;
    public nuint SchemaLength;
    // The pick hook is not exposed here: `CadaclysmPick` is a function pointer and both stay
    // null, which takes the library's own choice among a zip's members. They are declared
    // because init writes them -- without these two it wrote 16 bytes past the struct, which
    // showed up elsewhere as heap corruption on one open in three.
    public IntPtr Pick;
    public IntPtr PickUser;
}

/// <summary>`CadaclysmSvgOptions`. Field order and `Size` are the contract, as <see
/// cref="RawOpenOptions"/> above: `cadaclysm_svg_options_init` fills the library's whole
/// struct, so this must match the header field for field and may never reorder. Pinned by
/// `tests/bindings.rs` against the header, as the other structs here are.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawSvgOptions
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

/// <summary>`CadaclysmFemOptions`. Field order and `Size` are the whole contract, as <see
/// cref="RawOpenOptions"/> above: `cadaclysm_fem_options_init` fills the library's <em>whole</em>
/// struct, so this must be at least as long as the header's and may never reorder. A field the
/// library has and this one does not is written past what <see cref="Node.FemMesh"/> allocated,
/// which is the `CadaclysmOpenOptions` overrun the pin in `tests/bindings.rs` exists for.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawFemOptions
{
    public nuint Size;
    public double Tolerance;
    public double MaxSize;
}

/// <summary>`CadaclysmFemMeshView`. Every pointer here is borrowed from the FEM handle and dies
/// with it; the counts are in elements, so `Nodes` holds `NodeCount * 3` doubles and `Triangles`
/// `TriangleCount * 3` indices. Pinned against the header by `tests/bindings.rs`, which is the
/// only thing standing between a missing field here and reading `MinAngle` out of
/// `Watertight`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawFemMeshView
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

/// <summary>`CadaclysmFemEdge`: one B-rep edge's node chain. Pinned by `tests/bindings.rs`.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawFemEdge
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

/// <summary>`CadaclysmFemVertex`. `Point` is a fixed buffer of three doubles, not a pointer: the
/// vertex's own position, copied into the struct. Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawFemVertex
{
    public uint Node;
    public fixed double Point[3];
    [MarshalAs(UnmanagedType.I1)] public bool HasPosition;
}

[StructLayout(LayoutKind.Sequential)]
internal struct RawPolylines
{
    public IntPtr Positions;
    public IntPtr Counts;
    public uint PolylineCount;
    public uint VertexCount;
}

[StructLayout(LayoutKind.Sequential)]
internal struct RawEdgeColors
{
    public IntPtr Rgba;
    public uint Count;
}

// Field order must match the header's CadaclysmBeziers exactly; pinned by bindings.rs.
[StructLayout(LayoutKind.Sequential)]
internal struct RawBeziers
{
    public IntPtr Points;
    public IntPtr Weights;
    public uint Count;
}

// Field order must match the header's CadaclysmBeziers64 exactly; pinned by bindings.rs.
[StructLayout(LayoutKind.Sequential)]
internal struct RawBeziers64
{
    public IntPtr Points;
    public IntPtr Weights;
    public uint Count;
}

// CadaclysmCollision: `Size` first, which the caller fills. `Frame` and `HalfExtent` are
// fixed buffers, which bindings.rs's field parser does not read (as RawFace); the field
// order is the header's, checked by eye against it.
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawCollision
{
    public uint Size;
    public uint Shape;
    public uint Confidence;
    public uint Axis;
    public fixed double Frame[16];
    public fixed double HalfExtent[3];
    public double Radius;
    public double Height;
    public double Error;
    public uint HullVertexCount;
    public uint HullIndexCount;
}

// Field order must match the header's CadaclysmCollisionHull exactly; pinned by bindings.rs.
[StructLayout(LayoutKind.Sequential)]
internal struct RawCollisionHull
{
    public IntPtr Positions;
    public IntPtr Indices;
    public uint VertexCount;
    public uint IndexCount;
}

// Field order must match the header's CadaclysmAttribute exactly.
[StructLayout(LayoutKind.Sequential)]
internal struct RawAttribute
{
    public IntPtr Name;
    public int Kind; // enum CadaclysmValueKind
    public IntPtr Text;
    public long Integer;
    public double Real;
    [MarshalAs(UnmanagedType.I1)] public bool Boolean;
}

/// <summary>`CadaclysmSurfaces`, returned by value from `cadaclysm_node_surfaces`: a copy that
/// stops short is a return buffer the callee writes past, so every field is here whether this
/// binding reads it or not. Pinned against the header by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawSurfaces
{
    public IntPtr Faces;
    public uint FaceCount;
    public IntPtr Loops;
    public uint LoopCount;
    public IntPtr Points;
    public uint PointCount;
    public IntPtr Profiles;
    public uint ProfileCount;
    public IntPtr Nurbs;
    public uint NurbsCount;
    public IntPtr Shared;
    public uint SharedCount;
}

/// <summary>`CadaclysmFace`. Read only through a raw pointer into `RawSurfaces.Faces` — never
/// itself the return or parameter type of a `[DllImport]` — so the fixed buffers below give
/// it exactly the header's in-memory layout rather than the array-marshalling layout a
/// P/Invoke call boundary would apply to a `float[4]`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawFace
{
    public uint Kind;
    public uint Reversed;
    public uint Transposed;
    public uint Reserved;
    public fixed float Origin[4];
    public fixed float Ax[4];
    public fixed float Ay[4];
    public fixed float Az[4];
    public fixed float Domain[4];
    public fixed float Scalars[4];
    public uint LoopStart;
    public uint LoopCount;
    public uint ProfileStart;
    public uint ProfileCount;
    public uint Profile2Start;
    public uint Profile2Count;
    public uint NurbsStart;
    public uint NurbsCount;
}

// ---- owning a handle ----------------------------------------------------------------------

/// <summary>A native handle this binding owns, freed exactly once by the runtime's own
/// bookkeeping rather than by a finalizer of the owner's. Every `[DllImport]` that takes or
/// returns an owned handle is typed with a subclass of this instead of `IntPtr`: the
/// marshaller then holds a reference on it for the length of every call, so a temporary
/// operand -- `Solid.Cuboid(..).Join(Solid.Cylinder(..))`, the cylinder nobody's -- cannot be
/// collected and freed while the library is still reading it, which an owner's finalizer
/// could not promise once the JIT ended the operand's lifetime at its last use. A closed
/// handle refuses to be marshalled at all, and disposing twice is a no-op by construction.
/// Only the `*_free`/`close` entry points still take an `IntPtr`: they are what
/// <see cref="SafeHandle.ReleaseHandle"/> calls.</summary>
internal abstract class CadaclysmHandle : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid
{
    protected CadaclysmHandle() : base(ownsHandle: true)
    {
    }
}

/// <summary>`CadaclysmScene *`, given back by `cadaclysm_close`.</summary>
internal sealed class SceneHandle : CadaclysmHandle
{
    public SceneHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        Native.cadaclysm_close(handle);
        return true;
    }
}

/// <summary>`CadaclysmBrep *`, a reference on a body's brep, given back by
/// `cadaclysm_brep_release`. A `SafeHandle` so the marshaller holds it for the length of
/// `cadaclysm_blacksmith_from_brep`, as it does every other owned handle.</summary>
internal sealed class BrepHandle : CadaclysmHandle
{
    public BrepHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        Native.cadaclysm_brep_release(handle);
        return true;
    }
}

/// <summary>`CadaclysmMeshlets *`, freed by `cadaclysm_meshlets_free`.</summary>
internal sealed class MeshletsHandle : CadaclysmHandle
{
    public MeshletsHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        Native.cadaclysm_meshlets_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmFemMesh *`, freed by `cadaclysm_fem_mesh_free`.</summary>
internal sealed class FemMeshHandle : CadaclysmHandle
{
    public FemMeshHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        Native.cadaclysm_fem_mesh_free(handle);
        return true;
    }
}

// ---- loading the library ------------------------------------------------------------------

/// <summary>Resolves `cadaclysm_capi` for every P/Invoke in <see cref="Native"/>, and hands
/// `cadaclysm_blacksmith` to <see cref="Kernel"/> for every one in `Blacksmith.cs`'s
/// `BlacksmithNative`.</summary>
internal static class Loader
{
    private static readonly object Gate = new();
    private static bool _registered;

    /// <summary>How the kernel library is found: set by `Blacksmith.cs` before it registers,
    /// since the kernel follows its own rule -- Python's kernel module's, with its own variable
    /// and its own error -- and this file compiles without that one. The runtime allows one
    /// resolver per assembly, so the kernel's rule is handed to this one rather than
    /// installed beside it.</summary>
    internal static Func<IntPtr>? Kernel;

    /// <summary>Install this assembly's `DllImport` resolver, once. Both native classes call
    /// this from their static constructors: the runtime allows one resolver per assembly and
    /// throws on a second, so neither class may set its own.</summary>
    public static void Register()
    {
        lock (Gate)
        {
            if (_registered) return;
            _registered = true;
            NativeLibrary.SetDllImportResolver(typeof(Loader).Assembly, (name, assembly, path) =>
                name == "cadaclysm_blacksmith" ? Kernel?.Invoke() ?? IntPtr.Zero
                : name.StartsWith("cadaclysm_", StringComparison.Ordinal) ? Resolve(name)
                : IntPtr.Zero);
        }
    }

    /// <summary>The two libraries resolved through here, and the file names each goes by.
    /// </summary>
    private static readonly string[] Libraries = { "cadaclysm_capi", "cadaclysm_blacksmith" };

    private static string[] FilesOf(string libraryName) =>
        new[] { $"{libraryName}.dll", $"lib{libraryName}.dylib", $"lib{libraryName}.so" };

    /// <summary>Finds and loads the reader library: `CADACLYSM_LIBRARY` as a directory or the
    /// file itself, then beside this assembly, then `lib/` and `target/{release,debug}` in
    /// every ancestor, then the platform default search. The kernel has its own rule, in
    /// `Blacksmith.cs` (see <see cref="Kernel"/>).</summary>
    /// <remarks>The library sits in the Rust build directory, not beside this assembly by
    /// default, so this points the loader at it rather than making the caller arrange PATH.
    /// A deployment that ships the library alongside the executable works untouched, since
    /// that is tried before falling through to the OS's own search.</remarks>
    public static IntPtr Resolve(string libraryName)
    {
        var files = FilesOf(libraryName);
        var candidates = new List<string>();
        foreach (var variable in new[] { "CADACLYSM_LIBRARY" })
        {
            var env = Environment.GetEnvironmentVariable(variable);
            if (string.IsNullOrEmpty(env)) continue;
            if (Directory.Exists(env))
            {
                // A directory is taken as the place the library is, as Python takes it: one
                // holding neither library is the same mistake as a path to nothing, not a
                // hint to go on searching and load some other copy. One holding only the
                // other library is simply not for this one (see the file case below).
                var inside = files.Select(f => Path.Combine(env, f)).Where(File.Exists).ToArray();
                if (inside.Length == 0
                    && !Libraries.Any(l => FilesOf(l).Any(f => File.Exists(Path.Combine(env, f)))))
                    throw new CadaclysmException($"{variable}={env} names nothing that exists");
                candidates.AddRange(inside);
                continue;
            }
            // A variable that names nothing usable is a mistake to report, as Python's loader
            // reports it, not a hint to fall through to the search and load something else.
            if (!File.Exists(env)) throw new CadaclysmException($"{variable}={env} names nothing that exists");
            var basename = Path.GetFileName(env);
            if (files.Contains(basename, StringComparer.OrdinalIgnoreCase))
            {
                candidates.Add(env);
                continue;
            }
            // A file names one library, and two are resolved through here. One naming the
            // other library is simply not for this one (it would load, then fail at the first
            // entry point), so the search goes on; one naming neither is a mistake.
            if (!Libraries.Any(l => FilesOf(l).Contains(basename, StringComparer.OrdinalIgnoreCase)))
                throw new CadaclysmException(
                    $"{variable}={env} names neither cadaclysm_capi nor cadaclysm_blacksmith");
        }
        // Beside this assembly first, as Python looks beside its own file: a deployment that
        // ships the library alongside the executable. Then walking up from it: an SDK
        // checkout keeps the library in `lib/` beside the wrappers; the repository this
        // example ships in keeps it in `target/release` (or `target/debug`, a fallback for a
        // machine that only built that).
        var assembly = Assembly.GetExecutingAssembly().Location;
        var here = Path.GetDirectoryName(assembly);
        if (here is not null) candidates.AddRange(files.Select(f => Path.Combine(here, f)));
        for (var dir = here; dir is not null; dir = Path.GetDirectoryName(dir))
        {
            candidates.AddRange(files.Select(f => Path.Combine(dir, "lib", f)));
            candidates.AddRange(files.Select(f => Path.Combine(dir, "target", "release", f)));
            candidates.AddRange(files.Select(f => Path.Combine(dir, "target", "debug", f)));
        }
        foreach (var candidate in candidates)
            if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var handle))
                return handle;
        return NativeLibrary.TryLoad(libraryName, out var fallback) ? fallback : IntPtr.Zero;
    }
}

/// <summary>Every entry point in `include/cadaclysm.h` this binding declares — the same set
/// Python's `cadaclysm.py` does, no more and no less;
/// `tests/bindings.rs`'s `parity_languages_declare_everything_python_does` is what holds the
/// two sets equal, and prints the figure as a coverage table when asked
/// (`CADACLYSM_COVERAGE_OUT=…`).</summary>
/// <remarks>This sentence said "the same 58" until 2026-09-24, by which time the header
/// declared 121. A count written into prose is checked by nothing and goes stale silently, so
/// the figure now lives only where it is derived.</remarks>
internal static class Native
{
    private const string Lib = "cadaclysm_capi";

    static Native()
    {
        Loader.Register();
    }

    [DllImport(Lib)] internal static extern IntPtr cadaclysm_last_error();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_version();
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_license_set([MarshalAs(UnmanagedType.LPUTF8Str)] string textOrPath);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_license_info();
    [DllImport(Lib)] internal static extern ulong cadaclysm_license_notice_count();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_build_date();
    [DllImport(Lib)] internal static extern SceneHandle cadaclysm_open(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref RawOpenOptions options);
    [DllImport(Lib)] internal static extern SceneHandle cadaclysm_open_memory(
        IntPtr bytes, nuint length, [MarshalAs(UnmanagedType.LPUTF8Str)] string format,
        ref RawOpenOptions options);
    [DllImport(Lib)] internal static extern void cadaclysm_open_options_init(ref RawOpenOptions options);
    [DllImport(Lib)] internal static extern void cadaclysm_close(IntPtr scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_source_name(SceneHandle scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_count(SceneHandle scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_root_count(SceneHandle scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_root(SceneHandle scene, uint index);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_schema(SceneHandle scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_schema_read(SceneHandle scene);
    [DllImport(Lib)] internal static extern double cadaclysm_metres_per_unit(SceneHandle scene);
    [DllImport(Lib)] internal static extern RawBounds cadaclysm_bounds(SceneHandle scene);
    [DllImport(Lib)] internal static extern RawBounds64 cadaclysm_bounds64(SceneHandle scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_parent(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_child_count(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_child(SceneHandle scene, uint node, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_depth(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_name(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_kind(SceneHandle scene, uint node);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_visible(SceneHandle scene, uint node);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_save_mesh(SceneHandle scene, uint node,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, [MarshalAs(UnmanagedType.LPUTF8Str)] string format);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_scene_save(SceneHandle scene,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, [MarshalAs(UnmanagedType.LPUTF8Str)] string format);
    [DllImport(Lib)] internal static extern uint cadaclysm_mesh_format_count();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_mesh_format(uint index);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_mesh_format_extension(uint index);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_mesh_format_label(uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_format_count();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_format_name(uint index);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_format_extensions(uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_query(SceneHandle scene,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filter, [Out] uint[]? outArr, uint capacity);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_pick_file(IntPtr window);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_pick_save(IntPtr window, [MarshalAs(UnmanagedType.LPUTF8Str)] string? suggestedName);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_id(SceneHandle scene, uint node);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_color(SceneHandle scene, uint node, [Out] float[] rgba);
    [DllImport(Lib)] internal static extern void cadaclysm_node_transform(SceneHandle scene, uint node,
        [Out] double[] outMatrix);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_attribute_count(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawAttribute cadaclysm_node_attribute(SceneHandle scene, uint node, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_placement_count(SceneHandle scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_placement_geometry(SceneHandle scene, uint placement);
    [DllImport(Lib)] internal static extern uint cadaclysm_placement_select(SceneHandle scene, uint placement);
    [DllImport(Lib)] internal static extern void cadaclysm_placement_transform(SceneHandle scene, uint placement,
        [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_can_mesh(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawMesh cadaclysm_node_mesh(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawMesh64 cadaclysm_node_mesh64(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_lod_levels();
    [DllImport(Lib)] internal static extern RawMesh cadaclysm_node_mesh_lod(SceneHandle scene, uint node, uint level);
    [DllImport(Lib)] internal static extern float cadaclysm_node_lod_error(SceneHandle scene, uint node, uint level);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_collision(SceneHandle scene, uint node, uint hullBudget, ref RawCollision outBody);
    [DllImport(Lib)] internal static extern RawCollisionHull cadaclysm_node_collision_hull(SceneHandle scene, uint node, uint hullBudget);
    [DllImport(Lib)] internal static extern RawBounds cadaclysm_node_bounds_placed(SceneHandle scene, uint node, double[]? placement);
    [DllImport(Lib)] internal static extern RawBounds64 cadaclysm_node_bounds_placed64(SceneHandle scene, uint node, double[]? placement);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_is_meshed(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_surface_edges(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawBeziers cadaclysm_node_surface_edge_beziers(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawEdgeColors cadaclysm_node_surface_edge_colors(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_surface_isocurves(SceneHandle scene, uint node);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_surface_pick(SceneHandle scene, uint node, double[] from, double[] to, [Out] double[] outPoint);
    [DllImport(Lib)] internal static extern RawMesh cadaclysm_node_surface_proxy_mesh(SceneHandle scene, uint node, uint cells);
    [DllImport(Lib)] internal static extern long cadaclysm_node_triangle_estimate(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawSurfaces cadaclysm_node_surfaces(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern BrepHandle cadaclysm_node_brep(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern void cadaclysm_brep_release(IntPtr brep);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_brep_layout_id();
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_brep_manifold(BrepHandle brep, [Out] uint[] outRow);
    [DllImport(Lib)] internal static extern void cadaclysm_surface_matrix(SceneHandle scene, [Out] float[] outMatrix);
    [DllImport(Lib)] internal static extern RawBounds cadaclysm_node_bounds(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawBounds64 cadaclysm_node_bounds64(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_instance_of(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_select_as(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_generator(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_diagnostic_count(SceneHandle scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_diagnostic(SceneHandle scene, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_geometry_diagnostic_count(SceneHandle scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_geometry_diagnostic(SceneHandle scene, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_link_count(SceneHandle scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_link_name(SceneHandle scene, uint link);
    [DllImport(Lib)] internal static extern uint cadaclysm_link_node_count(SceneHandle scene, uint link);
    [DllImport(Lib)] internal static extern uint cadaclysm_link_node(SceneHandle scene, uint link, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_joint_count(SceneHandle scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_joint_name(SceneHandle scene, uint joint);
    [DllImport(Lib)] internal static extern uint cadaclysm_joint_start(SceneHandle scene, uint joint);
    [DllImport(Lib)] internal static extern uint cadaclysm_joint_end(SceneHandle scene, uint joint);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_edges(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawEdgeColors cadaclysm_node_edge_colors(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_curves(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_isocurves(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawBeziers cadaclysm_node_edge_beziers(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawBeziers64 cadaclysm_node_edge_beziers64(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawBeziers cadaclysm_node_curve_beziers(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawBeziers64 cadaclysm_node_curve_beziers64(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawBeziers cadaclysm_node_isocurve_beziers(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern RawBeziers64 cadaclysm_node_isocurve_beziers64(SceneHandle scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_realize_all(SceneHandle scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_realize_meshes(SceneHandle scene, uint skipSurfaced);
    [DllImport(Lib)] internal static extern uint cadaclysm_realized(SceneHandle scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_realize_total(SceneHandle scene);
    [DllImport(Lib)] internal static extern void cadaclysm_cancel(SceneHandle scene);
    [DllImport(Lib)] internal static extern MeshletsHandle cadaclysm_meshlets_build(float[] positions, float[]? normals, nuint vertexCount, uint[] indices, nuint indexCount, uint maxTriangles, uint maxVertices, int levels);
    [DllImport(Lib)] internal static extern uint cadaclysm_meshlets_count(MeshletsHandle handle);
    [DllImport(Lib)] internal static extern void cadaclysm_meshlets_free(IntPtr handle);
    [DllImport(Lib)] internal static extern uint cadaclysm_meshlet_triangle_count(MeshletsHandle handle, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_meshlet_vertex_count(MeshletsHandle handle, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_meshlet_level(MeshletsHandle handle, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_meshlet_group(MeshletsHandle handle, uint index);
    [DllImport(Lib)] internal static extern float cadaclysm_meshlet_error(MeshletsHandle handle, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_meshlet_child_count(MeshletsHandle handle, uint index);
    [DllImport(Lib)] internal static extern void cadaclysm_meshlet_positions(MeshletsHandle handle, uint index, [Out] float[] outPositions);
    [DllImport(Lib)] internal static extern void cadaclysm_meshlet_normals(MeshletsHandle handle, uint index, [Out] float[] outNormals);
    [DllImport(Lib)] internal static extern void cadaclysm_meshlet_indices(MeshletsHandle handle, uint index, [Out] uint[] outIndices);
    [DllImport(Lib)] internal static extern void cadaclysm_meshlet_children(MeshletsHandle handle, uint index, [Out] uint[] outChildren);
    // The FEM surface mesh: one handle per meshed body, freed by the caller. `msh_text` comes
    // back as an `IntPtr` and is marshalled into a `string` of ours, which is what makes the
    // borrowed-slot lifetime `cadaclysm_fem_mesh_msh_text` documents a non-issue here -- see
    // <see cref="FemMesh.MshText"/>.
    [DllImport(Lib)] internal static extern void cadaclysm_fem_options_init(ref RawFemOptions options);
    [DllImport(Lib)] internal static extern FemMeshHandle cadaclysm_node_fem_mesh(SceneHandle scene, uint node,
        double[]? placement, ref RawFemOptions options);
    [DllImport(Lib)] internal static extern void cadaclysm_fem_mesh_free(IntPtr mesh);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_fem_mesh_view(FemMeshHandle mesh, ref RawFemMeshView outView);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_fem_mesh_edge(FemMeshHandle mesh, uint index, ref RawFemEdge outEdge);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_fem_mesh_vertex(FemMeshHandle mesh, uint index, ref RawFemVertex outVertex);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_fem_mesh_open_edge(FemMeshHandle mesh, uint index,
        out uint outA, out uint outB, out uint outBrepEdge);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_fem_mesh_folded_edge(FemMeshHandle mesh, uint index,
        out uint outA, out uint outB, out uint outBrepEdge);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_fem_mesh_msh_text(FemMeshHandle mesh);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_fem_mesh_save_msh(FemMeshHandle mesh,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(Lib)] internal static extern void cadaclysm_forget_meshes(SceneHandle scene);
    [DllImport(Lib)] internal static extern void cadaclysm_svg_options_init(ref RawSvgOptions options);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_scene_svg_text(SceneHandle scene, ref RawSvgOptions options);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_scene_svg(SceneHandle scene,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref RawSvgOptions options);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_svg_text(SceneHandle scene, uint node, ref RawSvgOptions options);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_svg(SceneHandle scene, uint node,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref RawSvgOptions options);
}

/// <summary>A 4x4 column-major ABI matrix (16 doubles or 16 floats) as the row-major 2D array
/// this binding hands callers, so `M[row, col]` is the rotation/scale block for
/// `row,col &lt; 3` and the offset for `col == 3` -- the textbook convention, and the one
/// numpy's clients already read this ABI in.</summary>
internal static class Matrices
{
    internal static double[,] ToRowMajor(double[] raw)
    {
        var m = new double[4, 4];
        for (var col = 0; col < 4; col++)
            for (var row = 0; row < 4; row++)
                m[row, col] = raw[col * 4 + row];
        return m;
    }

    internal static float[,] ToRowMajor(float[] raw)
    {
        var m = new float[4, 4];
        for (var col = 0; col < 4; col++)
            for (var row = 0; row < 4; row++)
                m[row, col] = raw[col * 4 + row];
        return m;
    }
}

/// <summary>An axis-aligned box, or all zeros where there was nothing to bound.</summary>
public readonly struct Bounds
{
    public float[] Min { get; }
    public float[] Max { get; }

    public Bounds(float[] min, float[] max)
    {
        Min = min;
        Max = max;
    }

    /// <summary>Whether this is the all-zero box the ABI uses for "nothing here".</summary>
    public bool IsEmpty => Min.All(v => v == 0) && Max.All(v => v == 0);

    public float[] Size => new[] { Max[0] - Min[0], Max[1] - Min[1], Max[2] - Min[2] };

    public float[] Centre => new[]
    {
        (Min[0] + Max[0]) / 2f, (Min[1] + Max[1]) / 2f, (Min[2] + Max[2]) / 2f,
    };
}

/// <summary>`CadaclysmBounds64`: the same axis-aligned box as <see cref="Bounds"/>,
/// unnarrowed -- exact far from the origin, where <see cref="Bounds"/>'s widened `float`
/// positions are not.</summary>
public readonly struct Bounds64
{
    public double[] Min { get; }
    public double[] Max { get; }

    public Bounds64(double[] min, double[] max)
    {
        Min = min;
        Max = max;
    }

    /// <summary>Whether this is the all-zero box the ABI uses for "nothing here".</summary>
    public bool IsEmpty => Min.All(v => v == 0) && Max.All(v => v == 0);

    public double[] Size => new[] { Max[0] - Min[0], Max[1] - Min[1], Max[2] - Min[2] };

    public double[] Centre => new[]
    {
        (Min[0] + Max[0]) / 2, (Min[1] + Max[1]) / 2, (Min[2] + Max[2]) / 2,
    };
}

/// <summary>One thing the file said about a node.</summary>
/// <remarks><see cref="Value"/> is this value in .NET's own natural rendering — the nearest
/// equivalent of Python's typed `attribute.value` that a single string field can carry.
/// <see cref="Text"/> is the value rendered exactly as cadaclysm's own Rust `Display` renders
/// it, which is what agrees byte for byte with the Go, C# and Java clients — the two differ
/// only for <see cref="ValueKind.Real"/> (scientific notation) and <see cref="ValueKind.Boolean"/>
/// (capitalisation).</remarks>
public sealed record Attribute(string Name, ValueKind Kind, string Value)
{
    public string Text => Kind switch
    {
        ValueKind.None => "",
        ValueKind.Boolean => Value == "True" ? "true" : "false",
        ValueKind.Real => FormatReal(double.Parse(Value, NumberStyles.Float, CultureInfo.InvariantCulture)),
        _ => Value,
    };

    /// <summary>A real the way cadaclysm's own `Display for Value` renders it in Rust: the
    /// shortest decimal that round-trips, never forcing a trailing `.0`, and never in
    /// exponent notation for any magnitude a CAD property plausibly holds.</summary>
    /// <remarks><c>double.ToString("G")</c> already gives the shortest round-tripping digits
    /// and never adds a spurious `.0`, but it switches to scientific notation outside roughly
    /// `1e-4..1e17`, and an IFC geometric-context precision of `1e-5` is well inside what a
    /// CAD property plausibly holds. Where Rust prints `0.00001`, "G" prints `1E-05`. This
    /// expands that scientific form back to fixed notation, digit for digit.</remarks>
    private static string FormatReal(double value)
    {
        if (double.IsNaN(value)) return "NaN";
        if (double.IsPositiveInfinity(value)) return "inf";
        if (double.IsNegativeInfinity(value)) return "-inf";
        var s = value.ToString("G", CultureInfo.InvariantCulture);
        var e = s.IndexOfAny(new[] { 'E', 'e' });
        if (e < 0) return s;
        var negative = s[0] == '-';
        var body = negative ? s[1..] : s;
        e = body.IndexOfAny(new[] { 'E', 'e' });
        var mantissa = body[..e];
        var exponent = int.Parse(body[(e + 1)..], CultureInfo.InvariantCulture);
        var dot = mantissa.IndexOf('.');
        var digits = dot < 0 ? mantissa : mantissa.Remove(dot, 1);
        var pointPos = (dot < 0 ? mantissa.Length : dot) + exponent;
        var result = pointPos <= 0 ? "0." + new string('0', -pointPos) + digits
            : pointPos >= digits.Length ? digits + new string('0', pointPos - digits.Length)
            : digits[..pointPos] + "." + digits[pointPos..];
        return negative ? "-" + result : result;
    }
}

/// <summary>A node's triangles, copied out as managed arrays -- what <see cref="Mesh.Copy"/>
/// returns.</summary>
public sealed record MeshData(float[] Positions, float[] Normals, float[]? Uvs, float[]? Colours, uint[] Indices);

/// <summary>A node's triangles, in the node's own frame -- views over the scene's own memory,
/// valid until <see cref="Scene.Dispose"/> or <see cref="Scene.Close"/>.</summary>
/// <remarks><see cref="Positions"/> and <see cref="Normals"/> are `(VertexCount * 3)` floats,
/// <see cref="Uvs"/> is `(VertexCount * 2)`, <see cref="Colours"/> is `(VertexCount * 4)` RGBA,
/// and <see cref="Indices"/> is `(IndexCount)`, three to a triangle. An empty span (`Length ==
/// 0`) stands in for Python's `None`: a mesh built with no normals, no UVs and no per-vertex
/// colour is the common case.</remarks>
public sealed class Mesh
{
    private readonly RawMesh _raw;

    /// <summary>The scene this borrows from. Kept so a caller can see what must stay open,
    /// not to extend its lifetime -- see the module header on why nothing here does.</summary>
    public Scene Scene { get; }

    internal Mesh(Scene scene, RawMesh raw)
    {
        Scene = scene;
        _raw = raw;
    }

    public uint VertexCount => _raw.VertexCount;
    public uint IndexCount => _raw.IndexCount;
    public uint TriangleCount => _raw.IndexCount / 3;

    /// <summary>A view over a closed scene is over freed memory: every span below asks the
    /// scene first, and a closed one throws its own <see cref="CadaclysmException"/> rather
    /// than handing out a span into it.</summary>
    private unsafe ReadOnlySpan<T> View<T>(IntPtr at, uint length)
    {
        _ = Scene.Handle;
        return at == IntPtr.Zero ? ReadOnlySpan<T>.Empty : new ReadOnlySpan<T>((void*)at, (int)length);
    }

    public ReadOnlySpan<float> Positions => View<float>(_raw.Positions, _raw.VertexCount * 3);

    public ReadOnlySpan<float> Normals => View<float>(_raw.Normals, _raw.VertexCount * 3);

    /// <summary>Two floats a vertex, not three. See the surface-parameterisation note on
    /// `CadaclysmMesh::uvs` in the header for what generates them and what does not.</summary>
    public ReadOnlySpan<float> Uvs => View<float>(_raw.Uvs, _raw.VertexCount * 2);

    /// <summary>Four floats a vertex, RGBA -- present only for a body opened asking for
    /// per-vertex colour whose faces carry more than one between them.</summary>
    public ReadOnlySpan<float> Colours => View<float>(_raw.Colors, _raw.VertexCount * 4);

    public ReadOnlySpan<uint> Indices => View<uint>(_raw.Indices, _raw.IndexCount);

    /// <summary>The same triangles in memory of our own, safe to outlive the scene.</summary>
    /// <remarks>Expensive on purpose to be visible: this is where the gigabytes go on a large
    /// assembly, and it should be a line a reader can point at.</remarks>
    public MeshData Copy() => new(
        Positions.ToArray(),
        Normals.ToArray(),
        Uvs.IsEmpty ? null : Uvs.ToArray(),
        Colours.IsEmpty ? null : Colours.ToArray(),
        Indices.ToArray());
}

/// <summary>A node's triangles in `double`, copied out -- what <see cref="Mesh64.Copy"/>
/// returns.</summary>
public sealed record MeshData64(double[] Positions, double[] Normals, double[]? Uvs, float[]? Colours, uint[] Indices);

/// <summary>[`CadaclysmMesh64`]: this node's own mesh, in `double`, **lent as it is** rather
/// than narrowed the way <see cref="Mesh"/> is -- the same triangles and indices, <see
/// cref="Mesh"/>'s `float` positions being exactly these narrowed. For a caller that uses the
/// mesh as geometry (an exporter, a measurement, a solver) and wants the file's own
/// coordinates, which `float` cannot hold far from the origin.</summary>
/// <remarks>Colours stay `float` (RGBA in 0..1 needs no more). <strong>A forget drops
/// it</strong>: <see cref="Scene.ForgetMeshes"/> frees the document's own mesh these pointers
/// borrow -- read none of them after a forget, ask again and the mesh is built again. <see
/// cref="Mesh"/>'s pointers survive a forget, its `float` copy being kept separately.</remarks>
public sealed class Mesh64
{
    private readonly RawMesh64 _raw;

    /// <summary>The scene this borrows from.</summary>
    public Scene Scene { get; }

    internal Mesh64(Scene scene, RawMesh64 raw)
    {
        Scene = scene;
        _raw = raw;
    }

    public uint VertexCount => _raw.VertexCount;
    public uint IndexCount => _raw.IndexCount;
    public uint TriangleCount => _raw.IndexCount / 3;

    /// <summary>As <see cref="Mesh"/>'s: a closed scene throws rather than hands out a span
    /// over freed memory.</summary>
    private unsafe ReadOnlySpan<T> View<T>(IntPtr at, uint length)
    {
        _ = Scene.Handle;
        return at == IntPtr.Zero ? ReadOnlySpan<T>.Empty : new ReadOnlySpan<T>((void*)at, (int)length);
    }

    public ReadOnlySpan<double> Positions => View<double>(_raw.Positions, _raw.VertexCount * 3);

    public ReadOnlySpan<double> Normals => View<double>(_raw.Normals, _raw.VertexCount * 3);

    /// <summary>Two doubles a vertex, not three. See <see cref="Mesh.Uvs"/> for what
    /// generates them and what does not.</summary>
    public ReadOnlySpan<double> Uvs => View<double>(_raw.Uvs, _raw.VertexCount * 2);

    /// <summary>Four floats a vertex, RGBA -- still `float`, as the header's note on
    /// `CadaclysmMesh64::colors` says: RGBA in 0..1 needs no more precision.</summary>
    public ReadOnlySpan<float> Colours => View<float>(_raw.Colors, _raw.VertexCount * 4);

    public ReadOnlySpan<uint> Indices => View<uint>(_raw.Indices, _raw.IndexCount);

    /// <summary>The same triangles in memory of our own, safe to outlive the scene.</summary>
    public MeshData64 Copy() => new(
        Positions.ToArray(),
        Normals.ToArray(),
        Uvs.IsEmpty ? null : Uvs.ToArray(),
        Colours.IsEmpty ? null : Colours.ToArray(),
        Indices.ToArray());
}

/// <summary>A node's feature edges or free curves, already flattened to points -- a view over
/// the scene's own memory, valid until the scene closes.</summary>
public sealed class Polylines
{
    private readonly RawPolylines _raw;

    public Scene Scene { get; }

    internal Polylines(Scene scene, RawPolylines raw)
    {
        Scene = scene;
        _raw = raw;
    }

    public uint PolylineCount => _raw.PolylineCount;
    public uint VertexCount => _raw.VertexCount;

    /// <summary>As <see cref="Mesh"/>'s: a closed scene throws rather than hands out a span
    /// over freed memory.</summary>
    private unsafe ReadOnlySpan<T> View<T>(IntPtr at, uint length)
    {
        _ = Scene.Handle;
        return at == IntPtr.Zero ? ReadOnlySpan<T>.Empty : new ReadOnlySpan<T>((void*)at, (int)length);
    }

    /// <summary>`(VertexCount * 3)` floats, the runs end to end.</summary>
    public ReadOnlySpan<float> Positions => View<float>(_raw.Positions, _raw.VertexCount * 3);

    /// <summary>`(PolylineCount)` vertex counts saying where each run stops.</summary>
    public ReadOnlySpan<uint> Counts => View<uint>(_raw.Counts, _raw.PolylineCount);

    /// <summary>Indices into <see cref="Positions"/> making line-segment endpoint pairs: a
    /// polyline of n points is n - 1 segments, so each interior point is named twice.</summary>
    public int[] SegmentIndices()
    {
        var counts = Counts;
        if (counts.IsEmpty) return Array.Empty<int>();
        var pairs = new List<int>();
        var at = 0;
        foreach (var countU in counts)
        {
            var count = (int)countU;
            for (var i = 0; i + 1 < count; i++)
            {
                pairs.Add(at + i);
                pairs.Add(at + i + 1);
            }
            at += count;
        }
        return pairs.ToArray();
    }

    /// <summary>The endpoint pairs themselves, `(2 * segment_count, 3)` in the node's own
    /// frame.</summary>
    public float[] Segments()
    {
        var indices = SegmentIndices();
        var positions = Positions;
        var result = new float[indices.Length * 3];
        for (var i = 0; i < indices.Length; i++)
        {
            var p = indices[i] * 3;
            result[i * 3] = positions[p];
            result[i * 3 + 1] = positions[p + 1];
            result[i * 3 + 2] = positions[p + 2];
        }
        return result;
    }
}

/// <summary>A node's edges, curves or isocurves as cubic Bézier curves -- exact where the
/// file's curves were, where <see cref="Polylines"/> are their chords. A view over the
/// scene's memory, valid until the scene closes.</summary>
public sealed class Beziers
{
    private readonly RawBeziers _raw;

    public Scene Scene { get; }

    internal Beziers(Scene scene, RawBeziers raw)
    {
        Scene = scene;
        _raw = raw;
    }

    public uint Count => _raw.Count;

    private unsafe ReadOnlySpan<float> View(IntPtr at, uint length)
    {
        _ = Scene.Handle;
        return at == IntPtr.Zero ? ReadOnlySpan<float>.Empty : new ReadOnlySpan<float>((void*)at, (int)length);
    }

    /// <summary>`Count * 12` floats: four control points a curve, three floats each.</summary>
    public ReadOnlySpan<float> Points => View(_raw.Points, _raw.Count * 12);

    /// <summary>`Count * 4` floats: a weight per control point, all ones for a polynomial
    /// curve, and the weights that make a circular arc exact for a rational one.</summary>
    public ReadOnlySpan<float> Weights => View(_raw.Weights, _raw.Count * 4);

    public BeziersData Copy() => new(Points.ToArray(), Weights.ToArray());
}

/// <summary>A <see cref="Beziers"/> in memory of your own.</summary>
public sealed record BeziersData(float[] Points, float[] Weights);

/// <summary>[`CadaclysmBeziers64`]: the same segments as a <see cref="Beziers"/>, unnarrowed
/// -- four control points (xyz) and four weights a segment, in the same order; <see
/// cref="Beziers"/>'s `float` ones are these narrowed.</summary>
public sealed class Beziers64
{
    private readonly RawBeziers64 _raw;

    public Scene Scene { get; }

    internal Beziers64(Scene scene, RawBeziers64 raw)
    {
        Scene = scene;
        _raw = raw;
    }

    public uint Count => _raw.Count;

    private unsafe ReadOnlySpan<double> View(IntPtr at, uint length)
    {
        _ = Scene.Handle;
        return at == IntPtr.Zero ? ReadOnlySpan<double>.Empty : new ReadOnlySpan<double>((void*)at, (int)length);
    }

    /// <summary>`Count * 12` doubles: four control points a curve, three doubles each.</summary>
    public ReadOnlySpan<double> Points => View(_raw.Points, _raw.Count * 12);

    /// <summary>`Count * 4` doubles: a weight per control point, as <see cref="Beziers.Weights"/>.
    /// </summary>
    public ReadOnlySpan<double> Weights => View(_raw.Weights, _raw.Count * 4);

    public BeziersData64 Copy() => new(Points.ToArray(), Weights.ToArray());
}

/// <summary>A <see cref="Beziers64"/> in memory of your own.</summary>
public sealed record BeziersData64(double[] Points, double[] Weights);

/// <summary>What a node turned out to be for a physics engine: a box, sphere, capsule or
/// cylinder where one fits within <see cref="Error"/>, else a convex hull. <see cref="Frame"/>
/// (column-major) and <see cref="HalfExtent"/> are always the true oriented box. Plain data,
/// copied out of the scene.</summary>
public sealed class Collision
{
    private static readonly string[] Names = { "none", "box", "sphere", "capsule", "cylinder", "hull" };

    public uint Shape { get; }
    public uint Confidence { get; }
    public uint Axis { get; }
    public double[] Frame { get; }
    public double[] HalfExtent { get; }
    public double Radius { get; }
    public double Height { get; }
    public double Error { get; }
    public uint HullVertexCount { get; }
    public uint HullIndexCount { get; }

    internal unsafe Collision(in RawCollision raw)
    {
        Shape = raw.Shape;
        Confidence = raw.Confidence;
        Axis = raw.Axis;
        Frame = new double[16];
        HalfExtent = new double[3];
        fixed (RawCollision* p = &raw)
        {
            for (var i = 0; i < 16; i++) Frame[i] = p->Frame[i];
            for (var i = 0; i < 3; i++) HalfExtent[i] = p->HalfExtent[i];
        }
        Radius = raw.Radius;
        Height = raw.Height;
        Error = raw.Error;
        HullVertexCount = raw.HullVertexCount;
        HullIndexCount = raw.HullIndexCount;
    }

    /// <summary>`none`, `box`, `sphere`, `capsule`, `cylinder` or `hull`.</summary>
    public string ShapeName => Shape < Names.Length ? Names[Shape] : Shape.ToString();
}

/// <summary>A node's convex hull for a physics engine, as triangles -- a view over the
/// scene's memory, valid until the scene closes.</summary>
public sealed class CollisionHull
{
    private readonly RawCollisionHull _raw;

    public Scene Scene { get; }

    internal CollisionHull(Scene scene, RawCollisionHull raw)
    {
        Scene = scene;
        _raw = raw;
    }

    public uint VertexCount => _raw.VertexCount;
    public uint IndexCount => _raw.IndexCount;

    private unsafe ReadOnlySpan<T> View<T>(IntPtr at, uint length)
    {
        _ = Scene.Handle;
        return at == IntPtr.Zero ? ReadOnlySpan<T>.Empty : new ReadOnlySpan<T>((void*)at, (int)length);
    }

    /// <summary>`VertexCount * 3` floats.</summary>
    public ReadOnlySpan<float> Positions => View<float>(_raw.Positions, _raw.VertexCount * 3);

    /// <summary>`IndexCount` indices, three a triangle.</summary>
    public ReadOnlySpan<uint> Indices => View<uint>(_raw.Indices, _raw.IndexCount);
}

/// <summary>One trimmed face: the surface itself, plus the loops that cut it.</summary>
/// <remarks><see cref="Kind"/> is 0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus, 5
/// revolution, 6 extrusion, 7 NURBS, 8 sum. <see cref="Origin"/>, <see cref="Ax"/>, <see
/// cref="Ay"/>, <see cref="Az"/> are the frame; <see cref="Scalars"/> is kind-dependent; <see
/// cref="Domain"/> is `(u_min, v_min, u_max, v_max)`. <see cref="Loops"/> is one array of
/// `(u, v)` pairs per loop, each closing implicitly. Unlike <see cref="Mesh"/> and <see
/// cref="Polylines"/>, every array here is copied out at construction rather than kept as a
/// borrowed view: a face's trim loops and profile samples are a handful of points next to a
/// mesh's millions of vertices, so the copy this struct pays once is not the cost the module
/// header's "everything borrows" rule exists to avoid.</remarks>
public readonly struct Face
{
    public uint Kind { get; }
    /// <summary>Non-zero where the surface normal points into the solid, so a caller flips
    /// it. The CPU mesher already applied this to the triangles it built.</summary>
    public bool Reversed { get; }
    /// <summary>A revolution whose `u` is the profile and `v` the spin, rather than the other
    /// way.</summary>
    public bool Transposed { get; }
    public float[] Origin { get; }
    public float[] Ax { get; }
    public float[] Ay { get; }
    public float[] Az { get; }
    public float[] Domain { get; }
    public float[] Scalars { get; }
    public float[][] Loops { get; }
    /// <summary>A swept surface's profile samples: `(x, y, z, parameter)` a sample, four
    /// floats. Empty for a quadric, which needs none.</summary>
    public float[] Profile { get; }
    /// <summary>A sum surface's second curve. Empty for every other kind.</summary>
    public float[] Profile2 { get; }
    /// <summary>A NURBS surface's packed net and knots. Empty for every other kind.</summary>
    public float[] Nurbs { get; }

    internal Face(uint kind, bool reversed, bool transposed, float[] origin, float[] ax, float[] ay,
        float[] az, float[] domain, float[] scalars, float[][] loops, float[] profile,
        float[] profile2, float[] nurbs)
    {
        Kind = kind;
        Reversed = reversed;
        Transposed = transposed;
        Origin = origin;
        Ax = ax;
        Ay = ay;
        Az = az;
        Domain = domain;
        Scalars = scalars;
        Loops = loops;
        Profile = profile;
        Profile2 = profile2;
        Nurbs = nurbs;
    }
}

/// <summary>A part's faces as surfaces and trims, and the arrays they share.</summary>
/// <remarks>Iterate it for <see cref="Face"/> objects. Everything here is **in the file's own
/// frame**, unlike every other product this binding hands back -- see <see
/// cref="Scene.SurfaceMatrix"/>.</remarks>
public sealed class Surfaces : IReadOnlyList<Face>
{
    private readonly Face[] _faces;

    internal Surfaces(Face[] faces) => _faces = faces;

    public int Count => _faces.Length;
    public Face this[int index] => _faces[index];
    public IEnumerator<Face> GetEnumerator() => ((IEnumerable<Face>)_faces).GetEnumerator();
    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
}

/// <summary>What <see cref="Cadaclysm.MeshFormats"/> offers: every format <see
/// cref="Node.SaveMesh"/> writes, plus a label ready to put in a menu.</summary>
public sealed record MeshFormat(string Name, string Extension, string Label);

/// <summary>One format this build reads: its name and the extensions its files take.
/// What <see cref="Cadaclysm.Formats"/> offers, for an open dialog's filter.</summary>
public sealed record Format(string Name, IReadOnlyList<string> Extensions);

/// <summary>One drawing of one node's geometry, at one place.</summary>
/// <remarks><b>A node is not a drawing, and the difference is a bug this library shipped.</b>
/// Most nodes are structure and draw nothing; a node that places a block draws everything
/// inside that block; and a block's members draw once per placement of it rather than once on
/// their own account. So iterate <see cref="Scene.Placements"/> to draw, and nodes to build a
/// tree.</remarks>
public sealed class Placement
{
    public Scene Scene { get; }
    public uint Index { get; }

    internal Placement(Scene scene, uint index)
    {
        Scene = scene;
        Index = index;
    }

    /// <summary>The node whose mesh, edges and curves this draws.</summary>
    public Node Geometry => new(Scene, Native.cadaclysm_placement_geometry(Scene.Handle, Index));

    /// <summary>What a click on this drawing should select -- the placement rather than the
    /// shape it draws, which is shared with every sibling copy.</summary>
    public Node Select => new(Scene, Native.cadaclysm_placement_select(Scene.Handle, Index));

    /// <summary>Where to draw it, as a row-major 4x4 double matrix, already composed through
    /// every frame between the document's root and this drawing.</summary>
    public double[,] Transform => Matrices.ToRowMajor(RawTransform);

    /// <summary>The same matrix in the ABI's own column-major order, as 16 doubles.</summary>
    public double[] RawTransform
    {
        get
        {
            var m = new double[16];
            Native.cadaclysm_placement_transform(Scene.Handle, Index, m);
            return m;
        }
    }
}

/// <summary>A rigid body of the file's mechanism: the nodes that move together when a joint
/// moves it. From <see cref="Scene.Links"/>; borrows from the scene like <see cref="Node"/>.
/// </summary>
public sealed class Link : IEquatable<Link>
{
    public Scene Scene { get; }
    public uint Index { get; }

    internal Link(Scene scene, uint index)
    {
        Scene = scene;
        Index = index;
    }

    /// <summary>The link's name as the file gives it.</summary>
    public string Name => Marshal.PtrToStringUTF8(Native.cadaclysm_link_name(Scene.Handle, Index)) ?? "";

    /// <summary>The topmost node of each subtree this link moves, in node order: moving these
    /// moves everything under them.</summary>
    public IReadOnlyList<Node> Nodes
    {
        get
        {
            var count = Native.cadaclysm_link_node_count(Scene.Handle, Index);
            var found = new List<Node>((int)count);
            for (uint i = 0; i < count; i++)
                found.Add(new Node(Scene, Native.cadaclysm_link_node(Scene.Handle, Index, i)));
            return found;
        }
    }

    public bool Equals(Link? other) => other is not null && other.Index == Index && ReferenceEquals(other.Scene, Scene);
    public override bool Equals(object? obj) => Equals(obj as Link);
    public override int GetHashCode() => HashCode.Combine(System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(Scene), Index);
    public override string ToString() => $"<Link {Index} {Name}>";
}

/// <summary>A connection between two links of the file's mechanism. Topology only: how it
/// moves is not read yet. From <see cref="Scene.Joints"/>.</summary>
public sealed class Joint : IEquatable<Joint>
{
    public Scene Scene { get; }
    public uint Index { get; }

    internal Joint(Scene scene, uint index)
    {
        Scene = scene;
        Index = index;
    }

    /// <summary>The joint's name as the file gives it.</summary>
    public string Name => Marshal.PtrToStringUTF8(Native.cadaclysm_joint_name(Scene.Handle, Index)) ?? "";

    /// <summary>The link this joint starts at, in the file's order -- not a parent: a
    /// mechanism may be a network with loops.</summary>
    public Link Start => new(Scene, Native.cadaclysm_joint_start(Scene.Handle, Index));

    /// <summary>The link this joint ends at.</summary>
    public Link End => new(Scene, Native.cadaclysm_joint_end(Scene.Handle, Index));

    public bool Equals(Joint? other) => other is not null && other.Index == Index && ReferenceEquals(other.Scene, Scene);
    public override bool Equals(object? obj) => Equals(obj as Joint);
    public override int GetHashCode() => HashCode.Combine(System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(Scene), Index);
    public override string ToString() => $"<Joint {Index} {Name}>";
}

/// <summary>A body's exact B-rep -- the trimmed surfaces its mesh is cut from -- shared with
/// the scene rather than copied: a reference of this object's own, given back by
/// <see cref="Dispose"/>. Nothing here reads it; it is for the blacksmith library, which
/// operates on it without a copy (`Solid.FromNode`). It outlives its scene for as long as
/// anything holds it. In the node's own frame and the file's own units and axes, whatever
/// convention the scene was opened with. The blacksmith library must come from the same
/// release; it checks <see cref="LayoutId"/> and refuses otherwise.</summary>
public sealed class Brep : IDisposable
{
    internal BrepHandle Handle { get; }

    internal Brep(BrepHandle handle)
    {
        Handle = handle;
    }

    /// <summary>How this library lays a brep out in memory: its compiler, target and source.
    /// The blacksmith library shares a brep only with a library whose id equals its own.</summary>
    public static string LayoutId => Marshal.PtrToStringUTF8(Native.cadaclysm_brep_layout_id()) ?? "";

    public bool Closed => Handle.IsClosed;

    /// <summary>Whether its faces make a manifold -- every edge bordered by one face or two,
    /// the faces round every vertex one fan -- and whether it is closed. Read off the topology
    /// the file wrote, not a mesh: faces that name no shared edge (IGES, each surface its own
    /// sheet; an IFC face written as one polygon) read as open however well they meet in
    /// space.</summary>
    public Manifold Manifold
    {
        get
        {
            if (Handle.IsClosed) throw new CadaclysmException("brep: released");
            var row = new uint[8];
            if (!Native.cadaclysm_brep_manifold(Handle, row))
                throw new CadaclysmException(Cadaclysm.LastErrorOr("manifold"));
            return new Manifold(row);
        }
    }

    public void Dispose() => Handle.Dispose();
}

/// <summary>Whether a brep's or a solid's faces make a manifold, as plain data
/// (<see cref="Brep.Manifold"/>, and the kernel's <c>Solid.Manifold</c>): its faces, edges
/// and vertices; the edges one face borders (a sheet's rim), the edges three or more do, and
/// the vertices whose faces make more than one fan (two solids touching at a corner).
/// </summary>
public readonly struct Manifold
{
    public int Faces { get; }
    public int Edges { get; }
    public int Vertices { get; }
    public int BoundaryEdges { get; }
    public int NonManifoldEdges { get; }
    public int NonManifoldVertices { get; }

    /// <summary>No non-manifold edge or vertex: a manifold, possibly with a boundary.</summary>
    public bool IsManifold { get; }

    /// <summary>A manifold with no boundary edge either: it encloses a solid.</summary>
    public bool IsClosed { get; }

    /// <summary>From the eight counts `cadaclysm_brep_manifold` and
    /// `cadaclysm_blacksmith_manifold` write, in their order.</summary>
    internal Manifold(uint[] row)
    {
        Faces = (int)row[0];
        Edges = (int)row[1];
        Vertices = (int)row[2];
        BoundaryEdges = (int)row[3];
        NonManifoldEdges = (int)row[4];
        NonManifoldVertices = (int)row[5];
        IsManifold = row[6] == 1;
        IsClosed = row[7] == 1;
    }

    public override string ToString() =>
        $"Manifold(faces={Faces}, edges={Edges}, vertices={Vertices}, boundary_edges={BoundaryEdges}, " +
        $"non_manifold_edges={NonManifoldEdges}, non_manifold_vertices={NonManifoldVertices}, " +
        $"is_manifold={IsManifold}, is_closed={IsClosed})";
}

/// <summary>One meshlet, copied out: the arrays are yours.</summary>
public sealed record Meshlet(uint Index, uint Level, uint Group, float Error, uint VertexCount, uint TriangleCount,
                             float[] Positions, float[] Normals, uint[] Indices, uint[] Children);

/// <summary>A mesh split into meshlets, optionally with coarser levels above them, for a
/// mesh-shader or meshlet-based renderer. Built from any mesh and owned by you: dispose it.</summary>
public sealed class Meshlets : IDisposable
{
    internal MeshletsHandle Handle { get; }

    private Meshlets(MeshletsHandle handle)
    {
        Handle = handle;
    }

    /// <summary>Split <paramref name="positions"/> (three floats a vertex), <paramref name="normals"/>
    /// (the same, or empty for none) and <paramref name="indices"/> (three a triangle) into
    /// meshlets of at most <paramref name="maxTriangles"/> and <paramref name="maxVertices"/> each --
    /// the consumer's own limits, with no default: Nanite takes 128/256, a mesh-shader pipeline
    /// 124/64. <paramref name="levels"/> above 0 groups and simplifies each level into the next
    /// until one meshlet is left.</summary>
    public static Meshlets Build(ReadOnlySpan<float> positions, ReadOnlySpan<float> normals, ReadOnlySpan<uint> indices,
                                 uint maxTriangles, uint maxVertices, int levels = 0)
    {
        if (maxTriangles == 0 || maxVertices == 0) throw new CadaclysmException("meshlets: maxTriangles and maxVertices are required");
        if (positions.Length % 3 != 0 || indices.Length % 3 != 0)
            throw new CadaclysmException("meshlets: positions must hold three floats a vertex and indices three a triangle");
        if (!normals.IsEmpty && normals.Length != positions.Length)
            throw new CadaclysmException("meshlets: normals must hold one per vertex, three floats each");
        var handle = Native.cadaclysm_meshlets_build(positions.ToArray(), normals.IsEmpty ? null : normals.ToArray(),
            (nuint)(positions.Length / 3), indices.ToArray(), (nuint)indices.Length, maxTriangles, maxVertices, levels);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw new CadaclysmException(Cadaclysm.LastErrorOr("meshlets: build failed"));
        }
        return new Meshlets(handle);
    }

    private MeshletsHandle Live => Handle.IsClosed ? throw new CadaclysmException("meshlets: freed") : Handle;

    public bool Freed => Handle.IsClosed;

    /// <summary>How many meshlets, every level counted.</summary>
    public uint Count => Native.cadaclysm_meshlets_count(Live);

    public uint TriangleCount(uint i) => Native.cadaclysm_meshlet_triangle_count(Live, i);
    public uint VertexCount(uint i) => Native.cadaclysm_meshlet_vertex_count(Live, i);
    /// <summary>0 for a leaf over the mesh itself, higher for a simplified level above it.</summary>
    public uint Level(uint i) => Native.cadaclysm_meshlet_level(Live, i);
    public uint Group(uint i) => Native.cadaclysm_meshlet_group(Live, i);
    /// <summary>How far this meshlet's level moved the surface; zero at level 0.</summary>
    public float Error(uint i) => Native.cadaclysm_meshlet_error(Live, i);
    public uint ChildCount(uint i) => Native.cadaclysm_meshlet_child_count(Live, i);

    /// <summary>One meshlet's arrays and numbers, copied out.</summary>
    public Meshlet Meshlet(uint i)
    {
        var handle = Live;
        var vertexCount = Native.cadaclysm_meshlet_vertex_count(handle, i);
        var triangleCount = Native.cadaclysm_meshlet_triangle_count(handle, i);
        var childCount = Native.cadaclysm_meshlet_child_count(handle, i);
        var positions = new float[vertexCount * 3];
        var normals = new float[vertexCount * 3];
        var indices = new uint[triangleCount * 3];
        var children = new uint[childCount];
        Native.cadaclysm_meshlet_positions(handle, i, positions);
        Native.cadaclysm_meshlet_normals(handle, i, normals);
        Native.cadaclysm_meshlet_indices(handle, i, indices);
        Native.cadaclysm_meshlet_children(handle, i, children);
        return new Meshlet(i, Native.cadaclysm_meshlet_level(handle, i), Native.cadaclysm_meshlet_group(handle, i),
            Native.cadaclysm_meshlet_error(handle, i), vertexCount, triangleCount, positions, normals, indices, children);
    }

    /// <summary>Give the meshlets back. Idempotent.</summary>
    public void Free() => Handle.Dispose();

    public void Dispose() => Free();
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

    /// <summary>The <strong>body's own</strong> B-rep edge id -- `LoopTrim.edge` on the brep <see
    /// cref="Node.Brep"/> hands over, the number the file gave the edge.</summary>
    /// <remarks><strong>Not this mesh's edge index, and on a read body rarely equal to it.</strong>
    /// <see cref="FemMesh.Edges"/> is a densely renumbered <em>subset</em> of the body's edges --
    /// ascending by id, with every edge collapsed to a point left out -- so edge 0 of a STEP
    /// body's mesh routinely reports an id in the hundreds. Everything else that names an edge
    /// means the <em>index</em>: a <see cref="FemMesh.NodeKind"/> of 1 read through <see
    /// cref="FemMesh.NodeEntity"/>, the third number of an <see cref="FemMesh.OpenEdges"/> or
    /// <see cref="FemMesh.FoldedEdges"/> row, and the `edge_&lt;i&gt;` physical group of <see
    /// cref="FemMesh.MshText"/>. This is the one way back from any of them to the topology the
    /// file wrote.</remarks>
    public uint Id { get; }

    /// <summary>This mesh's node indices in order along the edge, its end vertices included; a
    /// closed edge repeats no node.</summary>
    public uint[] Nodes { get; }

    /// <summary>Where each connected run of <see cref="Nodes"/> begins; `[0]` for one chain along
    /// the whole edge.</summary>
    /// <remarks><strong>Read `Nodes[Runs[i]..Runs[i + 1]]` (the last run to the end) as one
    /// polyline and join nothing across a boundary.</strong> The two ends either side of one are
    /// two points of the edge with no mesh edge between them -- a crack along the edge, or a
    /// stretch of it the mesher sampled on one face only. One run is the ordinary answer, and a
    /// caller reading <see cref="Nodes"/> as one polyline without looking here silently jumps the
    /// gap.</remarks>
    public uint[] Runs { get; }

    /// <summary>The two faces it bounds, `B` being `uint.MaxValue` on an open body's rim.
    /// </summary>
    /// <remarks><strong>`0` is a real face, not a sentinel</strong>: an edge whose second face is
    /// face 0 reads `Faces.B == 0`. A non-manifold edge's third and further faces are not here;
    /// <see cref="Brep.Manifold"/> is where the whole list of them is read.</remarks>
    public (uint A, uint B) Faces { get; }

    /// <summary>The two B-rep vertices its chain ends at, as <see cref="FemMesh.Vertices"/>
    /// indexes them, `B` being `uint.MaxValue` where both ends are one vertex -- a closed edge, a
    /// circle's rim, a full-turn seam.</summary>
    /// <remarks><strong>`0` is a real vertex, not a sentinel.</strong> Which end is `A` is the
    /// first trim's direction and means nothing else: the pair bounds the edge, it does not
    /// orient it.</remarks>
    public (uint A, uint B) Ends { get; }

    /// <summary>The nodes make one loop. False wherever <see cref="Runs"/> is longer than one.
    /// </summary>
    public bool Closed { get; }

    /// <summary>Bounded twice by one face: a closed surface's seam rather than a real boundary.
    /// <see cref="Faces"/>'s two are then the same face.</summary>
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

    /// <summary>The mesh node at this vertex, or `uint.MaxValue` where the mesh has none there.
    /// </summary>
    /// <remarks><strong>A sentinel here is ordinary, not a fault.</strong> The analysis rebuilds
    /// a vertex wherever two trims meet, and a pole's polyline runs give a sphere 48 of them
    /// where the mesh has 2 points; a caller walking these skips the sentinel rather than
    /// treating it as a gap.</remarks>
    public uint Node { get; }

    /// <summary>Where the vertex is -- three doubles, in the same space and under the same
    /// placement as <see cref="FemMesh.Nodes"/>.</summary>
    /// <remarks><strong>Meaningless unless <see cref="HasPosition"/></strong>: it is all zeros
    /// then, a point no geometry has and one a solver would take for a node at the origin. The
    /// file's own vertex rather than a mesh node, so the two can differ by the reader's rounding.
    /// </remarks>
    public double[] Point { get; }

    /// <summary><see cref="Point"/> was placed. False where every trim meeting at this vertex is
    /// a curve with no geometry to read an end off -- then there is <strong>no position at
    /// all</strong>.</summary>
    public bool HasPosition { get; }

    public override string ToString() =>
        $"FemVertex(node={Node}, point=({Point[0]},{Point[1]},{Point[2]}), hasPosition={HasPosition})";
}

/// <summary>One body meshed for a solver: nodes welded by bits, triangles wound outward, every
/// node tagged with the lowest-dimension B-rep entity it lies on, and every crack reported rather
/// than closed. What <see cref="Node.FemMesh"/> returns, and <strong>owned by you</strong>:
/// dispose it (a `using`), or <see cref="Free"/> it.</summary>
/// <remarks>A handle rather than a snapshot, and its big arrays are `ReadOnlySpan&lt;T&gt;` views
/// into the library's own memory, exactly as <see cref="Mesh"/>'s are and for the same reason: a
/// solver mesh is megabytes, and copying it to hand it over would cost that twice.
///
/// <para><strong>The owner of these views is this object, not the scene.</strong> That is the one
/// thing this class does differently from every other view in this binding: <see
/// cref="Scene.Close"/> does not free a FEM mesh and does not stale one, and meshing the body
/// again does not either -- only <see cref="Free"/> (or the `using` that runs it) does. There is
/// no generation check here as the kernel's mesh views have: a FEM view's pointers are built with
/// the handle and never move.</para>
///
/// <para><strong>What the guard does and does not do.</strong> Every accessor below asks the
/// handle first, so a span <em>asked for</em> after <see cref="Free"/> throws. A span already in
/// hand is not protected and cannot be: a `ReadOnlySpan&lt;T&gt;` is a bare pointer and a length,
/// with nothing left to check by the time it is indexed -- it goes on reading the freed block and
/// hands back numbers that look like the mesh. So call `ToArray()` on any span that must outlive
/// the handle, and read the rest inside the `using`.</para></remarks>
public sealed class FemMesh : IDisposable
{
    internal FemMeshHandle Handle { get; }

    /// <summary>The view, read once in the constructor. Every pointer in it is built with the
    /// handle and good until it is freed -- nothing in this ABI is built lazily -- so asking again
    /// per property would be one C call per array for the same answer.</summary>
    private readonly RawFemMeshView _raw;

    internal FemMesh(FemMeshHandle handle)
    {
        Handle = handle;
        var raw = new RawFemMeshView();
        if (!Native.cadaclysm_fem_mesh_view(handle, ref raw))
        {
            var why = Cadaclysm.LastErrorOr("fem mesh view");
            handle.Dispose();
            throw new CadaclysmException(why);
        }
        _raw = raw;
    }

    /// <summary>The handle, refusing a freed one: every pointer in the cached view is the
    /// handle's, and a freed handle's point at nothing.</summary>
    private FemMeshHandle Live => Handle.IsClosed ? throw new CadaclysmException("fem mesh: freed") : Handle;

    /// <summary>The cached view, the handle checked first. Every read below goes through this, so
    /// no accessor can hand out a pointer the handle no longer owns.</summary>
    private RawFemMeshView Raw
    {
        get
        {
            _ = Live;
            return _raw;
        }
    }

    public bool Freed => Handle.IsClosed;

    /// <summary>A span over the FEM handle's own memory, the owner checked first -- <see
    /// cref="Mesh"/>'s `View` with this mesh in the scene's place. No generation check: unlike the
    /// kernel's tessellation cache, a FEM view's pointers never move.</summary>
    private unsafe ReadOnlySpan<T> View<T>(IntPtr at, uint length)
    {
        _ = Live;
        return at == IntPtr.Zero ? ReadOnlySpan<T>.Empty : new ReadOnlySpan<T>((void*)at, (int)length);
    }

    /// <summary>Every node's position, three doubles each -- placed, and in the space <see
    /// cref="Node.FemMesh"/> and <see cref="FromMesh"/> describe. Every node is used by at least
    /// one triangle.</summary>
    public ReadOnlySpan<double> Nodes => View<double>(_raw.Nodes, _raw.NodeCount * 3);

    /// <summary>Three node indices a triangle, wound outward -- a mirroring placement is wound
    /// back.</summary>
    public ReadOnlySpan<uint> Triangles => View<uint>(_raw.Triangles, _raw.TriangleCount * 3);

    /// <summary>The B-rep face each triangle lies on, one per triangle, into <see
    /// cref="FaceCount"/> faces.</summary>
    public ReadOnlySpan<uint> TriangleFace => View<uint>(_raw.TriangleFace, _raw.TriangleCount);

    /// <summary>What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per
    /// node: the lowest-dimension entity it lies on, which is the `.msh` format's own
    /// classification rule. <see cref="NodeEntity"/> says which entity of that kind.</summary>
    public ReadOnlySpan<uint> NodeKind => View<uint>(_raw.NodeKind, _raw.NodeCount);

    /// <summary>Which vertex, edge or face each node lies on, read by the matching <see
    /// cref="NodeKind"/>: an index into <see cref="Vertices"/>, into <see cref="Edges"/>, or into
    /// the body's faces. One per node.</summary>
    public ReadOnlySpan<uint> NodeEntity => View<uint>(_raw.NodeEntity, _raw.NodeCount);

    /// <summary>The body's faces; <see cref="TriangleFace"/> and a <see cref="NodeKind"/> of `2`
    /// index them. The same faces <see cref="Node.Surfaces"/> hands over, in the same order.
    /// </summary>
    public uint FaceCount => Raw.FaceCount;

    /// <summary>One <see cref="FemEdge"/> per B-rep edge, in the order a <see cref="NodeKind"/> of
    /// `1` indexes them. Empty for a <see cref="FromMesh"/> body, which has no B-rep edges at all.
    /// </summary>
    /// <remarks><strong>This list's own numbering, not the body's</strong>: each <see
    /// cref="FemEdge.Id"/> carries the body's own edge id.</remarks>
    public IReadOnlyList<FemEdge> Edges
    {
        get
        {
            var handle = Live;
            var edges = new List<FemEdge>((int)_raw.EdgeCount);
            for (var i = 0u; i < _raw.EdgeCount; i++)
            {
                var raw = new RawFemEdge();
                if (!Native.cadaclysm_fem_mesh_edge(handle, i, ref raw))
                    throw new CadaclysmException(Cadaclysm.LastErrorOr($"fem mesh edge {i}"));
                edges.Add(new FemEdge(raw.Id, Uints(raw.Nodes, raw.NodeCount), Uints(raw.Runs, raw.RunCount),
                    (raw.FaceA, raw.FaceB), (raw.EndA, raw.EndB), raw.Closed, raw.Seam));
            }
            return edges;
        }
    }

    /// <summary>One <see cref="FemVertex"/> per B-rep vertex, in the order a <see
    /// cref="NodeKind"/> of `0` indexes them. Empty for a <see cref="FromMesh"/> body.</summary>
    public IReadOnlyList<FemVertex> Vertices
    {
        get
        {
            var handle = Live;
            var vertices = new List<FemVertex>((int)_raw.VertexCount);
            for (var i = 0u; i < _raw.VertexCount; i++)
            {
                var raw = new RawFemVertex();
                if (!Native.cadaclysm_fem_mesh_vertex(handle, i, ref raw))
                    throw new CadaclysmException(Cadaclysm.LastErrorOr($"fem mesh vertex {i}"));
                vertices.Add(new FemVertex(raw.Node, PointOf(raw), raw.HasPosition));
            }
            return vertices;
        }
    }

    /// <summary>Every crack, as `(A, B, BrepEdge)`: a directed mesh edge `(A, B)` with no `(B, A)`,
    /// and the B-rep edge both nodes lie on or `uint.MaxValue` where they share none.</summary>
    /// <remarks><strong>Empty unless the body's topology is closed -- for a B-rep body</strong>,
    /// whose mesh is otherwise not asked about at all: such a body reports <see
    /// cref="Watertight"/> false with this and <see cref="FoldedEdges"/> <em>both</em> empty, and
    /// that trio together says "not asked", not "nothing found".
    ///
    /// <para><strong>A <see cref="FromMesh"/> body is the other case, and the opposite one.</strong>
    /// A bare mesh carries no topology to say whether it ought to close, so its census always runs
    /// over the welded triangles: an open render mesh reports its cracks here with <see
    /// cref="Watertight"/> false, a closed one reports it true, and an empty census there really
    /// does mean "nothing found".</para></remarks>
    public IReadOnlyList<(uint A, uint B, uint BrepEdge)> OpenEdges =>
        Census(Native.cadaclysm_fem_mesh_open_edge, Raw.OpenEdgeCount, "open edge");

    /// <summary>Every fold, as <see cref="OpenEdges"/> reports a crack: a directed mesh edge used
    /// by more than one triangle.</summary>
    /// <remarks><strong>A body can be folded without being open</strong> -- a solid no thicker
    /// than a line leaves no hole for an open edge to find -- and the closure census's own known-bad
    /// bodies are folds rather than open cracks. A caller that checks <see cref="OpenEdges"/> alone
    /// calls such a body sound. Empty under the same rule as <see cref="OpenEdges"/>.</remarks>
    public IReadOnlyList<(uint A, uint B, uint BrepEdge)> FoldedEdges =>
        Census(Native.cadaclysm_fem_mesh_folded_edge, Raw.FoldedEdgeCount, "folded edge");

    /// <summary>The library's census readers have one shape, so the two lists cannot drift.
    /// </summary>
    private delegate bool CensusRow(FemMeshHandle mesh, uint index, out uint a, out uint b, out uint brepEdge);

    private IReadOnlyList<(uint A, uint B, uint BrepEdge)> Census(CensusRow row, uint count, string what)
    {
        var handle = Live;
        var rows = new List<(uint, uint, uint)>((int)count);
        for (var i = 0u; i < count; i++)
        {
            if (!row(handle, i, out var a, out var b, out var brepEdge))
                throw new CadaclysmException(Cadaclysm.LastErrorOr($"fem mesh {what} {i}"));
            rows.Add((a, b, brepEdge));
        }
        return rows;
    }

    /// <summary>The welded mesh closes -- and, for a B-rep body, so does the topology behind it.
    /// <strong>False for every B-rep body whose topology is not closed</strong>, whose mesh is then
    /// not asked about at all; read <see cref="OpenEdges"/> for what an empty census beside a false
    /// here does and does not mean.</summary>
    /// <remarks>A <see cref="FromMesh"/> body has no topology to ask of, so this says only that its
    /// triangles close: a closed render mesh reports true with nothing exact behind it at all.
    /// </remarks>
    public bool Watertight => Raw.Watertight;

    /// <summary>This came from the scene's own mesh rather than from a brep: one face, every node
    /// on face `0`, no edges and no vertices.</summary>
    /// <remarks><strong>It is also which space the mesh is in.</strong> A B-rep body's FEM mesh is
    /// in the <em>file's own units and axes</em>, whatever <see cref="Convention"/> the scene was
    /// opened with, because it is taken off the brep. A node with no brep falls back to the scene's
    /// mesh, which <em>is</em> converted, so it comes back in the scene's convention, wound
    /// counter-clockwise about the outward normal even where the convention winds the other way.
    /// Under a non-Native convention those are two different spaces.
    ///
    /// <para>It is also which contract <see cref="Watertight"/> and the two censuses are reporting
    /// under: read <see cref="OpenEdges"/>.</para></remarks>
    public bool FromMesh => Raw.FromMesh;

    /// <summary>The smallest interior angle of any triangle, in degrees. There is always one: a
    /// body that meshed to no triangles is a refusal, not a mesh.</summary>
    public double MinAngle => Raw.MinAngle;

    /// <summary>The triangle with that angle, as an index into <see cref="Triangles"/> by triple.
    /// </summary>
    public uint WorstTriangle => Raw.WorstTriangle;

    /// <summary>The longest triangle edge, placed.</summary>
    /// <remarks><strong>The figure to check against <see cref="Node.FemMesh"/>'s `maxSize`, and the
    /// only one that says what the mesh actually is.</strong> `maxSize` bounds the boundary segments
    /// and merely <em>targets</em> the interior: measured at 1.03 x `maxSize` on a face whose
    /// parameters run unevenly, where a full-size boundary piece met a much shorter one left by
    /// halving. One small enough beside the body to reach the mesher's own piece and station
    /// ceilings is not honoured at all. A caller that asked for an element size reads this to find
    /// out whether it got one.</remarks>
    public double LongestEdge => Raw.LongestEdge;

    /// <summary>The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face,
    /// a volume where the body closes, and a physical group naming each.</summary>
    /// <remarks><strong>The library's text is borrowed from this handle</strong> and replaced by the
    /// next call on it -- this ABI's convention, and the opposite of the kernel library's, where
    /// `Cadaclysm.Blacksmith.FemMesh.MshText` is handed an owned string to free. Nothing here has to
    /// free anything either way: the `char *` is marshalled into a `string` of your own on the way
    /// out, which outlives the handle.
    ///
    /// <para><strong>No unlicensed notice is printed here.</strong> <see cref="Node.FemMesh"/> gave
    /// it once when the mesh was built, and this ABI deliberately does not repeat it on either
    /// `.msh` call -- where the kernel library notices on both of its writers and <em>not</em> on
    /// its builder. Each matches its own siblings, so moving the call to look like the other side
    /// breaks a convention.</para>
    ///
    /// <para>Throws <see cref="CadaclysmException"/> for a mesh the writer refuses, naming the
    /// field it cannot honour, and for a freed handle.</para></remarks>
    public string MshText()
    {
        var raw = Native.cadaclysm_fem_mesh_msh_text(Live);
        if (raw == IntPtr.Zero) throw new CadaclysmException(Cadaclysm.LastErrorOr("msh text"));
        return Marshal.PtrToStringUTF8(raw) ?? "";
    }

    /// <summary><see cref="MshText"/> written to <paramref name="path"/> by the library itself: the
    /// same bytes from the same writer, straight to the file rather than through the borrowed slot,
    /// so a <see cref="MshText"/> call on this handle from another thread cannot free the text under
    /// the write. Throws for a mesh the writer refuses or a file it cannot write, naming the path.
    /// No notice here either; see <see cref="MshText"/>.</summary>
    public void SaveMsh(string path)
    {
        if (!Native.cadaclysm_fem_mesh_save_msh(Live, path))
            throw new CadaclysmException(Cadaclysm.LastErrorOr($"could not write {path}"));
    }

    /// <summary>Give the mesh back, and with it every span taken from it. Idempotent.</summary>
    public void Free() => Handle.Dispose();

    public void Dispose() => Free();

    /// <summary>A vertex's own three doubles, out of the fixed buffer the struct holds them in --
    /// the one read here that needs `unsafe`, kept off <see cref="Vertices"/>'s own signature.
    /// </summary>
    private static unsafe double[] PointOf(RawFemVertex raw) =>
        new[] { raw.Point[0], raw.Point[1], raw.Point[2] };

    /// <summary>`count` uint32s at `at`, copied out: a <see cref="FemEdge"/>'s chain cannot hold a
    /// span, so these two are copies where the mesh's own arrays are views.</summary>
    private static unsafe uint[] Uints(IntPtr at, uint count) =>
        at == IntPtr.Zero ? Array.Empty<uint>() : new ReadOnlySpan<uint>((void*)at, (int)count).ToArray();

    public override string ToString() =>
        Freed ? "FemMesh(freed)"
            : $"FemMesh(nodes={_raw.NodeCount}, triangles={_raw.TriangleCount}, " +
              $"watertight={_raw.Watertight}, fromMesh={_raw.FromMesh})";
}

/// <summary>One node of the document: an assembly, a shape, a placement.</summary>
/// <remarks>A handle rather than a snapshot -- every property below asks the scene when you
/// ask it, so nothing here goes stale and nothing is read that a caller never looks at.
/// </remarks>
public sealed class Node : IEquatable<Node>
{
    private const uint None = uint.MaxValue;

    public Scene Scene { get; }
    public uint Index { get; }

    internal Node(Scene scene, uint index)
    {
        Scene = scene;
        Index = index;
    }

    public string Name => Marshal.PtrToStringUTF8(Native.cadaclysm_node_name(Scene.Handle, Index)) ?? "";

    /// <summary>What the file calls it -- a STEP `#N`, an IFC GlobalId, a Rhino UUID.</summary>
    public string Id => Marshal.PtrToStringUTF8(Native.cadaclysm_node_id(Scene.Handle, Index)) ?? "";

    /// <summary>What the file calls it -- an IFC type, an openNURBS class, a shape kind.</summary>
    public string Kind => Marshal.PtrToStringUTF8(Native.cadaclysm_node_kind(Scene.Handle, Index)) ?? "";

    /// <summary>Whether the file says to show this when it is opened. Not inherited -- see
    /// <see cref="VisibleNow"/> for that.</summary>
    public bool Visible => Native.cadaclysm_node_visible(Scene.Handle, Index);

    /// <summary><see cref="Visible"/>, but with every ancestor consulted.</summary>
    public bool VisibleNow
    {
        get
        {
            Node? node = this;
            while (node is not null)
            {
                if (!node.Visible) return false;
                node = node.Parent;
            }
            return true;
        }
    }

    /// <summary>Whether the file says this cannot be selected or edited. Locking is not
    /// hiding: a locked thing is drawn exactly as any other and only refuses to be picked.
    /// Only a `Locked` attribute of <see cref="ValueKind.Boolean"/> kind counts; one of any
    /// other kind reads as unlocked here, where Python truth-tests whatever value it finds.
    /// </summary>
    public bool Locked
    {
        get
        {
            foreach (var attribute in Attributes)
                if (attribute.Name == "Locked")
                    return attribute.Kind == ValueKind.Boolean && attribute.Value == "True";
            return false;
        }
    }

    /// <summary>Something to put in a tree row: the name, else the kind, else `#index`.</summary>
    public string Label => Name.Length > 0 ? Name : Kind.Length > 0 ? Kind : $"#{Index}";

    /// <summary>How far down the tree it sits, a root being zero.</summary>
    public uint Depth => Native.cadaclysm_node_depth(Scene.Handle, Index);

    /// <summary>What its geometry was before it was triangles -- `brep`, `mesh`, `csg`. Empty
    /// for a node that draws nothing.</summary>
    public string Generator => Marshal.PtrToStringUTF8(Native.cadaclysm_node_generator(Scene.Handle, Index)) ?? "";

    public Node? Parent
    {
        get
        {
            var p = Native.cadaclysm_node_parent(Scene.Handle, Index);
            return p == None ? null : new Node(Scene, p);
        }
    }

    public IReadOnlyList<Node> Children
    {
        get
        {
            var count = Native.cadaclysm_node_child_count(Scene.Handle, Index);
            var found = new List<Node>((int)count);
            for (uint i = 0; i < count; i++)
                found.Add(new Node(Scene, Native.cadaclysm_node_child(Scene.Handle, Index, i)));
            return found;
        }
    }

    /// <summary>The node whose geometry this one is a placement of, or null.</summary>
    public Node? InstanceOf
    {
        get
        {
            var p = Native.cadaclysm_node_instance_of(Scene.Handle, Index);
            return p == None ? null : new Node(Scene, p);
        }
    }

    /// <summary>What a click on this node's geometry should select -- itself, usually.
    /// </summary>
    public Node SelectAs
    {
        get
        {
            var chosen = Native.cadaclysm_node_select_as(Scene.Handle, Index);
            return chosen == None ? this : new Node(Scene, chosen);
        }
    }

    /// <summary>Everything the file said about this node.</summary>
    public IReadOnlyList<Attribute> Attributes
    {
        get
        {
            var count = Native.cadaclysm_node_attribute_count(Scene.Handle, Index);
            var found = new List<Attribute>((int)count);
            for (uint i = 0; i < count; i++)
            {
                var raw = Native.cadaclysm_node_attribute(Scene.Handle, Index, i);
                if (raw.Name == IntPtr.Zero) continue;
                found.Add(BuildAttribute(raw));
            }
            return found;
        }
    }

    private static Attribute BuildAttribute(RawAttribute raw)
    {
        var name = Marshal.PtrToStringUTF8(raw.Name) ?? "";
        var kind = raw.Kind is >= 0 and <= 6 ? (ValueKind)raw.Kind : ValueKind.None;
        var value = kind switch
        {
            ValueKind.Text or ValueKind.List or ValueKind.Reference =>
                Marshal.PtrToStringUTF8(raw.Text) ?? "",
            ValueKind.Integer => raw.Integer.ToString(CultureInfo.InvariantCulture),
            ValueKind.Real => raw.Real.ToString(CultureInfo.InvariantCulture),
            ValueKind.Boolean => raw.Boolean ? "True" : "False",
            _ => "",
        };
        return new Attribute(name, kind, value);
    }

    /// <summary>Whether this node is drawn -- whether it has geometry of its own to show.
    /// Asks for nothing to be built.</summary>
    public bool CanMesh => Native.cadaclysm_node_can_mesh(Scene.Handle, Index);

    /// <summary>Write this node's mesh to `path` in `format` -- one of <see
    /// cref="Cadaclysm.MeshFormats"/>. Raises if the node draws nothing or the format is not
    /// one the library writes.</summary>
    /// <remarks>No tolerance parameter: `cadaclysm_node_save_mesh` takes none, and Python's
    /// `save_mesh(path, fmt="stl")` doesn't either -- an earlier draft of this binding added
    /// one to match the task brief's smoke code, but Python is the reference and the smoke
    /// was wrong on that point.</remarks>
    public void SaveMesh(string path, string format = "stl")
    {
        if (!Native.cadaclysm_node_save_mesh(Scene.Handle, Index, path, format))
            throw new CadaclysmException(Cadaclysm.LastErrorOr($"could not write {path}"));
    }

    /// <summary>This node's own wireframe as SVG text, in its own frame -- <see
    /// cref="Scene.SvgText"/>'s options, read from just this node rather than every placement.
    /// </summary>
    public string SvgText(SvgOptions? options = null)
    {
        var raw = Cadaclysm.BuildSvgOptions(options, Scene.DefaultUp);
        var ptr = Native.cadaclysm_node_svg_text(Scene.Handle, Index, ref raw);
        if (ptr == IntPtr.Zero) throw new CadaclysmException(Cadaclysm.LastErrorOr("svg"));
        return Marshal.PtrToStringUTF8(ptr) ?? "";
    }

    /// <summary><see cref="SvgText"/> written to `path` by the library itself.</summary>
    public void Svg(string path, SvgOptions? options = null)
    {
        var raw = Cadaclysm.BuildSvgOptions(options, Scene.DefaultUp);
        if (!Native.cadaclysm_node_svg(Scene.Handle, Index, path, ref raw))
            throw new CadaclysmException(Cadaclysm.LastErrorOr($"could not write {path}"));
    }

    /// <summary>`(r, g, b, a)` if the file gave one, else null -- most STEP files carry no
    /// colour at all, and the honest answer lets the caller use its own.</summary>
    public float[]? Colour
    {
        get
        {
            var rgba = new float[4];
            return Native.cadaclysm_node_color(Scene.Handle, Index, rgba) ? rgba : null;
        }
    }

    /// <summary>Where this node's geometry sits, as a row-major 4x4 double matrix -- `M[0..2,
    /// 0..2]` the rotation and scale block, `M[0..2, 3]` the offset.</summary>
    public double[,] Transform => Matrices.ToRowMajor(RawTransform);

    /// <summary>The same matrix in the ABI's own column-major order, as 16 doubles.</summary>
    public double[] RawTransform
    {
        get
        {
            var m = new double[16];
            Native.cadaclysm_node_transform(Scene.Handle, Index, m);
            return m;
        }
    }

    /// <summary>The extent of the geometry this node draws, in that geometry's own frame.
    /// Builds the geometry if it has not been built.</summary>
    public Bounds Bounds
    {
        get
        {
            var raw = Native.cadaclysm_node_bounds(Scene.Handle, Index);
            return new Bounds(new[] { raw.MinX, raw.MinY, raw.MinZ }, new[] { raw.MaxX, raw.MaxY, raw.MaxZ });
        }
    }

    /// <summary><see cref="Bounds"/> in `double`.</summary>
    public Bounds64 Bounds64
    {
        get
        {
            var raw = Native.cadaclysm_node_bounds64(Scene.Handle, Index);
            return new Bounds64(new[] { raw.MinX, raw.MinY, raw.MinZ }, new[] { raw.MaxX, raw.MaxY, raw.MaxZ });
        }
    }

    /// <summary>Its triangles, in their own frame, built now if they have not been -- or null
    /// for a node with no triangles (structure, or geometry drawn only as curves).</summary>
    /// <remarks>A property, not a method taking a tolerance: `cadaclysm_node_mesh` takes none,
    /// and neither does Python's `Node.mesh`. A property is also what this binding's own
    /// property-for-zero-argument transcription rule calls for.</remarks>
    public Mesh? Mesh
    {
        get => MeshOf(Native.cadaclysm_node_mesh(Scene.Handle, Index));
    }

    private Mesh? MeshOf(RawMesh raw) =>
        raw.IndexCount == 0 || raw.Positions == IntPtr.Zero ? null : new Mesh(Scene, raw);

    /// <summary>This node's own mesh in `double`, lent rather than narrowed -- see <see
    /// cref="Mesh64"/>. Null for a node with no triangles.</summary>
    public Mesh64? Mesh64
    {
        get => MeshOf64(Native.cadaclysm_node_mesh64(Scene.Handle, Index));
    }

    private Mesh64? MeshOf64(RawMesh64 raw) =>
        raw.IndexCount == 0 || raw.Positions == IntPtr.Zero ? null : new Mesh64(Scene, raw);

    /// <summary>Its triangles at a coarser level of detail: 0 is <see cref="Mesh"/> itself,
    /// 1 up to <see cref="Cadaclysm.LodLevels"/> each about a quarter of the triangles of
    /// the one before, and past that null. Every level shares the level-0 vertices -- the
    /// same positions and vertex count, only the indices differ -- so upload the vertices
    /// once and switch level by drawing a different index range.</summary>
    public Mesh? MeshLod(uint level) => MeshOf(Native.cadaclysm_node_mesh_lod(Scene.Handle, Index, level));

    /// <summary>How far <see cref="MeshLod"/> at this level moved the surface, in the
    /// scene's units -- what to pick a level by. Zero at level 0.</summary>
    public float LodError(uint level) => Native.cadaclysm_node_lod_error(Scene.Handle, Index, level);

    /// <summary>This node's body meshed for a solver, as a <see cref="Cadaclysm.FemMesh"/>: nodes
    /// welded by bits, triangles wound outward, each node tagged with the lowest-dimension B-rep
    /// entity it lies on, and every crack reported rather than closed. Owned by the caller --
    /// dispose it.</summary>
    /// <param name="tolerance">The chordal tolerance in model units, finite and above zero.
    /// <strong>It alone governs how closely the mesh follows the geometry.</strong></param>
    /// <param name="maxSize">A size ceiling in model units, finite and zero or more, `0` being no
    /// ceiling (curvature alone). <strong>It bounds the boundary segments and merely targets the
    /// interior</strong>, which is not a longest-element-edge guarantee: it adds boundary nodes
    /// without refining boundary geometry, and <see cref="Cadaclysm.FemMesh.LongestEdge"/> is what
    /// the mesh actually came to -- the figure to check against this.</param>
    /// <param name="placement">16 numbers, column-major, as <see cref="BoundsPlaced"/> takes them
    /// (null for the identity), applied in `double` throughout. The kernel library's
    /// `Solid.FemMesh` takes <strong>twelve</strong> instead -- origin, x, y, z -- so a caller
    /// moving between the two reformats the placement.</param>
    /// <remarks>Those two defaults are `FemOptions::default()`'s own, restated here so that the
    /// signature says what a caller gets. The library's struct is still filled by
    /// `cadaclysm_fem_options_init` first, so a field added to it later defaults without this line
    /// being touched; only these two are overwritten.
    ///
    /// <para><strong>The space is the body's, not the scene's, for a B-rep -- and the scene's for a
    /// mesh</strong>, which <see cref="Cadaclysm.FemMesh.FromMesh"/> is the flag for; read it
    /// there, because under a non-Native <see cref="Convention"/> the two are different spaces.
    /// Meshed in the part's own frame and following the hop from an instance to the shape it draws
    /// that <see cref="Mesh"/> follows, so a node instanced six times meshes once.</para>
    ///
    /// <para><strong>A cracked body is not a failure</strong>: it comes back with <see
    /// cref="Cadaclysm.FemMesh.Watertight"/> false and its cracks in <see
    /// cref="Cadaclysm.FemMesh.OpenEdges"/> and <see cref="Cadaclysm.FemMesh.FoldedEdges"/> --
    /// <em>both</em> -- and nothing is welded shut to make it look sound. Throws <see
    /// cref="CadaclysmException"/> for a tolerance or size the mesher refuses, a placement that is
    /// not 16 numbers or is not finite and invertible, a node with neither a brep nor a mesh (an
    /// assembly, a storey, a layer, an empty definition, a curve), and a body that meshes to no
    /// triangles at all -- carrying the library's own words for it.</para>
    ///
    /// <para>Prints the unlicensed notice once, here, and not again on either of the mesh's `.msh`
    /// calls.</para></remarks>
    public FemMesh FemMesh(double tolerance = 0.01, double maxSize = 0.0, double[]? placement = null)
    {
        if (placement is not null && placement.Length != 16)
            throw new CadaclysmException($"fem_mesh: a placement is 16 numbers, not {placement.Length}");
        var options = new RawFemOptions();
        // `init` writes `sizeof(CadaclysmFemOptions)` bytes as the *library* knows that type, into
        // the struct `RawFemOptions` declares -- which is why `tests/bindings.rs` pins the two
        // field for field. `Size` is then set to this binding's own sizeof, which is what the
        // growth rule asks of a caller.
        Native.cadaclysm_fem_options_init(ref options);
        options.Size = (nuint)Marshal.SizeOf<RawFemOptions>();
        options.Tolerance = tolerance;
        options.MaxSize = maxSize;
        var handle = Native.cadaclysm_node_fem_mesh(Scene.Handle, Index, placement, ref options);
        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw new CadaclysmException(Cadaclysm.LastErrorOr("fem_mesh"));
        }
        return new FemMesh(handle);
    }

    /// <summary>Its exact B-rep, for `Cadaclysm.Blacksmith.Solid.FromNode` to operate on, or
    /// null where it has none (a mesh, a curve, a CSG body, a JT or OpenSCAD part). Shared
    /// with the scene, not copied; see <see cref="Cadaclysm.Brep"/>.</summary>
    public Brep? Brep
    {
        get
        {
            var handle = Native.cadaclysm_node_brep(Scene.Handle, Index);
            if (!handle.IsInvalid) return new Brep(handle);
            handle.Dispose();
            return null;
        }
    }

    /// <summary>Its faces as surfaces and trim loops, where the reader built them -- empty
    /// where the reader has no parametric read of this body or of this format.</summary>
    public Surfaces Surfaces
    {
        get
        {
            var raw = Native.cadaclysm_node_surfaces(Scene.Handle, Index);
            if (raw.FaceCount == 0) return new Surfaces(Array.Empty<Face>());
            unsafe
            {
                var facesPtr = (RawFace*)raw.Faces;
                var loopsPtr = (uint*)raw.Loops;
                var pointsPtr = (float*)raw.Points;
                var profilesPtr = (float*)raw.Profiles;
                var nurbsPtr = (float*)raw.Nurbs;
                var faces = new Face[raw.FaceCount];
                for (uint i = 0; i < raw.FaceCount; i++)
                {
                    ref var f = ref facesPtr[i];
                    var loops = new float[f.LoopCount][];
                    for (uint k = 0; k < f.LoopCount; k++)
                    {
                        var loopIndex = f.LoopStart + k;
                        var start = loopsPtr[loopIndex * 2];
                        var length = loopsPtr[loopIndex * 2 + 1];
                        var loop = new float[length * 2];
                        for (uint p = 0; p < length * 2; p++) loop[p] = pointsPtr[start * 2 + p];
                        loops[k] = loop;
                    }
                    faces[i] = new Face(
                        f.Kind, f.Reversed != 0, f.Transposed != 0,
                        new[] { f.Origin[0], f.Origin[1], f.Origin[2] },
                        new[] { f.Ax[0], f.Ax[1], f.Ax[2] },
                        new[] { f.Ay[0], f.Ay[1], f.Ay[2] },
                        new[] { f.Az[0], f.Az[1], f.Az[2] },
                        new[] { f.Domain[0], f.Domain[1], f.Domain[2], f.Domain[3] },
                        new[] { f.Scalars[0], f.Scalars[1], f.Scalars[2], f.Scalars[3] },
                        loops,
                        CopyRange(profilesPtr, f.ProfileStart, f.ProfileCount, 4),
                        CopyRange(profilesPtr, f.Profile2Start, f.Profile2Count, 4),
                        CopyRange(nurbsPtr, f.NurbsStart, f.NurbsCount, 1));
                }
                return new Surfaces(faces);
            }
        }
    }

    private static unsafe float[] CopyRange(float* basePtr, uint start, uint count, uint stride)
    {
        var result = new float[count * stride];
        for (uint i = 0; i < count * stride; i++) result[i] = basePtr[start * stride + i];
        return result;
    }

    /// <summary>Its feature edges, as polylines to draw an overlay from.</summary>
    public Polylines Edges => new(Scene, Native.cadaclysm_node_edges(Scene.Handle, Index));

    /// <summary>One RGBA per polyline of <see cref="Edges"/>, null for an edge the file does
    /// not style; empty when nothing is styled.</summary>
    public float[]?[] EdgeColours => ColoursOf(Native.cadaclysm_node_edge_colors(Scene.Handle, Index));
    /// <summary><see cref="EdgeColours"/> for <see cref="SurfaceEdges"/>.</summary>
    public float[]?[] SurfaceEdgeColours => ColoursOf(Native.cadaclysm_node_surface_edge_colors(Scene.Handle, Index));

    static float[]?[] ColoursOf(RawEdgeColors raw)
    {
        if (raw.Rgba == IntPtr.Zero || raw.Count == 0) return Array.Empty<float[]?>();
        var flat = new float[raw.Count * 4];
        System.Runtime.InteropServices.Marshal.Copy(raw.Rgba, flat, 0, flat.Length);
        var out_ = new float[]?[raw.Count];
        for (var i = 0; i < raw.Count; i++)
            out_[i] = flat[4 * i + 3] < 0 ? null : flat[(4 * i)..(4 * i + 4)];
        return out_;
    }

    /// <summary>Its free curves, as polylines. A 2D drawing is all of these.</summary>
    public Polylines Curves => new(Scene, Native.cadaclysm_node_curves(Scene.Handle, Index));

    /// <summary>Its interior surface lines, as polylines -- distinct from <see cref="Edges"/>:
    /// those bound the faces, these rule across them.</summary>
    public Polylines Isocurves => new(Scene, Native.cadaclysm_node_isocurves(Scene.Handle, Index));

    /// <summary>Its feature edges as cubic Bézier curves -- exact where the file's curves
    /// were, where <see cref="Edges"/> are their chords. Builds the geometry if needed.</summary>
    public Beziers EdgeBeziers => new(Scene, Native.cadaclysm_node_edge_beziers(Scene.Handle, Index));

    /// <summary><see cref="EdgeBeziers"/> in `double`, unnarrowed -- the same segments.</summary>
    public Beziers64 EdgeBeziers64 => new(Scene, Native.cadaclysm_node_edge_beziers64(Scene.Handle, Index));

    /// <summary>Its free curves as cubic Béziers; see <see cref="EdgeBeziers"/>.</summary>
    public Beziers CurveBeziers => new(Scene, Native.cadaclysm_node_curve_beziers(Scene.Handle, Index));

    /// <summary><see cref="CurveBeziers"/> in `double`; see <see cref="EdgeBeziers64"/>.</summary>
    public Beziers64 CurveBeziers64 => new(Scene, Native.cadaclysm_node_curve_beziers64(Scene.Handle, Index));

    /// <summary>Its isocurves as cubic Béziers; see <see cref="EdgeBeziers"/>.</summary>
    public Beziers IsocurveBeziers => new(Scene, Native.cadaclysm_node_isocurve_beziers(Scene.Handle, Index));

    /// <summary><see cref="IsocurveBeziers"/> in `double`; see <see cref="EdgeBeziers64"/>.</summary>
    public Beziers64 IsocurveBeziers64 => new(Scene, Native.cadaclysm_node_isocurve_beziers64(Scene.Handle, Index));

    /// <summary>The collision body for what this node draws, building its mesh if it is not
    /// built. <paramref name="hullBudget"/> is the most triangles a hull may have; 0 asks for
    /// the Unity limit (255) and is not clamped to it. Null for a node that draws nothing.
    /// Cached per node and budget.</summary>
    public Collision? Collision(uint hullBudget = 0)
    {
        var raw = new RawCollision { Size = (uint)Marshal.SizeOf<RawCollision>() };
        return Native.cadaclysm_node_collision(Scene.Handle, Index, hullBudget, ref raw) ? new Collision(in raw) : null;
    }

    /// <summary>The convex hull <see cref="Collision"/> counted, as triangles. Empty for a
    /// node that draws nothing. A view into the scene, good until it closes or this node is
    /// asked for a different <paramref name="hullBudget"/>, which refits and frees it.</summary>
    public CollisionHull CollisionHull(uint hullBudget = 0) =>
        new(Scene, Native.cadaclysm_node_collision_hull(Scene.Handle, Index, hullBudget));

    // -- the surface path: for a renderer drawing exact surfaces, never triangles --

    /// <summary>The box of what this node draws under <paramref name="placement"/> (16 doubles,
    /// column-major, as <see cref="Placement.RawTransform"/>; null for the identity), for a part
    /// drawn from its surfaces: every sample is carried through the convention and the placement
    /// before it is boxed, so it is tighter than placing the corners of <see cref="Bounds"/>. All
    /// zeros for a part with no surfaces.</summary>
    public Bounds BoundsPlaced(double[]? placement = null)
    {
        if (placement is not null && placement.Length != 16) throw new CadaclysmException("bounds_placed: a placement is 16 numbers");
        var raw = Native.cadaclysm_node_bounds_placed(Scene.Handle, Index, placement);
        return new Bounds(new[] { raw.MinX, raw.MinY, raw.MinZ }, new[] { raw.MaxX, raw.MaxY, raw.MaxZ });
    }

    /// <summary><see cref="BoundsPlaced"/> in `double`.</summary>
    public Bounds64 BoundsPlaced64(double[]? placement = null)
    {
        if (placement is not null && placement.Length != 16) throw new CadaclysmException("bounds_placed64: a placement is 16 numbers");
        var raw = Native.cadaclysm_node_bounds_placed64(Scene.Handle, Index, placement);
        return new Bounds64(new[] { raw.MinX, raw.MinY, raw.MinZ }, new[] { raw.MaxX, raw.MaxY, raw.MaxZ });
    }

    /// <summary>Whether its mesh has been built and is held -- by <see cref="Scene.RealizeAll"/>,
    /// by an ask for it, or by anything else that needed it.</summary>
    public bool IsMeshed => Native.cadaclysm_node_is_meshed(Scene.Handle, Index);

    /// <summary>Its face boundaries taken from its trimmed surfaces -- the outline that costs no
    /// tessellation, where <see cref="Edges"/> meshes the part. In the surfaces' own frame (see
    /// <see cref="Scene.SurfaceMatrix"/>); empty without surfaces.</summary>
    public Polylines SurfaceEdges => new(Scene, Native.cadaclysm_node_surface_edges(Scene.Handle, Index));

    /// <summary>Its edges as the exact curves, where the reader has them without meshing -- a Rhino
    /// extrusion's rims are its profile -- and empty everywhere else, so a caller drawing from
    /// surfaces tries this before <see cref="SurfaceEdges"/>, whose trims are thinned to the mesh
    /// tolerance. The same segments as <see cref="EdgeBeziers"/>, in the same space: not the
    /// surfaces' frame, so no <see cref="Scene.SurfaceMatrix"/>.</summary>
    public Beziers SurfaceEdgeBeziers => new(Scene, Native.cadaclysm_node_surface_edge_beziers(Scene.Handle, Index));

    /// <summary>Its isocurves taken from its trimmed surfaces and clipped to the trims, without
    /// meshing; a flat face gets none. In the surfaces' frame; empty without surfaces.</summary>
    public Polylines SurfaceIsocurves => new(Scene, Native.cadaclysm_node_surface_isocurves(Scene.Handle, Index));

    /// <summary>Where the segment <paramref name="from"/>..<paramref name="to"/> first meets this
    /// part's surfaces, or null where it meets none. Exact, and in the surfaces' own frame: carry
    /// a ray from the scene's space through the inverse of <see cref="Scene.SurfaceMatrix"/> first.</summary>
    public double[]? SurfacePick(double[] from, double[] to)
    {
        if (from.Length != 3 || to.Length != 3) throw new CadaclysmException("surface_pick: from and to are three numbers each");
        var hit = new double[3];
        return Native.cadaclysm_node_surface_pick(Scene.Handle, Index, from, to, hit) ? hit : null;
    }

    /// <summary>A coarse mesh over its surfaces for what needs triangles and not a picture (ray
    /// tracing, distance fields): each face gridded <paramref name="cells"/> by <paramref name="cells"/>,
    /// never welded, built once per part at the first size asked. Null without surfaces or for
    /// zero cells.</summary>
    public Mesh? SurfaceProxyMesh(uint cells) => MeshOf(Native.cadaclysm_node_surface_proxy_mesh(Scene.Handle, Index, cells));

    /// <summary>About how many triangles <see cref="Mesh"/> would give, without building it; -1
    /// where the reader cannot say without doing the work. Treat -1 as unknown, never as zero.</summary>
    public long TriangleEstimate => Native.cadaclysm_node_triangle_estimate(Scene.Handle, Index);

    /// <summary>This node and every node under it, parents before children.</summary>
    public IEnumerable<Node> Walk()
    {
        var stack = new Stack<Node>();
        stack.Push(this);
        while (stack.Count > 0)
        {
            var node = stack.Pop();
            yield return node;
            var children = node.Children;
            for (var i = children.Count - 1; i >= 0; i--) stack.Push(children[i]);
        }
    }

    // Identity is the pair, so a node from one lookup equals the same node from another and
    // can key a dictionary of, say, what a viewer has uploaded.
    public bool Equals(Node? other) => other is not null && other.Index == Index && ReferenceEquals(other.Scene, Scene);
    public override bool Equals(object? obj) => Equals(obj as Node);
    public override int GetHashCode() => HashCode.Combine(RuntimeHelpers_GetHashCode(Scene), Index);
    private static int RuntimeHelpers_GetHashCode(object o) => System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(o);
    public override string ToString() => $"<Node {Index} {(Label.Length > 0 ? Label : "?")}>";
}

/// <summary>An open document. Dispose it, or close it explicitly, when done -- everything it
/// hands back borrows from it.</summary>
public sealed class Scene : IDisposable
{
    private readonly SceneHandle _handle;
    private readonly string _label;

    internal Scene(SceneHandle handle, string label, string path, string? schemaPath, Convention convention)
    {
        _handle = handle;
        _label = label;
        Path = path;
        SchemaPath = schemaPath;
        Convention = convention;
    }

    /// <summary>The file this was read from -- or, for a scene opened by
    /// <see cref="Cadaclysm.OpenMemory"/>, the name it was given, as Python keeps it.</summary>
    public string Path { get; }

    /// <summary>The `.exp` actually used to open this, or null.</summary>
    public string? SchemaPath { get; }

    /// <summary>The convention this was opened with.</summary>
    /// <remarks>Named the same as the <see cref="Cadaclysm.Convention"/> type, which is legal
    /// in C# for the same reason <see cref="Node.Mesh"/> can share its name with the <see
    /// cref="Cadaclysm.Mesh"/> type -- member lookup and type lookup are separate.</remarks>
    public Convention Convention { get; }

    /// <summary>The handle, refusing to hand over a closed one -- every call in this file
    /// goes through here rather than touching the field directly, so a use-after-close raises
    /// a <see cref="CadaclysmException"/> at the call site instead of passing a dangling
    /// pointer into the library. (The marshaller would refuse the closed handle too, with an
    /// <see cref="ObjectDisposedException"/>; this keeps the exception the binding's own.)
    /// </summary>
    internal SceneHandle Handle => _handle.IsClosed
        ? throw new CadaclysmException($"{_label}: the scene is closed")
        : _handle;

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the scene back. Idempotent. Every borrowed <see cref="Mesh"/> and <see
    /// cref="Polylines"/> still held throws on its next read.</summary>
    public void Close() => _handle.Dispose();

    /// <summary><see cref="Close"/>. A scene never disposed is closed when the runtime
    /// collects its handle.</summary>
    public void Dispose() => Close();

    /// <summary>The version of the library that read it.</summary>
    public string Version => Cadaclysm.Version();

    /// <summary>The schema the file named, or "" for a format that names none.</summary>
    public string Schema => Marshal.PtrToStringUTF8(Native.cadaclysm_schema(Handle)) ?? "";

    /// <summary>The schema that actually read it, which is not always the one it named.
    /// </summary>
    public string SchemaRead => Marshal.PtrToStringUTF8(Native.cadaclysm_schema_read(Handle)) ?? "";

    /// <summary>Whether something other than the file's own schema read it.</summary>
    public bool Substituted
    {
        get
        {
            var read = SchemaRead;
            if (read.Length == 0) return false;
            static string Bare(string entry) => entry.Split('{')[0].Trim().Trim('.').ToUpperInvariant();
            var bareRead = Bare(read);
            return !Schema.Split(',').Select(Bare).Contains(bareRead);
        }
    }

    /// <summary>What one length in the file is worth in metres, or 1 where it did not say.
    /// </summary>
    public double MetresPerUnit => Native.cadaclysm_metres_per_unit(Handle);

    /// <summary>Everything the model covers, in world coordinates. This meshes all of it,
    /// being the only way to know how far it reaches.</summary>
    public Bounds Bounds
    {
        get
        {
            var raw = Native.cadaclysm_bounds(Handle);
            return new Bounds(new[] { raw.MinX, raw.MinY, raw.MinZ }, new[] { raw.MaxX, raw.MaxY, raw.MaxZ });
        }
    }

    /// <summary><see cref="Bounds"/> in `double`: the same union box, unnarrowed. This meshes
    /// all of it, being the only way to know how far it reaches.</summary>
    public Bounds64 Bounds64
    {
        get
        {
            var raw = Native.cadaclysm_bounds64(Handle);
            return new Bounds64(new[] { raw.MinX, raw.MinY, raw.MinZ }, new[] { raw.MaxX, raw.MaxY, raw.MaxZ });
        }
    }

    /// <summary>What this file held that the reader could not build.</summary>
    public IReadOnlyList<string> Diagnostics
    {
        get
        {
            var count = Native.cadaclysm_diagnostic_count(Handle);
            var found = new List<string>((int)count);
            for (uint i = 0; i < count; i++)
                found.Add(Marshal.PtrToStringUTF8(Native.cadaclysm_diagnostic(Handle, i)) ?? "");
            return found;
        }
    }

    /// <summary>What the reader built but the geometry stage could not finish -- a face that
    /// would not trim, a surface that would not mesh. <see cref="Diagnostics"/> is what the
    /// file held that could not be read; this is what the geometry did.</summary>
    public IReadOnlyList<string> GeometryDiagnostics
    {
        get
        {
            var count = Native.cadaclysm_geometry_diagnostic_count(Handle);
            var found = new List<string>((int)count);
            for (uint i = 0; i < count; i++)
                found.Add(Marshal.PtrToStringUTF8(Native.cadaclysm_geometry_diagnostic(Handle, i)) ?? "");
            return found;
        }
    }

    /// <summary>The rigid bodies of the file's mechanism, in the file's order; empty for a
    /// file that records none.</summary>
    public IReadOnlyList<Link> Links
    {
        get
        {
            var count = Native.cadaclysm_link_count(Handle);
            var found = new List<Link>((int)count);
            for (uint i = 0; i < count; i++) found.Add(new Link(this, i));
            return found;
        }
    }

    /// <summary>The connections between the links, in the file's order; empty for a file that
    /// records none.</summary>
    public IReadOnlyList<Joint> Joints
    {
        get
        {
            var count = Native.cadaclysm_joint_count(Handle);
            var found = new List<Joint>((int)count);
            for (uint i = 0; i < count; i++) found.Add(new Joint(this, i));
            return found;
        }
    }

    /// <summary>The archive member this was read from, or null for a plain file.</summary>
    public string? SourceName
    {
        get
        {
            var raw = Native.cadaclysm_source_name(Handle);
            return raw == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(raw);
        }
    }

    private sealed class NodeList : IReadOnlyList<Node>
    {
        private readonly Scene _scene;
        public NodeList(Scene scene) => _scene = scene;
        public int Count => (int)Native.cadaclysm_node_count(_scene.Handle);
        public Node this[int index] => new(_scene, (uint)index);
        public IEnumerator<Node> GetEnumerator()
        {
            for (var i = 0; i < Count; i++) yield return this[i];
        }
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
    }

    /// <summary>Every node, in index order.</summary>
    public IReadOnlyList<Node> Nodes => new NodeList(this);

    /// <summary>The indices of the nodes a filter matches, in document order, as <see
    /// cref="Node"/>s.</summary>
    /// <remarks>The filter is one boolean expression over a node --
    /// `class == ON_Brep and within(class == ON_Layer and name == Walls)`. Raises with the
    /// parser's own message if the filter will not parse; an empty result is not an error.
    /// </remarks>
    public IReadOnlyList<Node> Query(string filter)
    {
        var total = Native.cadaclysm_query(Handle, filter, null, 0);
        if (total == 0)
        {
            var reason = Marshal.PtrToStringUTF8(Native.cadaclysm_last_error());
            if (!string.IsNullOrEmpty(reason)) throw new CadaclysmException($"{_label}: {reason}");
            return Array.Empty<Node>();
        }
        var buffer = new uint[total];
        var written = Native.cadaclysm_query(Handle, filter, buffer, total);
        var count = (int)Math.Min(written, total);
        var found = new Node[count];
        for (var i = 0; i < count; i++) found[i] = new Node(this, buffer[i]);
        return found;
    }

    /// <summary>What this document draws and where -- not the nodes, and the difference is
    /// the point: a node walk draws a Rhino block once at its definition's frame and every
    /// placement of it not at all. This is the list to iterate to draw.</summary>
    public IReadOnlyList<Placement> Placements
    {
        get
        {
            var count = Native.cadaclysm_placement_count(Handle);
            var found = new List<Placement>((int)count);
            for (uint i = 0; i < count; i++) found.Add(new Placement(this, i));
            return found;
        }
    }

    /// <summary>The nodes nothing else contains.</summary>
    public IReadOnlyList<Node> Roots
    {
        get
        {
            var count = Native.cadaclysm_root_count(Handle);
            var found = new List<Node>((int)count);
            for (uint i = 0; i < count; i++)
            {
                var index = Native.cadaclysm_root(Handle, i);
                if (index != uint.MaxValue) found.Add(new Node(this, index));
            }
            return found;
        }
    }

    /// <summary>Every node reachable from the roots, parents before children.</summary>
    public IEnumerable<Node> Walk() => Roots.SelectMany(root => root.Walk());

    /// <summary>Build every mesh now, across threads, and say how many were built.</summary>
    /// <remarks>Reading is lazy so a caller can put the tree on screen while the shapes are
    /// still to come. Asking node by node instead meshes them one at a time on one core; this
    /// does the same work over every core.</remarks>
    public uint RealizeAll() => Native.cadaclysm_realize_all(Handle);

    /// <summary><see cref="RealizeAll"/>, leaving alone every node that carries surfaces when
    /// <paramref name="skipSurfaced"/> is true: a renderer drawing those from their surfaces never
    /// pays for their triangles. Returns how many were built.</summary>
    public uint RealizeMeshes(bool skipSurfaced = true) => Native.cadaclysm_realize_meshes(Handle, skipSurfaced ? 1u : 0u);

    /// <summary>How many nodes <see cref="RealizeAll"/> has finished with. Safe to read from
    /// another thread.</summary>
    public uint Realized => Native.cadaclysm_realized(Handle);

    /// <summary>How many there will be in all -- zero until <see cref="RealizeAll"/> starts.
    /// </summary>
    public uint RealizeTotal => Native.cadaclysm_realize_total(Handle);

    /// <summary>Ask a running <see cref="RealizeAll"/> to stop. One-way, for the life of the
    /// scene.</summary>
    public void Cancel() => Native.cadaclysm_cancel(Handle);

    /// <summary>Drop every mesh the scene has built; the next ask rebuilds. Every
    /// <see cref="Mesh"/> and <see cref="Polylines"/> handed out before this is over freed
    /// memory.</summary>
    public void ForgetMeshes() => Native.cadaclysm_forget_meshes(Handle);

    /// <summary>Write the whole scene to `path`: "glb", "gltf" or "obj" -- every placement of
    /// every shape, named and placed as the tree is, unlike <see cref="Node.SaveMesh"/> which
    /// writes one node's mesh on its own.</summary>
    public void Save(string path, string format = "glb")
    {
        if (!Native.cadaclysm_scene_save(Handle, path, format))
            throw new CadaclysmException(Cadaclysm.LastErrorOr($"could not write {path}"));
    }

    /// <summary>"y" or "z": which axis is up by default, from <see cref="Convention"/> --
    /// <see cref="Cadaclysm.Convention.Unity"/> and <see cref="Cadaclysm.Convention.YUp"/> give
    /// "y", every other convention "z". What <see cref="SvgOptions.Up"/> defaults to when left
    /// null.</summary>
    internal string DefaultUp => Convention is Convention.Unity or Convention.YUp ? "y" : "z";

    /// <summary>Every visible placement's wireframe as SVG text, from the camera <paramref
    /// name="options"/> describes -- the library's own camera, not a viewer. See <see
    /// cref="SvgOptions"/>. Borrowed: copied out before this returns, and replaced by this
    /// scene's next `SvgText`/`Svg` call.</summary>
    public string SvgText(SvgOptions? options = null)
    {
        var raw = Cadaclysm.BuildSvgOptions(options, DefaultUp);
        var ptr = Native.cadaclysm_scene_svg_text(Handle, ref raw);
        if (ptr == IntPtr.Zero) throw new CadaclysmException(Cadaclysm.LastErrorOr("svg"));
        return Marshal.PtrToStringUTF8(ptr) ?? "";
    }

    /// <summary><see cref="SvgText"/> written to `path` by the library itself.</summary>
    public void Svg(string path, SvgOptions? options = null)
    {
        var raw = Cadaclysm.BuildSvgOptions(options, DefaultUp);
        if (!Native.cadaclysm_scene_svg(Handle, path, ref raw))
            throw new CadaclysmException(Cadaclysm.LastErrorOr($"could not write {path}"));
    }

    /// <summary>The 4x4 that puts <see cref="Node.Surfaces"/> in the space everything else is
    /// already in. Only the surfaces need it -- meshes, polylines and the scene's other
    /// products arrive in the convention the document was opened with; a surface does not,
    /// because converting one means converting its parameter space too.</summary>
    public float[,] SurfaceMatrix
    {
        get
        {
            var raw = new float[16];
            Native.cadaclysm_surface_matrix(Handle, raw);
            return Matrices.ToRowMajor(raw);
        }
    }
}

/// <summary>The module-level entry points: opening a file, the library's version and
/// licensing, and the schema helpers that do not need an open scene.</summary>
public static class Cadaclysm
{
    /// <summary>The version of the library actually loaded, which is the one worth reporting.
    /// </summary>
    public static string Version() => Marshal.PtrToStringUTF8(Native.cadaclysm_version()) ?? "";

    /// <summary>When the loaded library was built, YYYY-MM-DD.</summary>
    public static string BuildDate() => Marshal.PtrToStringUTF8(Native.cadaclysm_build_date()) ?? "";

    /// <summary>Load a license: the certificate text, or the path of a file holding it.
    /// Without this the library looks in `CADACLYSM_LICENSE`, then for `cadaclysm.lic` beside
    /// the running executable and in the working directory. Raises with the library's reason
    /// when the text does not verify; the previous license, if any, stays in use.</summary>
    public static void License(string textOrPath)
    {
        if (!Native.cadaclysm_license_set(textOrPath))
            throw new CadaclysmException(LastErrorOr("license refused"));
    }

    /// <summary>One line about the license the library is running under. Never null: the
    /// license line, or, without one, "unlicensed".</summary>
    public static string LicenseInfo() => Marshal.PtrToStringUTF8(Native.cadaclysm_license_info()) ?? "unlicensed";

    /// <summary>How many unlicensed notices this library has printed to stderr in this
    /// process.</summary>
    public static ulong LicenseNoticeCount() => Native.cadaclysm_license_notice_count();

    /// <summary>How many coarser levels <see cref="Node.MeshLod"/> offers above the mesh
    /// itself (level 0).</summary>
    public static uint LodLevels() => Native.cadaclysm_lod_levels();

    /// <summary>Every format <see cref="Node.SaveMesh"/> writes.</summary>
    public static IReadOnlyList<MeshFormat> MeshFormats()
    {
        var count = Native.cadaclysm_mesh_format_count();
        var found = new List<MeshFormat>((int)count);
        for (uint i = 0; i < count; i++)
        {
            var name = Marshal.PtrToStringUTF8(Native.cadaclysm_mesh_format(i)) ?? "";
            var extension = Marshal.PtrToStringUTF8(Native.cadaclysm_mesh_format_extension(i)) ?? "";
            var label = Marshal.PtrToStringUTF8(Native.cadaclysm_mesh_format_label(i)) ?? "";
            found.Add(new MeshFormat(name, extension, label));
        }
        return found;
    }

    /// <summary>Every format this build reads, for an open dialog's filter. The extensions
    /// arrive semicolon-separated from the library and are split here.</summary>
    public static IReadOnlyList<Format> Formats()
    {
        var count = Native.cadaclysm_format_count();
        var found = new List<Format>((int)count);
        for (uint i = 0; i < count; i++)
        {
            var name = Marshal.PtrToStringUTF8(Native.cadaclysm_format_name(i)) ?? "";
            var extensions = (Marshal.PtrToStringUTF8(Native.cadaclysm_format_extensions(i)) ?? "")
                .Split(';', StringSplitOptions.RemoveEmptyEntries);
            found.Add(new Format(name, extensions));
        }
        return found;
    }

    /// <summary>Ask the user for a file to open, through the library's own dialog. Null if
    /// they cancelled, or if no dialog was available. Blocks until the user acts; on macOS
    /// must be called from the main thread.</summary>
    public static string? PickFile()
    {
        var raw = Native.cadaclysm_pick_file(IntPtr.Zero);
        return raw == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(raw);
    }

    /// <summary>Ask the user where to save, through the library's own dialog, with
    /// <paramref name="suggestedName"/> prefilled. Null if they cancelled or no dialog was
    /// available. Blocks; on macOS must be called from the main thread.</summary>
    public static string? PickSave(string? suggestedName = null)
    {
        var raw = Native.cadaclysm_pick_save(IntPtr.Zero, suggestedName);
        return raw == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(raw);
    }

    /// <summary>The schema a STEP or IFC file says it speaks, from its own header --
    /// `FILE_SCHEMA(('IFC2X3'))` sits near the top, so a few kilobytes is plenty.</summary>
    public static string DeclaredSchema(string modelPath)
    {
        byte[] head;
        using (var stream = File.OpenRead(modelPath))
        {
            head = new byte[Math.Min(8192, stream.Length)];
            var read = stream.Read(head, 0, head.Length);
            if (read != head.Length) Array.Resize(ref head, read);
        }
        var text = System.Text.Encoding.Latin1.GetString(head);
        var match = Regex.Match(text, @"FILE_SCHEMA\s*\(\s*\(\s*'([^']+)'", RegexOptions.IgnoreCase);
        return match.Success ? match.Groups[1].Value : "";
    }

    private static string Plain(string name) => new(name.ToUpperInvariant().Where(char.IsLetterOrDigit).ToArray());

    /// <summary>`schema` resolved to `(Chosen, Fallbacks)` -- one `.exp`, or a list to try.
    /// </summary>
    /// <remarks>A file is taken as given. A directory is matched against what the model says
    /// it speaks -- AP203 calls itself CONFIG_CONTROL_DESIGN, and where the declared name
    /// resembles no filename the whole directory comes back as fallbacks to try in turn.
    /// </remarks>
    public static (string? Chosen, IReadOnlyList<string> Fallbacks) ResolveSchema(string modelPath, string? schema)
    {
        if (schema is null) return (null, Array.Empty<string>());
        if (File.Exists(schema)) return (schema, Array.Empty<string>());
        if (!Directory.Exists(schema))
            throw new CadaclysmException($"schema {schema} is neither a file nor a directory");
        var available = Directory.GetFiles(schema, "*.exp").OrderBy(f => f, StringComparer.Ordinal).ToArray();
        if (available.Length == 0)
            throw new CadaclysmException($"no .exp schemas in {schema}");

        var declared = Plain(DeclaredSchema(modelPath));
        var matches = available.Where(exp => declared.Length > 0 && (
            declared.StartsWith(Plain(Path.GetFileNameWithoutExtension(exp)), StringComparison.Ordinal) ||
            Plain(Path.GetFileNameWithoutExtension(exp)).StartsWith(declared, StringComparison.Ordinal))).ToArray();
        if (matches.Length > 0)
        {
            var best = matches.OrderByDescending(exp => Plain(Path.GetFileNameWithoutExtension(exp)).Length).First();
            return (best, Array.Empty<string>());
        }
        return (null, available);
    }

    /// <summary>A packed <see cref="Convention"/> from a name a user typed, as the viewers
    /// take it -- "unreal", or "unreal+file-units" to keep the file's own units under the
    /// preset's axes.</summary>
    /// <remarks>Named <c>ParseConvention</c> rather than <c>Convention.Parse</c>, which is how
    /// Python spells its equivalent classmethod: a C# enum cannot carry a method, so this is
    /// the nearest legal home for it, beside <see cref="Open"/> which is the only other place
    /// a caller wants it. Throws <see cref="ArgumentException"/> rather than <see
    /// cref="CadaclysmException"/> since this never reaches the library -- Python raises
    /// `ValueError` here, not `CadaclysmError`, for the same reason.</remarks>
    public static Convention ParseConvention(string text)
    {
        var parts = text.Trim().ToLowerInvariant().Split('+', 2);
        Convention? preset = parts[0] switch
        {
            "native" => Convention.Native,
            "unreal" => Convention.Unreal,
            "unity" => Convention.Unity,
            "y-up" => Convention.YUp,
            "blender" => Convention.Blender,
            _ => null,
        };
        if (preset is null)
            throw new ArgumentException($"no convention called '{parts[0]}': native, unreal, unity, y-up or blender");
        var packed = (uint)preset.Value;
        if (parts.Length > 1)
        {
            foreach (var flag in parts[1].Split('+', StringSplitOptions.RemoveEmptyEntries))
            {
                if (flag != "file-units")
                    throw new ArgumentException($"no convention flag called '{flag}': file-units");
                packed |= ConventionFlag.FileUnits;
            }
        }
        return (Convention)packed;
    }

    internal static string LastErrorOr(string fallback)
    {
        var e = Marshal.PtrToStringUTF8(Native.cadaclysm_last_error());
        return string.IsNullOrEmpty(e) ? fallback : e;
    }

    /// <summary>`SvgOptions`, packed into `RawSvgOptions`: `View` fills `Azimuth`/`Elevation`
    /// unless they are set directly, `Up` defaults to `defaultUp`, colours are `'#rrggbb'`.
    /// Shared by <see cref="Scene.SvgText"/>/<see cref="Scene.Svg"/> and <see
    /// cref="Node.SvgText"/>/<see cref="Node.Svg"/>, as Python's `_svg_options` is shared by
    /// `Scene.svg` and `Node.svg`.</summary>
    internal static RawSvgOptions BuildSvgOptions(SvgOptions? options, string defaultUp)
    {
        var o = options ?? new SvgOptions();
        var raw = new RawSvgOptions();
        Native.cadaclysm_svg_options_init(ref raw);
        var (baseAzimuth, baseElevation) = SvgViewAngles.For(o.View);
        raw.Up = string.Equals(o.Up ?? defaultUp, "y", StringComparison.OrdinalIgnoreCase) ? 1u : 0u;
        raw.Azimuth = o.Azimuth ?? baseAzimuth;
        raw.Elevation = o.Elevation ?? baseElevation;
        raw.Fov = o.Fov;
        raw.Width = o.Width;
        raw.Height = o.Height;
        raw.Margin = o.Margin;
        raw.Tolerance = o.Tolerance;
        raw.StrokeWidth = o.StrokeWidth;
        raw.Stroke = ParseColour(o.Stroke);
        raw.Background = o.Background ?? 0xFFFFFFFFu; // CADACLYSM_SVG_TRANSPARENT
        raw.Flags = (o.Edges ? 1u : 0u) | (o.Curves ? 2u : 0u) | (o.Isocurves ? 4u : 0u) | (o.Polylines ? 8u : 0u);
        return raw;
    }

    /// <summary>A colour as the ABI's packed `0xRRGGBB`: `'#rrggbb'`, the leading `#` optional.
    /// </summary>
    internal static uint ParseColour(string colour)
    {
        var hex = colour.StartsWith('#') ? colour[1..] : colour;
        if (hex.Length != 6 || !uint.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
            throw new CadaclysmException($"colour {colour}: expected '#rrggbb'");
        return value;
    }

    private static RawOpenOptions BuildOptions(Convention convention, bool colours, double sourceMetresPerUnit)
    {
        var options = new RawOpenOptions();
        Native.cadaclysm_open_options_init(ref options);
        var packed = (uint)convention;
        options.Convention = packed & ~(ConventionFlag.FileUnits | ConventionFlag.UvWorld);
        options.FileUnits = (packed & ConventionFlag.FileUnits) != 0;
        options.Uvs = (packed & ConventionFlag.UvWorld) != 0 ? 1u : 0u;
        options.Colors = colours ? 1u : 0u;
        options.SourceMetersPerUnit = sourceMetresPerUnit;
        return options;
    }

    private static SceneHandle OpenNative(string path, string? schema, RawOpenOptions options)
    {
        IntPtr list = IntPtr.Zero, text = IntPtr.Zero;
        try
        {
            if (schema is not null)
            {
                text = Marshal.StringToCoTaskMemUTF8(schema);
                list = Marshal.AllocCoTaskMem(IntPtr.Size);
                Marshal.WriteIntPtr(list, text);
                options.Schemas = list;
                options.SchemaCount = 1;
            }
            return Native.cadaclysm_open(path, ref options);
        }
        finally
        {
            if (list != IntPtr.Zero) Marshal.FreeCoTaskMem(list);
            if (text != IntPtr.Zero) Marshal.FreeCoTaskMem(text);
        }
    }

    /// <summary>Open a CAD file, or a `.zip` holding one.</summary>
    /// <param name="schema">An EXPRESS schema (`.exp`) beyond the ones built into the
    /// library, or a directory of them matched against what the file says it speaks. Every
    /// schema the project ships is compiled in, so a STEP or IFC file opens with null.</param>
    /// <param name="convention">The space to read the file into. The library does the
    /// converting, so every array read out of the scene is already in it.</param>
    /// <param name="sourceMetresPerUnit">What one of the file's own units is worth in metres,
    /// for a format that states none -- OpenSCAD is the case, being unitless. Zero means "not
    /// said". This is a struct field Python's own `open()` wrapper never surfaces (only its
    /// private `_options` helper does); it is exposed here because the brief for this binding
    /// asked for it explicitly.</param>
    /// <remarks>Raises <see cref="CadaclysmException"/> on failure, carrying what the library
    /// said. A `.zip` opens its first readable member; <see cref="Scene.SourceName"/> says
    /// which.</remarks>
    public static Scene Open(string path, Convention convention = Convention.Native, string? schema = null,
        bool colours = false, double sourceMetresPerUnit = 0)
    {
        if (!File.Exists(path) && !Directory.Exists(path))
            throw new CadaclysmException($"{path}: no such file");

        var options = BuildOptions(convention, colours, sourceMetresPerUnit);

        // A directory goes over whole rather than being narrowed to one file here: the
        // library walks it and keys each schema under the name that schema itself declares.
        if (schema is not null && Directory.Exists(schema))
        {
            var handle = OpenNative(path, schema, options);
            if (!handle.IsInvalid) return new Scene(handle, Path.GetFileName(path), path, schema, convention);
            // The library's own message alone, exactly as Python's `f"{path.name}: {_last_error()}"`
            // does -- "open failed" only stands in for the message on the (untested-in-practice)
            // case that a null handle left none, which Python's raw (possibly empty) string does not
            // guard against.
            throw new CadaclysmException($"{Path.GetFileName(path)}: {LastErrorOr("open failed")}");
        }

        var (chosen, fallbacks) = ResolveSchema(path, schema);
        var candidates = chosen is not null || fallbacks.Count == 0
            ? new[] { chosen }
            : fallbacks.ToArray();
        foreach (var candidate in candidates)
        {
            var handle = OpenNative(path, candidate, options);
            if (!handle.IsInvalid) return new Scene(handle, Path.GetFileName(path), path, candidate, convention);
        }
        throw new CadaclysmException($"{Path.GetFileName(path)}: {LastErrorOr("open failed")}");
    }

    /// <summary>Open a CAD file already in bytes.</summary>
    /// <param name="format">The kind as an extension would name it -- "step", "ifc", "igs",
    /// "brep", "3dm", "scad". Defaults to <paramref name="name"/>'s own extension, since there
    /// is otherwise no file name to take it from -- Python's `open_memory` has no such
    /// default and always requires the caller to state it; this binding infers one because
    /// the smoke this binding is built against opens memory by name alone.</param>
    /// <param name="schema">Must be a path here: there is no file on disk to read a
    /// `FILE_SCHEMA` line out of.</param>
    public static unsafe Scene OpenMemory(ReadOnlySpan<byte> bytes, string name, string? format = null,
        string? schema = null, Convention convention = Convention.Native, bool colours = false)
    {
        format ??= Path.GetExtension(name).TrimStart('.');
        var options = BuildOptions(convention, colours, 0);
        IntPtr list = IntPtr.Zero, text = IntPtr.Zero;
        try
        {
            if (schema is not null)
            {
                text = Marshal.StringToCoTaskMemUTF8(schema);
                list = Marshal.AllocCoTaskMem(IntPtr.Size);
                Marshal.WriteIntPtr(list, text);
                options.Schemas = list;
                options.SchemaCount = 1;
            }
            SceneHandle handle;
            fixed (byte* ptr = bytes)
            {
                handle = Native.cadaclysm_open_memory((IntPtr)ptr, (nuint)bytes.Length, format, ref options);
            }
            // As above: the library's own message alone; "open failed" only stands in when it left none.
            if (handle.IsInvalid) throw new CadaclysmException($"{name}: {LastErrorOr("open failed")}");
            // The name stands as the scene's path, as Python's `Scene.path` keeps it.
            return new Scene(handle, name, name, schema, convention);
        }
        finally
        {
            if (list != IntPtr.Zero) Marshal.FreeCoTaskMem(list);
            if (text != IntPtr.Zero) Marshal.FreeCoTaskMem(text);
        }
    }
}
