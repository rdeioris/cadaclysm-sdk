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
// `Scene.Dispose()` (or `Scene.Close()`) runs.
//
// Strings are the easy half: every `char *` this ABI returns is marshalled into a copied
// `string` on the way out, so `Node.Name` and friends outlive anything.
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

// ---- the structs the ABI returns by value ----------------------------------------------

[StructLayout(LayoutKind.Sequential)]
internal struct RawBounds
{
    public float MinX, MinY, MinZ;
    public float MaxX, MaxY, MaxZ;
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

[StructLayout(LayoutKind.Sequential)]
internal struct RawPolylines
{
    public IntPtr Positions;
    public IntPtr Counts;
    public uint PolylineCount;
    public uint VertexCount;
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

/// <summary>`CadaclysmSurfaces`. Not pinned against the header by `tests/bindings.rs` (only
/// Mesh, Polylines and OpenOptions are), but built to the same field order regardless.
/// </summary>
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

// ---- loading the library ------------------------------------------------------------------

/// <summary>Resolves `cadaclysm_capi` for every P/Invoke in <see cref="Native"/>, and
/// `cadaclysm_blacksmith` for every one in `Blacksmith.cs`'s `BlacksmithNative`.</summary>
internal static class Loader
{
    private static readonly object Gate = new();
    private static bool _registered;

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
                name.StartsWith("cadaclysm_", StringComparison.Ordinal) ? Resolve(name) : IntPtr.Zero);
        }
    }

    /// <summary>The two libraries resolved through here, and the file names each goes by.
    /// </summary>
    private static readonly string[] Libraries = { "cadaclysm_capi", "cadaclysm_blacksmith" };

    private static string[] FilesOf(string libraryName) =>
        new[] { $"{libraryName}.dll", $"lib{libraryName}.dylib", $"lib{libraryName}.so" };

    /// <summary>Finds and loads the named library: the environment (`CADACLYSM_LIBRARY` for
    /// both, and `CADACLYSM_BLACKSMITH_LIBRARY` first for the kernel, as Python's kernel
    /// module reads it) as a directory or the file itself, then beside this assembly, then the
    /// platform default search.</summary>
    /// <remarks>The library sits in the Rust build directory, not beside this assembly by
    /// default, so this points the loader at it rather than making the caller arrange PATH.
    /// A deployment that ships the library alongside the executable works untouched, since
    /// that is tried before falling through to the OS's own search.</remarks>
    public static IntPtr Resolve(string libraryName)
    {
        var files = FilesOf(libraryName);
        var candidates = new List<string>();
        var variables = libraryName == "cadaclysm_blacksmith"
            ? new[] { "CADACLYSM_BLACKSMITH_LIBRARY", "CADACLYSM_LIBRARY" }
            : new[] { "CADACLYSM_LIBRARY" };
        foreach (var variable in variables)
        {
            var env = Environment.GetEnvironmentVariable(variable);
            if (string.IsNullOrEmpty(env)) continue;
            if (Directory.Exists(env))
            {
                candidates.AddRange(files.Select(f => Path.Combine(env, f)));
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
        // Walking up from this assembly: an SDK checkout keeps the library in `lib/` beside
        // the wrappers; the repository this example ships in keeps it in `target/release`
        // (or `target/debug`, a fallback for a machine that only built that).
        var assembly = Assembly.GetExecutingAssembly().Location;
        for (var dir = Path.GetDirectoryName(assembly); dir is not null; dir = Path.GetDirectoryName(dir))
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

/// <summary>Every entry point in `include/cadaclysm.h` this binding declares — the same 58
/// Python's `cadaclysm.py` does, no more and no less; `tests/bindings.rs` compares the two
/// sets by name.</summary>
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
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_open(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref RawOpenOptions options);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_open_memory(
        IntPtr bytes, nuint length, [MarshalAs(UnmanagedType.LPUTF8Str)] string format,
        ref RawOpenOptions options);
    [DllImport(Lib)] internal static extern void cadaclysm_open_options_init(ref RawOpenOptions options);
    [DllImport(Lib)] internal static extern void cadaclysm_close(IntPtr scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_source_name(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_count(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_root_count(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_root(IntPtr scene, uint index);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_schema(IntPtr scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_schema_read(IntPtr scene);
    [DllImport(Lib)] internal static extern double cadaclysm_metres_per_unit(IntPtr scene);
    [DllImport(Lib)] internal static extern RawBounds cadaclysm_bounds(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_parent(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_child_count(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_child(IntPtr scene, uint node, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_depth(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_name(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_kind(IntPtr scene, uint node);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_visible(IntPtr scene, uint node);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_save_mesh(IntPtr scene, uint node,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, [MarshalAs(UnmanagedType.LPUTF8Str)] string format);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_scene_save(IntPtr scene,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, [MarshalAs(UnmanagedType.LPUTF8Str)] string format);
    [DllImport(Lib)] internal static extern uint cadaclysm_mesh_format_count();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_mesh_format(uint index);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_mesh_format_extension(uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_query(IntPtr scene,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string filter, [Out] uint[]? outArr, uint capacity);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_pick_file(IntPtr window);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_id(IntPtr scene, uint node);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_color(IntPtr scene, uint node, [Out] float[] rgba);
    [DllImport(Lib)] internal static extern void cadaclysm_node_transform(IntPtr scene, uint node,
        [Out] double[] outMatrix);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_attribute_count(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawAttribute cadaclysm_node_attribute(IntPtr scene, uint node, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_placement_count(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_placement_geometry(IntPtr scene, uint placement);
    [DllImport(Lib)] internal static extern uint cadaclysm_placement_select(IntPtr scene, uint placement);
    [DllImport(Lib)] internal static extern void cadaclysm_placement_transform(IntPtr scene, uint placement,
        [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_can_mesh(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawMesh cadaclysm_node_mesh(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawSurfaces cadaclysm_node_surfaces(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern void cadaclysm_surface_matrix(IntPtr scene, [Out] float[] outMatrix);
    [DllImport(Lib)] internal static extern RawBounds cadaclysm_node_bounds(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_instance_of(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_select_as(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_generator(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_diagnostic_count(IntPtr scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_diagnostic(IntPtr scene, uint index);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_edges(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_curves(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_isocurves(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_realize_all(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_realized(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_realize_total(IntPtr scene);
    [DllImport(Lib)] internal static extern void cadaclysm_cancel(IntPtr scene);
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

    public unsafe ReadOnlySpan<float> Positions => _raw.Positions == IntPtr.Zero
        ? ReadOnlySpan<float>.Empty
        : new ReadOnlySpan<float>((void*)_raw.Positions, (int)(_raw.VertexCount * 3));

    public unsafe ReadOnlySpan<float> Normals => _raw.Normals == IntPtr.Zero
        ? ReadOnlySpan<float>.Empty
        : new ReadOnlySpan<float>((void*)_raw.Normals, (int)(_raw.VertexCount * 3));

    /// <summary>Two floats a vertex, not three. See the surface-parameterisation note on
    /// `CadaclysmMesh::uvs` in the header for what generates them and what does not.</summary>
    public unsafe ReadOnlySpan<float> Uvs => _raw.Uvs == IntPtr.Zero
        ? ReadOnlySpan<float>.Empty
        : new ReadOnlySpan<float>((void*)_raw.Uvs, (int)(_raw.VertexCount * 2));

    /// <summary>Four floats a vertex, RGBA -- present only for a body opened asking for
    /// per-vertex colour whose faces carry more than one between them.</summary>
    public unsafe ReadOnlySpan<float> Colours => _raw.Colors == IntPtr.Zero
        ? ReadOnlySpan<float>.Empty
        : new ReadOnlySpan<float>((void*)_raw.Colors, (int)(_raw.VertexCount * 4));

    public unsafe ReadOnlySpan<uint> Indices => _raw.Indices == IntPtr.Zero
        ? ReadOnlySpan<uint>.Empty
        : new ReadOnlySpan<uint>((void*)_raw.Indices, (int)_raw.IndexCount);

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

    /// <summary>`(VertexCount * 3)` floats, the runs end to end.</summary>
    public unsafe ReadOnlySpan<float> Positions => _raw.Positions == IntPtr.Zero
        ? ReadOnlySpan<float>.Empty
        : new ReadOnlySpan<float>((void*)_raw.Positions, (int)(_raw.VertexCount * 3));

    /// <summary>`(PolylineCount)` vertex counts saying where each run stops.</summary>
    public unsafe ReadOnlySpan<uint> Counts => _raw.Counts == IntPtr.Zero
        ? ReadOnlySpan<uint>.Empty
        : new ReadOnlySpan<uint>((void*)_raw.Counts, (int)_raw.PolylineCount);

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

    /// <summary>Its triangles, in their own frame, built now if they have not been -- or null
    /// for a node with no triangles (structure, or geometry drawn only as curves).</summary>
    /// <remarks>A property, not a method taking a tolerance: `cadaclysm_node_mesh` takes none,
    /// and neither does Python's `Node.mesh`. A property is also what this binding's own
    /// property-for-zero-argument transcription rule calls for.</remarks>
    public Mesh? Mesh
    {
        get
        {
            var raw = Native.cadaclysm_node_mesh(Scene.Handle, Index);
            return raw.IndexCount == 0 || raw.Positions == IntPtr.Zero ? null : new Mesh(Scene, raw);
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

    /// <summary>Its free curves, as polylines. A 2D drawing is all of these.</summary>
    public Polylines Curves => new(Scene, Native.cadaclysm_node_curves(Scene.Handle, Index));

    /// <summary>Its interior surface lines, as polylines -- distinct from <see cref="Edges"/>:
    /// those bound the faces, these rule across them.</summary>
    public Polylines Isocurves => new(Scene, Native.cadaclysm_node_isocurves(Scene.Handle, Index));

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
    private IntPtr _handle;
    private readonly string _label;

    internal Scene(IntPtr handle, string label, string? path, string? schemaPath, Convention convention)
    {
        _handle = handle;
        _label = label;
        Path = path;
        SchemaPath = schemaPath;
        Convention = convention;
    }

    /// <summary>The file this was read from -- null for a scene opened by
    /// <see cref="Cadaclysm.OpenMemory"/>, which has no file on disk to name.</summary>
    public string? Path { get; }

    /// <summary>The `.exp` actually used to open this, or null.</summary>
    public string? SchemaPath { get; }

    /// <summary>The convention this was opened with.</summary>
    /// <remarks>Named the same as the <see cref="Cadaclysm.Convention"/> type, which is legal
    /// in C# for the same reason <see cref="Node.Mesh"/> can share its name with the <see
    /// cref="Cadaclysm.Mesh"/> type -- member lookup and type lookup are separate.</remarks>
    public Convention Convention { get; }

    /// <summary>The raw handle, refusing to hand over a closed one -- every call in this file
    /// goes through here rather than touching the field directly, so a use-after-close raises
    /// a <see cref="CadaclysmException"/> at the call site instead of passing a dangling
    /// pointer into the library.</summary>
    internal IntPtr Handle => _handle != IntPtr.Zero
        ? _handle
        : throw new CadaclysmException($"{_label}: the scene is closed");

    public bool Closed => _handle == IntPtr.Zero;

    /// <summary>Give the scene back. Idempotent. Every borrowed <see cref="Mesh"/> and <see
    /// cref="Polylines"/> still held is reading freed memory afterwards.</summary>
    public void Close()
    {
        if (_handle == IntPtr.Zero) return;
        var handle = _handle;
        _handle = IntPtr.Zero;
        Native.cadaclysm_close(handle);
    }

    public void Dispose()
    {
        Close();
        GC.SuppressFinalize(this);
    }

    ~Scene()
    {
        if (_handle != IntPtr.Zero) Native.cadaclysm_close(_handle);
    }

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

    /// <summary>How many nodes <see cref="RealizeAll"/> has finished with. Safe to read from
    /// another thread.</summary>
    public uint Realized => Native.cadaclysm_realized(Handle);

    /// <summary>How many there will be in all -- zero until <see cref="RealizeAll"/> starts.
    /// </summary>
    public uint RealizeTotal => Native.cadaclysm_realize_total(Handle);

    /// <summary>Ask a running <see cref="RealizeAll"/> to stop. One-way, for the life of the
    /// scene.</summary>
    public void Cancel() => Native.cadaclysm_cancel(Handle);

    /// <summary>Write the whole scene to `path`: "glb", "gltf" or "obj" -- every placement of
    /// every shape, named and placed as the tree is, unlike <see cref="Node.SaveMesh"/> which
    /// writes one node's mesh on its own.</summary>
    public void Save(string path, string format = "glb")
    {
        if (!Native.cadaclysm_scene_save(Handle, path, format))
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

    /// <summary>Every format <see cref="Node.SaveMesh"/> writes.</summary>
    public static IReadOnlyList<MeshFormat> MeshFormats()
    {
        var count = Native.cadaclysm_mesh_format_count();
        var found = new List<MeshFormat>((int)count);
        for (uint i = 0; i < count; i++)
        {
            var name = Marshal.PtrToStringUTF8(Native.cadaclysm_mesh_format(i)) ?? "";
            var extension = Marshal.PtrToStringUTF8(Native.cadaclysm_mesh_format_extension(i)) ?? "";
            found.Add(new MeshFormat(name, extension, $"{name} (.{extension})"));
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

    private static IntPtr OpenNative(string path, string? schema, RawOpenOptions options)
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
            if (handle != IntPtr.Zero) return new Scene(handle, Path.GetFileName(path), path, schema, convention);
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
            if (handle != IntPtr.Zero) return new Scene(handle, Path.GetFileName(path), path, candidate, convention);
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
            IntPtr handle;
            fixed (byte* ptr = bytes)
            {
                handle = Native.cadaclysm_open_memory((IntPtr)ptr, (nuint)bytes.Length, format, ref options);
            }
            // As above: the library's own message alone; "open failed" only stands in when it left none.
            if (handle == IntPtr.Zero) throw new CadaclysmException($"{name}: {LastErrorOr("open failed")}");
            return new Scene(handle, name, null, schema, convention);
        }
        finally
        {
            if (list != IntPtr.Zero) Marshal.FreeCoTaskMem(list);
            if (text != IntPtr.Zero) Marshal.FreeCoTaskMem(text);
        }
    }
}
