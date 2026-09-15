// The cadaclysm C ABI, and nothing else: this file is the whole binding.
//
// Declared by hand from the published header, the way any .NET program would. No
// generated interop, no Rust, no build system — if this draws your node, so will your
// engine.
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Cadaclysm;

/// <summary>The coordinate space to open a file into — the header's
/// CadaclysmConvention.</summary>
/// <remarks>The library converts on the way out, so nothing here rotates anything: a
/// caller names the space it draws in and reads geometry already in it. Native keeps the
/// file's own axes and units, which is what every caller got before the parameter existed
/// and what this viewer still defaults to.</remarks>
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

/// <summary>The bits that ride in the same uint as a <see cref="Convention"/>.</summary>
public static class ConventionFlag
{
    /// <summary>Keep the preset's axes but the file's own units.</summary>
    /// <remarks>A packing of this binding's own now, not the ABI's: the library takes
    /// `file_units` as a field of `CadaclysmOpenOptions`, and <see cref="Cad.Open"/>
    /// unpacks this bit into it. It survives because the convention parser returns one
    /// integer and callers passing "unreal+file-units" expect that to keep working.</remarks>
    public const uint FileUnits = 0x100;

    /// <summary>CADACLYSM_UV_WORLD: ask for texture coordinates at world scale, which
    /// fills RawMesh.Uvs.</summary>
    /// <remarks>Off by default in the library and unused by this viewer, which draws no
    /// textures — it is here because the struct above has the field and a caller reaching
    /// for it needs the bit that fills it. What it turns on is <em>generating</em>
    /// coordinates from a surface's own parameters; a format that stores them is not
    /// gated by it.</remarks>
    public const uint UvWorld = 0x200;
}

[StructLayout(LayoutKind.Sequential)]
internal struct RawBounds
{
    public float MinX, MinY, MinZ;
    public float MaxX, MaxY, MaxZ;
}

// Field order must match the header's CadaclysmMesh exactly. Uvs sits between Normals
// and Indices, which is where the header puts it; a copy that leaves it out still
// compiles and still runs, and reads the null Uvs as Indices and the two halves of the
// real indices pointer as VertexCount and IndexCount.
//
// cadaclysm-capi/tests/bindings.rs now pins this against the header, by field order
// and by whether each field is a pointer. It does not pin the exact type, so float
// becoming double is still yours to get right.
[StructLayout(LayoutKind.Sequential)]
internal struct RawMesh
{
    public IntPtr Positions;
    public IntPtr Normals;
    public IntPtr Uvs;
    /// <summary>Four floats a vertex, RGBA — or null, which is the common case.
    /// Only a body the file painted in more than one colour, opened asking for
    /// them, carries any.</summary>
    public IntPtr Colors;
    public IntPtr Indices;
    public uint VertexCount;
    public uint IndexCount;
}

/// <summary>`CadaclysmOpenOptions`. `Size` is the contract for `cadaclysm_open`:
/// the library reads only the fields that fit inside it and defaults the rest.
/// But <see cref="Cad.Open"/> has `cadaclysm_open_options_init` fill the defaults,
/// and init writes the <em>whole</em> struct the library was built with (see the
/// header's note on it), so this must be at least as long as the header's or init
/// writes past the stack local — and it may never reorder.
/// `tests/bindings.rs` pins it against the header.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawOpenOptions
{
    public nuint Size;
    public uint Convention;
    public IntPtr Spec;
    // One byte in C, four in C# unless it is told otherwise. Every field after
    // this one would land at the wrong offset without the marshalling hint.
    [MarshalAs(UnmanagedType.I1)] public bool FileUnits;
    public uint Uvs;
    public uint Colors;
    // The header's spelling, not the file's: the pin in tests/bindings.rs matches
    // names letter for letter.
    public double SourceMetersPerUnit;
    public IntPtr Schemas;
    public nuint SchemaCount;
    public IntPtr SchemaText;
    public nuint SchemaLength;
    // The pick hook is not exposed here: `CadaclysmPick` is a function pointer
    // and both stay null, which takes the library's own choice among a zip's
    // members. They are declared because init writes them -- without these two
    // it wrote 16 bytes past the struct, which the Java binding showed up as
    // heap corruption on one open in three.
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
    public int Kind;        // enum CadaclysmValueKind
    public IntPtr Text;
    public long Integer;
    public double Real;
    [MarshalAs(UnmanagedType.I1)] public bool Boolean;
}

