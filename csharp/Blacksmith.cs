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
// It shares `Cad.cs`'s loader: point `CADACLYSM_LIBRARY` at the directory holding both
// libraries (or `CADACLYSM_BLACKSMITH_LIBRARY` at this one, as Python's kernel module reads
// it) if they are not where the loader looks by default.
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

// ---- the structs the ABI returns by value ----------------------------------------------
//
// These three are transcribed from `cadaclysm_blacksmith.h` by hand, in the header's field
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

// ---- the library ----------------------------------------------------------------------

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
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_rect(double w, double h);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_circle(double r);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_slot(double cx, double cy, double length, double r);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_polygon(double[] xy, nuint count);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_with_hole(ProfileHandle outer, ProfileHandle hole);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_translate_profile(ProfileHandle profile, double dx, double dy);
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
    internal static extern bool cadaclysm_blacksmith_slant_of_plane(double[] frame, double[] point, double[] normal,
        [Out] double[] outSlant);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_loft(ProfileHandle a, double[] frameA, ProfileHandle b,
        double[] frameB);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_loft_open(ProfileHandle a, double[] frameA, ProfileHandle b,
        double[] frameB);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_revolve(ProfileHandle profile, double[] axis, double angle);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_revolve_open(ProfileHandle profile, double[] axis, double angle);
    [DllImport(Lib)] internal static extern SweepPathHandle cadaclysm_blacksmith_sweep_path_begin(double x, double y, double z);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sweep_path_line_to(SweepPathHandle p, double x, double y, double z);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sweep_path_arc(SweepPathHandle p, double cx, double cy, double cz, double ax,
        double ay, double az, double angle);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_sweep_path_free(IntPtr p);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_sweep(ProfileHandle profile, double[] frame, SweepPathHandle path);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_sweep_open(ProfileHandle profile, double[] frame,
        SweepPathHandle path);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude_faces(SolidHandle sheet, double height);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_place(SolidHandle solid, double[] frame);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_translate(SolidHandle solid, double dx, double dy, double dz);
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
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_fillet(SolidHandle solid, uint[] edges, nuint count,
        double radius, double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_chamfer(SolidHandle solid, uint[] edges, nuint count,
        double distance, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_shell(SolidHandle solid, double thickness, uint[] openFaces,
        nuint count, double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_face_count(SolidHandle solid);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_select_face(SolidHandle solid, uint kind, double[]? v, uint index);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_face_frame(SolidHandle solid, uint face, [Out] double[] outFrame);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_face_kind(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_edge_count(SolidHandle solid);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge(SolidHandle solid, uint i, out RawBlacksmithEdge outEdge);
    [DllImport(Lib)] internal static extern RawBlacksmithMesh cadaclysm_blacksmith_mesh(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern RawBlacksmithPolylines cadaclysm_blacksmith_edge_polylines(SolidHandle solid, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_bounds(SolidHandle solid, double tolerance, [Out] double[] min, [Out] double[] max);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_leaked_edges(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_unpaired_edges(SolidHandle solid, double tolerance);
    // The one array of handles the ABI takes: the marshaller cannot ref-count an array of
    // SafeHandles, so `WriteStepText` passes the raw pointers and keeps the owners alive
    // itself, across the call, with `GC.KeepAlive`.
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_step(IntPtr[] solids, nuint count,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string schema, uint unit);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_string_free(IntPtr s);
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
    /// library.</summary>
    public static string DefaultSchema()
    {
        var candidates = new List<string>();
        var env = Environment.GetEnvironmentVariable("CADACLYSM_SCHEMAS");
        if (!string.IsNullOrEmpty(env)) candidates.Add(System.IO.Path.Combine(env, "ap203.exp"));
        // Python takes the repository root as a fixed number of parents above its own file;
        // this assembly sits under a bin/ directory of varying depth, so every ancestor is
        // tried -- the SDK layout and this repository's both keep `schemas/` at the top.
        var assembly = Assembly.GetExecutingAssembly().Location;
        for (var dir = System.IO.Path.GetDirectoryName(assembly); dir is not null; dir = System.IO.Path.GetDirectoryName(dir))
            candidates.Add(System.IO.Path.Combine(dir, "schemas", "ap203.exp"));
        foreach (var candidate in candidates)
            if (File.Exists(candidate)) return candidate;
        throw new BuildException("ap203.exp not found; pass schema (a path or the schema's text)");
    }

    /// <summary>Several solids as one AP203 part file's text, each its own body.</summary>
    /// <param name="schema">Null for the default lookup, the path of an `.exp`, or the
    /// schema's own text.</param>
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

    /// <summary>Several solids as one AP203 file, each its own body.</summary>
    public static void WriteStep(string path, IEnumerable<Solid> solids, string? schema = null, string unit = "mm") =>
        File.WriteAllText(path, WriteStepText(solids, schema, unit), new UTF8Encoding(false));

    /// <summary>`schema` is null (the default lookup), a path, or the schema's text.</summary>
    private static string SchemaText(string? schema)
    {
        schema ??= DefaultSchema();
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
    internal static T Checked<T>(T handle, string what) where T : CadaclysmHandle =>
        !handle.IsInvalid ? handle : throw Failure(what);

    private static double[] Doubles(double[]? values, int count, string what)
    {
        var got = values?.Length ?? 0;
        if (values is null || got != count) throw new BuildException($"{what}: expected {count} numbers, got {got}");
        return values;
    }

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

    /// <summary>A closed polygon through `points`, in order; the closing side is implied.
    /// </summary>
    public static Profile Polygon(IEnumerable<(double X, double Y)> points)
    {
        var flat = points.SelectMany(p => new[] { p.X, p.Y }).ToArray();
        return new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_polygon(flat, (nuint)(flat.Length / 2)));
    }

    /// <summary>Start drawing an outline at `start`, a segment at a time (the `Path` builder).
    /// </summary>
    public static Path Path((double X, double Y) start) => new(start);

    /// <summary>This outline with `hole` cut from it, as a new profile; both inputs are
    /// untouched.</summary>
    public Profile WithHole(Profile hole) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_with_hole(Handle, hole.Handle));

    /// <summary>This outline shifted by (`dx`, `dy`) in its own plane.</summary>
    public Profile Translate(double dx, double dy) =>
        new(BlacksmithNative.cadaclysm_blacksmith_translate_profile(Handle, dx, dy));
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

    /// <summary>A NURBS segment. `control`: every control point after the current one, the
    /// endpoint last; `weights`: one per control point <em>including</em> the current one, or
    /// null; `knots`: the full repeated knot vector.</summary>
    public Path NurbsTo(IEnumerable<(double X, double Y)> control, IEnumerable<double> knots, uint degree,
        IEnumerable<double>? weights = null)
    {
        var flat = control.SelectMany(p => new[] { p.X, p.Y }).ToArray();
        var k = knots.ToArray();
        var w = weights?.ToArray();
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

    /// <summary>`profile` swung `angle` radians about `axis` (six numbers: a point and a
    /// direction).</summary>
    public static Solid Revolve(Profile profile, double[] axis, double angle) =>
        new(BlacksmithNative.cadaclysm_blacksmith_revolve(profile.Handle, Blacksmith.AxisOf(axis), angle));

    public static Solid RevolveOpen(Profile profile, double[] axis, double angle) =>
        new(BlacksmithNative.cadaclysm_blacksmith_revolve_open(profile.Handle, Blacksmith.AxisOf(axis), angle));

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

    /// <summary>Every face of this sheet pushed `height` along its own normal, walled and
    /// closed: the sheet as a solid of that thickness.</summary>
    public Solid ExtrudeFaces(double height) => new(BlacksmithNative.cadaclysm_blacksmith_extrude_faces(Handle, height));

    /// <summary>This solid, built about the origin, moved onto `frame`.</summary>
    public Solid Place(double[] frame) => new(BlacksmithNative.cadaclysm_blacksmith_place(Handle, Blacksmith.Frame(frame)));

    public Solid Translate(double dx, double dy, double dz) =>
        new(BlacksmithNative.cadaclysm_blacksmith_translate(Handle, dx, dy, dz));

    /// <summary>This solid turned `radians` about `axis` (six numbers: a point and a
    /// direction).</summary>
    public Solid Rotate(double[] axis, double radians) =>
        new(BlacksmithNative.cadaclysm_blacksmith_rotate(Handle, Blacksmith.AxisOf(axis), radians));

    /// <summary>This solid reflected across `plane` (a frame; its z is the plane's normal).
    /// </summary>
    public Solid Mirror(double[] plane) => new(BlacksmithNative.cadaclysm_blacksmith_mirror(Handle, Blacksmith.Frame(plane)));

    // -- combining

    public Solid Join(Solid other, double tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_join(Handle, other.Handle, tolerance, IntPtr.Zero, IntPtr.Zero));

    public Solid Cut(Solid other, double tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_cut(Handle, other.Handle, tolerance, IntPtr.Zero, IntPtr.Zero));

    public Solid Common(Solid other, double tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_common(Handle, other.Handle, tolerance, IntPtr.Zero, IntPtr.Zero));

    /// <summary>This solid (a sheet or a solid) cut along `tool`'s boundary, nothing removed:
    /// every face comes back in its pieces outside `tool` and its pieces inside, each piece a
    /// face, in this solid's own face order with each face's outside pieces before its inside
    /// pieces. `tool` must be a closed solid. There is no way yet, from here or the C ABI, to
    /// build a new solid from a chosen subset of a result's faces: this only cuts.</summary>
    public Solid SplitSheet(Solid tool, double tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_split_sheet(Handle, tool.Handle, tolerance, IntPtr.Zero, IntPtr.Zero));

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

    // -- out

    /// <summary>The triangles at `tolerance`, as views into the solid's cache. See the file
    /// header for what invalidates them.</summary>
    public BlacksmithMesh Mesh(double tolerance = 0.05)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_mesh(Handle, tolerance);
        if (raw.Positions == IntPtr.Zero) throw Blacksmith.Failure("mesh");
        return new BlacksmithMesh(this, tolerance, Filled(tolerance), raw);
    }

    /// <summary>The feature edges as polylines, views into the same cache as
    /// <see cref="Mesh"/>.</summary>
    public BlacksmithPolylines EdgePolylines(double tolerance = 0.05)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_edge_polylines(Handle, tolerance);
        if (raw.Offsets == IntPtr.Zero) throw Blacksmith.Failure("edge_polylines");
        return new BlacksmithPolylines(this, tolerance, Filled(tolerance), raw);
    }

    /// <summary>This solid as AP203 STEP text; see <see cref="Blacksmith.WriteStepText"/>.
    /// </summary>
    public string StepText(string? schema = null, string unit = "mm") => Blacksmith.WriteStepText(new[] { this }, schema, unit);

    /// <summary>This solid written as an AP203 STEP file.</summary>
    public void Step(string path, string? schema = null, string unit = "mm") =>
        File.WriteAllText(path, StepText(schema, unit), new UTF8Encoding(false));

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
                found.Add(new Edge((int)i, Blacksmith.Text(raw.Kind), faces, segments));
            }
            return found;
        }
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

    /// <summary>This solid hollowed to a wall `thickness` thick (inward for a positive
    /// thickness, outward for a negative one), with the faces at `open` removed so the hollow
    /// is reachable.</summary>
    public Solid Shell(double thickness, IEnumerable<int>? open = null, double tolerance = 1e-6)
    {
        var which = Indices(open ?? Array.Empty<int>());
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_shell(Handle, thickness, which, (nuint)which.Length, tolerance,
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary>This solid as a reader <see cref="Scene"/>, through STEP text and
    /// <see cref="global::Cadaclysm.Cadaclysm.OpenMemory"/> -- the door to the viewer and the
    /// tree walk. Needs the reader's library built beside this one.</summary>
    /// <param name="schema">The path of the `.exp` to write and read with; null for
    /// <see cref="Blacksmith.DefaultSchema"/>. A path, not text: the reader's open takes
    /// one.</param>
    public Scene ToScene(string? schema = null)
    {
        var schemaPath = schema ?? Blacksmith.DefaultSchema();
        var bytes = Encoding.UTF8.GetBytes(StepText(schemaPath));
        return global::Cadaclysm.Cadaclysm.OpenMemory(bytes, "solid.stp", "stp", schema: schemaPath);
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

/// <summary>One edge of a solid, as plain data: its index (what <see cref="Solid.Fillet"/>
/// takes), the curve kind, the faces meeting on it, and its segments' ends.</summary>
public readonly struct Edge
{
    public int Index { get; }

    /// <summary>"line", "circle", "ellipse", "nurbs" or "other".</summary>
    public string Kind { get; }

    /// <summary>The faces that meet on it, in the solid's face order.</summary>
    public int[] Faces { get; }

    /// <summary>The two ends of each trim piece of the edge, three doubles each.</summary>
    public (double[] A, double[] B)[] Segments { get; }

    public Edge(int index, string kind, int[] faces, (double[] A, double[] B)[] segments)
    {
        Index = index;
        Kind = kind;
        Faces = faces;
        Segments = segments;
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