internal static class Native
{
    private const string Lib = "cadaclysm_capi";

    // The library sits in the Rust build directory, not beside this assembly, so point
    // the loader at it rather than making the caller arrange PATH. Anything else is left
    // to the default search, so a deployment that ships the library alongside the
    // executable works untouched.
    static Native()
    {
        NativeLibrary.SetDllImportResolver(typeof(Native).Assembly, (name, assembly, path) =>
        {
            if (name != Lib) return IntPtr.Zero;
            var files = new[] { $"{Lib}.dll", $"lib{Lib}.dylib", $"lib{Lib}.so" };
            // CADACLYSM_LIBRARY names the library or its directory; otherwise walk up from
            // this assembly: an SDK checkout keeps the library in `lib/`, the repository the
            // example ships in keeps it in `target/release`.
            var candidates = new List<string>();
            var env = Environment.GetEnvironmentVariable("CADACLYSM_LIBRARY");
            if (!string.IsNullOrEmpty(env))
            {
                if (Directory.Exists(env)) candidates.AddRange(files.Select(f => Path.Combine(env, f)));
                else candidates.Add(env);
            }
            for (var dir = Path.GetDirectoryName(assembly.Location); dir is not null; dir = Path.GetDirectoryName(dir))
            {
                candidates.AddRange(files.Select(f => Path.Combine(dir, "lib", f)));
                candidates.AddRange(files.Select(f => Path.Combine(dir, "target", "release", f)));
            }
            foreach (var candidate in candidates)
                if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var handle))
                    return handle;
            return IntPtr.Zero;
        });
    }

    [DllImport(Lib)] internal static extern IntPtr cadaclysm_last_error();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_version();
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_license_set([MarshalAs(UnmanagedType.LPUTF8Str)] string? textOrPath);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_license_info();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_build_date();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_open(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path,
        ref RawOpenOptions options);
    [DllImport(Lib)] internal static extern void cadaclysm_open_options_init(
        ref RawOpenOptions options);
    [DllImport(Lib)] internal static extern void cadaclysm_close(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_count(IntPtr scene);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_schema(IntPtr scene);
    [DllImport(Lib)] internal static extern double cadaclysm_metres_per_unit(IntPtr scene);
    [DllImport(Lib)] internal static extern RawBounds cadaclysm_bounds(IntPtr scene);
    [DllImport(Lib)] internal static extern void cadaclysm_node_transform(IntPtr scene, uint node, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_color(IntPtr scene, uint node, [Out] float[] rgba);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_node_can_mesh(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawMesh cadaclysm_node_mesh(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_edges(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_curves(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawPolylines cadaclysm_node_isocurves(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_realize_all(IntPtr scene);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_parent(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_depth(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_name(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_kind(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_id(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_node_generator(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_instance_of(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern uint cadaclysm_node_attribute_count(IntPtr scene, uint node);
    [DllImport(Lib)] internal static extern RawAttribute cadaclysm_node_attribute(IntPtr scene, uint node, uint index);
}

/// <summary>An open document. Dispose it when done; everything read out of it is copied,
/// so nothing borrows past that.</summary>
public sealed class Scene : IDisposable
{
    private IntPtr _handle;

    private Scene(IntPtr handle) => _handle = handle;

    public static string LastError() => Marshal.PtrToStringUTF8(Native.cadaclysm_last_error()) ?? "";

    /// <summary>The version of the library actually loaded, which is the one worth
    /// reporting.</summary>
    public static string Version() => Marshal.PtrToStringUTF8(Native.cadaclysm_version()) ?? "";

    /// <summary>Load a license: the certificate text, or the path of a file holding it.
    /// Without this the library looks in CADACLYSM_LICENSE, then for cadaclysm.lic beside
    /// the executable and in the working directory. False, with the reason in
    /// <see cref="LastError"/>, when the text does not verify; the previous license stays.</summary>
    public static bool LicenseSet(string? textOrPath) => Native.cadaclysm_license_set(textOrPath);
    /// <summary>One line about the license in use, or null (see <see cref="LastError"/>).</summary>
    public static string? LicenseInfo() => Marshal.PtrToStringUTF8(Native.cadaclysm_license_info());
    /// <summary>When the loaded library was built, YYYY-MM-DD.</summary>
    public static string BuildDate() => Marshal.PtrToStringUTF8(Native.cadaclysm_build_date()) ?? "";

    /// <summary>Open a file. <paramref name="schema"/> is the EXPRESS schema STEP and IFC
    /// need and every other format ignores; null for none.</summary>
    /// <param name="convention">The space to read the file into: a <see cref="Convention"/>,
    /// optionally OR'd with the bits in <see cref="ConventionFlag"/>. The library does the
    /// converting, so every array read out of the scene is already in it and there is
    /// nothing left for the caller to rotate or scale. An unrecognised value fails the open
    /// rather than falling back to Native, so a bad cast cannot pass for success.</param>
    public static Scene? Open(string path, string? schema, uint convention = (uint)Convention.Native)
    {
        var options = new RawOpenOptions();
        Native.cadaclysm_open_options_init(ref options);
        options.Convention = convention & ~(ConventionFlag.FileUnits | ConventionFlag.UvWorld);
        options.FileUnits = (convention & ConventionFlag.FileUnits) != 0;
        options.Uvs = (convention & ConventionFlag.UvWorld) != 0 ? 1u : 0u;
        // The array has to outlive the call, and a `string[]` marshalled in
        // place would not: allocate it, point at it, free it after.
        IntPtr list = IntPtr.Zero, text = IntPtr.Zero;
        if (schema is not null)
        {
            text = Marshal.StringToCoTaskMemUTF8(schema);
            list = Marshal.AllocCoTaskMem(IntPtr.Size);
            Marshal.WriteIntPtr(list, text);
            options.Schemas = list;
            options.SchemaCount = 1;
        }
        try
        {
            var handle = Native.cadaclysm_open(path, ref options);
            return handle == IntPtr.Zero ? null : new Scene(handle);
        }
        finally
        {
            if (list != IntPtr.Zero) { Marshal.FreeCoTaskMem(list); }
            if (text != IntPtr.Zero) { Marshal.FreeCoTaskMem(text); }
        }
    }

    public void Dispose()
    {
        if (_handle != IntPtr.Zero) { Native.cadaclysm_close(_handle); _handle = IntPtr.Zero; }
    }

    public uint NodeCount => Native.cadaclysm_node_count(_handle);
    public string Schema => Marshal.PtrToStringUTF8(Native.cadaclysm_schema(_handle)) ?? "";
    public double MetresPerUnit => Native.cadaclysm_metres_per_unit(_handle);
    public bool CanMesh(uint node) => Native.cadaclysm_node_can_mesh(_handle, node);

    /// <summary>Tessellate every node up front, across threads, and say how many were
    /// built.</summary>
    /// <remarks>Asking node by node instead meshes them one at a time on one core, because
    /// the reader is lazy and each mesh call realizes only the node it is asked about. On a
    /// large STEP file that is the difference between a demo and a wait.</remarks>
    public uint RealizeAll() => Native.cadaclysm_realize_all(_handle);

    public (float[] Min, float[] Max) Bounds()
    {
        var b = Native.cadaclysm_bounds(_handle);
        return (new[] { b.MinX, b.MinY, b.MinZ }, new[] { b.MaxX, b.MaxY, b.MaxZ });
    }

    /// <summary>Where a node's own frame sits in the world, column-major as OpenGL writes
    /// it.</summary>
    public double[] Transform(uint node)
    {
        var m = new double[16];
        Native.cadaclysm_node_transform(_handle, node, m);
        return m;
    }

    /// <summary>The colour the file gave a node, or null where it gave none. A node with no
    /// colour is the caller's to decide about — see Program.Unstyled.</summary>
    public float[]? Color(uint node)
    {
        var rgba = new float[4];
        return Native.cadaclysm_node_color(_handle, node, rgba) ? rgba : null;
    }

    /// <summary>A node's triangles, copied out, in the node's own frame.</summary>
    /// <remarks><c>Uvs</c> is two floats a vertex where the other two arrays are three,
    /// and null for a node whose reader produced none — which is most of them unless the
    /// scene was opened with <see cref="ConventionFlag.UvWorld"/>.</remarks>
    public (float[] Positions, float[]? Normals, float[]? Uvs, uint[] Indices)? Mesh(uint node)
    {
        var m = Native.cadaclysm_node_mesh(_handle, node);
        if (m.IndexCount == 0 || m.Positions == IntPtr.Zero) return null;
        var n = (int)m.VertexCount * 3;
        var positions = new float[n];
        Marshal.Copy(m.Positions, positions, 0, n);
        float[]? normals = null;
        if (m.Normals != IntPtr.Zero)
        {
            normals = new float[n];
            Marshal.Copy(m.Normals, normals, 0, n);
        }
        float[]? uvs = null;
        if (m.Uvs != IntPtr.Zero)
        {
            uvs = new float[(int)m.VertexCount * 2];
            Marshal.Copy(m.Uvs, uvs, 0, uvs.Length);
        }
        var indices = new uint[m.IndexCount];
        // Marshal.Copy has no uint overload; the bits are the same either way.
        var signed = new int[m.IndexCount];
        Marshal.Copy(m.Indices, signed, 0, (int)m.IndexCount);
        Buffer.BlockCopy(signed, 0, indices, 0, signed.Length * sizeof(int));
        return (positions, normals, uvs, indices);
    }

    /// <summary>A node's feature edges, or its free curves, as runs of points.</summary>
    public (float[] Positions, uint[] Counts)? Polylines(uint node, bool edges)
    {
        var p = edges
            ? Native.cadaclysm_node_edges(_handle, node)
            : Native.cadaclysm_node_curves(_handle, node);
        if (p.VertexCount == 0 || p.Positions == IntPtr.Zero) return null;
        var positions = new float[(int)p.VertexCount * 3];
        Marshal.Copy(p.Positions, positions, 0, positions.Length);
        var signed = new int[p.PolylineCount];
        Marshal.Copy(p.Counts, signed, 0, signed.Length);
        var counts = new uint[p.PolylineCount];
        Buffer.BlockCopy(signed, 0, counts, 0, signed.Length * sizeof(int));
        return (positions, counts);
    }

    /// <summary>A node's isocurves — the interior isoparametric lines across a curved
    /// face, which a flat face draws as its own outline instead.</summary>
    public (float[] Positions, uint[] Counts)? Isocurves(uint node)
    {
        var p = Native.cadaclysm_node_isocurves(_handle, node);
        if (p.VertexCount == 0 || p.Positions == IntPtr.Zero) return null;
        var positions = new float[(int)p.VertexCount * 3];
        Marshal.Copy(p.Positions, positions, 0, positions.Length);
        var signed = new int[p.PolylineCount];
        Marshal.Copy(p.Counts, signed, 0, signed.Length);
        var counts = new uint[p.PolylineCount];
        Buffer.BlockCopy(signed, 0, counts, 0, signed.Length * sizeof(int));
        return (positions, counts);
    }

    /// <summary>What the ABI returns for "no such node": UINT32_MAX, CADACLYSM_NONE.</summary>
    private const uint None = uint.MaxValue;

    public uint? Parent(uint node)
    {
        var p = Native.cadaclysm_node_parent(_handle, node);
        return p == None ? null : p;
    }

    /// <summary>How far down the tree a node sits, a root being zero. For indenting.</summary>
    public uint Depth(uint node) => Native.cadaclysm_node_depth(_handle, node);

    public string Name(uint node) => Marshal.PtrToStringUTF8(Native.cadaclysm_node_name(_handle, node)) ?? "";
    public string Kind(uint node) => Marshal.PtrToStringUTF8(Native.cadaclysm_node_kind(_handle, node)) ?? "";
    public string Id(uint node) => Marshal.PtrToStringUTF8(Native.cadaclysm_node_id(_handle, node)) ?? "";

    /// <summary>
    /// What a node's geometry was before it was triangles — "brep", "mesh", "csg". Empty for
    /// a node that draws nothing, there being no geometry to have come from anything.
    /// </summary>
    public string Generator(uint node) =>
        Marshal.PtrToStringUTF8(Native.cadaclysm_node_generator(_handle, node)) ?? "";

    public uint? InstanceOf(uint node)
    {
        var p = Native.cadaclysm_node_instance_of(_handle, node);
        return p == None ? null : p;
    }

    /// <summary>One thing the file said about a node, rendered as text.</summary>
    public readonly record struct Attribute(string Name, string Value);

    public Attribute[] Attributes(uint node)
    {
        var count = Native.cadaclysm_node_attribute_count(_handle, node);
        var out_ = new List<Attribute>((int)count);
        for (uint i = 0; i < count; i++)
        {
            var a = Native.cadaclysm_node_attribute(_handle, node, i);
            if (a.Name == IntPtr.Zero) continue;
            // The kinds, in the header's declaration order: none, text, integer, real,
            // boolean, list, reference. List and reference both arrive already rendered
            // into `text`, same as text itself.
            var value = a.Kind switch
            {
                2 => a.Integer.ToString(),
                3 => FormatReal(a.Real),
                // Not `a.Boolean.ToString()`: that gives "True"/"False", where cadaclysm's
                // own `Display for Value` in Rust — the reference every client here matches
                // — gives lowercase "true"/"false", same as Go and Java already do.
                4 => a.Boolean ? "true" : "false",
                _ => Marshal.PtrToStringUTF8(a.Text) ?? "",
            };
            out_.Add(new Attribute(Marshal.PtrToStringUTF8(a.Name) ?? "", value));
        }
        return out_.ToArray();
    }

    /// <summary>
    /// A real the same way cadaclysm's own <c>Display for Value</c> renders it in Rust: the
    /// shortest decimal that round-trips, never forcing a trailing <c>.0</c>, and never in
    /// exponent notation for any magnitude a CAD property plausibly holds.
    /// </summary>
    /// <remarks>
    /// <c>double.ToString("G")</c> already gives the shortest round-tripping digits, and
    /// never adds a spurious <c>.0</c> — but it switches to scientific notation outside
    /// roughly <c>1e-4..1e17</c>, and an IFC geometric-context precision of <c>1e-5</c> — a
    /// real value this project's own sample files carry — is well inside what a CAD property
    /// plausibly holds. Where Rust prints <c>0.00001</c>, "G" prints <c>1E-05</c>. This
    /// expands that scientific form back to fixed notation, digit for digit, without adding
    /// or losing precision.
    /// </remarks>
    private static string FormatReal(double value)
    {
        if (double.IsNaN(value)) return "NaN";
        if (double.IsPositiveInfinity(value)) return "inf";
        if (double.IsNegativeInfinity(value)) return "-inf";
        var s = value.ToString("G", CultureInfo.InvariantCulture);
        var e = s.IndexOfAny(new[] { 'E', 'e' });
        if (e < 0) return s; // already fixed notation
        var negative = s[0] == '-';
        var body = negative ? s.Substring(1) : s;
        e = body.IndexOfAny(new[] { 'E', 'e' });
        var mantissa = body.Substring(0, e);
        var exponent = int.Parse(body.Substring(e + 1), CultureInfo.InvariantCulture);
        var dot = mantissa.IndexOf('.');
        var digits = dot < 0 ? mantissa : mantissa.Remove(dot, 1);
        var pointPos = (dot < 0 ? mantissa.Length : dot) + exponent;
        var result = pointPos <= 0 ? "0." + new string('0', -pointPos) + digits
            : pointPos >= digits.Length ? digits + new string('0', pointPos - digits.Length)
            : digits.Substring(0, pointPos) + "." + digits.Substring(pointPos);
        return negative ? "-" + result : result;
    }
}
