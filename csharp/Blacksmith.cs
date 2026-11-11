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
// ## Every mesh view owns its own tessellation
//
// `Solid.Mesh`, `Solid.Mesh64` and `Solid.EdgePolylines` hand back `ReadOnlySpan<T>` views into
// the library's own memory, as the reader's `Mesh` does -- but not into the solid's cache.
// Each call takes out a *held* tessellation of its own (`cadaclysm_blacksmith_tessellation`)
// and the view keeps that handle alive, so disposing the solid or meshing it again at another
// tolerance -- through `Mesh`, `Mesh64`, `EdgePolylines` or `BoundsAt` -- never touches a view
// already in hand: nothing about it goes stale. Only the view itself going unreachable frees
// its handle, same as `FemMesh` below. A span **asked for** afterwards throws
// `ObjectDisposedException`; one already in hand goes on reading the freed block and hands back
// plausible numbers, a `ReadOnlySpan<T>` having nothing left to check once it is made -- so
// `GC.KeepAlive` the view while a span cut from it is still in use. `Copy()` gives memory of
// your own, safe to outlive the view. Strings are copied on the way out and are always safe.
// A view pins its *whole* tessellation -- positions, normals, indices, edges, face counts, in
// both precisions -- not just the array you asked for, until the view itself is disposed or
// collected; release waits for the garbage collector unless you `Dispose()` it yourself. For
// data that must outlive the view, `Copy()` it and drop the view.
//
// `FemMesh` is the one array product that is **not** the solid's, and never was: `Solid.FemMesh(..)`
// hands back a handle of its own, and its spans belong to that handle: neither the solid's dispose
// nor meshing it again touches them, and only `FemMesh.Free()` -- or the `using` that runs it, or
// the handle going unreachable -- invalidates them. `ToArray()` anything that must outlive the
// handle.
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
// ## Tolerances
//
// Every default above stays what it is: `Join(a, b)` still means `0.05`. Passing a null (or 0)
// `tolerance` to a verb that takes a distance tolerance -- a boolean, fillet, shell, split,
// section, hit test, mesh, curve fit or profile verb -- opts into the model's own:
// `Blacksmith.EffectiveTolerance(solids)`, the larger of the loosest absolute tolerance the
// inputs declare and the option `tolerance.relative` (default `1e-4`) times their size. A solid
// declares what its file said (`Solid.Tolerances`, null for what it did not say; `Scene.Tolerances`
// is the file's), every verb's result inherits the loosest of its inputs', and
// `Solid.WithTolerances` sets it. `tolerance.angular` (default one degree) stands in where
// nothing declares an angle.
//
// ## Ownership
//
// `Profile`, `Path`, `SweepPath`, `Solid`, `Tool`, `Stock`, `Job` and `Document` own a C handle, held in
// a `SafeHandle` (see `CadaclysmHandle` in `Cad.cs`): dispose them (a `using`), or let the
// runtime free them. Every entry point takes the `SafeHandle` itself, so the marshaller keeps
// an operand alive for the length of the call it is read in --
// `Solid.Cuboid(..).Join(Solid.Cylinder(..))` is safe with the cylinder nobody's.
// `Workplane`, `Selector`, `Slant`, `Edge` and `Axis` are plain values, and `Program`,
// `Operation`, `Report` and `ReportItem` are copied out. A call on a disposed object throws
// `ObjectDisposedException`. Python's `Solid.close()`/`SweepPath.close()` are `Dispose()`
// here, as is the freeing Python's `Job.__del__` does. The progress callbacks Python's
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
    public BuildException(string message, IEnumerable<uint>? ids = null) : base(message)
    {
        Ids = ids is null ? Array.Empty<uint>() : ids.ToArray();
    }

    /// <summary>The ids a refusal names (the sketcher's: the constraints a new constraint, value or
    /// reference conflicts with, the entities still using a point); empty when it names none.</summary>
    public IReadOnlyList<uint> Ids { get; }
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

/// <summary>A colour <see cref="SvgOptions.Stroke"/>/<see cref="SvgOptions.Background"/> take:
/// colour text -- `"#rgb"`, `"#rrggbb"` or a CSS colour name, any case -- or a packed
/// `0xRRGGBB` number, each converted implicitly, so `Stroke = "navy"` and `Stroke = 0x000080`
/// both compile. Text is read by the kernel library's own parser when the drawing is made;
/// text it refuses, or a number past `0xFFFFFF`, throws <see cref="BuildException"/> naming the
/// field. The reader's `Cadaclysm.SvgColour` twin, kept separate because this file is the
/// whole kernel binding on its own.</summary>
public readonly struct SvgColour : IEquatable<SvgColour>
{
    private SvgColour(string? text, long packed) { Text = text; Number = packed; }

    /// <summary>The colour text given, or null for a number.</summary>
    public string? Text { get; }

    /// <summary>The packed number given; meaningless when <see cref="Text"/> is set.</summary>
    public long Number { get; }

    public static implicit operator SvgColour(string text) => new(text ?? throw new ArgumentNullException(nameof(text)), 0);
    public static implicit operator SvgColour(uint packed) => new(null, packed);
    public static implicit operator SvgColour(int packed) => new(null, packed);

    /// <summary>`0xRRGGBB`, through the kernel's parser for text; <paramref name="what"/>
    /// names the field in a refusal.</summary>
    internal uint Packed(string what)
    {
        if (Text is null)
        {
            if (Number < 0 || Number > 0xFFFFFF)
                throw new BuildException($"{what}: a packed colour is 0x000000..0xFFFFFF, not 0x{Number:X}");
            return (uint)Number;
        }
        var rgb = new double[3];
        if (!BlacksmithNative.cadaclysm_blacksmith_parse_colour(Text, rgb))
            throw new BuildException($"{what}: a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or 0xRRGGBB, not '{Text}'");
        return ((uint)Math.Round(rgb[0] * 255) << 16) | ((uint)Math.Round(rgb[1] * 255) << 8) | (uint)Math.Round(rgb[2] * 255);
    }

    public bool Equals(SvgColour other) => Text == other.Text && (Text is not null || Number == other.Number);
    public override bool Equals(object? obj) => obj is SvgColour other && Equals(other);
    public override int GetHashCode() => Text is null ? Number.GetHashCode() : Text.GetHashCode();
    public override string ToString() => Text ?? $"0x{Number:X6}";
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

    /// <summary>The pen colour: `"#rgb"`, `"#rrggbb"`, a CSS colour name or a packed `0xRRGGBB`
    /// (a <see cref="SvgColour"/>). Default black.</summary>
    public SvgColour Stroke { get; set; } = "#000000";

    /// <summary>The pen's width, page units. Default 1.</summary>
    public double StrokeWidth { get; set; } = 1.0;

    /// <summary>`"#rgb"`, `"#rrggbb"`, a CSS colour name or a packed `0xRRGGBB` (a <see
    /// cref="SvgColour"/>) -- `Background = "navy"` or `Background = 0x000080` -- or null (the
    /// default) for no `&lt;rect&gt;` behind the drawing.</summary>
    public SvgColour? Background { get; set; }

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

    /// <summary>Also draw where each solid's surfaces turn away from the eye -- the outline a
    /// sphere has no edge for. One group per solid, after that solid's lines. Default true: a
    /// sphere's and a torus's only curves are the seams where their one face meets itself,
    /// which are not edges of the body and are never drawn, so without this those two draw a
    /// blank page. A line set in its own right -- set it with <see cref="Edges"/> false for the
    /// outline alone, or clear it for the lines alone.</summary>
    public bool Silhouettes { get; set; } = true;
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

/// <summary>`CadaclysmBlacksmithMassProperties`: what a body measures, per unit density, each
/// figure beside a bound on its own error. The volume, the centroid and the inertia mean something
/// only where <c>Closed</c> is 1, and are zero otherwise; the area is measured either way. The
/// arrays are marshalled by value, laid out inline as C lays them -- without <c>ByValArray</c> the
/// marshaller puts a pointer where C has the numbers and reads somebody else's memory.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithMassProperties
{
    public int Closed;
    public int Inverted;
    public int AccuracyMet;
    public int FromMesh;
    public double Area;
    public double AreaError;
    public double Volume;
    public double VolumeError;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public double[] Centroid;
    public double CentroidError;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 9)] public double[] Inertia;
    public double InertiaError;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)] public double[] PrincipalMoments;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 9)] public double[] PrincipalAxes;
}

/// <summary>What a solid measures, per unit density, each figure beside a bound on its own error.
///
/// <para>Per unit density is the primitive: a body's weight is <c>density * Volume</c> and its
/// inertia scales the same way, so <see cref="Weight"/> is the only figure that takes one. Nothing
/// here multiplies by a density on your behalf -- an assembly of two materials would have to undo
/// it.</para>
///
/// <para><c>Volume</c>, <c>Centroid</c>, <c>Inertia</c> and <c>PrincipalMoments</c> mean something
/// only where <c>Closed</c>. Where <c>AccuracyMet</c> is false the refinement stopped before the
/// accuracy asked for: the figures are honest, they are simply less certain, and the errors say by
/// how much.</para></summary>
public readonly struct Mass
{
    /// <summary>Closed, so the volume-side figures mean something.</summary>
    public bool Closed { get; }
    /// <summary>Every face pointed inward; the figures are given as if they had not.</summary>
    public bool Inverted { get; }
    /// <summary>Every error came under the accuracy asked for.</summary>
    public bool AccuracyMet { get; }
    /// <summary>Measured on a mesh rather than exact surfaces, so the errors are the rounding floor.</summary>
    public bool FromMesh { get; }
    /// <summary>The surface area.</summary>
    public double Area { get; }
    /// <summary>A bound on <c>Area</c>'s own error.</summary>
    public double AreaError { get; }
    /// <summary>The volume enclosed, where <c>Closed</c>.</summary>
    public double Volume { get; }
    /// <summary>A bound on <c>Volume</c>'s own error.</summary>
    public double VolumeError { get; }
    /// <summary>The volume's centroid, where <c>Closed</c>.</summary>
    public double[] Centroid { get; }
    /// <summary>A bound on the distance from <c>Centroid</c> to the true centroid.</summary>
    public double CentroidError { get; }
    /// <summary>Three rows of three about the centroid, products of inertia negated.</summary>
    public double[][] Inertia { get; }
    /// <summary>A bound on every entry of <c>Inertia</c>.</summary>
    public double InertiaError { get; }
    /// <summary>Ascending.</summary>
    public double[] PrincipalMoments { get; }
    /// <summary>Unit, orthogonal, right-handed; row <c>i</c> belongs to moment <c>i</c>.</summary>
    public double[][] PrincipalAxes { get; }

    internal Mass(RawBlacksmithMassProperties raw)
    {
        static double[][] Rows(double[] flat) => new[]
        {
            new[] { flat[0], flat[1], flat[2] },
            new[] { flat[3], flat[4], flat[5] },
            new[] { flat[6], flat[7], flat[8] },
        };
        Closed = raw.Closed != 0;
        Inverted = raw.Inverted != 0;
        AccuracyMet = raw.AccuracyMet != 0;
        FromMesh = raw.FromMesh != 0;
        Area = raw.Area;
        AreaError = raw.AreaError;
        Volume = raw.Volume;
        VolumeError = raw.VolumeError;
        Centroid = raw.Centroid;
        CentroidError = raw.CentroidError;
        Inertia = Rows(raw.Inertia);
        InertiaError = raw.InertiaError;
        PrincipalMoments = raw.PrincipalMoments;
        PrincipalAxes = Rows(raw.PrincipalAxes);
    }

    /// <summary><c>density * Volume</c>, in whatever units the model and the density agree on.</summary>
    public double Weight(double density) => density * Volume;

    public override string ToString() => Closed
        ? $"Mass(area {Area:G6}, volume {Volume:G6})"
        : $"Mass(open, area {Area:G6})";
}

/// <summary>`CadaclysmBlacksmithOrientedBox`: centre, three axes (row-major), three half extents.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithOrientedBox
{
    public fixed double Centre[3];
    public fixed double Axes[9];
    public fixed double Half[3];
}

/// <summary>A closed solid's box on its principal axes: <see cref="Solid.OrientedBox"/>. Not the
/// minimal box in general; where two moments are equal (a cube, a cylinder about its axis) any axes
/// in that plane are as principal as the others. The half extents are grown by
/// diag * max(accuracy, tau/16), about 3.1e-5 of the diagonal on a body that settles at once
/// (planes, cylinders, cones), so they hold the body.</summary>
public sealed class OrientedBox
{
    /// <summary>The box's centre.</summary>
    public double[] Centre { get; }
    /// <summary>Three rows of three: row <c>i</c> is the box's axis <c>i</c> (unit, orthogonal).</summary>
    public double[][] Axes { get; }
    /// <summary>The half extent along each axis.</summary>
    public double[] Half { get; }

    internal unsafe OrientedBox(RawBlacksmithOrientedBox raw)
    {
        Centre = new[] { raw.Centre[0], raw.Centre[1], raw.Centre[2] };
        Axes = new[]
        {
            new[] { raw.Axes[0], raw.Axes[1], raw.Axes[2] },
            new[] { raw.Axes[3], raw.Axes[4], raw.Axes[5] },
            new[] { raw.Axes[6], raw.Axes[7], raw.Axes[8] },
        };
        Half = new[] { raw.Half[0], raw.Half[1], raw.Half[2] };
    }

    public override string ToString() =>
        $"OrientedBox(centre=({Centre[0]:G6}, {Centre[1]:G6}, {Centre[2]:G6}), half=({Half[0]:G6}, {Half[1]:G6}, {Half[2]:G6}))";
}

/// <summary>`CadaclysmBlacksmithLength`: a length, a bound on its error, two flags.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithLength
{
    public double Length;
    public double Error;
    public int AccuracyMet;
    public int FromPolyline;
}

/// <summary>A measured length beside an estimate of its own error: <see cref="Solid.EdgeLength"/>
/// and <see cref="Profile.Length"/>. (<c>Value</c> is the length itself: a member cannot share
/// its type's name in C#.)</summary>
public readonly struct Length
{
    /// <summary>The length, in model units.</summary>
    public double Value { get; }
    /// <summary>An estimate of the distance from <c>Value</c> to the true length, not a proof.</summary>
    public double Error { get; }
    /// <summary>The error came under the accuracy asked for.</summary>
    public bool AccuracyMet { get; }
    /// <summary>The curve was a sampled polyline: exact for its points, not for whatever they were sampled from.</summary>
    public bool FromPolyline { get; }

    internal Length(RawBlacksmithLength raw)
    {
        Value = raw.Length;
        Error = raw.Error;
        AccuracyMet = raw.AccuracyMet != 0;
        FromPolyline = raw.FromPolyline != 0;
    }

    public override string ToString() => $"Length({Value:G10} +/- {Error:G3})";
}

/// <summary>`CadaclysmBlacksmithAt`: a point, its tangent, the curve's parameter there, the
/// segment, an error, a flag.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithAt
{
    public fixed double Point[3];
    public fixed double Tangent[3];
    public double Parameter;
    public uint Segment;
    public double Error;
    public int FromPolyline;
}

/// <summary>A point at some arc length along an edge or a profile's outer loop:
/// <see cref="Solid.EdgePointAtLength"/>, <see cref="Profile.PointAtLength"/> and the divides.</summary>
public sealed class At
{
    /// <summary>The point, three doubles.</summary>
    public double[] Point { get; }
    /// <summary>The unit tangent there, three doubles.</summary>
    public double[] Tangent { get; }
    /// <summary>The curve's own parameter at the point. On a profile it is the side's own: a
    /// line's 0..1, an arc's angle, a spline's parameter.</summary>
    public double Parameter { get; }
    /// <summary>On a profile the side the point lies on (the segment count for the implicit
    /// closing side); null on a solid's edge.</summary>
    public uint? Segment { get; }
    /// <summary>An estimate of the arc-length error, not a proof; 0 or more.</summary>
    public double Error { get; }
    /// <summary>The curve was a sampled polyline: exact for its points, not for whatever they were sampled from.</summary>
    public bool FromPolyline { get; }

    internal unsafe At(RawBlacksmithAt raw)
    {
        Point = new[] { raw.Point[0], raw.Point[1], raw.Point[2] };
        Tangent = new[] { raw.Tangent[0], raw.Tangent[1], raw.Tangent[2] };
        Parameter = raw.Parameter;
        Segment = raw.Segment == uint.MaxValue ? null : raw.Segment;
        Error = raw.Error;
        FromPolyline = raw.FromPolyline != 0;
    }

    public override string ToString() =>
        $"At(({Point[0]:G6}, {Point[1]:G6}, {Point[2]:G6}), parameter={Parameter:G10}, segment={(Segment is { } s ? s.ToString() : "none")})";
}

/// <summary>`CadaclysmBlacksmithCurvature`: the curvature, the Frenet frame, the osculating
/// circle's centre and whether it has one.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithCurvature
{
    public double Kappa;
    public fixed double Tangent[3];
    public fixed double Normal[3];
    public fixed double Binormal[3];
    public fixed double Centre[3];
    public int HasCentre;
}

/// <summary>A curve's bending at a parameter (<see cref="NurbsCurve.Curvature"/>): the
/// curvature <see cref="Kappa"/> (1 / radius), the unit <see cref="Tangent"/>, the unit
/// <see cref="Normal"/> toward the centre, the <see cref="Binormal"/> (tangent x normal) and the
/// <see cref="Centre"/> of the osculating circle. On a straight piece Kappa is 0, Normal and
/// Binormal are zero and Centre is null.</summary>
public sealed record Curvature(
    double Kappa,
    (double X, double Y, double Z) Tangent,
    (double X, double Y, double Z) Normal,
    (double X, double Y, double Z) Binormal,
    (double X, double Y, double Z)? Centre)
{
    internal static unsafe Curvature Of(RawBlacksmithCurvature raw) => new(
        raw.Kappa,
        (raw.Tangent[0], raw.Tangent[1], raw.Tangent[2]),
        (raw.Normal[0], raw.Normal[1], raw.Normal[2]),
        (raw.Binormal[0], raw.Binormal[1], raw.Binormal[2]),
        raw.HasCentre != 0 ? (raw.Centre[0], raw.Centre[1], raw.Centre[2]) : null);
}

/// <summary>`CadaclysmBlacksmithContinuity`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithContinuity
{
    public double Gap;
    public fixed double GapAt[3];
    public double Angle;
    public fixed double AngleAt[3];
    public double Curvature;
    public fixed double CurvatureAt[3];
    public uint Samples;
}

/// <summary>`CadaclysmBlacksmithKnotContinuity`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithKnotContinuity
{
    public double Angle;
    public double AngleParameter;
    public fixed double AngleAt[3];
    public double Curvature;
    public double CurvatureParameter;
    public fixed double CurvatureAt[3];
}

/// <summary>`CadaclysmBlacksmithCurvatureTurns`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithCurvatureTurns
{
    public uint GaussianPositive;
    public uint GaussianNegative;
    public uint GaussianTurns;
    public uint MeanPositive;
    public uint MeanNegative;
    public uint MeanTurns;
    public uint Samples;
}

/// <summary>`CadaclysmBlacksmithHighlightKink`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithHighlightKink
{
    public double Angle;
    public fixed double At[3];
    public fixed double LightPoint[3];
    public fixed double LightDirection[3];
    public uint Samples;
}

/// <summary>`CadaclysmBlacksmithPatchBoundary`: a sheet's side, or (Sheet null) a curve.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithPatchBoundary
{
    public IntPtr Sheet;
    public uint Face;
    public uint Side;
    public double From;
    public double To;
    public uint Level;
    public IntPtr Curve;
}

/// <summary>`CadaclysmBlacksmithPatchReport`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithPatchReport
{
    public uint Faces;
    public RawBlacksmithContinuity Boundary;
    public RawBlacksmithContinuity Internal;
    public double CornerAngle;
}

/// <summary>`CadaclysmBlacksmithJoinReport`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithJoinReport
{
    public uint Sewn;
    public uint NakedBefore;
    public uint NakedAfter;
    public uint Refused;
    public uint Turned;
    public double WorstGap;
    public int Closed;
}

/// <summary>How well two faces meet along their sides (<see cref="Solid.Continuity"/>): the
/// largest <see cref="Gap"/> between the sides (G0), the largest <see cref="Angle"/> between
/// their normals in radians (G1), the largest difference of normal <see cref="Curvature"/>
/// across the edge (G2), each with where it was found, and how many points were asked.</summary>
public sealed record Continuity(
    double Gap, (double X, double Y, double Z) GapAt,
    double Angle, (double X, double Y, double Z) AngleAt,
    double Curvature, (double X, double Y, double Z) CurvatureAt,
    int Samples)
{
    internal static unsafe Continuity Of(RawBlacksmithContinuity raw) => new(
        raw.Gap, (raw.GapAt[0], raw.GapAt[1], raw.GapAt[2]),
        raw.Angle, (raw.AngleAt[0], raw.AngleAt[1], raw.AngleAt[2]),
        raw.Curvature, (raw.CurvatureAt[0], raw.CurvatureAt[1], raw.CurvatureAt[2]),
        (int)raw.Samples);
}

/// <summary>How smoothly a curve runs through its own knots (<see cref="NurbsCurve.KnotContinuity"/>;
/// a closed curve's seam among them): the largest turn of its tangent in radians
/// (<see cref="Angle"/>) and the largest jump of its curvature vector <c>kappa * normal</c>
/// (<see cref="Curvature"/>), each with the parameter and the point it was found at. A curve
/// with no inner knot reads zero at its start.</summary>
public sealed record KnotContinuity(
    double Angle, double AngleParameter, (double X, double Y, double Z) AngleAt,
    double Curvature, double CurvatureParameter, (double X, double Y, double Z) CurvatureAt)
{
    internal static unsafe KnotContinuity Of(RawBlacksmithKnotContinuity raw) => new(
        raw.Angle, raw.AngleParameter, (raw.AngleAt[0], raw.AngleAt[1], raw.AngleAt[2]),
        raw.Curvature, raw.CurvatureParameter, (raw.CurvatureAt[0], raw.CurvatureAt[1], raw.CurvatureAt[2]));
}

/// <summary>Where a face's curvatures change sign (<see cref="Solid.CurvatureTurns"/>): how many
/// separate areas the sample grid finds where the Gaussian curvature is positive and negative
/// (<see cref="GaussianPositive"/>, <see cref="GaussianNegative"/>) and the mean curvature
/// (<see cref="MeanPositive"/>, <see cref="MeanNegative"/>, about the face's outward normal), and
/// the points between opposite signs (<see cref="GaussianTurns"/>, <see cref="MeanTurns"/>:
/// <c>Tangent</c> the face's unit normal there, <c>Parameter</c> its <c>u</c>). A sample within a
/// millionth of the face's size of flat is neither sign: a cylinder's patch reads no Gaussian
/// area at all.</summary>
public sealed record CurvatureTurns(
    int GaussianPositive, int GaussianNegative, List<At> GaussianTurns,
    int MeanPositive, int MeanNegative, List<At> MeanTurns, int Samples)
{
    internal static CurvatureTurns Of(RawBlacksmithCurvatureTurns raw, List<At> gaussianTurns, List<At> meanTurns) => new(
        (int)raw.GaussianPositive, (int)raw.GaussianNegative, gaussianTurns,
        (int)raw.MeanPositive, (int)raw.MeanNegative, meanTurns, (int)raw.Samples);
}

/// <summary>The worst kink of the highlight lines crossing an edge (<see cref="Solid.HighlightKink(int, int)"/>):
/// the <see cref="Angle"/> in radians (0 to pi/2) between a line on one face and the same line on
/// the other, the point <see cref="At"/> along the edge, and the light that shows it -- a straight
/// tube through <see cref="LightPoint"/> along <see cref="LightDirection"/> (unit) -- from
/// <see cref="Samples"/> points along the edge.</summary>
public sealed record HighlightKink(
    double Angle, (double X, double Y, double Z) At, (double X, double Y, double Z) LightPoint,
    (double X, double Y, double Z) LightDirection, int Samples)
{
    internal static unsafe HighlightKink Of(RawBlacksmithHighlightKink raw) => new(
        raw.Angle, (raw.At[0], raw.At[1], raw.At[2]), (raw.LightPoint[0], raw.LightPoint[1], raw.LightPoint[2]),
        (raw.LightDirection[0], raw.LightDirection[1], raw.LightDirection[2]), (int)raw.Samples);
}

/// <summary>How well an N-sided patch (<see cref="Solid.NSidedPatch"/>) meets: <see cref="Faces"/>
/// sub-patches, the worst <see cref="Boundary"/> figures against the neighbours, the worst
/// <see cref="Internal"/> across the patch's own spokes, and <see cref="CornerAngle"/> (radians),
/// the most a corner of the hole leaves no patch able to meet: zero where the neighbours meet
/// each other at G1.</summary>
public sealed record PatchReport(int Faces, Continuity Boundary, Continuity Internal, double CornerAngle)
{
    internal static PatchReport Of(RawBlacksmithPatchReport raw) =>
        new((int)raw.Faces, Continuity.Of(raw.Boundary), Continuity.Of(raw.Internal), raw.CornerAngle);
}

/// <summary>What <see cref="Solid.JoinSheets"/> did: <see cref="Sewn"/> edges (each two naked
/// edges become one shared edge), the widest <see cref="WorstGap"/> between two sewn edges, the
/// naked edges before (once the T-junctions are cut) and after, <see cref="Refused"/> groups of
/// naked edges that share both ends but were left apart, faces <see cref="Turned"/>, and whether
/// the result is <see cref="Closed"/>: a solid.</summary>
public sealed record JoinReport(int Sewn, double WorstGap, int NakedBefore, int NakedAfter, int Refused, int Turned, bool Closed)
{
    internal static JoinReport Of(RawBlacksmithJoinReport raw) =>
        new((int)raw.Sewn, raw.WorstGap, (int)raw.NakedBefore, (int)raw.NakedAfter, (int)raw.Refused, (int)raw.Turned, raw.Closed != 0);
}

/// <summary>What <see cref="Solid.MirrorJoin"/> did: the <see cref="Seams"/> (edges on the plane,
/// one face of the half and one of its mirror), the faces <see cref="Squared"/> to the plane and
/// the furthest a control point <see cref="Moved"/> doing it; the seam's worst <see cref="Gap"/>,
/// <see cref="Angle"/> between the two sides' normals (radians) and <see cref="Curvature"/> (the
/// largest difference of their normal curvatures in any one direction); and the
/// <see cref="Naked"/> edges left on the body.</summary>
public sealed record SymmetryReport(int Seams, int Squared, double Moved, double Gap, double Angle, double Curvature, int Naked)
{
    internal static SymmetryReport Of(double[] raw) =>
        new((int)raw[0], (int)raw[1], raw[2], raw[3], raw[4], raw[5], (int)raw[6]);
}

/// <summary>One side of the hole <see cref="Solid.NSidedPatch"/> fills: a sheet's side
/// (<see cref="OfSide"/>), or a <see cref="NurbsCurve"/> met at G0 (<see cref="OfCurve"/>, or the
/// implicit conversion).</summary>
public sealed class PatchBoundary
{
    internal Solid? Sheet { get; }
    internal string Side { get; }
    internal int Level { get; }
    internal int Face { get; }
    internal double From { get; }
    internal double To { get; }
    internal NurbsCurve? Curve { get; }

    private PatchBoundary(Solid? sheet, string side, int level, int face, double from, double to, NurbsCurve? curve)
    {
        Sheet = sheet; Side = side; Level = level; Face = face; From = from; To = to; Curve = curve;
    }

    /// <summary>Side <paramref name="side"/> ("u0", "u1", "v0" or "v1") of face
    /// <paramref name="face"/> of <paramref name="sheet"/>, over <paramref name="from"/> to
    /// <paramref name="to"/> of the side's parameter (0 to 1 the whole side, 1 to 0 the whole side
    /// backwards), met at G<paramref name="level"/> (0, 1 or 2).</summary>
    public static PatchBoundary OfSide(Solid sheet, string side, int level = 2, int face = 0, double from = 0.0, double to = 1.0) =>
        new(sheet ?? throw new ArgumentNullException(nameof(sheet)), side, level, face, from, to, null);

    /// <summary>The curve <paramref name="curve"/>, met at G0.</summary>
    public static PatchBoundary OfCurve(NurbsCurve curve) =>
        new(null, "u0", 0, 0, 0.0, 1.0, curve ?? throw new ArgumentNullException(nameof(curve)));

    public static implicit operator PatchBoundary(NurbsCurve curve) => OfCurve(curve);
}

/// <summary>`CadaclysmBlacksmithRTreeHit`: an entry's id and its distance (0 for a search).</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithRTreeHit
{
    public uint Id;
    public double Distance;
}

/// <summary>`CadaclysmBlacksmithRTreePair`: two entry ids.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithRTreePair
{
    public uint A;
    public uint B;
}

/// <summary>One answer of <see cref="RTree.Within"/> or <see cref="RTree.Nearest"/>: the entry's
/// id and the distance from the query point to its box (0 inside it).</summary>
public readonly record struct RTreeHit(uint Id, double Distance);

/// <summary>One pair of <see cref="RTree.Overlaps"/> (<see cref="A"/> from the first tree) or
/// <see cref="RTree.SelfOverlaps"/> (<see cref="A"/> the smaller id).</summary>
public readonly record struct RTreePair(uint A, uint B);

/// <summary>`CadaclysmBlacksmithClosest`. The two <c>kind</c> pointers are static strings owned
/// by the library: copied, never freed.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithClosest
{
    public double Distance;
    public fixed double OnA[3];
    public fixed double OnB[3];
    public IntPtr KindA;
    public uint IndexA;
    public uint EdgeA;
    public IntPtr KindB;
    public uint IndexB;
    public uint EdgeB;
    public int Refined;
}

/// <summary>The closest points between two solids' boundaries: <see cref="Solid.Closest"/>.
/// Side <c>a</c> is the solid asked, side <c>b</c> the other.</summary>
public sealed class Closest
{
    /// <summary>The gap between the two points; 0 where the boundaries touch or cross.</summary>
    public double Distance { get; }
    /// <summary>The closest point on side a's boundary.</summary>
    public double[] OnA { get; }
    /// <summary>The closest point on side b's boundary.</summary>
    public double[] OnB { get; }
    /// <summary>What side a's point lies on: "face", "edge" or "vertex".</summary>
    public string KindA { get; }
    /// <summary>Side a's face, edge or vertex index, by <see cref="KindA"/>.</summary>
    public uint IndexA { get; }
    /// <summary>Side a's fillet-table edge (what <see cref="Solid.Fillet(IEnumerable{int}, double, double)"/> takes), or null.</summary>
    public uint? EdgeA { get; }
    public string KindB { get; }
    public uint IndexB { get; }
    public uint? EdgeB { get; }
    /// <summary>The answer was refined to the tolerance.</summary>
    public bool Refined { get; }

    internal unsafe Closest(RawBlacksmithClosest raw)
    {
        Distance = raw.Distance;
        OnA = new[] { raw.OnA[0], raw.OnA[1], raw.OnA[2] };
        OnB = new[] { raw.OnB[0], raw.OnB[1], raw.OnB[2] };
        KindA = Blacksmith.Text(raw.KindA);
        IndexA = raw.IndexA;
        EdgeA = raw.EdgeA == uint.MaxValue ? null : raw.EdgeA;
        KindB = Blacksmith.Text(raw.KindB);
        IndexB = raw.IndexB;
        EdgeB = raw.EdgeB == uint.MaxValue ? null : raw.EdgeB;
        Refined = raw.Refined != 0;
    }

    public override string ToString() =>
        $"Closest(distance={Distance:G10}, a={KindA}#{IndexA}, b={KindB}#{IndexB})";
}

/// <summary>The nearest point of a solid (or of one face) to a query point:
/// <see cref="Solid.ClosestPoint"/>, <see cref="Projector.ClosestPoint"/>,
/// <see cref="Solid.FaceClosestPoint"/>. What the point lies on is named as <see cref="Closest"/>
/// names each side.</summary>
public sealed class PointFoot
{
    /// <summary>The nearest point, on the body's boundary.</summary>
    public double[] Point { get; }
    /// <summary>From the query point to <see cref="Point"/>.</summary>
    public double Distance { get; }
    /// <summary>What the point lies on: "face", "edge" or "vertex".</summary>
    public string Kind { get; }
    /// <summary>The kernel's id for the face, edge or vertex, by <see cref="Kind"/>.</summary>
    public uint Index { get; }
    /// <summary>The public edge number (what <see cref="Solid.EdgeLength"/>, the fillets and
    /// <see cref="Solid.EdgeClosestPoint"/> take) for an edge foot; null for a face, a vertex, and
    /// an edge the fillet table does not hold. Read this, not <see cref="Index"/>.</summary>
    public uint? Edge { get; }
    /// <summary>The face parameter of a foot inside a face; null for an edge or a vertex foot.</summary>
    public double[]? Uv { get; }
    /// <summary>Unit: a face foot's outward normal; an edge or vertex foot's direction from the
    /// foot to the query point; on the body the mean of the adjacent faces' outward normals.</summary>
    public double[] Normal { get; }
    /// <summary>Refined onto the exact geometry; false is the mesh's answer, within
    /// `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`.</summary>
    public bool Refined { get; }

    internal unsafe PointFoot(RawBlacksmithPointFoot raw)
    {
        Point = new[] { raw.Point[0], raw.Point[1], raw.Point[2] };
        Distance = raw.Distance;
        Kind = Blacksmith.Text(raw.Kind);
        Index = raw.Index;
        Edge = raw.Edge == uint.MaxValue ? null : raw.Edge;
        Uv = double.IsNaN(raw.Uv[0]) || double.IsNaN(raw.Uv[1]) ? null : new[] { raw.Uv[0], raw.Uv[1] };
        Normal = new[] { raw.Normal[0], raw.Normal[1], raw.Normal[2] };
        Refined = raw.Refined != 0;
    }

    public override string ToString() =>
        $"PointFoot(distance={Distance:G10}, {Kind}#{Index}, point=({Point[0]:G10}, {Point[1]:G10}, {Point[2]:G10}))";
}

/// <summary>The nearest points of two curves (<see cref="NurbsCurve.ClosestPoints"/>, and a
/// <see cref="NearestObject"/>'s answer for a curve): side `a` on the curve asked, at its
/// parameter <see cref="TA"/>, side `b` on the other, at <see cref="TB"/>, <see cref="Distance"/>
/// apart (0 where they cross). Exact.</summary>
public sealed class CurvePair
{
    /// <summary>From <see cref="PointA"/> to <see cref="PointB"/>.</summary>
    public double Distance { get; }
    /// <summary>The parameter of <see cref="PointA"/> on the curve asked.</summary>
    public double TA { get; }
    /// <summary>The nearest point on the curve asked.</summary>
    public double[] PointA { get; }
    /// <summary>The parameter of <see cref="PointB"/> on the other curve.</summary>
    public double TB { get; }
    /// <summary>The nearest point on the other curve.</summary>
    public double[] PointB { get; }

    internal unsafe CurvePair(RawBlacksmithCurvePair raw)
    {
        Distance = raw.Distance;
        TA = raw.TA;
        PointA = new[] { raw.PointA[0], raw.PointA[1], raw.PointA[2] };
        TB = raw.TB;
        PointB = new[] { raw.PointB[0], raw.PointB[1], raw.PointB[2] };
    }

    public override string ToString() => $"CurvePair(distance={Distance:G10}, t_a={TA:G10}, t_b={TB:G10})";
}

/// <summary>The nearest points of a curve and a solid's boundary
/// (<see cref="Solid.CurveClosestPoints"/>, <see cref="Projector.CurveClosestPoints"/>, and a
/// <see cref="NearestObject"/>'s answer for a solid or a projector): <see cref="PointOnCurve"/> at
/// the curve's parameter <see cref="T"/>, and <see cref="PointOnBody"/>, <see cref="Distance"/>
/// apart. The body's side is named as <see cref="PointFoot"/> names its point.</summary>
public sealed class CurveBodyFoot
{
    /// <summary>From <see cref="PointOnCurve"/> to <see cref="PointOnBody"/>.</summary>
    public double Distance { get; }
    /// <summary>The curve's parameter at <see cref="PointOnCurve"/>.</summary>
    public double T { get; }
    /// <summary>The nearest point on the curve.</summary>
    public double[] PointOnCurve { get; }
    /// <summary>The nearest point on the body's boundary.</summary>
    public double[] PointOnBody { get; }
    /// <summary>What the body's point lies on: "face", "edge" or "vertex".</summary>
    public string Kind { get; }
    /// <summary>The kernel's id for the face, edge or vertex, by <see cref="Kind"/>.</summary>
    public uint Index { get; }
    /// <summary>The public edge number for an edge foot (what <see cref="Solid.EdgeLength"/> and
    /// <see cref="Solid.EdgeClosestPoint"/> take); null otherwise. Read this, not
    /// <see cref="Index"/>.</summary>
    public uint? Edge { get; }
    /// <summary>The face parameter of a foot inside a face; null for an edge or a vertex foot.</summary>
    public double[]? Uv { get; }
    /// <summary>Unit, as <see cref="PointFoot.Normal"/>.</summary>
    public double[] Normal { get; }
    /// <summary>Refined onto the exact geometry; false is the mesh's answer, within
    /// `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`.</summary>
    public bool Refined { get; }
    /// <summary>True where the curve passes through the boundary: <see cref="Distance"/> is then
    /// exactly 0 and the earliest crossing in <see cref="T"/> answers.</summary>
    public bool Crossing { get; }

    internal unsafe CurveBodyFoot(RawBlacksmithCurveBodyFoot raw)
    {
        var body = new PointFoot(raw.Body);
        Distance = raw.Distance;
        T = raw.T;
        PointOnCurve = new[] { raw.PointOnCurve[0], raw.PointOnCurve[1], raw.PointOnCurve[2] };
        PointOnBody = body.Point;
        Kind = body.Kind;
        Index = body.Index;
        Edge = body.Edge;
        Uv = body.Uv;
        Normal = body.Normal;
        Refined = body.Refined;
        Crossing = raw.Crossing != 0;
    }

    public override string ToString() =>
        $"CurveBodyFoot(distance={Distance:G10}, t={T:G10}, {Kind}#{Index}, crossing={Crossing})";
}

/// <summary>The nearest of a list of things to a curve (<see cref="NurbsCurve.ClosestObject"/>):
/// <see cref="Which"/> the item's index in the list, <see cref="Distance"/> from
/// <see cref="PointOnCurve"/> (at the curve's parameter <see cref="T"/>) to
/// <see cref="PointOnItem"/>. The item's own answer is <see cref="Body"/> for a solid or a
/// projector, <see cref="Pair"/> (side `a` the curve asked) for a curve, and neither for a
/// point.</summary>
public sealed class NearestObject
{
    /// <summary>The item's index in the list asked.</summary>
    public int Which { get; }
    /// <summary>From <see cref="PointOnCurve"/> to <see cref="PointOnItem"/>.</summary>
    public double Distance { get; }
    /// <summary>The curve's parameter at <see cref="PointOnCurve"/>.</summary>
    public double T { get; }
    /// <summary>The nearest point on the curve.</summary>
    public double[] PointOnCurve { get; }
    /// <summary>The nearest point of the item.</summary>
    public double[] PointOnItem { get; }
    /// <summary>A solid's or a projector's answer; null for a curve or a point.</summary>
    public CurveBodyFoot? Body { get; }
    /// <summary>A curve's answer, side `a` the curve asked; null for a solid, a projector or a
    /// point.</summary>
    public CurvePair? Pair { get; }

    internal unsafe NearestObject(RawBlacksmithNearestObject raw)
    {
        Which = (int)raw.Which;
        Distance = raw.Distance;
        T = raw.T;
        PointOnCurve = new[] { raw.PointOnCurve[0], raw.PointOnCurve[1], raw.PointOnCurve[2] };
        PointOnItem = new[] { raw.PointOnItem[0], raw.PointOnItem[1], raw.PointOnItem[2] };
        // Only the member AnswerKind names is read: the other is zero bytes (a null `kind`).
        Body = raw.AnswerKind == 0 ? new CurveBodyFoot(raw.Body) : null;
        Pair = raw.AnswerKind == 1 ? new CurvePair(raw.Pair) : null;
    }

    public override string ToString() => $"NearestObject(which={Which}, distance={Distance:G10}, t={T:G10})";
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

/// <summary>`CadaclysmBlacksmithPointFoot`. The <c>kind</c> pointer is a static string owned by
/// the library: copied, never freed. Declared after <see cref="RawBlacksmithPoint"/>, whose
/// name is a prefix of this one's.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithPointFoot
{
    public double Distance;
    public fixed double Point[3];
    public IntPtr Kind;
    public uint Index;
    public uint Edge;
    public fixed double Uv[2];
    public fixed double Normal[3];
    public int Refined;
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

/// <summary>`CadaclysmBlacksmithCurvePair`, 72 bytes: side `a` the curve asked, side `b` the
/// other. Declared after <see cref="RawBlacksmithCurve"/>, whose name is a prefix of this
/// one's.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithCurvePair
{
    public double Distance;
    public double TA;
    public fixed double PointA[3];
    public double TB;
    public fixed double PointB[3];
}

/// <summary>`CadaclysmBlacksmithCurveBodyFoot`, 144 bytes: the curve's side, then the body's
/// as a <see cref="RawBlacksmithPointFoot"/>; four bytes of padding after `Crossing`, which
/// sequential layout reproduces.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithCurveBodyFoot
{
    public double Distance;
    public double T;
    public fixed double PointOnCurve[3];
    public RawBlacksmithPointFoot Body;
    public int Crossing;
}

/// <summary>`CadaclysmBlacksmithNearestObject`, 288 bytes. Only the member `AnswerKind` names
/// is filled (0 `Body`, 1 `Pair`, 2 neither); every byte of the other is zero, its `kind` a
/// null pointer, so it is never read.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithNearestObject
{
    public uint Which;
    public int AnswerKind;
    public double Distance;
    public double T;
    public fixed double PointOnCurve[3];
    public fixed double PointOnItem[3];
    public RawBlacksmithCurveBodyFoot Body;
    public RawBlacksmithCurvePair Pair;
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

/// <summary>`CadaclysmBlacksmithBox`: `Lo` and `Hi`, three doubles each.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithBox
{
    public fixed double Lo[3];
    public fixed double Hi[3];
}

/// <summary>`CadaclysmBlacksmithRegion`: one region of a solid -- `Finite` 0 for region 0,
/// `Min` / `Max` the box round its faces, how many face `Sides` bound it and its `Shells`.
/// Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithRegion
{
    public int Finite;
    public fixed double Min[3];
    public fixed double Max[3];
    public uint Sides;
    public uint Shells;
}

/// <summary>`CadaclysmBlacksmithFaceSide`: a face and the side of it, +1 or -1. Pinned by
/// `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithFaceSide
{
    public uint Face;
    public int Sense;
}

/// <summary>`CadaclysmBlacksmithColliderStats`: nine counts of one `collider_check` call.
/// Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithColliderStats
{
    public uint Considered;
    public uint WorldBoxes;
    public uint OrientedBoxes;
    public uint SkippedShare;
    public uint Cached;
    public uint ClosedForm;
    public uint Meshed;
    public uint Refused;
    public uint Confirmed;
}

/// <summary>`CadaclysmBlacksmithCollisionHit`: a pair the collider found overlapping, or could
/// not decide. Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithCollisionHit
{
    public uint A;
    public uint B;
    [MarshalAs(UnmanagedType.I1)] public bool Overlap;
    public double Depth;
    public IntPtr Positions;
    public IntPtr Normals;
    public IntPtr Indices;
    public uint VertexCount;
    public uint IndexCount;
    public IntPtr Text;
}

/// <summary>`CadaclysmBlacksmithClash`: one pair a clash call found. `Kind`, `KindA`, `KindB`
/// and `Text` borrow from the clashes handle: copied out at once. `EdgeA`/`EdgeB` are NONE where
/// the feature has no fillet-table edge; `KindA`/`KindB` are "none" for a penetrating or refused
/// pair. Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithClash
{
    public uint A;
    public uint B;
    public IntPtr Kind;
    public double Distance;
    public fixed double OnA[3];
    public fixed double OnB[3];
    public IntPtr KindA;
    public uint IndexA;
    public uint EdgeA;
    public IntPtr KindB;
    public uint IndexB;
    public uint EdgeB;
    public int Refined;
    public double Depth;
    public IntPtr Text;
}

/// <summary>`CadaclysmBlacksmithSweptClash`: one pair a swept clash call found -- its first time
/// (in pose units) and how many intervals it stays in clash for; its first `Clash` row comes from
/// `swept_clashes_firsts`. Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithSweptClash
{
    public uint A;
    public uint B;
    public double FirstTime;
    public uint IntervalCount;
}

/// <summary>`CadaclysmBlacksmithThickness`: one wall-thickness reading. `Vertex` is NONE for a
/// reading at a point, `Sphere` NaN where no ball under the maximum holds none of the surfaces.
/// Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithThickness
{
    public uint Body;
    public uint Vertex;
    public uint Face;
    public fixed double Point[3];
    public double Thickness;
    public fixed double Opposite[3];
    public uint OppositeBody;
    public uint OppositeFace;
    [MarshalAs(UnmanagedType.I1)] public bool Knife;
    public double ExactThickness;
    public fixed double ExactOpposite[3];
    public double Sphere;
}

/// <summary>`CadaclysmBlacksmithMeshThickness`: one reading on a plain mesh. Pinned by
/// `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithMeshThickness
{
    public uint Mesh;
    public uint Vertex;
    public double Thickness;
    public fixed double Point[3];
    public fixed double Opposite[3];
    public uint OppositeMesh;
    public uint OppositeTriangle;
    [MarshalAs(UnmanagedType.I1)] public bool Knife;
}

/// <summary>`CadaclysmBlacksmithFaceThickness`: a face's thickness; `Found` false leaves the
/// numbers NaN. Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithFaceThickness
{
    [MarshalAs(UnmanagedType.I1)] public bool Found;
    public double Thickness;
    public double Min;
    public double Max;
    [MarshalAs(UnmanagedType.I1)] public bool Uniform;
}

/// <summary>`CadaclysmBlacksmithThicknessMesh`: a gauge body's measuring mesh, as views borrowed
/// from the gauge: copied out at once. Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithThicknessMesh
{
    public IntPtr Positions;
    public IntPtr Normals;
    public IntPtr Indices;
    public IntPtr Faces;
    public uint VertexCount;
    public uint TriangleCount;
}

/// <summary>`CadaclysmBlacksmithSubdParts`: a cage's parts, as views into its handle, valid until
/// the handle is freed. Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithSubdParts
{
    public IntPtr Positions;
    public uint VertexCount;
    public IntPtr FaceSizes;
    public uint FaceCount;
    public IntPtr FaceIndices;
    public uint IndexCount;
    public IntPtr Creases;
    public uint CreaseCount;
    public IntPtr Pins;
    public uint PinCount;
    public int SymmetryAxis;
    public double SymmetryTolerance;
    public uint SelectionKind;
    public IntPtr Selection;
    public uint SelectionCount;
}

/// <summary>`CadaclysmBlacksmithSubdMesh`: one level of a cage's smooth surface, as views valid
/// until the cage is freed. Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct RawBlacksmithSubdMesh
{
    public IntPtr Positions;
    public uint VertexCount;
    public IntPtr Normals;
    public IntPtr Indices;
    public uint IndexCount;
    public IntPtr TriangleFace;
}

/// <summary>`CadaclysmBlacksmithSubdReport`: what `subd_to_solid` did and how close it came.
/// Pinned by `tests/bindings.rs`.</summary>
[StructLayout(LayoutKind.Sequential)]
internal unsafe struct RawBlacksmithSubdReport
{
    public uint Regular;
    public uint Refined;
    public uint Steps;
    public uint Levels;
    public double Deviation;
    public double G1AngleDeg;
    public fixed double DeviationAt[3];
    public fixed double G1At[3];
}

// ---- the handles the ABI hands out ------------------------------------------------------
//
// One `SafeHandle` a kind, each knowing its own free. `Path`'s is the one the library can
// consume (`path_end`), after which the handle is marked invalid so no free follows.

/// <summary>`CadaclysmBlacksmithProfile *`.</summary>
/// <summary>A read-only map that enumerates in insertion order (a key set again keeps its first
/// place): .NET 8 has no generic OrderedDictionary, so the attribute maps use this.</summary>
internal sealed class OrderedAttributes : IReadOnlyDictionary<string, string>
{
    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);
    private readonly List<string> _keys = new();

    internal void Set(string key, string value)
    {
        if (!_values.ContainsKey(key)) _keys.Add(key);
        _values[key] = value;
    }

    public string this[string key] => _values[key];
    public IEnumerable<string> Keys => _keys;
    public IEnumerable<string> Values => _keys.Select(k => _values[k]);
    public int Count => _keys.Count;
    public bool ContainsKey(string key) => _values.ContainsKey(key);
    public bool TryGetValue(string key, [System.Diagnostics.CodeAnalysis.MaybeNullWhen(false)] out string value) =>
        _values.TryGetValue(key, out value);
    public IEnumerator<KeyValuePair<string, string>> GetEnumerator() =>
        _keys.Select(k => new KeyValuePair<string, string>(k, _values[k])).GetEnumerator();
    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
}

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

/// <summary>`CadaclysmBlacksmithCollider *`.</summary>
internal sealed class ColliderHandle : CadaclysmHandle
{
    public ColliderHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_collider_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithClassifier *`.</summary>
internal sealed class ClassifierHandle : CadaclysmHandle
{
    public ClassifierHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_classifier_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithProjector *`.</summary>
internal sealed class ProjectorHandle : CadaclysmHandle
{
    public ProjectorHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_projector_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithRTree *`.</summary>
internal sealed class RTreeHandle : CadaclysmHandle
{
    public RTreeHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_rtree_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithInterpolator *`.</summary>
internal sealed class InterpolatorHandle : CadaclysmHandle
{
    public InterpolatorHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_interpolator_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithSubd *`.</summary>
internal sealed class SubdHandle : CadaclysmHandle
{
    public SubdHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_subd_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithSketch *`.</summary>
internal sealed class SketchHandle : CadaclysmHandle
{
    public SketchHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_sketch_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithCollisions *`. Kept alive by every <see cref="CollisionHit"/>
/// of one `Collider.Check` call (the managed GC keeps a referenced object reachable), not just
/// by the `Collider` itself: <see cref="CollisionHit.Solid"/> must still work after the
/// collider that made it has closed.</summary>
internal sealed class CollisionsHandle : CadaclysmHandle
{
    public CollisionsHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_collisions_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithClashes *`. Kept alive by every <see cref="Clash"/> of one
/// `Collider.Clash` or `Blacksmith.Clash` call, as <see cref="CollisionsHandle"/> is by its hits:
/// <see cref="Clash.Solid"/> and <see cref="Clash.Intersect"/> must still work after the collider
/// that made them has closed.</summary>
internal sealed class ClashesHandle : CadaclysmHandle
{
    public ClashesHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_clashes_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithSweptClashes *`. Held only inside one `Collider.SweptClash` or
/// `Blacksmith.SweptClash` call: every row and interval is read out and the handle freed before
/// the call returns. The rows' first `Clash`es live on in their own <see cref="ClashesHandle"/>
/// (`swept_clashes_firsts`), independent of this one.</summary>
internal sealed class SweptClashesHandle : CadaclysmHandle
{
    public SweptClashesHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_swept_clashes_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithThicknessGauge *`.</summary>
internal sealed class ThicknessGaugeHandle : CadaclysmHandle
{
    public ThicknessGaugeHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_thickness_gauge_free(handle);
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

    /// <summary>Takes over a solid pointer the library wrote into an out array.</summary>
    internal SolidHandle(IntPtr owned)
    {
        SetHandle(owned);
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_solid_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithNurbsCurve *`, freed by `cadaclysm_blacksmith_nurbs_curve_free`.
/// A `SafeHandle`, so no finalizer frees a curve while a P/Invoke is still reading it.</summary>
internal sealed class NurbsCurveHandle : CadaclysmHandle
{
    public NurbsCurveHandle()
    {
    }

    /// <summary>Takes over a curve pointer the library wrote into an out array.</summary>
    internal NurbsCurveHandle(IntPtr owned)
    {
        SetHandle(owned);
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithHealth *`, freed by `cadaclysm_blacksmith_health_free`: owned
/// report data, independent of the solid it was made from.</summary>
internal sealed class HealthHandle : CadaclysmHandle
{
    public HealthHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_health_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithHeal *`, freed by `cadaclysm_blacksmith_heal_free`; the solid
/// taken from it with `cadaclysm_blacksmith_heal_body` is the caller's and outlives it.</summary>
internal sealed class HealHandle : CadaclysmHandle
{
    public HealHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_heal_free(handle);
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

/// <summary>`CadaclysmBlacksmithTessellation *`, freed by `cadaclysm_blacksmith_tessellation_free`.
/// A held tessellation: one solid meshed at one tolerance, kept alive on its own regardless of
/// what happens to the solid afterwards -- re-meshed at another tolerance, or disposed. <see
/// cref="BlacksmithMesh"/>, <see cref="BlacksmithMesh64"/> and <see cref="BlacksmithPolylines"/>
/// each hold one of these instead of the solid itself.</summary>
internal sealed class TessellationHandle : CadaclysmHandle
{
    public TessellationHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_tessellation_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithTool *`. A job it was used in keeps its own copy.</summary>
internal sealed class ToolHandle : CadaclysmHandle
{
    public ToolHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_tool_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithStock *`. A job made on it keeps its own copy.</summary>
internal sealed class StockHandle : CadaclysmHandle
{
    public StockHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_stock_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithJob *`. The lists it wrote are independent and outlive it.
/// </summary>
internal sealed class JobHandle : CadaclysmHandle
{
    public JobHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_job_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithPrograms *`: the strings read out of it are the list's, so
/// they are copied before it is freed.</summary>
internal sealed class ProgramsHandle : CadaclysmHandle
{
    public ProgramsHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_programs_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithReport *`: as <see cref="ProgramsHandle"/>, its strings are
/// copied before it is freed.</summary>
internal sealed class ReportHandle : CadaclysmHandle
{
    public ReportHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_report_free(handle);
        return true;
    }
}

/// <summary>`CadaclysmBlacksmithOperations *`: as <see cref="ProgramsHandle"/>, its strings
/// are copied before it is freed.</summary>
internal sealed class OperationsHandle : CadaclysmHandle
{
    public OperationsHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_operations_free(handle);
        return true;
    }
}

// ---- the library ----------------------------------------------------------------------

/// <summary>`CadaclysmBlacksmithDocument *`, freed by `cadaclysm_blacksmith_document_free`.</summary>
internal sealed class DocumentHandle : CadaclysmHandle
{
    public DocumentHandle()
    {
    }

    protected override bool ReleaseHandle()
    {
        BlacksmithNative.cadaclysm_blacksmith_document_free(handle);
        return true;
    }
}

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
        // The NuGet package's runtimes/{rid}/native/.
        searched.AddRange(Loader.PackageDirectories(here).Select(d => System.IO.Path.Combine(d, name)));
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
    // The material and the outside style: set as `named` is, read back borrowed as `solid_name` is.
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_with_material(SolidHandle solid,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string material);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_solid_material(SolidHandle solid);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_styled(SolidHandle solid,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? location, [MarshalAs(UnmanagedType.LPUTF8Str)] string? identification);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_solid_style_location(SolidHandle solid);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_solid_style_identification(SolidHandle solid);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_rect(double w, double h);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_circle(double r);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_slot(double cx, double cy, double length, double r);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_polygon(double[] xy, nuint count);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_regular_polygon(double cx, double cy, double radius, uint sides,
        double angle);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_circumscribed_polygon(double cx, double cy, double radius,
        uint sides, double angle);
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
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_to_arcs(ProfileHandle p, double tolerance);
    [DllImport(Lib)] internal static extern ProfileListHandle cadaclysm_blacksmith_profile_offset(ProfileHandle p, double distance, double tolerance);
    [DllImport(Lib)] internal static extern ProfileListHandle cadaclysm_blacksmith_solid_section(SolidHandle s, double z, double tolerance);
    [DllImport(Lib)] internal static extern ProfileListHandle cadaclysm_blacksmith_profile_text(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string text, double size, [MarshalAs(UnmanagedType.LPUTF8Str)] string font,
        byte[]? fontBytes, nuint fontLen, [MarshalAs(UnmanagedType.LPUTF8Str)] string halign,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string valign, double spacing, [MarshalAs(UnmanagedType.LPUTF8Str)] string direction);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_profile_list_count(ProfileListHandle list);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_list_get(ProfileListHandle list, uint i);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_profile_list_free(IntPtr list);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_translate_profile(ProfileHandle profile, double dx, double dy);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_rotate(ProfileHandle profile, double cx, double cy, double radians);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_scale(ProfileHandle profile, double cx, double cy, double sx, double sy);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_mirror(ProfileHandle profile, double px, double py, double dx, double dy);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_transform2d(ProfileHandle profile, double[] m);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_round(ProfileHandle profile, double radius, uint[]? corners,
        nuint count, [MarshalAs(UnmanagedType.I1)] bool open);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_close_loop(ProfileHandle profile);
    [DllImport(Lib)] internal static extern RawBlacksmithPolylines cadaclysm_blacksmith_profile_polylines(ProfileHandle profile, double tolerance);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_coloured(ProfileHandle profile, double r, double g, double b);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_profile_colour(ProfileHandle profile, [Out] double[] outRgb);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_chain(IntPtr[] pieces, nuint count,
        double tolerance);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_polyline(double[] xy, nuint count,
        [MarshalAs(UnmanagedType.I1)] bool closed);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_arc(double cx, double cy, double r, double a0, double a1);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_arc_through(double x0, double y0, double xm, double ym,
        double x1, double y1);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_ellipse(double cx, double cy, double rx, double ry);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_profile_from_beziers(double[] beziers, nuint count,
        [MarshalAs(UnmanagedType.I1)] bool recognise);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_profile_bezier_count(ProfileHandle profile);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_profile_beziers(ProfileHandle profile, double[]? frame, [Out] double[] outBeziers);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_profile_loops(IntPtr[] pieces, nuint count, double tolerance, [Out] uint[] outLoops);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_profile_chain_order(IntPtr[] pieces, nuint count, double tolerance, [Out] uint[] outOrder);
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
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_pyramid(uint sides, double r, double h);
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
    internal static extern bool cadaclysm_blacksmith_transform_translation(double[] v, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_rotation(double[] axis, double radians, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_mirror(double[] plane, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_scale(double[] centre, double k, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_scale_xyz(double[] frame, double sx, double sy, double sz, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_shear(double[] plane, double[] dir, double factor, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_plane_to_plane(double[] a, double[] b, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_change_basis(double[] from, double[] to, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_planar_projection(double[] plane, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_project_along(double[] plane, double[] dir, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_compose(double[] a, double[] b, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_inverse(double[] m, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_decompose_rigid(double[] m, double tolerance, [Out] double[] outParts);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_decompose_similarity(double[] m, double tolerance, [Out] double[] outParts);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_transform_decompose_affine(double[] m, [Out] double[] outParts);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_quaternion_from_axis_angle(double[] dir, double radians, [Out] double[] outQuaternion);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_quaternion_from_transform(double[] m, [Out] double[] outQuaternion);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_quaternion_to_transform(double[] q, double[] centre, [Out] double[] outMatrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_quaternion_slerp(double[] a, double[] b, double s, [Out] double[] outQuaternion);
    // 1 or 0; NONE (with last_error) for a refused tolerance.
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_transform_is_rigid(double[] m, double tolerance);
    // k > 0, or 0; NaN (with last_error) for a refused tolerance.
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_transform_is_similarity(double[] m, double tolerance);
    // Value geometry (plan B3): every value is a flat array of doubles tagged with its kind,
    // CADACLYSM_BLACKSMITH_VALUE_*. The bool calls write `out` and leave a refusal in last_error.
    internal const uint ValueLine = 0;
    internal const uint ValueCircle = 1;
    internal const uint ValueArc = 2;
    internal const uint ValueEllipse = 3;
    internal const uint ValueSphere = 4;
    internal const uint ValueCylinder = 5;
    internal const uint ValueCone = 6;
    internal const uint ValueTorus = 7;
    internal const uint ValueCuboid = 8;
    // The count of a kind's array; 0 for an unknown kind.
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_value_size(uint kind);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_value_check(uint kind, double[] value, [Out] double[] outValue);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_value_bounds(uint kind, double[] value, [Out] double[] outBounds);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_value_transform(uint kind, double[] value, double[] matrix, [Out] double[] outValue);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_curve_value_point_at(uint kind, double[] value, double t, [Out] double[] outPoint);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_curve_value_tangent_at(uint kind, double[] value, double t, [Out] double[] outTangent);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_curve_value_length(uint kind, double[] value, [Out] double[] outLength);
    // out: t x y z unique
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_curve_value_closest_point(uint kind, double[] value, double[] point, [Out] double[] outFoot);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_circle_through(double[] a, double[] b, double[] c, [Out] double[] outValue);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_arc_through(double[] a, double[] b, double[] c, [Out] double[] outValue);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_arc_from_start_tangent_end(double[] a, double[] tangent, double[] c, [Out] double[] outValue);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_ellipse_from_circle(double[] value, [Out] double[] outValue);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_surface_value_point_at(uint kind, double[] value, double u, double v, [Out] double[] outPoint);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_surface_value_normal_at(uint kind, double[] value, double u, double v, [Out] double[] outNormal);
    // out: u v x y z unique
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_surface_value_closest_point(uint kind, double[] value, double[] point, [Out] double[] outFoot);
    // out: u0 u1 v0 v1
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_surface_value_domain(uint kind, double[] value, [Out] double[] outDomain);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_surface_value_nurbs_sheet(uint kind, double[] value);
    // 1 or 0; NONE (with last_error) for a refusal.
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_solid_value_contains(uint kind, double[] value, double[] point, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_solid_value_area(uint kind, double[] value, [Out] double[] outArea);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_solid_value_volume(uint kind, double[] value, [Out] double[] outVolume);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_solid_value_to_solid(uint kind, double[] value);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_cuboid_from_bounds(double[] min, double[] max, [Out] double[] outValue);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_cuboid_around(double[] frame, double[] xyz, nuint count, [Out] double[] outValue);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_cuboid_corners(double[] value, [Out] double[] outCorners);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_cuboid_point_at(double[] value, double sx, double sy, double sz, [Out] double[] outPoint);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_cuboid_closest_point(double[] value, double[] point, [Out] double[] outPoint);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_frame_fit(double[] xyz, nuint count, [Out] double[] outFrame, out double deviation);
    internal const uint ValueRectangle = 9;
    internal const uint ValueTriangle = 10;
    internal const uint ValueRay = 11;
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rectangle_corners(double[] value, [Out] double[] outCorners);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rectangle_area(double[] value, [Out] double[] outArea);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rectangle_closest_point(double[] value, double[] point,
        [MarshalAs(UnmanagedType.I1)] bool includeInterior, [Out] double[] outPoint);
    // 0 outside, 1 inside, 2 on; NONE (with last_error) for a refusal. NaN tolerance is unset.
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_rectangle_contains(double[] value, double[] point, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_rectangle_to_sheet(double[] value);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_triangle_area(double[] value, [Out] double[] outArea);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_triangle_perimeter(double[] value, [Out] double[] outPerimeter);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_triangle_centroid(double[] value, [Out] double[] outPoint);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_triangle_circumcircle(double[] value, [Out] double[] outCircle);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_triangle_point_at(double[] value, double wa, double wb, double wc, [Out] double[] outPoint);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_triangle_barycentric(double[] value, double[] point, [Out] double[] outWeights);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_triangle_closest_point(double[] value, double[] point, [Out] double[] outPoint);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_triangle_edge(double[] value, uint index, [Out] double[] outLine);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_triangle_to_sheet(double[] value);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_ray_point_at(double[] value, double t, [Out] double[] outPoint);
    // out: t x y z, t clamped at 0
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_ray_closest_point(double[] value, double[] point, [Out] double[] outFoot);
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
    // `inexactOut` receives the trims the call lost (see `Solid.InexactTrims`).
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_solid_transform(SolidHandle solid, double[] matrix, out uint inexactOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_solid_convert_to_nurbs(SolidHandle solid, uint level, out uint inexactOut);
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
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_split_by_profile(SolidHandle solid, ProfileHandle profile,
        double[] frame, double tolerance, IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_lump_count(SolidHandle solid);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_lump(SolidHandle solid, uint index);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_face_count(SolidHandle solid);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_select_face(SolidHandle solid, uint kind, double[]? v, uint index);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_face_frame(SolidHandle solid, uint face, [Out] double[] outFrame);

    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_mass_properties(SolidHandle solid, double accuracy, out RawBlacksmithMassProperties outMass);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_oriented_box(SolidHandle solid, double accuracy, out RawBlacksmithOrientedBox outBox);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge_length(SolidHandle solid, uint edge, double accuracy, out RawBlacksmithLength outLength);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_profile_length(ProfileHandle profile, double accuracy, out RawBlacksmithLength outLength);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge_point_at_length(SolidHandle solid, uint edge, double s, double accuracy, out RawBlacksmithAt outAt);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_edge_divide_by_count(SolidHandle solid, uint edge, uint n, double accuracy);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_edge_divide_by_length(SolidHandle solid, uint edge, double step, double accuracy);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_profile_point_at_length(ProfileHandle profile, double s, double accuracy, out RawBlacksmithAt outAt);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_profile_divide_by_count(ProfileHandle profile, uint n, double accuracy);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_profile_divide_by_length(ProfileHandle profile, double step, double accuracy);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_samples_count(IntPtr samples);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_samples_at(IntPtr samples, uint i, out RawBlacksmithAt outAt);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_samples_free(IntPtr samples);
    // ---- NurbsCurve ----
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_new(double[] xyz, nuint count, double[]? weights, uint degree, double[]? knots, nuint knotCount);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_through(double[] xyz, nuint count, uint degree, [MarshalAs(UnmanagedType.I1)] bool closed, double[]? start, double[]? end);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_fit(double[] xyz, nuint count, uint degree, double tolerance, out double errorOut);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_from_edge(SolidHandle solid, uint edge);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_from_face_isocurve(SolidHandle solid, uint face, [MarshalAs(UnmanagedType.I1)] bool alongU, double at);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_blend(NurbsCurveHandle a, [MarshalAs(UnmanagedType.I1)] bool aEnd, NurbsCurveHandle b, [MarshalAs(UnmanagedType.I1)] bool bEnd, uint continuity, double bulge);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_joined(IntPtr[] curves, nuint count, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_tween(NurbsCurveHandle a, NurbsCurveHandle b, uint count, uint method, uint samples, [MarshalAs(UnmanagedType.I1)] bool align, double tolerance, [Out] IntPtr[] outCurves);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_projected_to_plane(NurbsCurveHandle curve, double[] origin, double[] normal, double[]? direction);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_projected_to_face(NurbsCurveHandle curve, SolidHandle solid, uint face, double[] direction, double tolerance, out double errorOut);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_pulled_to_face(NurbsCurveHandle curve, SolidHandle solid, uint face, double tolerance, out double errorOut);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_reversed(NurbsCurveHandle curve);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_trimmed(NurbsCurveHandle curve, double t0, double t1);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_extended(NurbsCurveHandle curve, [MarshalAs(UnmanagedType.I1)] bool atStart, double length);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_elevated(NurbsCurveHandle curve, uint by);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_transformed(NurbsCurveHandle curve, double[] matrix);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_clone(NurbsCurveHandle curve);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_nurbs_curve_free(IntPtr curve);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_nurbs_curve_degree(NurbsCurveHandle curve);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_nurbs_curve_control_count(NurbsCurveHandle curve);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_nurbs_curve_knot_count(NurbsCurveHandle curve);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_control_points(NurbsCurveHandle curve, [Out] double[] xyz);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_weights(NurbsCurveHandle curve, [Out] double[] w);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_knots(NurbsCurveHandle curve, [Out] double[] k);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_is_rational(NurbsCurveHandle curve);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_is_closed(NurbsCurveHandle curve);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_domain(NurbsCurveHandle curve, [Out] double[] domain);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_point(NurbsCurveHandle curve, double t, [Out] double[] point);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_derivatives(NurbsCurveHandle curve, double t, uint order, [Out] double[] derivatives);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_curvature(NurbsCurveHandle curve, double t, out RawBlacksmithCurvature outCurvature);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_length(NurbsCurveHandle curve, double accuracy, out RawBlacksmithLength outLength);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_point_at_length(NurbsCurveHandle curve, double s, double accuracy, out RawBlacksmithAt outAt);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_nurbs_curve_divide_by_count(NurbsCurveHandle curve, uint n, double accuracy);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_nurbs_curve_divide_by_length(NurbsCurveHandle curve, double step, double accuracy);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_nurbs_curve_plane_hits(NurbsCurveHandle curve, double[] origin, double[] normal);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_nurbs_curve_face_hits(NurbsCurveHandle curve, SolidHandle solid, uint face, double tolerance);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_fair(double[] xyz, nuint count, uint degree, double tolerance,
        [MarshalAs(UnmanagedType.I1)] bool noInflection, double spanFrom, double spanTo, out double errorOut);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_faired(NurbsCurveHandle curve, uint degree, double tolerance,
        [MarshalAs(UnmanagedType.I1)] bool noInflection, double spanFrom, double spanTo, out double errorOut);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_nurbs_curve_inflections(NurbsCurveHandle curve);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_nurbs_curve_knot_continuity(NurbsCurveHandle curve, out RawBlacksmithKnotContinuity outContinuity);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge_continuity(SolidHandle solid, uint edge, uint samples, out RawBlacksmithContinuity outContinuity);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_surface_faired(SolidHandle solid, uint face, double tolerance, uint degree,
        uint controlsU, uint controlsV, int[] keep, uint noInflection, out double errorOut);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_curvature_turns(SolidHandle solid, uint face, uint samples, out RawBlacksmithCurvatureTurns outTurns);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_curvature_turn_points(SolidHandle solid, uint face, uint samples, [MarshalAs(UnmanagedType.I1)] bool mean);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_highlight_kink(SolidHandle solid, uint edge, uint samples, out RawBlacksmithHighlightKink outKink);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_curve_value_to_nurbs(uint kind, double[] value);
    // ---- sheets from curves ----
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_loft_curves(IntPtr[] sections, nuint count, uint degree, [MarshalAs(UnmanagedType.I1)] bool loose, [MarshalAs(UnmanagedType.I1)] bool closed);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_sweep_rail(NurbsCurveHandle rail, IntPtr[] sections, nuint count, uint frame, double[]? up, double tolerance, out double errorOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_sweep_two_rails(NurbsCurveHandle railA, NurbsCurveHandle railB, IntPtr[] sections, nuint count, double tolerance, out double errorOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_edge_surface(IntPtr[] curves, nuint count, double tolerance, out double errorOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_network_surface(IntPtr[] uCurves, nuint uCount, IntPtr[] vCurves, nuint vCount, double tolerance, out double errorOut);
    [DllImport(Lib)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_continuity(SolidHandle a, uint faceA, uint sideA, SolidHandle b, uint faceB, uint sideB, uint samples, out RawBlacksmithContinuity outContinuity);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_match_side(SolidHandle a, uint faceA, uint sideA, SolidHandle b, uint faceB, uint sideB, uint level);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_blend_sides(SolidHandle a, uint faceA, uint sideA, SolidHandle b, uint faceB, uint sideB, uint level, double bulge);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_n_sided_patch(RawBlacksmithPatchBoundary[] boundaries, nuint count, double bulge, double tolerance, out RawBlacksmithPatchReport reportOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_fillet_surfaces(SolidHandle a, uint faceA, SolidHandle b, uint faceB, double radiusStart, double radiusEnd,
        [MarshalAs(UnmanagedType.I1)] bool flipA, [MarshalAs(UnmanagedType.I1)] bool flipB, double tolerance, out IntPtr railA, out IntPtr railB, out double errorOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_fillet_varying(SolidHandle solid, uint[] edges, nuint count, double radiusStart, double radiusEnd, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_fillet_law(SolidHandle solid, uint[] edges, nuint count, double[] shares, double[] radii, nuint stationCount, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_split_by_curve(SolidHandle sheet, NurbsCurveHandle curve, double[]? direction, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_trim_by_curve(SolidHandle sheet, NurbsCurveHandle curve, double[]? direction, [MarshalAs(UnmanagedType.I1)] bool keepInside, double tolerance);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_flange(SolidHandle sheet, uint[] edges, nuint count, NurbsCurveHandle section, double tolerance,
        [MarshalAs(UnmanagedType.I1)] bool join, out double errorOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_extrude_to(SolidHandle sheet, uint[] edges, nuint count, double[]? direction, SolidHandle target, double tolerance,
        [MarshalAs(UnmanagedType.I1)] bool join, out double errorOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_join_sheets(IntPtr[] sheets, nuint count, double tolerance, out RawBlacksmithJoinReport report);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_split_along_curve(SolidHandle sheet, NurbsCurveHandle curve, double tolerance);
    [DllImport(Lib)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_panel_gap(SolidHandle sheet, NurbsCurveHandle curve, double gap, double flange, double tolerance, [Out] IntPtr[] outPanels);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_nurbs_curve_offset_on_sheet(NurbsCurveHandle curve, SolidHandle solid, double distance, double tolerance, out double errorOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_recess(SolidHandle sheet, NurbsCurveHandle outline, double depth, double draft, double fillet, [MarshalAs(UnmanagedType.I1)] bool pane, double tolerance, [Out] uint[] facesOut);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_mirror_join(SolidHandle half, double[] plane, double snap, double tolerance, [Out] double[] reportOut);
    [DllImport(Lib)] internal static extern RTreeHandle cadaclysm_blacksmith_rtree_new();
    [DllImport(Lib)] internal static extern RTreeHandle cadaclysm_blacksmith_rtree_from_boxes(uint[] ids, double[] boxes, uint n);
    [DllImport(Lib)] internal static extern RTreeHandle cadaclysm_blacksmith_rtree_from_points(double[] xyz, uint n);
    [DllImport(Lib)] internal static extern RTreeHandle cadaclysm_blacksmith_rtree_from_triangles(double[] xyz, uint nPoints, uint[] indices, uint nTriangles);
    [DllImport(Lib)] internal static extern RTreeHandle cadaclysm_blacksmith_solid_face_tree(SolidHandle solid);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rtree_insert(RTreeHandle tree, uint id, double[] box);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rtree_insert_point(RTreeHandle tree, uint id, double[] p);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rtree_remove(RTreeHandle tree, uint id, double[] box);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_rtree_count(RTreeHandle tree);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rtree_bounds(RTreeHandle tree, [Out] double[] outBox);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_rtree_free(IntPtr tree);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_rtree_search(RTreeHandle tree, double[] box);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_rtree_within(RTreeHandle tree, double[] p, double r);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_rtree_nearest(RTreeHandle tree, double[] p, uint k);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_rtree_ray(RTreeHandle tree, double[] origin, double[] direction, double maxT);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_rtree_hits_count(IntPtr hits);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rtree_hits_at(IntPtr hits, uint i, out RawBlacksmithRTreeHit outHit);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_rtree_hits_free(IntPtr hits);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_rtree_overlaps(RTreeHandle a, RTreeHandle b, double slack);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_rtree_self_overlaps(RTreeHandle tree, double slack);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_rtree_pairs_count(IntPtr pairs);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_rtree_pairs_at(IntPtr pairs, uint i, out RawBlacksmithRTreePair outPair);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_rtree_pairs_free(IntPtr pairs);
    [DllImport(Lib)] internal static extern InterpolatorHandle cadaclysm_blacksmith_interpolator_new(double[] samples, uint count, uint dimension,
        [MarshalAs(UnmanagedType.I1)] bool cyclic);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_interpolator_count(InterpolatorHandle interpolator);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_interpolator_dimension(InterpolatorHandle interpolator);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_interpolator_cyclic(InterpolatorHandle interpolator);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_interpolator_at(InterpolatorHandle interpolator, double t, uint mode, [Out] double[] outValues,
        uint outLen);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_interpolator_sample(InterpolatorHandle interpolator, double[] ts, uint n, uint mode,
        [Out] double[] outValues, uint outLen);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_interpolator_free(IntPtr interpolator);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_merge(SolidHandle a, SolidHandle b, double tolerance,
        IntPtr progress, IntPtr user);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_regions(SolidHandle solid);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_regions_count(IntPtr regions);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_regions_at(IntPtr regions, uint i, out RawBlacksmithRegion outRegion);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_regions_side_at(IntPtr regions, uint i, uint k, out RawBlacksmithFaceSide outSide);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_regions_free(IntPtr regions);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_region_solid(SolidHandle solid, uint region);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_contains(SolidHandle solid, double[] point, double tolerance, out uint outCode);
    [DllImport(Lib)] internal static extern ClassifierHandle cadaclysm_blacksmith_classifier_new(SolidHandle solid, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_classifier_contains(ClassifierHandle classifier, double[] point, out uint outCode);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_classifier_free(IntPtr classifier);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_closest(SolidHandle a, SolidHandle b, double tolerance, IntPtr progress, IntPtr user,
        out RawBlacksmithClosest outClosest);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_closest_point(SolidHandle solid, double[] p, double maxDistance, double tolerance, out RawBlacksmithPointFoot outFoot);
    [DllImport(Lib)] internal static extern ProjectorHandle cadaclysm_blacksmith_projector_new(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_projector_closest_point(ProjectorHandle projector, double[] p, double maxDistance, out RawBlacksmithPointFoot outFoot);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_projector_free(IntPtr projector);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_face_closest_point(SolidHandle solid, uint face, double[] p, out RawBlacksmithPointFoot outFoot);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_edge_closest_point(SolidHandle solid, uint edge, double[] p, [Out] double[] outFoot);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_nurbs_curve_closest_point(NurbsCurveHandle curve, double[] p, [Out] double[] outFoot);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_nurbs_curve_closest_point_within(NurbsCurveHandle curve, double[] p, double maxDistance, [Out] double[] outFoot);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_nurbs_curve_closest_points(NurbsCurveHandle a, NurbsCurveHandle b, double maxDistance, out RawBlacksmithCurvePair outPair);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_curve_closest_points(SolidHandle solid, NurbsCurveHandle curve, double maxDistance, double tolerance, out RawBlacksmithCurveBodyFoot outFoot);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_projector_curve_closest_points(ProjectorHandle projector, NurbsCurveHandle curve, double maxDistance, out RawBlacksmithCurveBodyFoot outFoot);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_nurbs_curve_closest_object(NurbsCurveHandle curve, byte[] kinds, uint count,
        IntPtr[] solids, uint nSolids, IntPtr[] curves, uint nCurves, double[] points, uint nPoints, IntPtr[] projectors, uint nProjectors,
        double maxDistance, double tolerance, out RawBlacksmithNearestObject outNearest);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_face_ref(SolidHandle solid, uint face, [Out] double[] outRef);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_find_face(SolidHandle solid, double[] faceRef, int hint, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge_ref(SolidHandle solid, uint edge, [Out] double[] outRef);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_find_edge(SolidHandle solid, double[] edgeRef, double tolerance);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_vertex_count(SolidHandle solid);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_vertex_ref(SolidHandle solid, uint vertex, [Out] double[] outRef);
    [DllImport(Lib)] internal static extern int cadaclysm_blacksmith_find_vertex(SolidHandle solid, double[] vertexRef, double tolerance);
    // Identity: face and edge ids (0 for none), their origins, and a verb's history.
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_solid_tracked(SolidHandle solid);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_solid_is_tracked(SolidHandle solid);
    [DllImport(Lib)] internal static extern ulong cadaclysm_blacksmith_face_id(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_face_with_id(SolidHandle solid, ulong id);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_face_origin_count(SolidHandle solid, uint face);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_face_origin_at(SolidHandle solid, uint face, uint i, out uint operand, out ulong id);
    [DllImport(Lib)] internal static extern ulong cadaclysm_blacksmith_edge_id(SolidHandle solid, uint edge);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_edge_with_id(SolidHandle solid, ulong id);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_edge_origin_count(SolidHandle solid, uint edge);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge_origin_at(SolidHandle solid, uint edge, uint i, out uint operand, out ulong id);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_origins_through(SolidHandle outSolid, SolidHandle via);
    // History handles are read whole and freed at once, so they stay raw pointers.
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_history(SolidHandle outSolid, IntPtr[] inputs, nuint count);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_edge_history(SolidHandle outSolid, IntPtr[] inputs, nuint count);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_history_free(IntPtr history);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_history_kept_count(IntPtr history);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_history_kept_at(IntPtr history, uint i, out uint operand, out ulong id, out ulong outId);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_history_modified_count(IntPtr history);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_history_modified_at(IntPtr history, uint i, out uint operand, out ulong id);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_history_modified_output_count(IntPtr history, uint i);
    [DllImport(Lib)] internal static extern ulong cadaclysm_blacksmith_history_modified_output_at(IntPtr history, uint i, uint j);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_history_generated_count(IntPtr history);
    [DllImport(Lib)] internal static extern ulong cadaclysm_blacksmith_history_generated_at(IntPtr history, uint i);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_history_deleted_count(IntPtr history);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_history_deleted_at(IntPtr history, uint i, out uint operand, out ulong id);
    // Attributes: set as `named` is; read back borrowed (good until the solid is freed).
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_with_attribute(SolidHandle solid,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_without_attribute(SolidHandle solid,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string key);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_attribute(SolidHandle solid, [MarshalAs(UnmanagedType.LPUTF8Str)] string key);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_attribute_count(SolidHandle solid);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_attribute_key_at(SolidHandle solid, uint i);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_attribute_value_at(SolidHandle solid, uint i);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_with_face_attribute(SolidHandle solid, uint face,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_without_face_attribute(SolidHandle solid, uint face,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string key);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_face_attribute(SolidHandle solid, uint face,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string key);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_face_attribute_count(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_face_attribute_key_at(SolidHandle solid, uint face, uint i);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_face_attribute_value_at(SolidHandle solid, uint face, uint i);
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
    // A held tessellation: one solid meshed at one tolerance, on a handle of its own so that
    // the views cut from it stay valid regardless of what happens to the solid afterwards.
    [DllImport(Lib)] internal static extern TessellationHandle cadaclysm_blacksmith_tessellation(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_tessellation_free(IntPtr tessellation);
    [DllImport(Lib)] internal static extern RawBlacksmithMesh cadaclysm_blacksmith_tessellation_mesh(TessellationHandle tessellation);
    [DllImport(Lib)] internal static extern RawBlacksmithMesh64 cadaclysm_blacksmith_tessellation_mesh64(TessellationHandle tessellation);
    [DllImport(Lib)] internal static extern RawBlacksmithFaceTriangles cadaclysm_blacksmith_tessellation_face_triangles(TessellationHandle tessellation);
    [DllImport(Lib)] internal static extern RawBlacksmithPolylines cadaclysm_blacksmith_tessellation_edge_polylines(TessellationHandle tessellation);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_bounds(SolidHandle solid, double tolerance, [Out] double[] min, [Out] double[] max);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_bounds64(SolidHandle solid, double tolerance, [Out] double[] min, [Out] double[] max);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_solid_bounds_box(SolidHandle solid, double tolerance, out RawBlacksmithBox outBox);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_box_moved(ref RawBlacksmithBox box_, double[] frame, out RawBlacksmithBox outBox);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_box_overlaps(ref RawBlacksmithBox a, ref RawBlacksmithBox b);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_boxes_apart(ref RawBlacksmithBox a, double[] frameA, ref RawBlacksmithBox b, double[] frameB,
        [MarshalAs(UnmanagedType.I1)] out bool apart);
    [DllImport(Lib)]
    internal static extern ColliderHandle cadaclysm_blacksmith_collider_new(IntPtr[] solids, uint count, double tolerance,
        uint[]? groups, uint[]? allowed, uint allowedCount);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_collider_free(IntPtr collider);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_collider_group_count(ColliderHandle collider);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_collider_stats(ColliderHandle collider, out RawBlacksmithColliderStats outStats);
    [DllImport(Lib)]
    internal static extern CollisionsHandle cadaclysm_blacksmith_collider_check(ColliderHandle collider, double[] frames, uint frameCount,
        uint shareK, uint shareN);
    // Clash: `collider_clash` takes frames as `collider_check` does; the one-shot `clash` takes
    // `b` null with count 0 for one set and `allowed` as a flat list of `allowedCount` pairs.
    [DllImport(Lib)]
    internal static extern ClashesHandle cadaclysm_blacksmith_collider_clash(ColliderHandle collider, double[] frames, uint frameCount,
        double clearance, uint shareK, uint shareN);
    [DllImport(Lib)]
    internal static extern ClashesHandle cadaclysm_blacksmith_clash(IntPtr[] a, uint aCount, IntPtr[]? b, uint bCount, double tolerance,
        double clearance, uint[]? allowed, uint allowedCount);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_clashes_free(IntPtr clashes);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_clashes_count(ClashesHandle clashes);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_clashes_at(ClashesHandle clashes, uint i, out RawBlacksmithClash outClash);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_clashes_solid(ClashesHandle clashes, uint i);
    [DllImport(Lib)] internal static extern IntersectionHandle cadaclysm_blacksmith_clashes_intersect(ClashesHandle clashes, uint i);
    // Swept clash: `collider_swept_clash` takes `poseCount` poses of `frameCount` frames each, 12
    // doubles a frame, pose-major; the one-shot `swept_clash` takes `posesA` as `poseCount x aCount`
    // frames (and `posesB` likewise), `b`/`posesB` null with count 0 for one set, and `allowed` as
    // a flat list of `allowedCount` pairs. `swept_clashes_firsts` gives an owned clashes list.
    [DllImport(Lib)]
    internal static extern SweptClashesHandle cadaclysm_blacksmith_collider_swept_clash(ColliderHandle collider, double[] poses,
        uint poseCount, uint frameCount, double clearance, double resolution, uint maxSteps, uint shareK, uint shareN);
    [DllImport(Lib)]
    internal static extern SweptClashesHandle cadaclysm_blacksmith_swept_clash(IntPtr[] a, uint aCount, double[] posesA, IntPtr[]? b,
        uint bCount, double[]? posesB, uint poseCount, double tolerance, double clearance, double resolution, uint maxSteps,
        uint[]? allowed, uint allowedCount);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_swept_clashes_free(IntPtr swept);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_swept_clashes_count(SweptClashesHandle swept);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_swept_clashes_at(SweptClashesHandle swept, uint i, out RawBlacksmithSweptClash outSwept);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_swept_clashes_interval(SweptClashesHandle swept, uint i, uint k, [Out] double[] outSpan);
    [DllImport(Lib)] internal static extern ClashesHandle cadaclysm_blacksmith_swept_clashes_firsts(SweptClashesHandle swept);
    // Wall thickness. The three lists (`Thicknesses`, `MeshThicknesses`) come back as raw pointers,
    // read out and freed at once by `Blacksmith.ThicknessesOf` / `MeshThicknessesOf`; a gauge's
    // `_mesh` view is borrowed from the gauge and copied before the next call.
    [DllImport(Lib)]
    internal static extern ThicknessGaugeHandle cadaclysm_blacksmith_thickness_gauge_new(IntPtr[] solids, uint count, double tolerance);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_thickness_gauge_free(IntPtr gauge);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_thickness_gauge_body_count(ThicknessGaugeHandle gauge);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_thickness_gauge_tolerance(ThicknessGaugeHandle gauge);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_thickness_gauge_mesh(ThicknessGaugeHandle gauge, uint body,
        out RawBlacksmithThicknessMesh outMesh);
    [DllImport(Lib)]
    internal static extern IntPtr cadaclysm_blacksmith_thickness_gauge_measure(ThicknessGaugeHandle gauge, double maximum, double sharpAngle);
    [DllImport(Lib)]
    internal static extern IntPtr cadaclysm_blacksmith_thickness_gauge_at(ThicknessGaugeHandle gauge, uint body, uint face, double[] point,
        double maximum, double sharpAngle);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_thickness_gauge_face(ThicknessGaugeHandle gauge, uint body, uint face, double[]? at,
        double maximum, out RawBlacksmithFaceThickness outFace);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_thicknesses_free(IntPtr list);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_thicknesses_count(IntPtr list);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_thicknesses_at(IntPtr list, uint i, out RawBlacksmithThickness outRow);
    [DllImport(Lib)]
    internal static extern IntPtr cadaclysm_blacksmith_mesh_thickness(double[] positions, uint[] vertexCounts, uint[] indices,
        uint[] triangleCounts, uint meshCount, double maximum, double sharpAngle);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_mesh_thicknesses_free(IntPtr list);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_mesh_thicknesses_count(IntPtr list);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_mesh_thicknesses_at(IntPtr list, uint i, out RawBlacksmithMeshThickness outRow);
    // The 2D constraint sketcher. The `uint*` lists are borrowed (`IntPtr` + `out nuint count`): valid
    // only until the next call on the same sketch, so `Sketch` copies each before it makes another.
    [DllImport(Lib)] internal static extern SketchHandle cadaclysm_blacksmith_sketch_new();
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_sketch_free(IntPtr sketch);
    [DllImport(Lib)]
    internal static extern SketchHandle cadaclysm_blacksmith_sketch_from_profile(ProfileHandle profile, [MarshalAs(UnmanagedType.I1)] bool infer,
        double tolerance);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_add_point(SketchHandle s, double x, double y);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_add_line(SketchHandle s, uint a, uint b);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_add_circle(SketchHandle s, uint centre, double r);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_add_arc(SketchHandle s, uint centre, uint start, uint end);
    [DllImport(Lib)]
    internal static extern uint cadaclysm_blacksmith_sketch_add_bezier(SketchHandle s, uint start, double c1x, double c1y, double c2x, double c2y,
        double x, double y);
    [DllImport(Lib)]
    internal static extern uint cadaclysm_blacksmith_sketch_add_conic(SketchHandle s, uint start, double cx, double cy, double x, double y,
        double weight);
    [DllImport(Lib)]
    internal static extern uint cadaclysm_blacksmith_sketch_add_nurbs(SketchHandle s, uint start, uint degree, double[] xy, nuint count,
        double[]? weights, double[] knots, nuint knotCount);
    [DllImport(Lib)]
    internal static extern IntPtr cadaclysm_blacksmith_sketch_add_rect(SketchHandle s, double x0, double y0, double x1, double y1, out nuint count);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_kind(SketchHandle s, uint id);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sketch_entities(SketchHandle s, out nuint count);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_point(SketchHandle s, uint id, [Out] double[] xy);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_set_point(SketchHandle s, uint id, double x, double y);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_sketch_radius(SketchHandle s, uint id);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_set_radius(SketchHandle s, uint id, double r);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_centre(SketchHandle s, uint id);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sketch_ends(SketchHandle s, uint id, out nuint count);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_set_construction(SketchHandle s, uint id, [MarshalAs(UnmanagedType.I1)] bool on);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_is_construction(SketchHandle s, uint id);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_is_reference(SketchHandle s, uint id);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sketch_remove_entity(SketchHandle s, uint id, out nuint count);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_reference(SketchHandle s, SketchHandle other, uint entity);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_update_reference(SketchHandle s, uint id, SketchHandle other, [Out] double[] report);
    [DllImport(Lib)]
    internal static extern uint cadaclysm_blacksmith_sketch_constrain(SketchHandle s, uint kind, uint[] refs, nuint refCount, double value,
        [MarshalAs(UnmanagedType.I1)] bool driving, uint sense, uint end);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sketch_constraints(SketchHandle s, out nuint count);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_constraint_kind(SketchHandle s, uint id);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sketch_constraint_refs(SketchHandle s, uint id, out nuint count);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_sketch_constraint_value(SketchHandle s, uint id);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_constraint_driving(SketchHandle s, uint id);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_constraint_sense(SketchHandle s, uint id);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_sketch_constraint_end(SketchHandle s, uint id);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_is_joint_tangent(SketchHandle s, uint id);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_remove(SketchHandle s, uint id);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_set_value(SketchHandle s, uint id, double value, [Out] double[] report);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_set_driving(SketchHandle s, uint id, [MarshalAs(UnmanagedType.I1)] bool driving,
        [Out] double[] report);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_sketch_measure(SketchHandle s, uint id);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_solve(SketchHandle s, [Out] double[] report);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_drag(SketchHandle s, uint[] points, double[] xy, nuint count, [Out] double[] report);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sketch_report_ids(SketchHandle s, out nuint count);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_diagnose(SketchHandle s, [Out] double[] output);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sketch_dof_list(SketchHandle s, uint which, out nuint count);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_sketch_dof_part(SketchHandle s, uint part, [Out] double[] output);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_sketch_dof_part_list(SketchHandle s, uint part, uint which, out nuint count);
    [DllImport(Lib)] internal static extern ProfileListHandle cadaclysm_blacksmith_sketch_profiles(SketchHandle s, double tolerance);
    [DllImport(Lib)] internal static extern ProfileListHandle cadaclysm_blacksmith_sketch_open_chains(SketchHandle s, double tolerance);
    // The SubD cage. Every edit returns a new owned cage, or null with `last_error` set; the
    // input is untouched. `subd_pick` answers false with an empty `last_error` for nothing near.
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_cuboid(double sx, double sy, double sz, uint nx, uint ny, uint nz);
    [DllImport(Lib)]
    internal static extern SubdHandle cadaclysm_blacksmith_subd_cylinder(double radius, double height, uint sides, uint rings,
        [MarshalAs(UnmanagedType.I1)] bool creasedRims);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_sphere(double radius, uint segments);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_torus(double major, double minor, uint around, uint tube);
    [DllImport(Lib)]
    internal static extern SubdHandle cadaclysm_blacksmith_subd_from_parts(double[] positions, uint vertexCount, uint[] faceSizes, uint faceCount,
        uint[] faceIndices, uint indexCount, uint[] creases, uint creaseCount, uint[] pins, uint pinCount, int symmetryAxis, double symmetryTolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_subd_parts(SubdHandle subd, out RawBlacksmithSubdParts outParts);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_subd_free(IntPtr subd);
    [DllImport(Lib)]
    internal static extern SubdHandle cadaclysm_blacksmith_subd_transform(SubdHandle subd, uint kind, uint[] ids, uint idCount, double[] matrix);
    [DllImport(Lib)]
    internal static extern SubdHandle cadaclysm_blacksmith_subd_set_crease(SubdHandle subd, uint[] edges, uint edgeCount,
        [MarshalAs(UnmanagedType.I1)] bool on);
    [DllImport(Lib)]
    internal static extern SubdHandle cadaclysm_blacksmith_subd_set_pin(SubdHandle subd, uint[] vertices, uint vertexCount,
        [MarshalAs(UnmanagedType.I1)] bool on);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_extrude(SubdHandle subd, uint[] faces, uint faceCount, double distance);
    [DllImport(Lib)]
    internal static extern SubdHandle cadaclysm_blacksmith_subd_inset(SubdHandle subd, uint[] faces, uint faceCount, double amount,
        [MarshalAs(UnmanagedType.I1)] bool individual);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_subdivide(SubdHandle subd, uint[] faces, uint faceCount);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_insert_loop(SubdHandle subd, uint a, uint b, double at);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_mirror_on(SubdHandle subd, uint axis);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_mirror_off(SubdHandle subd);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_full(SubdHandle subd);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_subd_edge_loop(SubdHandle subd, uint a, uint b);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_subd_smooth_mesh(SubdHandle subd, uint levels, out RawBlacksmithSubdMesh outMesh);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_subd_pick(SubdHandle subd, double[] point, uint kind, uint[] output);
    [DllImport(Lib)]
    internal static extern SolidHandle cadaclysm_blacksmith_subd_to_solid(SubdHandle subd, double tolerance, double g1AngleDeg, uint maxLevels,
        out RawBlacksmithSubdReport report);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_collisions_free(IntPtr collisions);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_collisions_count(CollisionsHandle collisions);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_collisions_hit(CollisionsHandle collisions, uint i, out RawBlacksmithCollisionHit outHit);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_collisions_solid(CollisionsHandle collisions, uint i);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_box(SolidHandle solid, [Out] double[] min, [Out] double[] max);
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
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_fem_mesh_crossing_count(FemMeshHandle mesh);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_fem_mesh_crossing(FemMeshHandle mesh, uint index,
        out uint outA, out uint outB);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_fem_mesh_msh_text(FemMeshHandle mesh);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_fem_mesh_save_msh(FemMeshHandle mesh,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_leaked_edges(SolidHandle solid, double tolerance);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_unpaired_edges(SolidHandle solid, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_manifold(SolidHandle solid, [Out] uint[] outRow);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_face_round_radius(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_face_chamfer_distance(SolidHandle solid, uint face);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_edge_bezier_count(SolidHandle solid, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_edge_beziers(SolidHandle solid, double tolerance, [Out] double[] outBeziers);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_isocurve_bezier_count(SolidHandle solid, uint density, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_isocurve_beziers(SolidHandle solid, uint density, double tolerance, [Out] double[] outBeziers);
    [DllImport(Lib)] internal static extern HealthHandle cadaclysm_blacksmith_health(SolidHandle solid, double tolerance, [MarshalAs(UnmanagedType.I1)] bool mesh);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_health_free(IntPtr health);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_health_summary(HealthHandle health, [Out] uint[] counts, [Out] double[] sizes);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_health_free_edges(HealthHandle health, [Out] uint[]? ids, [Out] double[]? sizes);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_health_wires(HealthHandle health, [Out] uint[]? runs, [Out] double[]? sizes);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_health_small(HealthHandle health, [Out] uint[]? items, [Out] double[]? sizes);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_health_crack_edges(HealthHandle health, [Out] uint[]? ids);
    [DllImport(Lib)] internal static extern HealHandle cadaclysm_blacksmith_healed(SolidHandle solid, double tolerance, uint flags);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_heal_body(HealHandle heal);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_heal_free(IntPtr heal);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_heal_summary(HealHandle heal, [Out] uint[] counts, [Out] double[] sizes);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_heal_fixes(HealHandle heal, [Out] uint[]? items, [Out] double[]? sizes);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_heal_refused(HealHandle heal, [Out] uint[]? items, [Out] double[]? sizes);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_edge_tolerance(SolidHandle solid, uint edge);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_effective_tolerance(IntPtr[] solids, nuint count);
    [DllImport(Lib)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_solid_tolerances(SolidHandle solid, out double absolute, out double angular);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_solid_with_tolerances(SolidHandle solid, double absolute, double angular);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_vertex_tolerance(SolidHandle solid, double x, double y, double z);
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
    // A `.3dm` comes back as owned bytes, `len` long, released with `bytes_free` and that same
    // length -- never `string_free`. On success a non-null `last_error` holds the writer's notes,
    // one a line (a body written as its mesh, and so on).
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_3dm_bytes(IntPtr[] solids, nuint count, uint unit, out nuint len);
    // `mesh_file`'s bytes are owned the same way: `bytes_free` with that length. `names` null or
    // one UTF-8 string a solid, `looks` null or six doubles a solid.
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_mesh_file(IntPtr[] solids, nuint count,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string format, IntPtr[]? names, double[]? looks, double tolerance, out nuint len);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_3dm(IntPtr[] solids, nuint count,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, uint unit);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_assembly_3dm_bytes(AssemblyHandle assembly, uint unit, out nuint len);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_assembly_3dm(AssemblyHandle assembly,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, uint unit);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_bytes_free(IntPtr bytes, nuint len);
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
    // `placements` is a raw `IntPtr[]` of UTF-8 C strings: the CLR's marshaller refuses
    // `LPArray(ArraySubType = LPUTF8Str)` ("Invalid managed/unmanaged type combination"), so
    // `Assembly.Link` allocates each string with `Marshal.StringToCoTaskMemUTF8` and frees them
    // itself, once each, in a `finally` -- the per-string allocations and the array itself all
    // stay alive for exactly the call. `placements` may be null only when `count` is 0 (an
    // empty list still reaches C as count 0, not a null array, so the kernel's own "names no
    // placements" refusal comes back rather than a marshalling failure). Both refuse (false)
    // and leave the assembly unchanged, with the reason in `last_error`, like `license_set`.
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_assembly_link(AssemblyHandle a,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, IntPtr[]? placements, nuint count);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_assembly_joint(AssemblyHandle a,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, [MarshalAs(UnmanagedType.LPUTF8Str)] string start,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string end);
    // `assembly_pair`/`assembly_state`/`assembly_base`/`pair_freedom_count`: the pair plan's
    // four entry points (spec 2026-09-28/29). Ranges are four parallel arrays of
    // `freedomCount` entries (all null with `freedomCount` 0 for none); `hasLower`/`hasUpper`
    // are one byte per entry (1/0, matching the header's C `bool`), since the CLR marshaller
    // has no narrow `bool[]` the way `MarshalAs(I1)` narrows one `bool`. `pitch` is NaN unless
    // the caller gave one. False refuses and leaves the assembly unchanged, with the reason in
    // `last_error`, like `assembly_link`.
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_assembly_pair(AssemblyHandle a,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string joint, [MarshalAs(UnmanagedType.LPUTF8Str)] string kind,
        double[] frame, double[]? endFrame,
        double[]? lower, double[]? upper, byte[]? hasLower, byte[]? hasUpper,
        nuint freedomCount, double pitch);
    // `assembly_pair` with `params` (`paramCount` doubles) in place of the pitch, for the
    // coupled pairs; the ranges are the same four parallel arrays.
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_assembly_pair_with(AssemblyHandle a,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string joint, [MarshalAs(UnmanagedType.LPUTF8Str)] string kind,
        double[] frame, double[]? endFrame,
        double[]? lower, double[]? upper, byte[]? hasLower, byte[]? hasUpper,
        nuint freedomCount, double[]? @params, nuint paramCount);
    // `joints` is a raw `IntPtr[]` of UTF-8 C strings, allocated and freed exactly as
    // `assembly_link`'s `placements` is; row i sets joint `joints[i]` to `counts[i]` values,
    // consecutive in `values`.
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_assembly_state(AssemblyHandle a,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, IntPtr[]? joints, uint[]? counts,
        double[]? values, nuint rowCount);
    // `states` and `interpolations` are raw `IntPtr[]`s of UTF-8 C strings, allocated and freed
    // as `assembly_state`'s `joints` are; `ts` holds one parameter per segment.
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_assembly_sequence(AssemblyHandle a,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, IntPtr[] states, double[] ts,
        IntPtr[] interpolations, nuint count, [MarshalAs(UnmanagedType.I1)] bool seconds);
    // The posed copy: `joints`, `counts`, `values` laid out as `assembly_state`'s are; null `state`
    // or `ground` means none. Returns a new owned assembly, or null with `last_error` set.
    [DllImport(Lib)]
    internal static extern AssemblyHandle cadaclysm_blacksmith_assembly_posed(AssemblyHandle a,
        IntPtr[]? joints, uint[]? counts, double[]? values, nuint rowCount,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? state, [MarshalAs(UnmanagedType.LPUTF8Str)] string? ground);
    // The solids under an assembly, depth first: `part_path` is owned, freed with `string_free`,
    // and null past `part_count`.
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_assembly_part_count(AssemblyHandle a);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_assembly_part_path(AssemblyHandle a, uint i);
    // The mechanism sweep: `joints` and `counts` laid out as `assembly_posed`'s, `values` key-major
    // (keyframe 0's values for every joint, then keyframe 1's), `ground` null for none, and
    // `allowed` a flat list of `allowedCount` pairs.
    [DllImport(Lib)]
    internal static extern SweptClashesHandle cadaclysm_blacksmith_assembly_swept_clash(AssemblyHandle a,
        IntPtr[]? joints, uint[]? counts, nuint jointCount, double[]? values, uint keyCount,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? ground, double tolerance, double clearance, double resolution,
        uint maxSteps, uint[]? allowed, uint allowedCount, [MarshalAs(UnmanagedType.I1)] bool joined);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_assembly_base(AssemblyHandle a,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string link);
    // How many freedoms a pair kind has, so a caller can size `Assembly.Pair`'s `ranges`: 0
    // for an unknown name, and for `fully_constrained`, which has none.
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_pair_freedom_count(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string kind);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_svg_options_init(ref RawBlacksmithSvgOptions options);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_parse_colour(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string text, [Out] double[] rgb);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_option_set(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, double value);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_option_get(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, out double value);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_svg_text(IntPtr[] solids, nuint count, ref RawBlacksmithSvgOptions options);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_svg(IntPtr[] solids, nuint count,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string path, ref RawBlacksmithSvgOptions options);

    // OWNED: 16 doubles a curve (four control points xyz, then four weights), released by the
    // matching `_free` with the same count. `BlacksmithNative`'s only caller of the pair is
    // `Blacksmith.SilhouetteBeziersOf`, which frees before it returns.
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_silhouette_beziers(SolidHandle solid,
        ref RawBlacksmithSvgOptions options, out uint count);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_silhouette_beziers_free(IntPtr data, uint count);

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
    // Machining. Tools, stocks and jobs are handles of their own; `job_gcode`/`job_camotics`,
    // `job_machine` and `job_operations` hand back lists whose strings are **borrowed** from
    // the list (good until its free), so each is read through `Text` -- a copy -- before the
    // list's `SafeHandle` is disposed. `job_machine`'s drills are raw pointers, as `step`'s
    // solids are: the marshaller cannot ref-count an array of SafeHandles.
    [DllImport(Lib)] internal static extern ToolHandle cadaclysm_blacksmith_tool_flat(uint number, double diameter, double fluteLength,
        double feed, double plunge, double rpm);
    [DllImport(Lib)] internal static extern ToolHandle cadaclysm_blacksmith_tool_ball(uint number, double diameter, double fluteLength,
        double feed, double plunge, double rpm);
    [DllImport(Lib)] internal static extern ToolHandle cadaclysm_blacksmith_tool_drill(uint number, double diameter, double fluteLength,
        double feed, double rpm);
    [DllImport(Lib)] internal static extern ToolHandle cadaclysm_blacksmith_tool_with_ramp_angle(ToolHandle t, double degrees);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_tool_free(IntPtr t);
    [DllImport(Lib)] internal static extern StockHandle cadaclysm_blacksmith_stock_box(double minX, double minY, double minZ,
        double maxX, double maxY, double maxZ);
    [DllImport(Lib)] internal static extern StockHandle cadaclysm_blacksmith_stock_around(SolidHandle s, double margin);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_stock_free(IntPtr s);
    [DllImport(Lib)] internal static extern JobHandle cadaclysm_blacksmith_job_new(StockHandle stock, double safeZ);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_set_clearance(JobHandle j, double clearance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_set_tolerance(JobHandle j, double tolerance);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_set_spindle_dwell(JobHandle j, double seconds);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_set_name(JobHandle j, [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_set_resolution(JobHandle j, double resolution);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_face(JobHandle j, ToolHandle t, double z, double stepover, double stepdown);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_contour(JobHandle j, ToolHandle t, ProfileHandle p, double top, double bottom,
        uint side, double stepdown, [MarshalAs(UnmanagedType.I1)] bool climb, [MarshalAs(UnmanagedType.I1)] bool open);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_pocket(JobHandle j, ToolHandle t, ProfileHandle p, double top, double bottom,
        double stepover, double stepdown);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_job_drill(JobHandle j, ToolHandle t, double[] xy, nuint count, double top,
        double bottom, double peck);
    [DllImport(Lib)] internal static extern ProgramsHandle cadaclysm_blacksmith_job_gcode(JobHandle j);
    [DllImport(Lib)] internal static extern ProgramsHandle cadaclysm_blacksmith_job_camotics(JobHandle j,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string stem);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_job_free(IntPtr j);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_programs_count(ProgramsHandle l);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_programs_tool(ProgramsHandle l, uint i);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_programs_name(ProgramsHandle l, uint i);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_programs_text(ProgramsHandle l, uint i);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_programs_free(IntPtr l);
    [DllImport(Lib)] internal static extern ReportHandle cadaclysm_blacksmith_job_machine(JobHandle j, SolidHandle part, ToolHandle endMill,
        IntPtr[] drills, nuint drillCount, double stepover, double stepdown, double skin, double peck);
    [DllImport(Lib)] internal static extern ReportHandle cadaclysm_blacksmith_job_machine_with(JobHandle j, SolidHandle part,
        IntPtr[] endMills, nuint endMillCount, IntPtr[] drills, nuint drillCount, double stepover, double stepdown,
        double skin, double peck);
    [DllImport(Lib)] internal static extern ReportHandle cadaclysm_blacksmith_job_machine_relieved(JobHandle j, SolidHandle part,
        IntPtr[] endMills, nuint endMillCount, IntPtr[] drills, nuint drillCount, double stepover, double stepdown,
        double skin, double peck, [MarshalAs(UnmanagedType.I1)] bool cornerRelief);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_report_top(ReportHandle r, uint i);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_report_bottom(ReportHandle r, uint i);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_report_count(ReportHandle r);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_report_kind(ReportHandle r, uint i);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_report_at(ReportHandle r, uint i, [Out] double[] outAt);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_report_size(ReportHandle r, uint i);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_report_reason(ReportHandle r, uint i);
    [DllImport(Lib)] internal static extern ProfileListHandle cadaclysm_blacksmith_report_region(ReportHandle r, uint i);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_report_text(ReportHandle r);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_report_free(IntPtr r);
    [DllImport(Lib)] internal static extern OperationsHandle cadaclysm_blacksmith_job_operations(JobHandle j);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_operations_count(OperationsHandle l);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_operations_kind(OperationsHandle l, uint i);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_operations_tool(OperationsHandle l, uint i);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_operations_param_count(OperationsHandle l, uint i);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_operations_param_name(OperationsHandle l, uint i, uint k);
    [DllImport(Lib)] internal static extern double cadaclysm_blacksmith_operations_param_value(OperationsHandle l, uint i, uint k);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_operations_free(IntPtr l);
    // The document: every `char *` answer is owned, read then given to `string_free`; null is a
    // refusal with `last_error`. Results are new handles of the caller's own.
    [DllImport(Lib)] internal static extern DocumentHandle cadaclysm_blacksmith_document_new([MarshalAs(UnmanagedType.LPUTF8Str)] string? units);
    [DllImport(Lib)] internal static extern DocumentHandle cadaclysm_blacksmith_document_load([MarshalAs(UnmanagedType.LPUTF8Str)] string text);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_save(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_apply(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string op, [MarshalAs(UnmanagedType.LPUTF8Str)] string? message);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_preview(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string op);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_document_preview_begin(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_end_preview(DocumentHandle doc);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_document_batch_begin(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? message);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_batch_end(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_batch_abort(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_undo(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_redo(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_params(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_evaluate(DocumentHandle doc,
        [MarshalAs(UnmanagedType.I1)] bool cheapOnly);
    /// <summary>`CadaclysmBlacksmithDocumentProgress`: the node id, the phase, done of total, the user pointer.</summary>
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void DocumentProgress(IntPtr node, IntPtr phase, UIntPtr done, UIntPtr total, IntPtr user);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_evaluate_with(DocumentHandle doc,
        [MarshalAs(UnmanagedType.I1)] bool cheapOnly, DocumentProgress? progress, IntPtr user);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_result_kind(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Lib)] internal static extern SolidHandle cadaclysm_blacksmith_document_result_solid(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_document_result_profile(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Lib)] internal static extern uint cadaclysm_blacksmith_document_result_profile_count(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Lib)] internal static extern ProfileHandle cadaclysm_blacksmith_document_result_profile_at(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id, uint i);
    [DllImport(Lib)] internal static extern NurbsCurveHandle cadaclysm_blacksmith_document_result_nurbs_curve(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Lib)] internal static extern SubdHandle cadaclysm_blacksmith_document_result_subd(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_value(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string id);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_errors(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_kinds();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_solid_body(SolidHandle solid);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_profile_path(ProfileHandle profile);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_branch_new(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, [MarshalAs(UnmanagedType.LPUTF8Str)] string? at);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_branch_switch(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string nameOrCommitId);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_tips(DocumentHandle doc);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_document_branch_rename(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string old, [MarshalAs(UnmanagedType.LPUTF8Str)] string @new);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_blacksmith_document_branch_delete(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_branch_list(DocumentHandle doc);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_blacksmith_document_log(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? branch);
    [DllImport(Lib)] internal static extern void cadaclysm_blacksmith_document_free(IntPtr doc);
    // The building document: a document opened with the `bim.*` kinds, and its IFC export.
    [DllImport(Lib)] internal static extern DocumentHandle cadaclysm_bim_document_new([MarshalAs(UnmanagedType.LPUTF8Str)] string? units);
    [DllImport(Lib)] internal static extern DocumentHandle cadaclysm_bim_document_load([MarshalAs(UnmanagedType.LPUTF8Str)] string text);
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_bim_kinds();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_bim_document_export_ifc(DocumentHandle doc,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? optionsJson);
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

    /// <summary>Set a kernel option, by its name, for the whole process from the next call on:
    /// "boolean.mesh_budget", "boolean.finest_tolerance", "profile_boolean.point_budget",
    /// "measure.default_accuracy", "step.validation_properties",
    /// "step.validation_accuracy", "tolerance.relative" or
    /// "tolerance.angular". Throws -- and changes nothing -- for a name that is not an
    /// option or a value it does not take, saying which and what it takes. The last two stamp
    /// a written STEP part file with each body's measured area, volume and centroid, there for
    /// the kernel that reads the file to check the transfer against; off by default, since it
    /// measures every body in the file at "step.validation_accuracy" (1e-5).</summary>
    public static void SetOption(string name, double value)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_option_set(name, value)) throw Failure($"option '{name}' refused");
    }

    /// <summary>A kernel option's value, by its name: what <see cref="SetOption"/> last set,
    /// else its default. Throws for a name that is not an option, listing the ones there are.</summary>
    public static double Option(string name)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_option_get(name, out var value)) throw Failure($"no option '{name}'");
        return value;
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

    /// <summary>How many freedoms a pair kind has, so a caller can size
    /// <see cref="Assembly.Pair"/>'s `ranges`. 0 for an unknown name, and for
    /// "fully_constrained", which has none.</summary>
    public static int PairFreedomCount(string kind) => (int)BlacksmithNative.cadaclysm_blacksmith_pair_freedom_count(kind);

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

    /// <summary>Several solids as one Rhino `.3dm` (version 8, which Rhino 8 and 9 open), one
    /// object each: its exact brep, or -- where a body has no exact form there -- its mesh, with
    /// a warning saying so. Each object is named as its solid is, coloured with the solid's own
    /// colour (a face's or an edge's own is left out) and carries the solid's attributes as user
    /// text. The warnings -- one a line of what was not written as itself -- go to <see
    /// cref="System.Diagnostics.Trace.TraceWarning(string)"/>, each starting "3dm: ".</summary>
    /// <param name="unit">The file's unit: "m", "mm" or "in". The numbers written are the
    /// numbers held.</param>
    public static byte[] Rhino3dmBytes(IEnumerable<Solid> solids, string unit = "mm")
    {
        var unitCode = UnitCode(unit);
        var owners = solids.ToArray();
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var raw = BlacksmithNative.cadaclysm_blacksmith_3dm_bytes(handles, (nuint)handles.Length, unitCode, out var len);
        GC.KeepAlive(owners);
        return Taken3dm(raw, len, "3dm_bytes");
    }

    /// <summary><see cref="Rhino3dmBytes"/> written to <paramref name="path"/> by the library
    /// itself, which names the file in its refusal when it cannot.</summary>
    public static void Write3dm(string path, IEnumerable<Solid> solids, string unit = "mm")
    {
        var unitCode = UnitCode(unit);
        var owners = solids.ToArray();
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var ok = BlacksmithNative.cadaclysm_blacksmith_3dm(handles, (nuint)handles.Length, path, unitCode);
        GC.KeepAlive(owners);
        if (!ok) throw Failure("3dm");
        Warn3dm();
    }

    /// <summary>What a `.3dm` write did not write as itself -- `last_error` on a success, a
    /// line each -- said as one <see cref="System.Diagnostics.Trace.TraceWarning(string)"/>
    /// per line.</summary>
    internal static void Warn3dm()
    {
        foreach (var line in LastError().Split('\n', StringSplitOptions.RemoveEmptyEntries))
            System.Diagnostics.Trace.TraceWarning($"3dm: {line}");
    }

    /// <summary>The bytes a `.3dm` call handed over, copied out and released with
    /// `bytes_free`, its notes warned; a null is the failure `last_error` names.</summary>
    internal static byte[] Taken3dm(IntPtr raw, nuint len, string what)
    {
        if (raw == IntPtr.Zero) throw Failure(what);
        Warn3dm();
        try
        {
            var bytes = new byte[checked((int)len)];
            Marshal.Copy(raw, bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_bytes_free(raw, len);
        }
    }

    /// <summary>Several solids meshed at `tolerance` (null: each one's effective tolerance) --
    /// each the mesh <c>Solid.Mesh</c> hands out -- as one file's bytes in `format`: "stl"
    /// (binary, every solid in one body), "stl-ascii" (one body named as the first solid), "obj"
    /// (one named object a solid, no material library), "glb" or "gltf" (one named node a solid
    /// in a material of its own; the `.gltf` with its buffer embedded). `names` one a solid
    /// (null: each solid's own name, else `Solid 1`, `Solid 2`, ...). `looks` one a solid, six
    /// numbers each -- linear (r, g, b, a, metallic, roughness) in 0..1 -- the glTF's materials
    /// (null: each solid's own colour); STL and OBJ ignore them.</summary>
    public static byte[] MeshFile(IEnumerable<Solid> solids, string format = "stl", IEnumerable<string>? names = null,
        IEnumerable<IEnumerable<double>>? looks = null, double? tolerance = null)
    {
        var owners = solids.ToArray();
        var nameList = names?.ToArray();
        if (nameList is not null && nameList.Length != owners.Length)
            throw new BuildException($"mesh_file: {nameList.Length} names for {owners.Length} solids");
        var flat = looks?.SelectMany(l => l).ToArray();
        if (flat is not null && flat.Length != 6 * owners.Length)
            throw new BuildException($"mesh_file: {flat.Length} look values for {owners.Length} solids -- 6 a solid");
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var native = nameList?.Select(Marshal.StringToCoTaskMemUTF8).ToArray();
        try
        {
            var raw = BlacksmithNative.cadaclysm_blacksmith_mesh_file(handles, (nuint)handles.Length, format, native, flat,
                Tol(tolerance), out var len);
            GC.KeepAlive(owners);
            if (raw == IntPtr.Zero) throw Failure("mesh_file");
            try
            {
                var bytes = new byte[checked((int)len)];
                Marshal.Copy(raw, bytes, 0, bytes.Length);
                return bytes;
            }
            finally
            {
                BlacksmithNative.cadaclysm_blacksmith_bytes_free(raw, len);
            }
        }
        finally
        {
            if (native is not null) foreach (var n in native) Marshal.FreeCoTaskMem(n);
        }
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

    /// <summary>The curves where <paramref name="solid"/>'s surfaces turn away from the camera
    /// <paramref name="options"/> describes, as cubic Béziers -- <see cref="Solid.SilhouetteBeziers"/>.
    /// The library hands back one owned block of 16 doubles a curve; this unpacks it into the two
    /// arrays <see cref="BeziersData64"/> carries and frees the block before it returns, so
    /// nothing here outlives the call. An empty answer is a null block with no message, a refusal
    /// is a null block with one: the library clears the error slot as this call starts (it runs under
    /// its `guard`), so the slot read straight after is this call's own.</summary>
    internal static BeziersData64 SilhouetteBeziersOf(Solid solid, SvgOptions? options)
    {
        var raw = BuildSvgOptions(options);
        var data = BlacksmithNative.cadaclysm_blacksmith_silhouette_beziers(solid.Handle, ref raw, out var count);
        if (data == IntPtr.Zero)
        {
            if (LastError().Length > 0) throw Failure("silhouette");
            return new BeziersData64(Array.Empty<double>(), Array.Empty<double>());
        }
        try
        {
            var n = checked((int)count);
            var flat = new double[n * 16];
            Marshal.Copy(data, flat, 0, flat.Length);
            var points = new double[n * 12];
            var weights = new double[n * 4];
            for (var i = 0; i < n; i++)
            {
                Array.Copy(flat, i * 16, points, i * 12, 12);
                Array.Copy(flat, i * 16 + 12, weights, i * 4, 4);
            }
            return new BeziersData64(points, weights);
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_silhouette_beziers_free(data, count);
        }
    }

    /// <summary><see cref="SvgOptions"/>, packed into `RawBlacksmithSvgOptions`: `View` fills
    /// `Azimuth`/`Elevation` unless they are set directly, `Up` defaults to "z" (a solid
    /// carries no convention of its own), colours are `'#rgb'`, `'#rrggbb'` or a CSS colour name -- as the reader's own
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
        raw.Stroke = o.Stroke.Packed("svg: stroke");
        raw.Background = o.Background is { } background ? background.Packed("svg: background") : 0xFFFFFFFFu; // CADACLYSM_BLACKSMITH_SVG_TRANSPARENT
        raw.Flags = (o.Edges ? 1u : 0u) | (o.Curves ? 2u : 0u) | (o.Isocurves ? 4u : 0u) | (o.Polylines ? 8u : 0u)
            | (o.Silhouettes ? 16u : 0u);
        return raw;
    }

    /// <summary>(r, g, b) in 0..1 from colour text -- `"#rgb"`, `"#rrggbb"` or a CSS colour name --
    /// read by the library's own parser, so every wrapper takes the same forms.</summary>
    private static bool TryParse(string colour, double[] rgb) =>
        BlacksmithNative.cadaclysm_blacksmith_parse_colour(colour, rgb);

    /// <summary>(r, g, b) in 0..1 from colour text, for a paint entry point that also takes a
    /// numeric triple -- <paramref name="what"/> is that verb, so the refusal lists every form
    /// paint accepts, `(r, g, b) in 0..1` included.</summary>
    internal static double[] Rgb(string colour, string what)
    {
        var rgb = new double[3];
        if (TryParse(colour, rgb)) return rgb;
        throw new BuildException($"{what}: a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or (r, g, b) in 0..1, not '{colour}'");
    }

    private static uint Pack(double[] rgb) =>
        ((uint)Math.Round(rgb[0] * 255) << 16) | ((uint)Math.Round(rgb[1] * 255) << 8) | (uint)Math.Round(rgb[2] * 255);

    /// <summary>A colour as the ABI's packed `0xRRGGBB`, from `"#rgb"`, `"#rrggbb"` or a CSS colour name --
    /// for a host that wants the number itself (<see cref="SvgOptions.Stroke"/>/<see
    /// cref="SvgOptions.Background"/> take the text directly). Takes no numeric triple of its
    /// own, so its refusal lists only the text forms.</summary>
    public static uint Packed(string colour)
    {
        var rgb = new double[3];
        if (!TryParse(colour, rgb))
            throw new BuildException($"colour: a colour is \"#rgb\", \"#rrggbb\" or a CSS colour name, not '{colour}'");
        return Pack(rgb);
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

    /// <summary>Owned text the library returned, read and given back with `string_free`; a null
    /// one is the refusal named <paramref name="what"/> (the library's reason, or that name).</summary>
    internal static string OwnedText(IntPtr raw, string what)
    {
        if (raw == IntPtr.Zero) throw Failure(what);
        try
        {
            return Marshal.PtrToStringUTF8(raw) ?? "";
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
        }
    }

    /// <summary>A verb's distance tolerance as the C ABI takes it: null is unset, NaN, which the
    /// library works at the inputs' <see cref="EffectiveTolerance"/> (as it does 0).</summary>
    internal static double Tol(double? tolerance) => tolerance ?? double.NaN;

    internal static double? Declared(double value) => double.IsNaN(value) ? null : value;

    /// <summary>The tolerance a verb given a null (or 0) <c>tolerance</c> works at over
    /// <c>solids</c>: the larger of the loosest absolute tolerance they declare
    /// (<see cref="Solid.Tolerances"/>) and <c>Option("tolerance.relative")</c> times the
    /// largest of their sizes, never finer than their coordinates can represent. 0 for no
    /// solids, or solids with nothing to size by -- which a verb refuses.</summary>
    public static double EffectiveTolerance(params Solid[] solids)
    {
        var handles = solids.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var t = BlacksmithNative.cadaclysm_blacksmith_effective_tolerance(handles, (nuint)handles.Length);
        GC.KeepAlive(solids);
        if (double.IsNaN(t)) throw Failure("effective_tolerance");
        return t;
    }

    /// <summary>The list a divide returned, read through `samples_count`/`samples_at` and freed
    /// on every path; a null list is the divide's refusal, named `what`.</summary>
    internal static List<At> Samples(IntPtr list, string what)
    {
        if (list == IntPtr.Zero) throw Failure(what);
        try
        {
            var n = BlacksmithNative.cadaclysm_blacksmith_samples_count(list);
            var found = new List<At>((int)Math.Min(n, 1024u));
            for (uint i = 0; i < n; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_samples_at(list, i, out var raw)) throw Failure("samples_at");
                found.Add(new At(raw));
            }
            return found;
        }
        finally { BlacksmithNative.cadaclysm_blacksmith_samples_free(list); }
    }

    /// <summary>Every pair of <paramref name="parts"/> -- or, with <paramref name="others"/>, every
    /// part of <paramref name="parts"/> against every part of <paramref name="others"/> -- that
    /// penetrates, touches or lies within <paramref name="clearance"/> of the other, as `Clash`
    /// rows, the solids as they stand. <paramref name="tolerance"/> is
    /// the meshing tolerance, absolute. <paramref name="allowed"/> is pairs of part indices never
    /// tested (designed contacts), flat as <see cref="Collider"/>'s: `(a0, b0, a1, b1, ...)`; with
    /// <paramref name="others"/> a pair is (index in parts, index in others). In a row `A` indexes
    /// <paramref name="parts"/> and `B` indexes <paramref name="others"/> (or parts again, then `A
    /// &lt; B`). Throws <see cref="BuildException"/> for an empty <paramref name="others"/>, an odd
    /// number of <paramref name="allowed"/> entries, a negative or non-finite clearance, a
    /// tolerance not positive and finite, an allowed index out of range or a part that is not a
    /// closed solid.</summary>
    public static IReadOnlyList<Clash> Clash(IEnumerable<Solid> parts, IEnumerable<Solid>? others = null, double clearance = 0,
        double? tolerance = 0.05, uint[]? allowed = null)
    {
        var first = parts.ToArray();
        var second = others?.ToArray();
        if (second is { Length: 0 }) throw new BuildException("clash: an empty set");
        var flatAllowed = allowed ?? Array.Empty<uint>();
        if (flatAllowed.Length % 2 != 0) throw new BuildException($"clash: allowed is {flatAllowed.Length} numbers, not pairs");
        var a = first.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var b = second?.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var clashes = BlacksmithNative.cadaclysm_blacksmith_clash(a, (uint)a.Length, b, (uint)(b?.Length ?? 0), Blacksmith.Tol(tolerance), clearance,
            flatAllowed.Length == 0 ? null : flatAllowed, (uint)(flatAllowed.Length / 2));
        GC.KeepAlive(first);
        GC.KeepAlive(second);
        return ClashesOf(Checked(clashes, "clash"));
    }

    /// <summary>A clashes handle read out into rows, each keeping the handle alive; disposed at
    /// once when there are no rows, or when a row cannot be read.</summary>
    internal static IReadOnlyList<Clash> ClashesOf(ClashesHandle clashes)
    {
        var count = BlacksmithNative.cadaclysm_blacksmith_clashes_count(clashes);
        var rows = new List<Clash>((int)count);
        if (count == 0)
        {
            clashes.Dispose();
            return rows;
        }
        for (uint i = 0; i < count; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_clashes_at(clashes, i, out var raw))
            {
                var failure = Failure("clashes_at");
                clashes.Dispose();
                throw failure;
            }
            rows.Add(new Clash(raw, clashes, i));
        }
        return rows;
    }

    /// <summary>Every pair of <paramref name="parts"/> -- or, with <paramref name="others"/>, every
    /// part of <paramref name="parts"/> against every part of <paramref name="others"/> -- that
    /// penetrates, touches or comes within <paramref name="clearance"/> of the other anywhere on a
    /// path, as `SweptClash` rows. Each part is its own group: pose `k` of <paramref name="poses"/>
    /// is one frame per part of <paramref name="parts"/>, and pose `k` of <paramref
    /// name="otherPoses"/> one per part of <paramref name="others"/> (the two go together, and have
    /// as many poses). The motion between poses, the guarantee, <paramref name="resolution"/> and
    /// <paramref name="maxSteps"/> are <see cref="Collider.SweptClash"/>'s. <paramref
    /// name="tolerance"/> is the meshing tolerance, absolute. <paramref name="allowed"/> is pairs
    /// of part indices never tested, flat as the one-shot `Clash`'s:
    /// `(a0, b0, a1, b1, ...)`; with <paramref name="others"/> a pair is
    /// (index in parts, index in others). In a row `A` indexes <paramref name="parts"/> and `B`
    /// indexes <paramref name="others"/> (or parts again). Throws <see cref="BuildException"/> as
    /// <see cref="Collider.SweptClash"/> does, and for <paramref name="others"/> without <paramref
    /// name="otherPoses"/> or the other way round, pose counts that differ between the sets, a pose
    /// with the wrong number of frames, an empty <paramref name="others"/>, an odd number of
    /// <paramref name="allowed"/> entries, an allowed index out of range or a part that is not a
    /// closed solid.</summary>
    public static IReadOnlyList<SweptClash> SweptClash(IEnumerable<Solid> parts, IEnumerable<IEnumerable<double[]>> poses,
        IEnumerable<Solid>? others = null, IEnumerable<IEnumerable<double[]>>? otherPoses = null, double clearance = 0,
        double? tolerance = 0.05, double resolution = 1e-3, uint maxSteps = 100000, uint[]? allowed = null)
    {
        if ((others is null) != (otherPoses is null)) throw new BuildException("swept_clash: others and other_poses go together");
        var first = parts.ToArray();
        var second = others?.ToArray();
        var framesA = poses.Select(pose => pose.ToArray()).ToArray();
        var framesB = otherPoses?.Select(pose => pose.ToArray()).ToArray();
        // C reads each set's poses at its part count: the kernel's own checks, in its order
        if (framesB is not null && framesB.Length != framesA.Length)
            throw new BuildException($"swept_clash: {framesA.Length} poses for set a, {framesB.Length} for set b");
        foreach (var (name, frames, n) in new[] { ("a", framesA, first.Length), ("b", framesB ?? Array.Empty<double[][]>(), second?.Length ?? 0) })
            for (var k = 0; k < frames.Length; k++)
                if (frames[k].Length != n) throw new BuildException($"swept_clash: pose {k} of set {name} has {frames[k].Length} frames for {n} parts");
        if (second is { Length: 0 }) throw new BuildException("swept_clash: an empty set");
        var flatAllowed = allowed ?? Array.Empty<uint>();
        if (flatAllowed.Length % 2 != 0) throw new BuildException($"swept_clash: allowed is {flatAllowed.Length} numbers, not pairs");
        var a = first.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var b = second?.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var posesA = PoseFrames(framesA, first.Length);
        var posesB = second is null ? null : PoseFrames(framesB!, second.Length);
        var swept = BlacksmithNative.cadaclysm_blacksmith_swept_clash(a, (uint)a.Length, posesA, b, (uint)(b?.Length ?? 0), posesB,
            (uint)framesA.Length, Blacksmith.Tol(tolerance), clearance, resolution, maxSteps, flatAllowed.Length == 0 ? null : flatAllowed,
            (uint)(flatAllowed.Length / 2));
        GC.KeepAlive(first);
        GC.KeepAlive(second);
        return SweptClashesOf(Checked(swept, "swept_clash"));
    }

    /// <summary>Poses of `frameCount` frames each, flattened pose by pose, 12 numbers a frame.</summary>
    internal static double[] PoseFrames(double[][][] poses, int frameCount)
    {
        var flat = new double[poses.Length * frameCount * 12];
        for (var k = 0; k < poses.Length; k++)
            for (var f = 0; f < frameCount; f++) Array.Copy(Frame(poses[k][f]), 0, flat, (k * frameCount + f) * 12, 12);
        return flat;
    }

    /// <summary>A swept clashes handle read out into rows and disposed; each row's `First` a `Clash`
    /// of the handle's first rows (<see cref="ClashesOf"/>), which keep their own clashes handle
    /// alive. A row or interval that cannot be read disposes both handles.</summary>
    internal static IReadOnlyList<SweptClash> SweptClashesOf(SweptClashesHandle swept)
    {
        using (swept)
        {
            var count = BlacksmithNative.cadaclysm_blacksmith_swept_clashes_count(swept);
            if (count == 0) return Array.Empty<SweptClash>();
            var firstsHandle = Checked(BlacksmithNative.cadaclysm_blacksmith_swept_clashes_firsts(swept), "swept_clashes_firsts");
            var firsts = ClashesOf(firstsHandle);
            var rows = new List<SweptClash>((int)count);
            var span = new double[2];
            for (uint i = 0; i < count; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_swept_clashes_at(swept, i, out var raw))
                {
                    var failure = Failure("swept_clashes_at");
                    firstsHandle.Dispose();
                    throw failure;
                }
                var intervals = new List<(double Start, double End)>((int)raw.IntervalCount);
                for (uint k = 0; k < raw.IntervalCount; k++)
                {
                    if (!BlacksmithNative.cadaclysm_blacksmith_swept_clashes_interval(swept, i, k, span))
                    {
                        var failure = Failure("swept_clashes_interval");
                        firstsHandle.Dispose();
                        throw failure;
                    }
                    intervals.Add((span[0], span[1]));
                }
                rows.Add(new SweptClash((int)raw.A, (int)raw.B, raw.FirstTime, firsts[(int)i], intervals));
            }
            return rows;
        }
    }

    /// <summary>Every wall-thickness reading within <paramref name="maximum"/> on
    /// <paramref name="solids"/>, measured against each other: <c>new ThicknessGauge(solids,
    /// tolerance).Thickness(maximum, sharpAngle)</c> on a gauge used once and disposed on every
    /// path. A reading's `Body` is the solid's index in <paramref name="solids"/>. Throws
    /// <see cref="BuildException"/> as the gauge's own calls do (`thickness_gauge_new: ...`,
    /// `thickness_gauge_measure: ...`).</summary>
    public static IReadOnlyList<Thickness> Thickness(IEnumerable<Solid> solids, double maximum, double sharpAngle = 0.0,
        double? tolerance = 0.01)
    {
        using var gauge = new ThicknessGauge(solids, Blacksmith.Tol(tolerance));
        return gauge.Thickness(maximum, sharpAngle);
    }

    /// <summary>The nearest-opposing-wall rule on plain meshes measured against each other: each
    /// mesh a pair of its points (`x, y, z` each) and its triangles (three indices into its own
    /// points). One reading per vertex that has one within <paramref name="maximum"/> (positive and
    /// finite), by mesh then vertex; <paramref name="sharpAngle"/> as for <see
    /// cref="ThicknessGauge.Thickness"/>. Throws <see cref="BuildException"/> for a mesh that is
    /// not such a pair, a position or a triangle that is not three numbers, a triangle past its
    /// mesh, a position not finite or a bad limit.</summary>
    public static IReadOnlyList<MeshThickness> MeshThickness(IEnumerable<(double[][] Positions, uint[][] Triangles)> meshes,
        double maximum, double sharpAngle = 0.0)
    {
        var positions = new List<double>();
        var indices = new List<uint>();
        var vertexCounts = new List<uint>();
        var triangleCounts = new List<uint>();
        var m = 0;
        foreach (var (points, triangles) in meshes)
        {
            if (points is null || triangles is null) throw new BuildException($"mesh_thickness: mesh {m} is not a (positions, triangles) pair");
            for (var i = 0; i < points.Length; i++)
            {
                if (points[i] is not { Length: 3 } xyz) throw new BuildException($"mesh_thickness: mesh {m} position {i} is not three numbers");
                positions.AddRange(xyz);
            }
            vertexCounts.Add((uint)points.Length);
            for (var i = 0; i < triangles.Length; i++)
            {
                if (triangles[i] is not { Length: 3 } ijk) throw new BuildException($"mesh_thickness: mesh {m} triangle {i} is not three indices");
                indices.AddRange(ijk);
            }
            triangleCounts.Add((uint)triangles.Length);
            m++;
        }
        var list = BlacksmithNative.cadaclysm_blacksmith_mesh_thickness(positions.ToArray(), vertexCounts.ToArray(), indices.ToArray(),
            triangleCounts.ToArray(), (uint)vertexCounts.Count, maximum, sharpAngle);
        if (list == IntPtr.Zero) throw Failure("mesh_thickness");
        try
        {
            var count = BlacksmithNative.cadaclysm_blacksmith_mesh_thicknesses_count(list);
            var rows = new List<MeshThickness>((int)Math.Min(count, 1u << 20));
            for (uint i = 0; i < count; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_mesh_thicknesses_at(list, i, out var raw)) throw Failure("mesh_thicknesses_at");
                rows.Add(new MeshThickness(raw));
            }
            return rows;
        }
        finally { BlacksmithNative.cadaclysm_blacksmith_mesh_thicknesses_free(list); }
    }

    /// <summary>A thicknesses list (null: the library's refusal, named <paramref name="what"/>)
    /// read out into rows and freed on every path.</summary>
    internal static IReadOnlyList<Thickness> ThicknessesOf(IntPtr list, string what)
    {
        if (list == IntPtr.Zero) throw Failure(what);
        try
        {
            var count = BlacksmithNative.cadaclysm_blacksmith_thicknesses_count(list);
            var rows = new List<Thickness>((int)Math.Min(count, 1u << 20));
            for (uint i = 0; i < count; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_thicknesses_at(list, i, out var raw)) throw Failure("thicknesses_at");
                rows.Add(new Thickness(raw));
            }
            return rows;
        }
        finally { BlacksmithNative.cadaclysm_blacksmith_thicknesses_free(list); }
    }

    /// <summary>For each of <paramref name="needles"/>, the indices of the <paramref name="hay"/>
    /// points within <paramref name="limit"/> of it, by distance then index -- one <see cref="RTree"/>
    /// over the hay answers every needle. Throws <see cref="BuildException"/> for a limit negative
    /// or NaN, then the first hay point and the first needle not finite, by index.</summary>
    public static List<List<uint>> ClosestPoints(IEnumerable<double[]> hay, IEnumerable<double[]> needles, double limit)
    {
        if (!(limit >= 0.0)) throw new BuildException($"closest_points: limit {RustNumber(limit)} is not a distance");
        var (hayFlat, points) = PointTriples("closest_points", hay, needles);
        using var tree = RTree.FromPoints(hayFlat);
        return points.Select(p => tree.Within(p, limit).Select(h => h.Id).ToList()).ToList();
    }

    /// <summary>For each of <paramref name="needles"/>, the indices of the <paramref name="k"/>
    /// nearest <paramref name="hay"/> points, by distance then index (all of them when k is over
    /// the hay count). Throws <see cref="BuildException"/> for the first hay point and the first
    /// needle not finite, by index, then a k above 1,000,000.</summary>
    public static List<List<uint>> KNeighbors(IEnumerable<double[]> hay, IEnumerable<double[]> needles, uint k)
    {
        var (hayFlat, points) = PointTriples("k_neighbors", hay, needles);
        if (k > 1_000_000) throw new BuildException($"k_neighbors: k {k} is not at most 1000000");
        using var tree = RTree.FromPoints(hayFlat);
        return points.Select(p => tree.Nearest(p, k).Select(h => h.Id).ToList()).ToList();
    }

    /// <summary>`hay` and `needles` as triples, refused as the kernel's `closest_points` /
    /// `k_neighbors` refuse: the first hay point, then needle, that is not finite, by index.</summary>
    private static (List<double[]> Hay, List<double[]> Needles) PointTriples(string call, IEnumerable<double[]> hay, IEnumerable<double[]> needles)
    {
        List<double[]> Triples(IEnumerable<double[]> points, string name)
        {
            var list = new List<double[]>();
            foreach (var p in points)
            {
                var i = list.Count;
                var values = Point(p, $"{call}: {name} point {i}");
                if (!values.All(double.IsFinite)) throw new BuildException($"{call}: {name} point {i} is not finite");
                list.Add(values);
            }
            return list;
        }
        return (Triples(hay, "hay"), Triples(needles, "needle"));
    }

    /// <summary>Points, three numbers each, as one flat array, the shape refused by index under `what`.</summary>
    internal static double[] PointsFlat(IEnumerable<double[]> points, string what, string name)
    {
        var flat = new List<double>();
        var i = 0;
        foreach (var p in points) flat.AddRange(Point(p, $"{what}: {name} {i++}"));
        return flat.ToArray();
    }

    /// <summary>`x` as Rust's `{}` prints an f64 -- the kernel's refusals quote numbers that way.</summary>
    internal static string RustNumber(double x)
    {
        if (double.IsNaN(x)) return "NaN";
        if (double.IsInfinity(x)) return x > 0 ? "inf" : "-inf";
        // "R" is the shortest round-trip digits, as Rust's are; Rust lays them out without an exponent.
        var sign = double.IsNegative(x) ? "-" : "";
        var body = Math.Abs(x).ToString("R", System.Globalization.CultureInfo.InvariantCulture);
        var e = body.IndexOfAny(new[] { 'e', 'E' });
        var shift = e < 0 ? 0 : int.Parse(body.Substring(e + 1), System.Globalization.CultureInfo.InvariantCulture);
        var mantissa = e < 0 ? body : body.Substring(0, e);
        var dot = mantissa.IndexOf('.');
        var fraction = dot < 0 ? "" : mantissa.Substring(dot + 1);
        var digits = ((dot < 0 ? mantissa : mantissa.Substring(0, dot)) + fraction).TrimStart('0');
        shift -= fraction.Length;
        var stripped = digits.TrimEnd('0');
        shift += digits.Length - stripped.Length;
        digits = stripped;
        if (digits.Length == 0) return sign + "0";
        if (shift >= 0) return sign + digits + new string('0', shift);
        var point = digits.Length + shift;
        return point > 0
            ? sign + digits.Substring(0, point) + "." + digits.Substring(point)
            : sign + "0." + new string('0', -point) + digits;
    }

    /// <summary>The library's own reason, or `what` if it left none.</summary>
    internal static BuildException Failure(string what)
    {
        var reason = LastError();
        return new BuildException(reason.Length > 0 ? reason : what);
    }

    /// <summary><see cref="Failure"/> for a call routed through
    /// `cadaclysm_blacksmith_tessellation`: that entry point fails with a leading
    /// "tessellation:" naming itself, not the caller, so this rewrites that prefix back to
    /// `what` -- the C-level name the caller reported before it held a tessellation of its
    /// own -- leaving the rest of the library's message untouched.</summary>
    internal static BuildException TessellationFailure(string what)
    {
        var reason = LastError();
        const string prefix = "tessellation:";
        if (reason.StartsWith(prefix, StringComparison.Ordinal)) reason = what + ":" + reason.Substring(prefix.Length);
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

    /// <summary>`count` values at `at`, copied out as an array of the caller's own (empty for a null
    /// pointer or a zero count).</summary>
    internal static unsafe T[] CopyOf<T>(IntPtr at, uint count) where T : unmanaged =>
        at == IntPtr.Zero || count == 0 ? Array.Empty<T>() : new ReadOnlySpan<T>((void*)at, (int)count).ToArray();

    internal static T Checked<T>(T handle, string what) where T : CadaclysmHandle =>
        !handle.IsInvalid ? handle : throw Failure(what);

    /// <summary><see cref="Checked{T}"/> for a `cadaclysm_blacksmith_tessellation` handle: see
    /// <see cref="TessellationFailure"/>.</summary>
    internal static T TessellationChecked<T>(T handle, string what) where T : CadaclysmHandle =>
        !handle.IsInvalid ? handle : throw TessellationFailure(what);

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

    /// <summary>`count` numbers, refused in `what`'s name otherwise.</summary>
    internal static double[] Numbers(double[] values, int count, string what) => Doubles(values, count, what);

    /// <summary>Six numbers: a point and a direction.</summary>
    internal static double[] AxisOf(double[] axis) => Doubles(axis, 6, "axis");

    /// <summary>The word for a containment code the library answered: 0 "outside", 1 "inside", 2 "on".</summary>
    internal static string ContainmentOf(uint code, string call) => code switch
    {
        0 => "outside",
        1 => "inside",
        2 => "on",
        _ => throw new BuildException($"{call}: the library answered {code}, not a containment code"),
    };

    /// <summary>Three numbers: a point, or a <see cref="Box"/>'s `Lo`/`Hi`.</summary>
    internal static double[] Point(double[] point, string what) => Doubles(point, 3, what);
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

    /// <summary>The perimeter of the outer loop (holes are not counted) as a <see cref="Length"/>,
    /// to the relative <paramref name="accuracy"/> (0 asks for the default).</summary>
    public Length Length(double accuracy = 0.0)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_profile_length(Handle, accuracy, out var raw)) throw Blacksmith.Failure("profile_length");
        return new Length(raw);
    }

    /// <summary>The point <paramref name="s"/> of arc length along the outer loop from its start, to
    /// the relative <paramref name="accuracy"/> (0 or less asks for the default). <c>Segment</c> is the
    /// side it lies on. A length outside the loop, or an accuracy NaN or infinite, throws.</summary>
    public At PointAtLength(double s, double accuracy = 0.0)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_profile_point_at_length(Handle, s, accuracy, out var raw)) throw Blacksmith.Failure("profile_point_at_length");
        return new At(raw);
    }

    /// <summary><paramref name="n"/> points equally spaced in arc length round the outer loop from
    /// its start (the loop is closed, so the first is not repeated); 1 to 1,000,000.</summary>
    public List<At> DivideByCount(uint n, double accuracy = 0.0) =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_profile_divide_by_count(Handle, n, accuracy), "profile_divide_by_count");

    /// <summary>A point every <paramref name="step"/> of arc length from the start of the outer
    /// loop, the short last piece kept and the start never repeated.</summary>
    public List<At> DivideByLength(double step, double accuracy = 0.0) =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_profile_divide_by_length(Handle, step, accuracy), "profile_divide_by_length");

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

    /// <summary>A regular polygon of `sides` sides (at least 3) whose sides touch the circle of
    /// `radius` about `centre` -- the polygon across flats, a nut's hex: its corners on the circle
    /// of `radius / cos(pi / sides)`, the first at `angle` radians from the sketch's x axis, the
    /// rest counter-clockwise, on the same rays as <see cref="RegularPolygon"/>'s corners with the
    /// same `angle`; each side's midpoint on the circle of `radius`.</summary>
    public static Profile CircumscribedPolygon((double X, double Y) centre, double radius, int sides, double angle = 0) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_circumscribed_polygon(centre.X, centre.Y, radius, (uint)Math.Max(0, sides), angle));

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
    public static Profile Chain(IEnumerable<Profile> pieces, double? tolerance = 1e-6)
    {
        // Raw pointers, as WriteStepText passes its solids: the owners kept reachable
        // until the call has returned.
        var owners = pieces.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var chained = BlacksmithNative.cadaclysm_blacksmith_profile_chain(handles, (nuint)handles.Length, Blacksmith.Tol(tolerance));
        GC.KeepAlive(owners);
        return new Profile(chained);
    }

    /// <summary>A polyline through `points` in order, a straight segment per side: an open
    /// chain, or `closed` with a side from the last point back to the first. A side of no length
    /// is kept, so a corner dragged onto its neighbour still draws. Throws for fewer than two
    /// points (three closed) or a coordinate not finite.</summary>
    public static Profile Polyline(IEnumerable<(double X, double Y)> points, bool closed = false)
    {
        var flat = points.SelectMany(p => new[] { p.X, p.Y }).ToArray();
        return new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_polyline(flat, (nuint)(flat.Length / 2), closed));
    }

    /// <summary>The arc of radius `r` about `centre` from angle `a0` counter-clockwise to `a1`
    /// (radians from the sketch's x axis), one exact arc, open: `a1` is brought past `a0` when it
    /// is not. Equal angles are the whole circle, closed, starting at `a0`. Throws for a radius
    /// not positive and finite.</summary>
    public static Profile Arc((double X, double Y) centre, double r, double a0, double a1) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_arc(centre.X, centre.Y, r, a0, a1));

    /// <summary>The arc from `start` through `through` to `end`, one exact arc leaving the
    /// start, open: the circle through the three points, swept the way round that passes
    /// `through`. Throws when the three are in a line.</summary>
    public static Profile ArcThrough((double X, double Y) start, (double X, double Y) through, (double X, double Y) end) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_arc_through(start.X, start.Y, through.X, through.Y, end.X, end.Y));

    /// <summary>The ellipse about `centre` with semi-axes `rx` along x and `ry` along y, closed:
    /// four exact quarter conics counter-clockwise from the point `rx` along x. Throws for a
    /// semi-axis not positive and finite.</summary>
    public static Profile Ellipse((double X, double Y) centre, double rx, double ry) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_ellipse(centre.X, centre.Y, rx, ry));

    /// <summary>Rational cubic Beziers end to end -- sixteen numbers each, `x y z w` per control
    /// point, the record <see cref="Beziers"/> hands back -- as one open profile. With
    /// `recognise` a straight Bezier becomes an exact line and a circular one an exact arc;
    /// without, every Bezier is kept as the exact cubic it is. Throws for none, a count not a
    /// multiple of sixteen, a number not finite or a weight not positive.</summary>
    public static Profile FromBeziers(IEnumerable<double> beziers, bool recognise = true)
    {
        var flat = beziers.ToArray();
        if (flat.Length % 16 != 0)
            throw new BuildException($"profile_from_beziers: {flat.Length} numbers are not whole Beziers of sixteen");
        return new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_from_beziers(flat, (nuint)(flat.Length / 16), recognise));
    }

    /// <summary>This profile as rational cubic Beziers, sixteen numbers each (`x y z w` per
    /// control point): a line one straight Bezier, an arc exact conic pieces of a quarter turn
    /// or less, a free-form side its own decomposition -- the outline from its start, then each
    /// hole's. On the sketch plane (z = 0), or with `frame` (twelve numbers, a
    /// <see cref="Frame"/>) carried onto that frame's plane.</summary>
    public double[] Beziers(double[]? frame = null)
    {
        var n = BlacksmithNative.cadaclysm_blacksmith_profile_bezier_count(Handle);
        var found = new double[16 * n];
        if (!BlacksmithNative.cadaclysm_blacksmith_profile_beziers(Handle, frame is null ? null : Blacksmith.Frame(frame), found))
            throw Blacksmith.Failure("profile_beziers");
        return found;
    }

    /// <summary>The closed loops among `pieces`, each read by its two ends, the way a CAD sketch
    /// finds them: ends meet within `tolerance`; a loop is a chain of pieces through corners
    /// where exactly two ends meet, and a piece whose own ends meet is a loop of its own. Each
    /// loop is its pieces' indices in the order it runs, from its lowest. Throws for a piece
    /// with holes or nothing drawn.</summary>
    public static List<List<int>> Loops(IEnumerable<Profile> pieces, double? tolerance = 1e-6)
    {
        var owners = pieces.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var flat = new uint[2 * owners.Length];
        var ok = BlacksmithNative.cadaclysm_blacksmith_profile_loops(handles, (nuint)handles.Length, Blacksmith.Tol(tolerance), flat);
        GC.KeepAlive(owners);
        if (!ok) throw Blacksmith.Failure("profile_loops");
        // Records `len, i, i, ...` then zeros: a record of length 0 ends the list.
        var found = new List<List<int>>();
        for (var at = 0; at < flat.Length && flat[at] != 0; at += 1 + (int)flat[at])
            found.Add(flat.Skip(at + 1).Take((int)flat[at]).Select(i => (int)i).ToList());
        return found;
    }

    /// <summary>The order <see cref="Chain"/> takes `pieces` in, from the chain's start to its
    /// end: per piece its index and whether it was turned round to meet. Throws as
    /// <see cref="Chain"/> does.</summary>
    public static List<(int Index, bool Turned)> ChainOrder(IEnumerable<Profile> pieces, double? tolerance = 1e-6)
    {
        var owners = pieces.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var flat = new uint[2 * owners.Length];
        var ok = BlacksmithNative.cadaclysm_blacksmith_profile_chain_order(handles, (nuint)handles.Length, Blacksmith.Tol(tolerance), flat);
        GC.KeepAlive(owners);
        if (!ok) throw Blacksmith.Failure("profile_chain_order");
        return Enumerable.Range(0, owners.Length).Select(i => ((int)flat[2 * i], flat[2 * i + 1] != 0)).ToList();
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
    public IReadOnlyList<Profile> Pieces(IEnumerable<Profile> cutters, double? tolerance = 1e-6)
    {
        var owners = cutters.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var n = BlacksmithNative.cadaclysm_blacksmith_profile_piece_count(Handle, handles, (nuint)handles.Length, Blacksmith.Tol(tolerance));
        if (n == 0) throw Blacksmith.Failure("profile_piece_count");
        var found = new List<Profile>((int)n);
        for (uint i = 0; i < n; i++) found.Add(new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_piece(Handle, handles, (nuint)handles.Length, i, Blacksmith.Tol(tolerance))));
        GC.KeepAlive(owners);
        return found;
    }

    /// <summary>This curve with piece <paramref name="piece"/> of <see cref="Pieces"/> taken
    /// away -- the sketch trim, Python's <c>trim</c>: what is left, as open profiles. One for a
    /// closed curve (its other pieces run together from where the removed one ended), the
    /// stretches before and after for an open one, none where the piece was the whole curve.
    /// Throws for a piece the curve does not have.</summary>
    public IReadOnlyList<Profile> Trim(IEnumerable<Profile> cutters, uint piece, double? tolerance = 1e-6)
    {
        var owners = cutters.ToArray();
        var handles = owners.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var n = BlacksmithNative.cadaclysm_blacksmith_profile_trim_count(Handle, handles, (nuint)handles.Length, piece, Blacksmith.Tol(tolerance));
        if (n == 0 && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("profile_trim_count");
        var found = new List<Profile>((int)n);
        for (uint i = 0; i < n; i++) found.Add(new Profile(BlacksmithNative.cadaclysm_blacksmith_profile_trim_chain(Handle, handles, (nuint)handles.Length, piece, i, Blacksmith.Tol(tolerance))));
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
    public IReadOnlyList<Hit> Hits(Profile other, double? tolerance = 1e-6)
    {
        using var hits = Blacksmith.Checked(
            BlacksmithNative.cadaclysm_blacksmith_profile_hits(Handle, other.Handle, Blacksmith.Tol(tolerance)), "profile_hits");
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
    public IReadOnlyList<Profile> Common(Profile other, double? tolerance = 1e-6) =>
        ProfileList(BlacksmithNative.cadaclysm_blacksmith_profile_common(Handle, other.Handle, Blacksmith.Tol(tolerance)), "profile_common");

    /// <summary>This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by
    /// lines and arcs within `tolerance` of it -- what a G-code writer can say. Lines and arcs
    /// pass through as they are, every loop closes on itself exactly, holes are converted the
    /// same way. Throws <see cref="BuildException"/> for a `tolerance` not positive and finite,
    /// or a spline that does not evaluate.</summary>
    public Profile ToArcs(double? tolerance = 0.01) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_to_arcs(Handle, Blacksmith.Tol(tolerance)));

    /// <summary>This profile grown by `distance` (shrunk where it is negative), as zero or more
    /// profiles, all lines and arcs: outward corners rounded by `|distance|`, holes moving
    /// against the boundary (a hole shrinks as the profile grows). Free-form sides are fitted to
    /// `tolerance` first (<see cref="ToArcs"/>). A shrink that eats the whole profile is an empty
    /// list. Throws <see cref="BuildException"/> for a `distance` not finite, a `tolerance` not
    /// positive and finite, a loop with no sides, or loops that cross or touch.</summary>
    public IReadOnlyList<Profile> Offset(double distance, double? tolerance = 0.01) =>
        ProfileList(BlacksmithNative.cadaclysm_blacksmith_profile_offset(Handle, distance, Blacksmith.Tol(tolerance)), "profile_offset");

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
    /// its own, the list freed. <see cref="Solid.Section"/> and <see cref="Job.Machine"/>'s
    /// report regions read theirs through it too.</summary>
    internal static IReadOnlyList<Profile> ProfileList(ProfileListHandle handle, string what)
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

    /// <summary>This outline turned `radians` (counter-clockwise) about `centre`.</summary>
    public Profile Rotate((double X, double Y) centre, double radians) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_rotate(Handle, centre.X, centre.Y, radians));

    /// <summary>This outline scaled by `sx`, `sy` about `centre`: an arc stays an arc where the
    /// two are equal in size, and becomes exact conics otherwise. A negative factor mirrors; a
    /// zero one is singular and throws <see cref="BuildException"/>.</summary>
    public Profile Scale((double X, double Y) centre, double sx, double sy) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_scale(Handle, centre.X, centre.Y, sx, sy));

    /// <summary>This outline reflected across the line through `point` along `direction`. A
    /// zero `direction` throws <see cref="BuildException"/>.</summary>
    public Profile Mirror((double X, double Y) point, (double X, double Y) direction) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_mirror(Handle, point.X, point.Y, direction.X, direction.Y));

    /// <summary>This outline under the 2D affine map `m`, six numbers row-major (2x3):
    /// `x' = m0 x + m1 y + m2`, `y' = m3 x + m4 y + m5`. A singular map throws
    /// <see cref="BuildException"/>.</summary>
    public Profile Transform2d(double[] m) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_transform2d(Handle, Blacksmith.Numbers(m, 6, "profile_transform2d")));

    /// <summary>This outline coloured (`r`, `g`, `b`), each in 0..1: how it is drawn. The verbs
    /// that make a profile from one carry it; a solid made from it takes nothing.</summary>
    public Profile Coloured(double r, double g, double b) =>
        new(BlacksmithNative.cadaclysm_blacksmith_profile_coloured(Handle, r, g, b));

    /// <summary><see cref="Coloured(double, double, double)"/> from `"#rgb"`, `"#rrggbb"` or a CSS colour name.</summary>
    public Profile Coloured(string colour) { var c = Blacksmith.Rgb(colour, "coloured"); return Coloured(c[0], c[1], c[2]); }

    /// <summary>This profile as a <see cref="Document"/>'s `profile.path` node holds it, as JSON
    /// text: `{"start", "segments", "holes", "colour"}`, each segment a `line`, `arc`, `bezier`,
    /// `conic` or `nurbs` exactly, never flattened. What <see cref="Document.AddProfile"/> puts in
    /// a document.</summary>
    public string DocumentPath() =>
        Blacksmith.OwnedText(BlacksmithNative.cadaclysm_blacksmith_document_profile_path(Handle), "document_profile_path");

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
    public static SweepPath Along(Profile curve, double[] frame, double? tolerance = 0.05, bool open = true) =>
        new(BlacksmithNative.cadaclysm_blacksmith_sweep_path_along(curve.Handle, Blacksmith.Frame(frame), Blacksmith.Tol(tolerance), open),
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

/// <summary>The same triangles in memory of our own, safe to outlive the view they were copied
/// from.</summary>
public sealed record BlacksmithMeshData(float[] Positions, float[] Normals, uint[] Indices);

/// <summary>A solid's triangles -- a view over a held tessellation of its own (see the file
/// header): it owns its filling, so nothing about the solid afterwards touches it. A span read
/// from it does not keep this reachable -- <see cref="GC.KeepAlive"/> it while one is in hand.
/// </summary>
/// <remarks><see cref="Positions"/> and <see cref="Normals"/> are `(VertexCount * 3)` floats,
/// <see cref="Indices"/> is `(IndexCount)`, three to a triangle.</remarks>
public sealed class BlacksmithMesh
{
    private readonly RawBlacksmithMesh _raw;
    private readonly TessellationHandle _held;

    /// <summary>The solid this view was meshed from; the view's arrays do not depend on it --
    /// they stay valid after the solid is disposed or meshed again.</summary>
    public Solid Solid { get; }

    /// <summary>The tolerance this was meshed at.</summary>
    public double Tolerance { get; }

    internal BlacksmithMesh(Solid solid, TessellationHandle held, double tolerance, RawBlacksmithMesh raw)
    {
        Solid = solid;
        _held = held;
        Tolerance = tolerance;
        _raw = raw;
    }

    public int VertexCount => (int)_raw.VertexCount;
    public int IndexCount => (int)_raw.IndexCount;
    public int TriangleCount => (int)(_raw.IndexCount / 3);

    private void CheckHeld()
    {
        if (_held.IsClosed) throw new ObjectDisposedException(nameof(BlacksmithMesh), "mesh: freed");
    }

    public unsafe ReadOnlySpan<float> Positions
    {
        get
        {
            CheckHeld();
            return _raw.Positions == IntPtr.Zero
                ? ReadOnlySpan<float>.Empty
                : new ReadOnlySpan<float>((void*)_raw.Positions, (int)(_raw.VertexCount * 3));
        }
    }

    public unsafe ReadOnlySpan<float> Normals
    {
        get
        {
            CheckHeld();
            return _raw.Normals == IntPtr.Zero
                ? ReadOnlySpan<float>.Empty
                : new ReadOnlySpan<float>((void*)_raw.Normals, (int)(_raw.VertexCount * 3));
        }
    }

    public unsafe ReadOnlySpan<uint> Indices
    {
        get
        {
            CheckHeld();
            return _raw.Indices == IntPtr.Zero
                ? ReadOnlySpan<uint>.Empty
                : new ReadOnlySpan<uint>((void*)_raw.Indices, (int)_raw.IndexCount);
        }
    }

    /// <summary>The same triangles in memory of our own, safe to outlive this view.</summary>
    public BlacksmithMeshData Copy() => new(Positions.ToArray(), Normals.ToArray(), Indices.ToArray());
}

/// <summary>A <see cref="BlacksmithMesh64"/> in memory of your own.</summary>
public sealed record BlacksmithMeshData64(double[] Positions, double[] Normals, uint[] Indices);

/// <summary>[`cadaclysm_blacksmith_tessellation_mesh64`]: the same tessellation as <see
/// cref="BlacksmithMesh"/> -- a view over its own held tessellation, unaffected by anything
/// done to the solid afterwards. A span read from it does not keep this reachable -- <see
/// cref="GC.KeepAlive"/> it while one is in hand.</summary>
/// <remarks><see cref="Positions"/> and <see cref="Normals"/> are `(VertexCount * 3)`
/// doubles, <see cref="Indices"/> is `(IndexCount)`, the very pointer <see
/// cref="BlacksmithMesh"/> gives.</remarks>
public sealed class BlacksmithMesh64
{
    private readonly RawBlacksmithMesh64 _raw;
    private readonly TessellationHandle _held;

    /// <summary>The solid this view was meshed from; the view's arrays do not depend on it --
    /// they stay valid after the solid is disposed or meshed again.</summary>
    public Solid Solid { get; }

    /// <summary>The tolerance this was meshed at.</summary>
    public double Tolerance { get; }

    internal BlacksmithMesh64(Solid solid, TessellationHandle held, double tolerance, RawBlacksmithMesh64 raw)
    {
        Solid = solid;
        _held = held;
        Tolerance = tolerance;
        _raw = raw;
    }

    public int VertexCount => (int)_raw.VertexCount;
    public int IndexCount => (int)_raw.IndexCount;
    public int TriangleCount => (int)(_raw.IndexCount / 3);

    private void CheckHeld()
    {
        if (_held.IsClosed) throw new ObjectDisposedException(nameof(BlacksmithMesh64), "mesh64: freed");
    }

    public unsafe ReadOnlySpan<double> Positions
    {
        get
        {
            CheckHeld();
            return _raw.Positions == IntPtr.Zero
                ? ReadOnlySpan<double>.Empty
                : new ReadOnlySpan<double>((void*)_raw.Positions, (int)(_raw.VertexCount * 3));
        }
    }

    public unsafe ReadOnlySpan<double> Normals
    {
        get
        {
            CheckHeld();
            return _raw.Normals == IntPtr.Zero
                ? ReadOnlySpan<double>.Empty
                : new ReadOnlySpan<double>((void*)_raw.Normals, (int)(_raw.VertexCount * 3));
        }
    }

    public unsafe ReadOnlySpan<uint> Indices
    {
        get
        {
            CheckHeld();
            return _raw.Indices == IntPtr.Zero
                ? ReadOnlySpan<uint>.Empty
                : new ReadOnlySpan<uint>((void*)_raw.Indices, (int)_raw.IndexCount);
        }
    }

    /// <summary>The same triangles in memory of our own, safe to outlive this view.</summary>
    public BlacksmithMeshData64 Copy() => new(Positions.ToArray(), Normals.ToArray(), Indices.ToArray());
}

/// <summary>A solid's feature edges as polylines -- a view over its own held tessellation,
/// under the same lifetime rule as <see cref="BlacksmithMesh"/>. Polyline `i` is
/// `Points[Offsets[i] * 3 .. Offsets[i + 1] * 3]`, three floats a point.</summary>
public sealed class BlacksmithPolylines
{
    private readonly RawBlacksmithPolylines _raw;
    private readonly TessellationHandle _held;

    /// <summary>The solid this view was meshed from; the view's arrays do not depend on it --
    /// they stay valid after the solid is disposed or meshed again.</summary>
    public Solid Solid { get; }

    public double Tolerance { get; }

    internal BlacksmithPolylines(Solid solid, TessellationHandle held, double tolerance, RawBlacksmithPolylines raw)
    {
        Solid = solid;
        _held = held;
        Tolerance = tolerance;
        _raw = raw;
    }

    public int PointCount => (int)_raw.PointCount;
    public int PolylineCount => (int)_raw.PolylineCount;

    private void CheckHeld()
    {
        if (_held.IsClosed) throw new ObjectDisposedException(nameof(BlacksmithPolylines), "edge_polylines: freed");
    }

    /// <summary>`(PointCount * 3)` floats, the polylines end to end.</summary>
    public unsafe ReadOnlySpan<float> Points
    {
        get
        {
            CheckHeld();
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
            CheckHeld();
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
    /// this view.</summary>
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
/// tolerance does not touch one either -- a FEM view's pointers are built with the handle and
/// never move. <see cref="BlacksmithMesh"/> now owns its own tessellation the same way, so
/// there is no generation machinery anywhere in this file any more (see the file header).</para>
///
/// <para><strong>What the guard does and does not do.</strong> Every accessor below asks the
/// handle first, so a span <em>asked for</em> after <see cref="Free"/> throws. A span already in
/// hand is not protected and cannot be: a `ReadOnlySpan&lt;T&gt;` is a bare pointer and a length,
/// with nothing left to check by the time it is indexed -- it goes on reading the freed block and
/// hands back numbers that look like the mesh. <see cref="BlacksmithMesh"/>'s own guard is no
/// different in this respect, and neither is the reader's. So call `ToArray()` on any span that
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

    /// <summary>Every pair of triangles that pass through each other, as `(A, B)` with `A &lt;
    /// B`, sorted: an edge of one through the other's interior. Their B-rep faces are <see
    /// cref="TriangleFace"/>`[A]` and `[B]`.</summary>
    /// <remarks><strong>Computed for every body, open or closed.</strong> The census <see
    /// cref="Watertight"/>, <see cref="OpenEdges"/> and <see cref="FoldedEdges"/> report is
    /// topological and cannot see a surface passing through itself; a mesh is ready for a volume
    /// mesher when it is <see cref="Watertight"/> <strong>and</strong> this is empty -- Gmsh
    /// refuses one that crosses. A copy.</remarks>
    public IReadOnlyList<(uint A, uint B)> Crossings
    {
        get
        {
            var handle = Live;
            var count = BlacksmithNative.cadaclysm_blacksmith_fem_mesh_crossing_count(handle);
            var rows = new List<(uint, uint)>((int)count);
            for (var i = 0u; i < count; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_fem_mesh_crossing(handle, i, out var a, out var b))
                    throw Blacksmith.Failure($"fem_mesh_crossing {i}");
                rows.Add((a, b));
            }
            return rows;
        }
    }

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
    /// <remarks>The reader library's `Node.FemMesh` sets it for a node with no brep (an STL,
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

/// <summary>A curve in space -- always a NURBS, so a line, an arc or a conic is an exact rational
/// one -- to model with: built through points, read off an edge or a face, projected onto a plane
/// or a face, trimmed, extended and blended; asked for its points, derivatives, curvature, length
/// and crossings. Immutable; every edit returns a new curve. Dispose it to free it; the runtime
/// does so otherwise, through its handle, and a curve outlives the solid or curves it came
/// from.
///
/// A face here is its whole surface: projecting onto, pulling to and crossing a face ignore its
/// trims. Tolerances: 0 or null asks for the inputs' effective tolerance.</summary>
public sealed class NurbsCurve : IDisposable
{
    private readonly NurbsCurveHandle _handle;

    private NurbsCurve(NurbsCurveHandle handle, string what, double? fitError)
    {
        _handle = Blacksmith.Checked(handle, what);
        FitError = fitError;
    }

    /// <summary>A curve from a handle the library returned, or the library's refusal named
    /// <paramref name="what"/>.</summary>
    internal static NurbsCurve Of(NurbsCurveHandle handle, string what, double? fitError = null) => new(handle, what, fitError);

    /// <summary>The curve with control points <paramref name="points"/>, of
    /// <paramref name="degree"/> (1 to 7), <paramref name="weights"/> one per point (positive) or
    /// null, and the full knot vector <paramref name="knots"/> (points + degree + 1 values,
    /// non-decreasing) or null for clamped and uniform.</summary>
    public NurbsCurve(IEnumerable<(double X, double Y, double Z)> points, int degree = 3,
                      IEnumerable<double>? weights = null, IEnumerable<double>? knots = null)
    {
        var xyz = Flat(points);
        var w = weights?.ToArray();
        var k = knots?.ToArray();
        if (w is not null && w.Length != xyz.Length / 3)
            throw new BuildException($"nurbs_curve_new: {w.Length} weights for {xyz.Length / 3} points; give one per point");
        var deg = Whole(degree, "nurbs_curve_new: degree");
        _handle = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_new(
            xyz, (nuint)(xyz.Length / 3), w, deg, k, (nuint)(k?.Length ?? 0)), "nurbs_curve_new");
    }

    private static double[] Flat(IEnumerable<(double X, double Y, double Z)> points)
    {
        ArgumentNullException.ThrowIfNull(points);
        return ValueCalls.FlatPoints(points);
    }

    private static uint Whole(int value, string what) =>
        value >= 0 ? (uint)value : throw new BuildException($"{what}: {value} is not a whole number from 0");

    private static double[]? Dir((double X, double Y, double Z)? v) => v is { } p ? new[] { p.X, p.Y, p.Z } : null;

    private static double[] Dir3((double X, double Y, double Z) v) => new[] { v.X, v.Y, v.Z };

    /// <summary>The handle, refusing a disposed curve at the call site.</summary>
    internal NurbsCurveHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(NurbsCurve), "nurbs_curve: closed");

    /// <summary>Give the curve back. Idempotent.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>The largest distance from a point to the curve: set only on a curve made by
    /// <see cref="Fit"/>, <see cref="ProjectedToFace"/> or <see cref="PulledToFace"/>, else
    /// null.</summary>
    public double? FitError { get; }

    // -- building

    /// <summary>The curve of <paramref name="degree"/> (1 to 7) through <paramref name="points"/> in
    /// order, chord-length parametrised. <paramref name="closed"/> closes it back to the first
    /// point, smooth across the seam; an open curve may leave along
    /// <paramref name="startTangent"/> and arrive along <paramref name="endTangent"/> (directions;
    /// their length does not matter).</summary>
    public static NurbsCurve Through(IEnumerable<(double X, double Y, double Z)> points, int degree = 3, bool closed = false,
                                     (double X, double Y, double Z)? startTangent = null, (double X, double Y, double Z)? endTangent = null)
    {
        var xyz = Flat(points);
        return Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_through(
            xyz, (nuint)(xyz.Length / 3), Whole(degree, "nurbs_curve_through: degree"), closed, Dir(startTangent), Dir(endTangent)),
            "nurbs_curve_through");
    }

    /// <summary>A curve of <paramref name="degree"/> within <paramref name="tolerance"/> of every
    /// point, through the first and the last (least squares); its <see cref="FitError"/> is the
    /// largest distance from a point to it.</summary>
    public static NurbsCurve Fit(IEnumerable<(double X, double Y, double Z)> points, int degree = 3, double? tolerance = 1e-3)
    {
        var xyz = Flat(points);
        var h = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_fit(
            xyz, (nuint)(xyz.Length / 3), Whole(degree, "nurbs_curve_fit: degree"), Blacksmith.Tol(tolerance), out var error);
        return Of(h, "nurbs_curve_fit", error);
    }

    /// <summary>The smoothest curve of <paramref name="degree"/> (3 to 7) within
    /// <paramref name="tolerance"/> of every point, through the first and the last: least squares
    /// plus the curvature's derivative squared, weighed as heavily as the tolerance allows. Where
    /// <see cref="Fit"/> follows the points' noise, this spends the tolerance on a calm curvature
    /// comb. <paramref name="noInflection"/> keeps the curvature from turning over between two
    /// point indices (fractions between points; a null end is the curve's own end, so
    /// <c>(null, null)</c> is the whole curve); null leaves it free. Throws
    /// <see cref="BuildException"/> where no such curve is within the tolerance. Its
    /// <see cref="FitError"/> is the largest distance from a point to it.</summary>
    public static NurbsCurve Fair(IEnumerable<(double X, double Y, double Z)> points, int degree = 5, double? tolerance = 1e-3,
                                  (double? From, double? To)? noInflection = null)
    {
        var xyz = Flat(points);
        var (held, lo, hi) = NoInflection(noInflection);
        var h = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_fair(
            xyz, (nuint)(xyz.Length / 3), Whole(degree, "nurbs_curve_fair: degree"), Blacksmith.Tol(tolerance), held, lo, hi, out var error);
        return Of(h, "nurbs_curve_fair", error);
    }

    /// <summary>`noInflection` as the C ABI takes it: the flag and the span's two ends, NaN for an open one.</summary>
    static (bool Held, double From, double To) NoInflection((double? From, double? To)? span) =>
        span is { } s ? (true, s.From ?? double.NaN, s.To ?? double.NaN) : (false, 0.0, 0.0);

    /// <summary>Edge <paramref name="edge"/> of <paramref name="solid"/> as an exact NURBS over the
    /// edge's own span of its curve, running the way the edge runs.</summary>
    public static NurbsCurve FromEdge(Solid solid, int edge) =>
        Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_from_edge(solid.Handle, Solid.Index(edge)), "nurbs_curve_from_edge");

    /// <summary><see cref="FromEdge(Solid, int)"/> for an <see cref="Edge"/>.</summary>
    public static NurbsCurve FromEdge(Solid solid, Edge edge) => FromEdge(solid, edge.Index);

    /// <summary>The isocurve of face <paramref name="face"/> of <paramref name="solid"/>'s surface:
    /// along u at v = <paramref name="at"/> when <paramref name="alongU"/>, else along v at
    /// u = at. NURBS faces only.</summary>
    public static NurbsCurve Isocurve(Solid solid, int face, bool alongU, double at) =>
        Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_from_face_isocurve(solid.Handle, Solid.Index(face), alongU, at),
            "nurbs_curve_from_face_isocurve");

    /// <summary>The curve bridging <paramref name="a"/> (at its end when <paramref name="aEnd"/>, else
    /// its start) to <paramref name="b"/> (at its end when <paramref name="bEnd"/>, else its start):
    /// <paramref name="continuity"/> 1 matches position and tangent (a cubic), 2 also the
    /// curvature (a quintic); <paramref name="bulge"/> (positive) scales how far the tangents
    /// reach.</summary>
    public static NurbsCurve Blend(NurbsCurve a, bool aEnd, NurbsCurve b, bool bEnd, int continuity = 2, double bulge = 1.0) =>
        Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_blend(a.Handle, aEnd, b.Handle, bEnd,
            Whole(continuity, "nurbs_curve_blend: continuity"), bulge), "nurbs_curve_blend");

    /// <summary><paramref name="curves"/> joined end to end into one curve (Rhino's JoinCurves): in
    /// the order given, each turned where needed so its start meets the previous one's end within
    /// <paramref name="tolerance"/> (the joint placed at the midpoint of the two ends). All are
    /// raised to the highest degree among them and each runs over k..k + 1, joined C0; a rational
    /// curve keeps its points. One curve gives a copy; none, or a gap past the tolerance, throws
    /// <see cref="BuildException"/> naming the two curves.</summary>
    public static NurbsCurve Joined(IEnumerable<NurbsCurve> curves, double tolerance = 1e-6)
    {
        ArgumentNullException.ThrowIfNull(curves);
        var owners = curves.ToArray();
        var raw = owners.Select(c => c.Handle.DangerousGetHandle()).ToArray();
        var made = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_joined(raw, (nuint)raw.Length, tolerance);
        GC.KeepAlive(owners);
        return Of(made, "nurbs_curve_joined");
    }

    private static readonly string[] TweenMethods = { "plain", "matching", "sampling" };

    /// <summary><paramref name="count"/> curves blending evenly from this curve to
    /// <paramref name="other"/> (Rhino's CreateTweenCurves family), tween i at the fraction
    /// (i + 1) / (count + 1). <paramref name="method"/> is a string: "plain" (control point by
    /// control point; the curves must share one structure), "matching" (made compatible exactly,
    /// blended in homogeneous coordinates) or "sampling" (both divided by arc length into
    /// <paramref name="samples"/> pieces, required here and refused otherwise, and a cubic
    /// interpolated through the blended samples). <paramref name="align"/> turns
    /// <paramref name="other"/>, and moves a closed curve's seam, to line it up first.
    /// <paramref name="tolerance"/> null: the inputs' effective tolerance. A wrong method or
    /// samples throws <see cref="BuildException"/> before the call; so do a count of 0, one curve
    /// closed and the other open, plain on curves that are not compatible and too few
    /// samples.</summary>
    public List<NurbsCurve> Tween(NurbsCurve other, uint count, string method = "matching", uint? samples = null,
                                  bool align = true, double? tolerance = null)
    {
        var code = Array.IndexOf(TweenMethods, method);
        if (code < 0)
            throw new BuildException($"nurbs_curve_tween: method must be one of {string.Join(", ", TweenMethods)}, not '{method}'");
        if (method == "sampling")
        {
            if (samples is null) throw new BuildException("nurbs_curve_tween: sampling needs samples");
        }
        else if (samples is not null)
            throw new BuildException($"nurbs_curve_tween: samples is read only by sampling, not {method}");
        var raw = new IntPtr[Math.Max(count, 1u)];
        var ok = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_tween(
            Handle, other.Handle, count, (uint)code, samples ?? 0u, align, Blacksmith.Tol(tolerance), raw);
        GC.KeepAlive(other);
        if (!ok) throw Blacksmith.Failure("nurbs_curve_tween");
        var made = new List<NurbsCurve>((int)Math.Min(count, 1024u));
        for (var i = 0; i < count; i++) made.Add(Of(new NurbsCurveHandle(raw[i]), "nurbs_curve_tween"));
        return made;
    }

    // -- edits

    /// <summary>This curve projected onto the plane through <paramref name="origin"/> with
    /// <paramref name="normal"/>, along <paramref name="direction"/> (null: the normal). Exact.</summary>
    public NurbsCurve ProjectedToPlane((double X, double Y, double Z) origin, (double X, double Y, double Z) normal,
                                       (double X, double Y, double Z)? direction = null) =>
        Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_projected_to_plane(Handle, Dir3(origin), Dir3(normal), Dir(direction)),
            "nurbs_curve_projected_to_plane");

    /// <summary>This curve projected along <paramref name="direction"/> onto face
    /// <paramref name="face"/> of <paramref name="solid"/> (its whole surface), fitted within
    /// <paramref name="tolerance"/>; the result's <see cref="FitError"/> is the largest distance
    /// between it and the surface. Throws where a point's ray misses.</summary>
    public NurbsCurve ProjectedToFace(Solid solid, int face, (double X, double Y, double Z) direction, double? tolerance = 1e-3)
    {
        var h = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_projected_to_face(
            Handle, solid.Handle, Solid.Index(face), Dir3(direction), Blacksmith.Tol(tolerance), out var error);
        return Of(h, "nurbs_curve_projected_to_face", error);
    }

    /// <summary>This curve pulled onto face <paramref name="face"/> of <paramref name="solid"/> (its
    /// whole surface): every point to its nearest surface point, fitted within
    /// <paramref name="tolerance"/> (<see cref="FitError"/> as for the projection).</summary>
    public NurbsCurve PulledToFace(Solid solid, int face, double? tolerance = 1e-3)
    {
        var h = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_pulled_to_face(
            Handle, solid.Handle, Solid.Index(face), Blacksmith.Tol(tolerance), out var error);
        return Of(h, "nurbs_curve_pulled_to_face", error);
    }

    /// <summary>This curve, lying on the sheet solid (any of its faces, within ten times tolerance), offset
    /// distance along it: each point walked that far across the sheet, square to the curve -- left
    /// of its run seen from the outward side for a positive distance -- over the seams of a joined
    /// sheet, and fitted within tolerance. <see cref="FitError"/> is the larger of the fit's error and its
    /// distance off the sheet. Refused where the curve does not lie on the sheet.</summary>
    public NurbsCurve OffsetOnSheet(Solid solid, double distance, double? tolerance = 1e-3)
    {
        ArgumentNullException.ThrowIfNull(solid);
        var h = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_offset_on_sheet(Handle, solid.Handle, distance, Blacksmith.Tol(tolerance), out var error);
        GC.KeepAlive(solid);
        return Of(h, "nurbs_curve_offset_on_sheet", error);
    }

    /// <summary>The same curve run the other way over the same domain.</summary>
    public NurbsCurve Reversed() => Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_reversed(Handle), "nurbs_curve_reversed");

    /// <summary>The part from <paramref name="t0"/> to <paramref name="t1"/> (t0 &lt; t1, inside the
    /// domain), over t0..t1.</summary>
    public NurbsCurve Trimmed(double t0, double t1) =>
        Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_trimmed(Handle, t0, t1), "nurbs_curve_trimmed");

    /// <summary>This curve continued <paramref name="length"/> past its end (or start, with
    /// <paramref name="atStart"/>) along its own end polynomial: position, tangent and curvature
    /// there unchanged, every old parameter its old point.</summary>
    public NurbsCurve Extended(double length, bool atStart = false) =>
        Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_extended(Handle, atStart, length), "nurbs_curve_extended");

    /// <summary>The same curve at degree <c>Degree + by</c> (at most 12).</summary>
    public NurbsCurve Elevated(int by = 1) =>
        Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_elevated(Handle, Whole(by, "nurbs_curve_elevated: by")), "nurbs_curve_elevated");

    /// <summary>This curve through the affine map <paramref name="t"/>: its control points mapped,
    /// weights and knots kept -- exact. A singular map (a projection) is allowed.</summary>
    public NurbsCurve Transformed(Transform t) => Transformed(t.Rows);

    /// <summary><see cref="Transformed(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public NurbsCurve Transformed(double[] matrix) =>
        Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_transformed(Handle, Blacksmith.Numbers(matrix, 16, "nurbs_curve_transformed")),
            "nurbs_curve_transformed");

    /// <summary>A copy, with its own handle and the same <see cref="FitError"/>.</summary>
    public NurbsCurve Clone() => Of(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_clone(Handle), "nurbs_curve_clone", FitError);

    // -- reading

    public int Degree => (int)BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_degree(Handle);

    /// <summary>The control points.</summary>
    public (double X, double Y, double Z)[] ControlPoints
    {
        get
        {
            var n = (int)BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_control_count(Handle);
            var flat = new double[3 * n];
            if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_control_points(Handle, flat)) throw Blacksmith.Failure("nurbs_curve_control_points");
            return Enumerable.Range(0, n).Select(i => (flat[3 * i], flat[3 * i + 1], flat[3 * i + 2])).ToArray();
        }
    }

    /// <summary>One weight a control point (all 1 for a non-rational curve).</summary>
    public double[] Weights
    {
        get
        {
            var w = new double[BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_control_count(Handle)];
            if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_weights(Handle, w)) throw Blacksmith.Failure("nurbs_curve_weights");
            return w;
        }
    }

    /// <summary>The full knot vector.</summary>
    public double[] Knots
    {
        get
        {
            var k = new double[BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_knot_count(Handle)];
            if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_knots(Handle, k)) throw Blacksmith.Failure("nurbs_curve_knots");
            return k;
        }
    }

    /// <summary>The parameter range, first and last.</summary>
    public (double Lo, double Hi) Domain
    {
        get
        {
            var d = new double[2];
            if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_domain(Handle, d)) throw Blacksmith.Failure("nurbs_curve_domain");
            return (d[0], d[1]);
        }
    }

    public bool IsRational => BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_is_rational(Handle);

    /// <summary>The curve ends where it starts (the answer, not a flag).</summary>
    public bool IsClosed => BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_is_closed(Handle);

    /// <summary>The point at parameter <paramref name="t"/>, inside the domain.</summary>
    public (double X, double Y, double Z) Point(double t)
    {
        var p = new double[3];
        if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_point(Handle, t, p)) throw Blacksmith.Failure("nurbs_curve_point");
        return (p[0], p[1], p[2]);
    }

    /// <summary>The point and its derivatives at <paramref name="t"/> up to <paramref name="order"/>
    /// (at most 8): order + 1 points, <c>[C, C', C'', ...]</c>.</summary>
    public (double X, double Y, double Z)[] Derivatives(double t, uint order = 2)
    {
        var flat = new double[3 * (Math.Min(order, 8u) + 1)];
        if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_derivatives(Handle, t, order, flat)) throw Blacksmith.Failure("nurbs_curve_derivatives");
        return Enumerable.Range(0, (int)order + 1).Select(i => (flat[3 * i], flat[3 * i + 1], flat[3 * i + 2])).ToArray();
    }

    /// <summary>The curvature and Frenet frame at <paramref name="t"/>.</summary>
    public Curvature Curvature(double t)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_curvature(Handle, t, out var raw)) throw Blacksmith.Failure("nurbs_curve_curvature");
        return global::Cadaclysm.Blacksmith.Curvature.Of(raw);
    }

    /// <summary>The curve's length, to the relative <paramref name="accuracy"/> (0 asks for the
    /// default).</summary>
    public Length Length(double accuracy = 0.0)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_length(Handle, accuracy, out var raw)) throw Blacksmith.Failure("nurbs_curve_length");
        return new Length(raw);
    }

    /// <summary>The point at arc length <paramref name="s"/> from the curve's start.</summary>
    public At PointAtLength(double s, double accuracy = 0.0)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_point_at_length(Handle, s, accuracy, out var raw)) throw Blacksmith.Failure("nurbs_curve_point_at_length");
        return new At(raw);
    }

    /// <summary>The <see cref="CurveFoot"/> nearest <paramref name="p"/> over the curve's whole
    /// domain: <c>Unique</c> is false where another point of the curve is as near (a point on a
    /// circle's axis) and <c>Point</c> is a pick among them. Exact.</summary>
    public CurveFoot ClosestPoint((double X, double Y, double Z) p)
    {
        var o = new double[5];
        if (BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_closest_point(Handle, Dir3(p), o) < 0)
            throw Blacksmith.Failure("nurbs_curve_closest_point");
        return new CurveFoot(o[0], (o[1], o[2], o[3]), o[4] != 0.0);
    }

    /// <summary><see cref="ClosestPoint((double X, double Y, double Z))"/> within
    /// <paramref name="maxDistance"/>: null where the nearest point lies beyond it (null, NaN or
    /// +inf: no limit, the same answer as with none). A negative limit throws.</summary>
    public CurveFoot? ClosestPoint((double X, double Y, double Z) p, double? maxDistance)
    {
        var o = new double[5];
        var found = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_closest_point_within(Handle, Dir3(p), maxDistance ?? double.NaN, o);
        if (found < 0) throw Blacksmith.Failure("nurbs_curve_closest_point_within");
        return found == 0 ? null : new CurveFoot(o[0], (o[1], o[2], o[3]), o[4] != 0.0);
    }

    /// <summary>The nearest points of this curve and <paramref name="other"/>, as a
    /// <see cref="CurvePair"/> (side `a` this curve, distance 0 where they cross; among equal
    /// distances the smallest <c>TA</c>, then <c>TB</c>), or null where they lie farther apart
    /// than <paramref name="maxDistance"/> (null, NaN or +inf: no limit). Exact.</summary>
    public CurvePair? ClosestPoints(NurbsCurve other, double? maxDistance = null)
    {
        ArgumentNullException.ThrowIfNull(other);
        var found = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_closest_points(Handle, other.Handle, maxDistance ?? double.NaN, out var raw);
        if (found < 0) throw Blacksmith.Failure("nurbs_curve_closest_points");
        return found == 0 ? null : new CurvePair(raw);
    }

    /// <summary>The item of <paramref name="items"/> nearest to this curve, as a
    /// <see cref="NearestObject"/> -- <c>Which</c> its index -- or null where none lies within
    /// <paramref name="maxDistance"/> (null, NaN or +inf: no limit) or the list is empty. Each
    /// item is a <see cref="Solid"/>, a <see cref="NurbsCurve"/>, a <see cref="Projector"/> or a
    /// point (a <c>double[3]</c> or a <c>(double, double, double)</c>). Items are asked in order,
    /// each with the best distance so far as its limit; equal distances go to the earlier item.
    /// <paramref name="tolerance"/> (null, 0 or NaN: each solid's effective tolerance) sizes each
    /// solid's search; a projector keeps its own, and its lock is held for the whole curve
    /// query.</summary>
    public NearestObject? ClosestObject(IEnumerable<object> items, double? maxDistance = null, double? tolerance = null)
    {
        const string what = "nurbs_curve_closest_object";
        ArgumentNullException.ThrowIfNull(items);
        var kinds = new List<byte>();
        var solids = new List<Solid>();
        var curves = new List<NurbsCurve>();
        var points = new List<double>();
        var projectors = new List<Projector>();
        var i = 0;
        foreach (var item in items)
        {
            switch (item)
            {
                case Solid s: kinds.Add(0); solids.Add(s); break;
                case NurbsCurve c: kinds.Add(1); curves.Add(c); break;
                case Projector pr: kinds.Add(3); projectors.Add(pr); break;
                case double[] { Length: 3 } xyz: kinds.Add(2); points.AddRange(xyz); break;
                case ValueTuple<double, double, double> t: kinds.Add(2); points.Add(t.Item1); points.Add(t.Item2); points.Add(t.Item3); break;
                default:
                    throw new BuildException($"{what}: item {i}: not a Solid, a NurbsCurve, a Projector or a point of 3 numbers, got {item?.ToString() ?? "null"}");
            }
            i++;
        }
        // Arrays of raw pointers, which the marshaller cannot ref-count: the owners stay
        // reachable until the call has returned (`GC.KeepAlive`).
        var solidHandles = solids.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var curveHandles = curves.Select(c => c.Handle.DangerousGetHandle()).ToArray();
        var projectorHandles = projectors.Select(p => p.Handle.DangerousGetHandle()).ToArray();
        var found = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_closest_object(Handle, kinds.ToArray(), (uint)kinds.Count,
            solidHandles, (uint)solidHandles.Length, curveHandles, (uint)curveHandles.Length, points.ToArray(), (uint)(points.Count / 3),
            projectorHandles, (uint)projectorHandles.Length, maxDistance ?? double.NaN, Blacksmith.Tol(tolerance), out var raw);
        GC.KeepAlive(solids);
        GC.KeepAlive(curves);
        GC.KeepAlive(projectors);
        if (found < 0) throw Blacksmith.Failure(what);
        return found == 0 ? null : new NearestObject(raw);
    }

    /// <summary>The curve in <paramref name="n"/> pieces of equal arc length: n + 1 samples, n for a
    /// closed curve.</summary>
    public List<At> DivideByCount(uint n, double accuracy = 0.0) =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_divide_by_count(Handle, n, accuracy), "nurbs_curve_divide_by_count");

    /// <summary>Samples every <paramref name="step"/> of arc length from the start; a closed curve
    /// never repeats it.</summary>
    public List<At> DivideByLength(double step, double accuracy = 0.0) =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_divide_by_length(Handle, step, accuracy), "nurbs_curve_divide_by_length");

    /// <summary>Where the curve crosses the plane through <paramref name="origin"/> with
    /// <paramref name="normal"/>, in parameter order (<c>Error</c> each point's distance from the
    /// plane). Throws for a curve lying in the plane; a touch that does not cross is not
    /// listed.</summary>
    public List<At> PlaneHits((double X, double Y, double Z) origin, (double X, double Y, double Z) normal) =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_plane_hits(Handle, Dir3(origin), Dir3(normal)), "nurbs_curve_plane_hits");

    /// <summary>Where the curve crosses face <paramref name="face"/> of <paramref name="solid"/> (its
    /// whole surface), within <paramref name="tolerance"/> of it, in parameter order (<c>Error</c>
    /// each point's distance from the surface).</summary>
    public List<At> FaceHits(Solid solid, int face, double? tolerance = 1e-3) =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_face_hits(Handle, solid.Handle, Solid.Index(face), Blacksmith.Tol(tolerance)),
            "nurbs_curve_face_hits");

    /// <summary>This curve faired: the smoothest curve of <paramref name="degree"/> within
    /// <paramref name="tolerance"/> of it, from its start to its end, as <see cref="Fair"/> makes
    /// one from points; <paramref name="noInflection"/>'s ends are this curve's own parameters
    /// here. Its <see cref="FitError"/> is the largest distance found between the two.</summary>
    public NurbsCurve Faired(int degree = 5, double? tolerance = 1e-3, (double? From, double? To)? noInflection = null)
    {
        var (held, lo, hi) = NoInflection(noInflection);
        var h = BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_faired(Handle, Whole(degree, "nurbs_curve_faired: degree"), Blacksmith.Tol(tolerance),
            held, lo, hi, out var error);
        return Of(h, "nurbs_curve_faired", error);
    }

    /// <summary>Where the curvature turns from one side to the other, in parameter order
    /// (<c>Error</c> zero): the comb flipping sides. Empty for a curve that bends one way only --
    /// what a test of a design line asks for.</summary>
    public List<At> Inflections() =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_inflections(Handle), "nurbs_curve_inflections");

    /// <summary>The largest turn of the tangent and jump of the curvature at the curve's knots.</summary>
    public KnotContinuity KnotContinuity()
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_nurbs_curve_knot_continuity(Handle, out var raw)) throw Blacksmith.Failure("nurbs_curve_knot_continuity");
        return global::Cadaclysm.Blacksmith.KnotContinuity.Of(raw);
    }

    /// <summary>A curvature comb to draw: at n + 1 even parameters (n at least 1), the curve point
    /// and that point moved by <c>-scale * kappa * normal</c> (out of the bend). Straight
    /// stretches give zero teeth.</summary>
    public List<((double X, double Y, double Z) From, (double X, double Y, double Z) To)> Comb(int n = 64, double scale = 1.0)
    {
        var (lo, hi) = Domain;
        var steps = Math.Max(n, 1);
        var teeth = new List<((double X, double Y, double Z), (double X, double Y, double Z))>(steps + 1);
        for (var i = 0; i <= steps; i++)
        {
            var t = lo + (hi - lo) * i / steps;
            var k = Curvature(t);
            var p = Point(t);
            teeth.Add((p, (p.X - scale * k.Kappa * k.Normal.X, p.Y - scale * k.Kappa * k.Normal.Y, p.Z - scale * k.Kappa * k.Normal.Z)));
        }
        return teeth;
    }

    public override string ToString()
    {
        var (lo, hi) = Domain;
        return $"NurbsCurve(degree={Degree}, controls={ControlPoints.Length}, rational={IsRational}, domain=({lo:G9}, {hi:G9}))";
    }
}

/// <summary>An exact B-rep solid (or open sheet). Immutable; every operation returns a new
/// one. Dispose it to free it; the runtime does so otherwise, through its handle.</summary>
public sealed class Solid : IDisposable
{
    private readonly SolidHandle _handle;

    internal Solid(SolidHandle handle)
    {
        _handle = Blacksmith.Checked(handle, "solid");
    }

    /// <summary>The trims lost by the <see cref="Transform(Transform)"/> or
    /// <see cref="ConvertToNurbs"/> call that made this solid: face boundaries that survive only
    /// as a polyline lifted through the old surface, where no exact edge curve was left. Per
    /// call, not this solid's history; 0 for a solid neither call made.</summary>
    public uint InexactTrims { get; private init; }

    /// <summary>The handle, refusing to hand over a disposed one, so a use-after-dispose
    /// throws at the call site instead of passing a dangling pointer into the library. (The
    /// marshaller would refuse it too; this keeps the message the binding's own.)</summary>
    internal SolidHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Solid), "solid: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Draw with the view library in use: blocks until the window is closed; on the terminal, prints a still.
    /// Choose the library with <see cref="Cadaclysm.Views.ViewLibrary"/> before the first view.</summary>
    public void Show(global::Cadaclysm.Views.ShowOptions? options = null) => global::Cadaclysm.Views.View.Present(this, options, false);

    /// <summary>Orbit until the window is closed; the camera it was left at and the last pick.</summary>
    public global::Cadaclysm.Views.Camera View(global::Cadaclysm.Views.ShowOptions? options = null) =>
        global::Cadaclysm.Views.View.Present(this, options, true)!;

    /// <summary>Give the solid back. Idempotent. Every <see cref="BlacksmithMesh"/> and
    /// <see cref="BlacksmithPolylines"/> still held owns its own tessellation and reads on,
    /// untouched by this.</summary>
    public void Dispose() => _handle.Dispose();

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

    /// <summary>A right pyramid of `sides` sides (at least 3): its base the regular polygon of
    /// circumradius `r` on z=0, its first corner on +x, its tip at (0, 0, `h`).</summary>
    public static Solid Pyramid(int sides, double r, double h) =>
        new(BlacksmithNative.cadaclysm_blacksmith_pyramid((uint)Math.Max(0, sides), r, h));

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

    /// <summary>This solid through the affine map `t`, exact, its colours and name kept. A rigid
    /// map or a similarity keeps every surface's kind; a map within 1e-6 of a similarity is
    /// applied as the exact similarity nearest it. Any other map (a non-uniform scale, a shear)
    /// turns the curved surfaces into their exact NURBS and maps those. The result's
    /// <see cref="InexactTrims"/> counts the trims this call lost. Throws
    /// <see cref="BuildException"/> for a singular map (it flattens the solid).</summary>
    public Solid Transform(Transform t) => Transform(t.Rows);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Solid Transform(double[] matrix)
    {
        var handle = BlacksmithNative.cadaclysm_blacksmith_solid_transform(Handle, Blacksmith.Numbers(matrix, 16, "solid_transform"), out var lost);
        return new Solid(Blacksmith.Checked(handle, "solid_transform")) { InexactTrims = lost };
    }

    /// <summary>This solid with its surfaces rewritten as their exact NURBS: `"procedural"` the
    /// revolutions, extrusions and sums; `"analytic"` those and the cylinders, cones, spheres and
    /// tori; `"all"` everything, planes and edge curves too, a body made only of NURBS. Colours
    /// and name kept; <see cref="InexactTrims"/> counts the trims this call lost.</summary>
    public Solid ConvertToNurbs(string level = "all")
    {
        uint code = level switch
        {
            "procedural" => 0,
            "analytic" => 1,
            "all" => 2,
            _ => throw new BuildException($"convert_to_nurbs: level '{level}' is not \"procedural\", \"analytic\" or \"all\""),
        };
        var handle = BlacksmithNative.cadaclysm_blacksmith_solid_convert_to_nurbs(Handle, code, out var lost);
        return new Solid(Blacksmith.Checked(handle, "solid_convert_to_nurbs")) { InexactTrims = lost };
    }

    // -- combining

    /// <summary>This solid and `other` as one. `merge` merges the flush faces the join leaves
    /// (<see cref="MergeFlush"/>), off by default, so face and edge numbers
    /// stay as they were.</summary>
    public Solid Join(Solid other, double? tolerance = 0.05, bool merge = false) =>
        Merged(new(BlacksmithNative.cadaclysm_blacksmith_join(Handle, other.Handle, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero)), merge);

    /// <summary>This solid with `other` removed; `merge` as <see cref="Join"/>'s.</summary>
    public Solid Cut(Solid other, double? tolerance = 0.05, bool merge = false) =>
        Merged(new(BlacksmithNative.cadaclysm_blacksmith_cut(Handle, other.Handle, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero)), merge);

    /// <summary>What this solid and `other` share; `merge` as <see cref="Join"/>'s.</summary>
    public Solid Common(Solid other, double? tolerance = 0.05, bool merge = false) =>
        Merged(new(BlacksmithNative.cadaclysm_blacksmith_common(Handle, other.Handle, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero)), merge);

    /// <summary>`solid`, its flush faces merged when `merge`; the unmerged one disposed. One verb
    /// to the caller: a tracked result's origins are read back through the boolean's
    /// (`origins_through`), so they name this solid as operand 0 and `other` as 1, not the faces
    /// between the two steps.</summary>
    private static Solid Merged(Solid solid, bool merge)
    {
        if (!merge) return solid;
        using (solid)
        {
            if (!solid.IsTracked) return solid.MergeFlush();
            using var merged = solid.MergeFlush();
            return new Solid(BlacksmithNative.cadaclysm_blacksmith_origins_through(merged.Handle, solid.Handle));
        }
    }

    /// <summary>This solid (a sheet or a solid) cut along `tool`'s boundary, nothing removed:
    /// every face comes back in its pieces outside `tool` and its pieces inside, each piece a
    /// face, in this solid's own face order with each face's outside pieces before its inside
    /// pieces. `tool` must be a closed solid. Keep or discard pieces with
    /// <see cref="DropFaces"/>; <see cref="Trim"/> is the split with one side dropped.</summary>
    public Solid SplitSheet(Solid tool, double? tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_split_sheet(Handle, tool.Handle, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero));

    /// <summary>This sheet (or solid) cut along the closed `tool`'s boundary and the pieces on
    /// one side thrown away: `keep` "outside" keeps what lies outside the tool (a hole punched
    /// through), "inside" what lies within it.</summary>
    public Solid Trim(Solid tool, string keep = "outside", double? tolerance = 0.05)
    {
        if (keep != "outside" && keep != "inside")
            throw new BuildException($"trim: keep must be 'outside' or 'inside', not '{keep}'");
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_trim(Handle, tool.Handle, keep == "inside", Blacksmith.Tol(tolerance),
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
    /// be empty for a partial overlap of curved faces whose outlines cross. Known limit: a crossing narrower than
    /// `tolerance` -- two surfaces passing within it without their meshes crossing -- can be
    /// missed; near-tangent contact is where this bites.
    ///
    /// Throws <see cref="BuildException"/> for a `tolerance` not positive and finite, a solid
    /// with no faces, or one that meshes to nothing.</summary>
    public Intersection Intersect(Solid other, double? tolerance = 0.05)
    {
        using var found = Blacksmith.Checked(
            BlacksmithNative.cadaclysm_blacksmith_intersect(Handle, other.Handle, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero), "intersect");
        return Intersection.Read(found);
    }

    /// <summary>This solid cut by the plane `Z = z`: its closed outlines there, in XY, nested
    /// into profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a
    /// circle crossing kept exact and any other curve as lines within `tolerance`. A plane that
    /// misses the solid is an empty list. Throws <see cref="BuildException"/> for a `z` not
    /// finite, a `tolerance` not positive and finite, a face lying in the plane (section a
    /// little above or below it), or a crossing that does not close.</summary>
    public IReadOnlyList<Profile> Section(double z, double? tolerance = 0.05) =>
        Profile.ProfileList(BlacksmithNative.cadaclysm_blacksmith_solid_section(Handle, z, Blacksmith.Tol(tolerance)), "solid_section");

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
    public SolidHits Hits(Profile profile, double[] frame, double? tolerance = 0.05)
    {
        using var found = Blacksmith.Checked(
            BlacksmithNative.cadaclysm_blacksmith_solid_profile_hits(Handle, profile.Handle, Blacksmith.Frame(frame), Blacksmith.Tol(tolerance),
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

    /// <summary>The solid's axis-aligned box, at the same cost whatever its size: its mesh at
    /// a thousandth of its own extent, in `double`, so the box is inside the exact one and short
    /// of it by at most that. Worked out once per solid, apart from the tessellation
    /// <see cref="Mesh"/> caches -- asking it never invalidates a mesh's spans.
    /// <see cref="BoundsAt"/> is the box of the mesh at a tolerance you name.</summary>
    public (double[] Min, double[] Max) Bounds
    {
        get
        {
            double[] lo = new double[3], hi = new double[3];
            if (!BlacksmithNative.cadaclysm_blacksmith_box(Handle, lo, hi)) throw Blacksmith.Failure("box");
            return (lo, hi);
        }
    }

    /// <summary>The solid's axis-aligned bounds, over the positions of its cached
    /// tessellation at `tolerance` (the same cache <see cref="Mesh"/> fills and reuses, so a
    /// second call at the same tolerance is free).</summary>
    public (double[] Min, double[] Max) BoundsAt(double tolerance)
    {
        double[] lo = new double[3], hi = new double[3];
        if (!BlacksmithNative.cadaclysm_blacksmith_bounds(Handle, tolerance, lo, hi)) throw Blacksmith.Failure("bounds");
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
        return (lo, hi);
    }

    /// <summary>This solid's box at `tolerance`: its boolean mesh, padded by twice that -- the
    /// broad phase's own shape, cheaper to move and test than the solid itself.</summary>
    public Box BoundsBox(double? tolerance = 0.05)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_solid_bounds_box(Handle, Blacksmith.Tol(tolerance), out var raw)) throw Blacksmith.Failure("bounds_box");
        return new Box(raw);
    }

    /// <summary>An <see cref="RTree"/> over this solid's faces: one entry per face, its id the
    /// face index the other face calls take, its box holding the face (the box the boolean's broad
    /// phase pairs faces by, grown by a thousandth of the solid's extent). No faces give an empty
    /// tree.</summary>
    public RTree FaceTree() => new(BlacksmithNative.cadaclysm_blacksmith_solid_face_tree(Handle), "solid_face_tree");

    /// <summary>How many edges of the mesh at `tolerance` -- the triangles the mesh calls hand
    /// out -- are bound by anything other than exactly two triangles -- zero for a closed
    /// solid. A hole, a fold, and a seam two solids share along a line (four triangles) all
    /// count here; UnpairedEdges is the check that lets the seam pass.
    /// </summary>
    public int LeakedEdges(double? tolerance = 0.05)
    {
        var n = BlacksmithNative.cadaclysm_blacksmith_leaked_edges(Handle, Blacksmith.Tol(tolerance));
        if (n == Blacksmith.None) throw Blacksmith.Failure("leaked_edges");
        return (int)n;
    }

    /// <summary>How many edges of the mesh at `tolerance` have directed triangle uses that do
    /// not cancel out -- zero for a closed, consistently oriented solid. Where
    /// <see cref="LeakedEdges"/> asks for exactly two triangles on an edge, this asks that
    /// they run opposite ways: a shared seam pairs off and is <em>not</em> counted, a fold --
    /// two triangles running the same way -- is.</summary>
    public int UnpairedEdges(double? tolerance = 0.05)
    {
        var n = BlacksmithNative.cadaclysm_blacksmith_unpaired_edges(Handle, Blacksmith.Tol(tolerance));
        if (n == Blacksmith.None) throw Blacksmith.Failure("unpaired_edges");
        return (int)n;
    }

    /// <summary>`LeakedEdges(tolerance) == 0`.</summary>
    public bool IsWatertight(double? tolerance = 0.05) => LeakedEdges(Blacksmith.Tol(tolerance)) == 0;

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

    /// <summary>The radius of the round face `face` belongs to -- a fillet's face that
    /// <c>Unfillet</c> can take back -- 0 where it is none. Throws <see cref="BuildException"/>
    /// for a face the solid does not have.</summary>
    public double FaceRoundRadius(int face)
    {
        var r = BlacksmithNative.cadaclysm_blacksmith_face_round_radius(Handle, Index(face));
        if (double.IsNaN(r)) throw Blacksmith.Failure("face_round_radius");
        return r;
    }

    /// <summary>The distance of the chamfer face `face` belongs to -- a bevel <c>Unchamfer</c>
    /// can take back -- 0 where it is none. Throws <see cref="BuildException"/> for a face the
    /// solid does not have.</summary>
    public double FaceChamferDistance(int face)
    {
        var d = BlacksmithNative.cadaclysm_blacksmith_face_chamfer_distance(Handle, Index(face));
        if (double.IsNaN(d)) throw Blacksmith.Failure("face_chamfer_distance");
        return d;
    }

    /// <summary>The edges as rational cubic Beziers, sixteen numbers each (`x y z w` per control
    /// point, the point Cartesian and its weight beside it) -- what a viewer draws the edges by:
    /// exact where an edge's curve has a Bezier form, flattened within `tolerance` where it has
    /// none (null: the solid's effective tolerance).</summary>
    public double[] EdgeBeziers(double? tolerance = null)
    {
        var t = Blacksmith.Tol(tolerance);
        var n = BlacksmithNative.cadaclysm_blacksmith_edge_bezier_count(Handle, t);
        var found = new double[16 * n];
        if (!BlacksmithNative.cadaclysm_blacksmith_edge_beziers(Handle, t, found)) throw Blacksmith.Failure("edge_beziers");
        return found;
    }

    /// <summary>The faces' isoparametric curves as rational cubic Beziers, sixteen numbers each as
    /// <see cref="EdgeBeziers"/> gives them: `density` interior lines each way on every curved
    /// face, clipped to the face, plus the lines at the ends of its parameter span; a flat face
    /// draws none. Exact where the surface has a closed form for the line, flattened within
    /// `tolerance` elsewhere (null: the solid's effective tolerance).</summary>
    public double[] IsocurveBeziers(int density = 4, double? tolerance = null)
    {
        var t = Blacksmith.Tol(tolerance);
        var d = Index(density);
        var n = BlacksmithNative.cadaclysm_blacksmith_isocurve_bezier_count(Handle, d, t);
        var found = new double[16 * n];
        if (!BlacksmithNative.cadaclysm_blacksmith_isocurve_beziers(Handle, d, t, found)) throw Blacksmith.Failure("isocurve_beziers");
        return found;
    }

    /// <summary>What is wrong with this solid, as a <see cref="HealthReport"/>: the free edges (the
    /// sides one face bounds) and the wires they chain into, with each edge's nearest partner and
    /// the gap to it; the features below <c>tolerance</c>; the loose edges; and what sewing
    /// would join and leave. <c>tolerance</c> is the length below which
    /// a feature is small and a gap closes -- null, or a value that is not finite and positive,
    /// takes the default, <c>1e-4</c> times the diagonal (the report shows what was used).
    /// <c>mesh</c> also meshes the solid and reports where the mesh cracks
    /// (<see cref="HealthReport.Cracks"/>); without it that is null. Nothing moves.</summary>
    public HealthReport Health(double? tolerance = null, bool mesh = false)
    {
        using var health = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_health(Handle, tolerance ?? double.NaN, mesh), "health");
        var counts = new uint[18];
        var sizes = new double[8];
        if (!BlacksmithNative.cadaclysm_blacksmith_health_summary(health, counts, sizes)) throw Blacksmith.Failure("health");
        var n = BlacksmithNative.cadaclysm_blacksmith_health_free_edges(health, null, null);
        var freeIds = new uint[6 * n];
        var freeSizes = new double[2 * n];
        if (n > 0) BlacksmithNative.cadaclysm_blacksmith_health_free_edges(health, freeIds, freeSizes);
        n = BlacksmithNative.cadaclysm_blacksmith_health_wires(health, null, null);
        var wireRuns = new uint[3 * n];
        var wireSizes = new double[2 * n];
        if (n > 0) BlacksmithNative.cadaclysm_blacksmith_health_wires(health, wireRuns, wireSizes);
        n = BlacksmithNative.cadaclysm_blacksmith_health_small(health, null, null);
        var smallItems = new uint[2 * n];
        var smallSizes = new double[n];
        if (n > 0) BlacksmithNative.cadaclysm_blacksmith_health_small(health, smallItems, smallSizes);
        n = BlacksmithNative.cadaclysm_blacksmith_health_crack_edges(health, null);
        var cracks = new uint[n];
        if (n > 0) BlacksmithNative.cadaclysm_blacksmith_health_crack_edges(health, cracks);
        return HealthReport.FromRows(counts, sizes, freeIds, freeSizes, wireRuns, wireSizes, smallItems, smallSizes, cracks);
    }

    /// <summary>This solid with its small features removed, and what was done, as a new
    /// <see cref="Solid"/> and a <see cref="HealReport"/>; this one is left as it was. The
    /// features are the ones <see cref="Health"/> lists as small at <c>tolerance</c>: short and
    /// collapsed edges, sliver and tiny faces, small holes. Every fix is a vertex merge, and an
    /// edge it moves records how far as its <see cref="EdgeTolerance"/>. A guard compares the
    /// result's health with this one's and refuses fixes that made it worse
    /// (<see cref="HealReport.Guarded"/>). <c>edges</c>, <c>faces</c> and <c>holes</c> switch each
    /// kind of fix; a kind switched off is refused as <c>toggled</c>. <c>tolerance</c> null, or a
    /// value that is not finite and positive, takes the default (the report shows what was
    /// used). The new solid is the caller's to dispose.</summary>
    public (Solid Solid, HealReport Report) Healed(double? tolerance = null, bool edges = true, bool faces = true, bool holes = true)
    {
        using var heal = Blacksmith.Checked(
            BlacksmithNative.cadaclysm_blacksmith_healed(Handle, tolerance ?? double.NaN, HealFlags(edges, faces, holes)), "healed");
        var counts = new uint[11];
        var sizes = new double[2];
        if (!BlacksmithNative.cadaclysm_blacksmith_heal_summary(heal, counts, sizes)) throw Blacksmith.Failure("healed");
        var n = BlacksmithNative.cadaclysm_blacksmith_heal_fixes(heal, null, null);
        var fixItems = new uint[2 * n];
        var fixSizes = new double[2 * n];
        if (n > 0) BlacksmithNative.cadaclysm_blacksmith_heal_fixes(heal, fixItems, fixSizes);
        n = BlacksmithNative.cadaclysm_blacksmith_heal_refused(heal, null, null);
        var refusedItems = new uint[3 * n];
        var refusedSizes = new double[n];
        if (n > 0) BlacksmithNative.cadaclysm_blacksmith_heal_refused(heal, refusedItems, refusedSizes);
        var report = HealReport.FromRows(counts, sizes, fixItems, fixSizes, refusedItems, refusedSizes);
        return (new Solid(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_heal_body(heal), "healed")), report);
    }

    /// <summary>How far brep edge <c>edge</c> (as a <see cref="HealFix"/> or
    /// <see cref="FreeEdge"/> names one) may lie off its curve: 0 for an exact edge, the distance
    /// healing (or sewing) moved it where that is recorded, null when no trim names the id (an
    /// edge healing removed).</summary>
    public double? EdgeTolerance(uint edge)
    {
        var t = BlacksmithNative.cadaclysm_blacksmith_edge_tolerance(Handle, edge);
        if (double.IsNaN(t) && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("edge_tolerance");
        return double.IsNaN(t) ? null : t;
    }

    /// <summary>What this solid declares about its own precision, as <see cref="global::Cadaclysm.Tolerances"/>:
    /// read from its file, inherited through every verb from the loosest of its inputs, or set by
    /// <see cref="WithTolerances"/>; null in a field nothing declared. A verb given a null
    /// <c>tolerance</c> works at <see cref="Blacksmith.EffectiveTolerance"/>, which takes it into
    /// account.</summary>
    public global::Cadaclysm.Tolerances Tolerances
    {
        get
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_solid_tolerances(Handle, out var absolute, out var angular))
                throw Blacksmith.Failure("solid_tolerances");
            return new global::Cadaclysm.Tolerances(Blacksmith.Declared(absolute), Blacksmith.Declared(angular));
        }
    }

    /// <summary>A new solid: this one declaring <c>absolute</c> (a length) and <c>angular</c>
    /// (radians) instead of what it declared, its name, paint and marks kept. Null (or 0) declares
    /// nothing for that field; a negative or infinite value throws. The new solid is the caller's
    /// to dispose.</summary>
    public Solid WithTolerances(double? absolute = null, double? angular = null) =>
        new(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_solid_with_tolerances(Handle, Blacksmith.Tol(absolute),
            Blacksmith.Tol(angular)), "solid_with_tolerances"));

    /// <summary>How loose this solid's vertex at <c>point</c> is, where its producer said (an OCCT
    /// <c>.brep</c> records one per vertex): the tolerance of the nearest recorded vertex within its
    /// own tolerance of <c>point</c>. Null where none is recorded there.</summary>
    public double? VertexTolerance(double[] point)
    {
        var p = Blacksmith.Point(point, "vertex_tolerance");
        var t = BlacksmithNative.cadaclysm_blacksmith_vertex_tolerance(Handle, p[0], p[1], p[2]);
        if (double.IsNaN(t) && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("vertex_tolerance");
        return Blacksmith.Declared(t);
    }

    /// <summary><see cref="Healed"/>'s switches as the C ABI's flag bits: 1 edges, 2 faces, 4 holes.</summary>
    internal static uint HealFlags(bool edges, bool faces, bool holes) =>
        (edges ? 1u : 0u) | (faces ? 2u : 0u) | (holes ? 4u : 0u);

    /// <summary>What this solid measures, per unit density, each figure beside a bound on its own
    /// error. <paramref name="accuracy"/> is relative and 0 asks for the library's default. The
    /// volume-side figures mean something only where <c>Closed</c>; where <c>AccuracyMet</c> is
    /// false the refinement stopped early and the figures are honest but less certain, which the
    /// errors say.</summary>
    public Mass Mass(double accuracy = 0.0)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_mass_properties(Handle, accuracy, out var raw))
        {
            throw Blacksmith.Failure("mass_properties");
        }
        return new Mass(raw);
    }

    /// <summary>This closed solid's box on its principal axes (see <see
    /// cref="OrientedBox"/>): tight along a clear long direction, not the minimal box in general. To the relative <paramref name="accuracy"/> (0, or below, asking for
    /// the default, 1e-5). An open body has no oriented box, and an accuracy NaN or infinite
    /// throws.</summary>
    public OrientedBox OrientedBox(double accuracy = 0.0)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_oriented_box(Handle, accuracy, out var raw)) throw Blacksmith.Failure("oriented_box");
        return new OrientedBox(raw);
    }

    /// <summary>The length of edge <paramref name="edge"/> (an index into <see cref="Edges"/>,
    /// as <see cref="Fillet(IEnumerable{int}, double, double)"/> takes) over its own range, to the
    /// relative <paramref name="accuracy"/>. An edge past the end, or one with no curve to measure,
    /// throws.</summary>
    public Length EdgeLength(int edge, double accuracy = 0.0)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_edge_length(Handle, (uint)edge, accuracy, out var raw)) throw Blacksmith.Failure("edge_length");
        return new Length(raw);
    }

    /// <summary>The point <paramref name="s"/> of arc length along edge <paramref name="edge"/> from
    /// the start of its range, to the relative <paramref name="accuracy"/>. <c>Parameter</c> is the
    /// curve's own; <c>Segment</c> is null. A length outside the edge, an edge past the end or
    /// with no curve, or an accuracy NaN or infinite, throws.</summary>
    public At EdgePointAtLength(int edge, double s, double accuracy = 0.0)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_edge_point_at_length(Handle, Index(edge), s, accuracy, out var raw)) throw Blacksmith.Failure("edge_point_at_length");
        return new At(raw);
    }

    /// <summary><paramref name="n"/> points equally spaced in arc length along edge
    /// <paramref name="edge"/>: n + 1 on an open edge (both ends), n on a closed one (the start
    /// not repeated). 1 to 1,000,000.</summary>
    public List<At> EdgeDivideByCount(int edge, uint n, double accuracy = 0.0) =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_edge_divide_by_count(Handle, Index(edge), n, accuracy), "edge_divide_by_count");

    /// <summary>A point every <paramref name="step"/> of arc length along edge
    /// <paramref name="edge"/>, the short last piece kept and a closed edge's start never repeated.</summary>
    public List<At> EdgeDivideByLength(int edge, double step, double accuracy = 0.0) =>
        Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_edge_divide_by_length(Handle, Index(edge), step, accuracy), "edge_divide_by_length");

    /// <summary>Where <paramref name="point"/> is relative to this closed solid: "inside",
    /// "outside", or "on" within <paramref name="tolerance"/> (absolute, model units) of its
    /// boundary. The body is meshed on every call; for more than a few points build a <see
    /// cref="Classifier"/> once.</summary>
    public string Contains(double[] point, double? tolerance = 0.05)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_contains(Handle, Blacksmith.Point(point, "point"), Blacksmith.Tol(tolerance), out var code)) throw Blacksmith.Failure("contains");
        return Blacksmith.ContainmentOf(code, "contains");
    }

    /// <summary>A <see cref="Classifier"/> for this closed solid at <paramref name="tolerance"/>:
    /// the body meshed once, then asked point after point. It keeps its own reference to the body,
    /// so it goes on answering after this solid is disposed.</summary>
    public Classifier Classifier(double? tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_classifier_new(Handle, Blacksmith.Tol(tolerance)));

    /// <summary>The closest points between this solid's boundary and <paramref name="other"/>'s,
    /// to <paramref name="tolerance"/> (absolute, model units); this solid is side <c>a</c>.
    /// Boundaries are measured, not volumes. No progress callback is offered here.</summary>
    public Closest Closest(Solid other, double? tolerance = 0.05)
    {
        var ok = BlacksmithNative.cadaclysm_blacksmith_closest(Handle, other.Handle, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero, out var raw);
        GC.KeepAlive(other);
        if (!ok) throw Blacksmith.Failure("closest");
        return new Closest(raw);
    }

    /// <summary>The nearest point of this solid's boundary to <paramref name="p"/>, as a
    /// <see cref="PointFoot"/>, or null where it lies beyond <paramref name="maxDistance"/> (null,
    /// NaN or +inf: no limit; 0 finds a point on the body). <paramref name="tolerance"/> --
    /// absolute, in model units; null (or 0, or NaN) is unset, the solid's effective tolerance --
    /// sizes the mesh search only: a <c>Refined</c> false answer is within
    /// `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`. Meshes the body every call:
    /// for more than a few points build a <see cref="Projector"/> once.</summary>
    public PointFoot? ClosestPoint(double[] p, double? maxDistance = null, double? tolerance = null)
    {
        var found = BlacksmithNative.cadaclysm_blacksmith_closest_point(Handle, Blacksmith.Point(p, "closest_point"),
            maxDistance ?? double.NaN, Blacksmith.Tol(tolerance), out var raw);
        if (found < 0) throw Blacksmith.Failure("closest_point");
        return found == 0 ? null : new PointFoot(raw);
    }

    /// <summary>A <see cref="Projector"/> for this solid at <paramref name="tolerance"/> (null:
    /// unset, the solid's effective tolerance): the body meshed once, then asked
    /// <see cref="Projector.ClosestPoint"/> point after point. It keeps its own reference to the
    /// body, so it goes on answering after this solid is disposed. Open bodies and sheets are
    /// accepted.</summary>
    public Projector Projector(double? tolerance = null) =>
        new(BlacksmithNative.cadaclysm_blacksmith_projector_new(Handle, Blacksmith.Tol(tolerance)));

    /// <summary>The nearest points of <paramref name="curve"/> and this solid's boundary, as a
    /// <see cref="CurveBodyFoot"/> -- <c>Crossing</c> true, distance 0, where the curve passes
    /// through the boundary (the earliest crossing in <c>T</c>) -- or null where the body lies
    /// beyond <paramref name="maxDistance"/> (null, NaN or +inf: no limit).
    /// <paramref name="tolerance"/> -- absolute, in model units; null (or 0, or NaN) is unset,
    /// the solid's effective tolerance -- sizes the march along the curve and the mesh search: a
    /// <c>Refined</c> false answer is within `[d - 2/3 tolerance, d + tolerance]` of the true
    /// distance `d`. Meshes the body every call: for more than a few curves build a
    /// <see cref="Projector"/> once.</summary>
    public CurveBodyFoot? CurveClosestPoints(NurbsCurve curve, double? maxDistance = null, double? tolerance = null)
    {
        ArgumentNullException.ThrowIfNull(curve);
        var found = BlacksmithNative.cadaclysm_blacksmith_curve_closest_points(Handle, curve.Handle, maxDistance ?? double.NaN,
            Blacksmith.Tol(tolerance), out var raw);
        if (found < 0) throw Blacksmith.Failure("curve_closest_points");
        return found == 0 ? null : new CurveBodyFoot(raw);
    }

    /// <summary>The nearest point to <paramref name="p"/> of face <paramref name="face"/> alone,
    /// inside its trims or on its boundary: exact, no mesh, always refined.</summary>
    public PointFoot FaceClosestPoint(int face, double[] p)
    {
        if (BlacksmithNative.cadaclysm_blacksmith_face_closest_point(Handle, Index(face), Blacksmith.Point(p, "face_closest_point"), out var raw) < 0)
            throw Blacksmith.Failure("face_closest_point");
        return new PointFoot(raw);
    }

    /// <summary>The nearest point to <paramref name="p"/> of edge <paramref name="edge"/> (an index
    /// into <see cref="Edges"/>, a <see cref="PointFoot"/>'s <c>Edge</c>) on its own curve over its
    /// range: <c>T</c> the curve's parameter, as <see cref="EdgePointAtLength"/> gives it. Exact.</summary>
    public (double T, double[] Point, double Distance) EdgeClosestPoint(int edge, double[] p)
    {
        var o = new double[5];
        if (BlacksmithNative.cadaclysm_blacksmith_edge_closest_point(Handle, Index(edge), Blacksmith.Point(p, "edge_closest_point"), o) < 0)
            throw Blacksmith.Failure("edge_closest_point");
        return (o[0], new[] { o[1], o[2], o[3] }, o[4]);
    }

    /// <summary>One thickness for face <paramref name="face"/> of this solid alone, on a
    /// <see cref="ThicknessGauge"/> meshed at <paramref name="tolerance"/> (default 0.01), used once
    /// and disposed -- build the gauge yourself to ask more than once. Null where nothing is found;
    /// see <see cref="ThicknessGauge.ThicknessAtFace(uint, uint, double[], double)"/>.</summary>
    public FaceThickness? ThicknessAtFace(uint face, double[]? at, double maximum, double? tolerance = 0.01)
    {
        using var gauge = new ThicknessGauge(new[] { this }, Blacksmith.Tol(tolerance));
        return gauge.ThicknessAtFace(0, face, at, maximum);
    }

    /// <summary><see cref="ThicknessAtFace(uint, double[], double, double)"/> over the face's
    /// vertices (no point).</summary>
    public FaceThickness? ThicknessAtFace(uint face, double maximum, double? tolerance = 0.01) => ThicknessAtFace(face, null, maximum, Blacksmith.Tol(tolerance));

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

    // -- material and look defined outside the file

    /// <summary>This solid made of `material` -- a name, written to STEP as the product's
    /// MATERIAL_DESIGNATION. Kept by every operation as the solid's colour is: a move keeps it,
    /// a boolean's result is made of its first solid's. Writing it moves <see cref="Step"/>'s
    /// default schema to AP242; a named schema without the entity drops it, as it drops a
    /// colour. Refused when blank.</summary>
    public Solid WithMaterial(string material) => new(BlacksmithNative.cadaclysm_blacksmith_with_material(Handle, material));

    /// <summary>What this solid is made of, or null -- see <see cref="WithMaterial"/>.</summary>
    public string? Material => Borrowed(BlacksmithNative.cadaclysm_blacksmith_solid_material(Handle));

    /// <summary>This solid drawn in a style defined outside the file: `identification` the
    /// style's name in the library at `location` -- a MaterialX or MDL file and a material in
    /// it, say. Either may be null, not both. Written to STEP as an EXTERNALLY_DEFINED_STYLE
    /// beside the solid's colour, which a reader without the library draws instead (AP242 or
    /// AP214: the default schema moves to AP242). Kept as <see cref="WithMaterial"/>'s
    /// material is.</summary>
    public Solid Styled(string? location, string? identification) =>
        new(BlacksmithNative.cadaclysm_blacksmith_styled(Handle, location, identification));

    /// <summary>Where this solid's outside style lives (<see cref="Styled"/>'s `location`), or
    /// null.</summary>
    public string? StyleLocation => Borrowed(BlacksmithNative.cadaclysm_blacksmith_solid_style_location(Handle));

    /// <summary>This solid's outside style's name in its library (<see cref="Styled"/>'s
    /// `identification`), or null.</summary>
    public string? StyleIdentification => Borrowed(BlacksmithNative.cadaclysm_blacksmith_solid_style_identification(Handle));

    /// A borrowed pointer into this solid, read as <see cref="Name"/> reads its own: null is
    /// "none", never a failure to look up.
    private string? Borrowed(IntPtr raw)
    {
        var result = raw == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(raw);
        GC.KeepAlive(this);
        return result;
    }

    // -- out

    /// <summary>The triangles at `tolerance`, as views over a tessellation held of their own.
    /// See the file header for the lifetime this gives them.</summary>
    public BlacksmithMesh Mesh(double? tolerance = 0.05)
    {
        var held = Blacksmith.TessellationChecked(BlacksmithNative.cadaclysm_blacksmith_tessellation(Handle, Blacksmith.Tol(tolerance)), "mesh");
        return new BlacksmithMesh(this, held, Blacksmith.Tol(tolerance), BlacksmithNative.cadaclysm_blacksmith_tessellation_mesh(held));
    }

    /// <summary><see cref="Mesh"/> in `double`, from the same held tessellation this solid's
    /// cache would give at `tolerance` -- and, once held, untouched by anything done to the
    /// solid afterwards, through <see cref="Mesh"/> as much as through this.</summary>
    public BlacksmithMesh64 Mesh64(double? tolerance = 0.05)
    {
        var held = Blacksmith.TessellationChecked(BlacksmithNative.cadaclysm_blacksmith_tessellation(Handle, Blacksmith.Tol(tolerance)), "mesh64");
        return new BlacksmithMesh64(this, held, Blacksmith.Tol(tolerance), BlacksmithNative.cadaclysm_blacksmith_tessellation_mesh64(held));
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

    /// <summary>The feature edges as polylines, views over a tessellation held the same way
    /// as <see cref="Mesh"/>'s.</summary>
    public BlacksmithPolylines EdgePolylines(double? tolerance = 0.05)
    {
        var held = Blacksmith.TessellationChecked(BlacksmithNative.cadaclysm_blacksmith_tessellation(Handle, Blacksmith.Tol(tolerance)), "edge_polylines");
        return new BlacksmithPolylines(this, held, Blacksmith.Tol(tolerance), BlacksmithNative.cadaclysm_blacksmith_tessellation_edge_polylines(held));
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

    /// <summary>This solid as a Rhino `.3dm`'s bytes: its exact brep, named and coloured as the
    /// solid is; see <see cref="Blacksmith.Rhino3dmBytes"/>.</summary>
    public byte[] Rhino3dmBytes(string unit = "mm") => Blacksmith.Rhino3dmBytes(new[] { this }, unit);

    /// <summary><see cref="Rhino3dmBytes"/> written to <paramref name="path"/> by the library itself.</summary>
    public void Write3dm(string path, string unit = "mm") => Blacksmith.Write3dm(path, new[] { this }, unit);

    /// <summary>This solid as OCCT `.brep` text; see <see cref="Blacksmith.WriteBrepText"/>.
    /// </summary>
    public string BrepText() => Blacksmith.WriteBrepText(new[] { this });

    /// <summary>This solid as a <see cref="Document"/>'s `solid.body` node holds it, as JSON text:
    /// the kernel's own B-rep, every table and number as they are, and its colours (the solid's,
    /// each face's and each edge's). What <see cref="Document.AddSolid"/> puts in a
    /// document.</summary>
    public string DocumentBody() =>
        Blacksmith.OwnedText(BlacksmithNative.cadaclysm_blacksmith_document_solid_body(Handle), "document_solid_body");

    /// <summary>This solid written as a `.brep` file, by the library itself.</summary>
    public void Brep(string path) => Blacksmith.WriteBrep(path, new[] { this });

    /// <summary>This solid's wireframe as SVG text, from the camera <paramref name="options"/>
    /// describes -- the library's own camera, not a viewer. See <see cref="Blacksmith.WriteSvgText"/>.
    /// </summary>
    public string SvgText(SvgOptions? options = null) => Blacksmith.WriteSvgText(new[] { this }, options);

    /// <summary>This solid written as an SVG file by the library itself.</summary>
    public void Svg(string path, SvgOptions? options = null) => Blacksmith.WriteSvg(path, new[] { this }, options);

    /// <summary>This solid's silhouette from the camera <paramref name="options"/> describes --
    /// the curves where its surfaces turn away from the eye, which no edge of it lies on, so a
    /// sphere has an outline here that its wireframe has none of. The same <see cref="SvgOptions"/>
    /// that draw a picture ask about the same eye; `Width` is the image width the library reads
    /// the `Tolerance` against, so set both or neither. The line-set flags are not read.
    /// Exact Béziers where the surface has a closed silhouette form -- sphere, cylinder, cone,
    /// extrusion -- and a straight-chord polyline carried as degree-1 Béziers for every other
    /// surface.
    /// <para>Owned by this call: the library's block is copied into <see cref="BeziersData64"/>
    /// and released before this returns. A solid with no silhouette (every face planar) gives a
    /// result with <see cref="BeziersData64.Count"/> 0, which is not an error; a refused option
    /// throws <see cref="BuildException"/>.</para></summary>
    public BeziersData64 SilhouetteBeziers(SvgOptions? options = null) => Blacksmith.SilhouetteBeziersOf(this, options);

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
    public int? FindFace(double[] faceRef, int? hint = null, double? tolerance = 1e-3)
    {
        if (faceRef.Length != 8) throw new BuildException("find_face: a face reference is eight numbers");
        var found = BlacksmithNative.cadaclysm_blacksmith_find_face(Handle, faceRef, hint ?? -1, Blacksmith.Tol(tolerance));
        if (found == -2) throw Blacksmith.Failure("find_face");
        return found < 0 ? null : found;
    }

    /// <summary>Edge `edge` (an index into <see cref="Edges"/>) by what it is, fifteen doubles:
    /// its kind (line 0, circle 1, ellipse 2, B-spline 3, other 4), its midpoint (x y z), its unit
    /// tangent there (x y z), its length, the outward normals there of the two faces meeting on
    /// it (x y z each; an open sheet's rim gives the one face's twice), and its span -- how far
    /// from the midpoint <see cref="FindEdge"/> may find it on a resized solid.
    /// <see cref="FaceRef"/>'s twin. Throws for an edge past the table or one with no length.</summary>
    public double[] EdgeRef(int edge)
    {
        var r = new double[15];
        if (!BlacksmithNative.cadaclysm_blacksmith_edge_ref(Handle, Index(edge), r)) throw Blacksmith.Failure("edge_ref");
        return r;
    }

    /// <summary>The edge `edgeRef` (from <see cref="EdgeRef"/>) refers to: of the edges of that
    /// kind passing within `tolerance` of its midpoint and running the same way, the one of
    /// nearest length; where none does (the solid was resized), the edge of that kind running the
    /// same way between faces facing the same two ways, the only one or the one clearly nearest,
    /// no farther than the span. Null where the edge is gone. Throws for a malformed reference or
    /// a tolerance not positive.</summary>
    public int? FindEdge(double[] edgeRef, double? tolerance = 1e-3)
    {
        if (edgeRef.Length != 15) throw new BuildException("find_edge: an edge reference is fifteen finite numbers");
        var found = BlacksmithNative.cadaclysm_blacksmith_find_edge(Handle, edgeRef, Blacksmith.Tol(tolerance));
        if (found == -2) throw Blacksmith.Failure("find_edge");
        return found < 0 ? null : found;
    }

    /// <summary>How many vertices this solid has: its edges' ends, welded, in the order
    /// <see cref="VertexRef"/> and <see cref="FindVertex"/> index.</summary>
    public int VertexCount
    {
        get
        {
            var n = BlacksmithNative.cadaclysm_blacksmith_vertex_count(Handle);
            if (n == 0 && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("vertex_count");
            return (int)n;
        }
    }

    /// <summary>Vertex `vertex` by where it is: x, y, z. Throws for a vertex the solid does not
    /// have.</summary>
    public double[] VertexRef(int vertex)
    {
        var r = new double[3];
        if (!BlacksmithNative.cadaclysm_blacksmith_vertex_ref(Handle, Index(vertex), r)) throw Blacksmith.Failure("vertex_ref");
        return r;
    }

    /// <summary>The vertex nearest `vertexRef` (any point: a <see cref="VertexRef"/>, or one
    /// picked) within `tolerance`; null where no vertex is that near. Throws for a point that is
    /// not three finite numbers or a tolerance not positive.</summary>
    public int? FindVertex(double[] vertexRef, double? tolerance = 1e-3)
    {
        if (vertexRef.Length != 3) throw new BuildException("find_vertex: a vertex reference is three finite numbers");
        var found = BlacksmithNative.cadaclysm_blacksmith_find_vertex(Handle, vertexRef, Blacksmith.Tol(tolerance));
        if (found == -2) throw Blacksmith.Failure("find_vertex");
        return found < 0 ? null : found;
    }

    // -- identity: ids on faces and edges, where each came from, and a verb's history

    /// <summary>This solid tracked: its faces numbered 1..n in face order and its edges 1..m in
    /// the edge table's order, each its own origin. Tracking is opt-in and rides on from here: a
    /// verb on a tracked solid gives a tracked result, its faces keeping the ids of the faces they
    /// lie on, and naming those as their origins. A tracked solid comes back as it is.</summary>
    public Solid Tracked() => new(BlacksmithNative.cadaclysm_blacksmith_solid_tracked(Handle));

    /// <summary>Whether this solid carries face and edge ids (<see cref="Tracked"/>, made from a
    /// tracked solid, or given an attribute).</summary>
    public bool IsTracked
    {
        get
        {
            var tracked = BlacksmithNative.cadaclysm_blacksmith_solid_is_tracked(Handle);
            if (!tracked && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("solid_is_tracked");
            return tracked;
        }
    }

    /// <summary>An id the library returned: null for its 0 ("untracked"), unless it left a
    /// reason, which is thrown.</summary>
    private static ulong? IdOf(ulong id, string what)
    {
        if (id != 0) return id;
        if (Blacksmith.LastError().Length > 0) throw Blacksmith.Failure(what);
        return null;
    }

    /// <summary>An index the library returned: null for its NONE, unless it left a reason.</summary>
    private static int? FoundOf(uint found, string what)
    {
        if (found != Blacksmith.None) return (int)found;
        if (Blacksmith.LastError().Length > 0) throw Blacksmith.Failure(what);
        return null;
    }

    /// <summary>Face `face`'s id, null where this solid is untracked. An id stays with its face
    /// through every verb that keeps the face -- a move, a boolean, a fillet of another edge --
    /// so it names "the same face, through my edits" within a session; a piece split off, a
    /// later operand's face whose id an earlier one already has, and a face on no input get
    /// fresh ids, the same run after run. Ids are not written to files: to find a face on a
    /// model rebuilt or read again, use <see cref="FaceRef"/>. Throws for a face the solid does
    /// not have.</summary>
    public ulong? FaceId(int face) => IdOf(BlacksmithNative.cadaclysm_blacksmith_face_id(Handle, Index(face)), "face_id");

    /// <summary>The face whose id is `id`, null where no face has it (an untracked solid, a face a
    /// verb deleted).</summary>
    public int? FaceWithId(ulong id) => FoundOf(BlacksmithNative.cadaclysm_blacksmith_face_with_id(Handle, id), "face_with_id");

    /// <summary>The input faces face `face` came from, as `(Operand, Id)`: the operand its
    /// input's index in the verb's operand order (a boolean's target 0, its tool 1), the id that
    /// input face's <see cref="FaceId"/>. The face it lies on most first; empty for a face the
    /// verb generated (a fillet's round, a split's cut face) or an untracked solid; more than one
    /// for a face merged from several (`Join(merge: true)`). Throws for a face the solid does not
    /// have.</summary>
    public IReadOnlyList<(int Operand, ulong Id)> FaceOrigins(int face)
    {
        var index = Index(face);
        var n = BlacksmithNative.cadaclysm_blacksmith_face_origin_count(Handle, index);
        if (n == Blacksmith.None) throw Blacksmith.Failure("face_origin_count");
        var out_ = new List<(int, ulong)>((int)n);
        for (uint i = 0; i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_face_origin_at(Handle, index, i, out var operand, out var id))
                throw Blacksmith.Failure("face_origin_at");
            out_.Add(((int)operand, id));
        }
        return out_.AsReadOnly();
    }

    /// <summary>Edge `edge`'s id (an index into <see cref="Edges"/>), as <see cref="FaceId"/>.</summary>
    public ulong? EdgeId(int edge) => IdOf(BlacksmithNative.cadaclysm_blacksmith_edge_id(Handle, Index(edge)), "edge_id");

    /// <summary>The edge whose id is `id`, null where no edge has it.</summary>
    public int? EdgeWithId(ulong id) => FoundOf(BlacksmithNative.cadaclysm_blacksmith_edge_with_id(Handle, id), "edge_with_id");

    /// <summary>The input edge edge `edge` lies on, as <see cref="FaceOrigins"/>: one
    /// `(Operand, Id)`, or none for a new edge (edge merges are not seen).</summary>
    public IReadOnlyList<(int Operand, ulong Id)> EdgeOrigins(int edge)
    {
        var index = Index(edge);
        var n = BlacksmithNative.cadaclysm_blacksmith_edge_origin_count(Handle, index);
        if (n == Blacksmith.None) throw Blacksmith.Failure("edge_origin_count");
        var out_ = new List<(int, ulong)>((int)n);
        for (uint i = 0; i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_edge_origin_at(Handle, index, i, out var operand, out var id))
                throw Blacksmith.Failure("edge_origin_at");
            out_.Add(((int)operand, id));
        }
        return out_.AsReadOnly();
    }

    /// <summary>What the verb that made this solid did to the faces of `inputs` -- passed in its
    /// operand order (`a.Cut(b).History(a, b)`) -- read off this solid's ids and origins alone,
    /// as a <see cref="global::Cadaclysm.Blacksmith.History"/>. Throws where this solid or an
    /// input is untracked, or an origin names an operand past the inputs.</summary>
    public History History(params Solid[] inputs) => ReadHistory("history", inputs);

    /// <summary><see cref="History(Solid[])"/> for the edges, by edge id.</summary>
    public History EdgeHistory(params Solid[] inputs) => ReadHistory("edge_history", inputs);

    private History ReadHistory(string what, Solid[] inputs)
    {
        // Raw pointers again (see `WriteStepText`): the owners are kept reachable until the
        // call has returned. Never an empty array, so the library is never handed null.
        var handles = new IntPtr[Math.Max(inputs.Length, 1)];
        for (var i = 0; i < inputs.Length; i++) handles[i] = inputs[i].Handle.DangerousGetHandle();
        var h = what == "history"
            ? BlacksmithNative.cadaclysm_blacksmith_history(Handle, handles, (nuint)inputs.Length)
            : BlacksmithNative.cadaclysm_blacksmith_edge_history(Handle, handles, (nuint)inputs.Length);
        GC.KeepAlive(inputs);
        if (h == IntPtr.Zero) throw Blacksmith.Failure(what);
        try
        {
            return global::Cadaclysm.Blacksmith.History.Read(h);
        }
        finally
        {
            BlacksmithNative.cadaclysm_blacksmith_history_free(h);
        }
    }

    // -- attributes: text on a solid (written to STEP files) and on its faces (in memory)

    private IReadOnlyDictionary<string, string>? _attributes;

    /// <summary>`count` attributes listed by `keyAt`/`valueAt` (key order), copied out of the
    /// borrowed strings into a read-only map that enumerates in that order.</summary>
    private IReadOnlyDictionary<string, string> AttributeMap(uint count, Func<uint, IntPtr> keyAt, Func<uint, IntPtr> valueAt)
    {
        var map = new OrderedAttributes();
        for (uint i = 0; i < count; i++)
        {
            IntPtr k = keyAt(i), v = valueAt(i);
            if (k == IntPtr.Zero || v == IntPtr.Zero) throw Blacksmith.Failure("attributes");
            map.Set(Marshal.PtrToStringUTF8(k) ?? "", Marshal.PtrToStringUTF8(v) ?? "");
        }
        GC.KeepAlive(this);
        return map;
    }

    /// <summary>A borrowed attribute: null where there is none, unless the library left a
    /// reason, which is thrown.</summary>
    private string? AttributeText(IntPtr raw, string what)
    {
        var result = Borrowed(raw);
        if (result is null && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure(what);
        return result;
    }

    /// <summary>This solid's attributes, read-only, in key order (built once per solid). A
    /// solid's attributes go with it through every verb (a verb's result takes its first
    /// operand's) and are written to STEP files as user-defined attributes.</summary>
    public IReadOnlyDictionary<string, string> Attributes
    {
        get
        {
            if (_attributes is null)
            {
                var h = Handle;
                var n = BlacksmithNative.cadaclysm_blacksmith_attribute_count(h);
                if (n == 0 && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("attribute_count");
                _attributes = AttributeMap(n, i => BlacksmithNative.cadaclysm_blacksmith_attribute_key_at(h, i),
                    i => BlacksmithNative.cadaclysm_blacksmith_attribute_value_at(h, i));
            }
            return _attributes;
        }
    }

    /// <summary>Attribute `key`, null where this solid has none.</summary>
    public string? Attribute(string key) => AttributeText(BlacksmithNative.cadaclysm_blacksmith_attribute(Handle, key), "attribute");

    /// <summary>This solid with attribute `key` set to `value`, over any it had: a new solid,
    /// tracked if this one was not. Keys and values are text (no NUL); an empty key is
    /// refused.</summary>
    public Solid WithAttribute(string key, string value) => new(BlacksmithNative.cadaclysm_blacksmith_with_attribute(Handle, key, value));

    /// <summary>This solid with every attribute given set, in key order; each step's
    /// intermediate solid disposed.</summary>
    public Solid WithAttributes(IEnumerable<KeyValuePair<string, string>> attributes) =>
        Chained(attributes, (s, k, v) => s.WithAttribute(k, v));

    /// <summary>This solid without attribute `key`: a new solid, equal to this one where it had
    /// none.</summary>
    public Solid WithoutAttribute(string key) => new(BlacksmithNative.cadaclysm_blacksmith_without_attribute(Handle, key));

    /// <summary>Face `face`'s attributes, read-only, in key order. A face's attributes follow its
    /// id: kept through a verb, and copied to every face that names it as an origin (each piece
    /// of a split face has its parent's). They stay in memory: no file carries them. Throws for a
    /// face the solid does not have.</summary>
    public IReadOnlyDictionary<string, string> FaceAttributes(int face)
    {
        var index = Index(face);
        var h = Handle;
        var n = BlacksmithNative.cadaclysm_blacksmith_face_attribute_count(h, index);
        if (n == Blacksmith.None) throw Blacksmith.Failure("face_attribute_count");
        return AttributeMap(n, i => BlacksmithNative.cadaclysm_blacksmith_face_attribute_key_at(h, index, i),
            i => BlacksmithNative.cadaclysm_blacksmith_face_attribute_value_at(h, index, i));
    }

    /// <summary>Face `face`'s attribute `key`, null where it has none. Throws for a face the
    /// solid does not have.</summary>
    public string? FaceAttribute(int face, string key) =>
        AttributeText(BlacksmithNative.cadaclysm_blacksmith_face_attribute(Handle, Index(face), key), "face_attribute");

    /// <summary>This solid with face `face`'s attribute `key` set to `value`: a new solid,
    /// tracked if this one was not. Refused as <see cref="WithAttribute"/>, and for a face the
    /// solid does not have.</summary>
    public Solid WithFaceAttribute(int face, string key, string value) =>
        new(BlacksmithNative.cadaclysm_blacksmith_with_face_attribute(Handle, Index(face), key, value));

    /// <summary>This solid with every attribute given set on face `face`, in key order; each
    /// step's intermediate solid disposed.</summary>
    public Solid WithFaceAttributes(int face, IEnumerable<KeyValuePair<string, string>> attributes) =>
        Chained(attributes, (s, k, v) => s.WithFaceAttribute(face, k, v));

    /// <summary>This solid without face `face`'s attribute `key`: a new solid, equal to this one
    /// where the face had none.</summary>
    public Solid WithoutFaceAttribute(int face, string key) =>
        new(BlacksmithNative.cadaclysm_blacksmith_without_face_attribute(Handle, Index(face), key));

    /// <summary>`step` applied once per attribute, in key order, from this solid: always a new
    /// solid (an empty set gives this one unmoved), every intermediate disposed.</summary>
    private Solid Chained(IEnumerable<KeyValuePair<string, string>> attributes, Func<Solid, string, string, Solid> step)
    {
        Solid? out_ = null;
        foreach (var (key, value) in attributes.OrderBy(p => p.Key, StringComparer.Ordinal).ToList())
        {
            var next = step(out_ ?? this, key, value);
            out_?.Dispose();
            out_ = next;
        }
        return out_ ?? Translate(0, 0, 0);
    }

    // -- colour

    /// <summary>This solid coloured (`r`, `g`, `b`), each in 0..1 -- or with `face` just that
    /// face, whose colour then wins over the solid's. What is made from a coloured solid
    /// inherits: a move keeps every colour; a boolean, fillet, chamfer or shell gives each face
    /// the colour of the face it lies on (a cut's bore the tool's), and a new face the
    /// solid's.</summary>
    public Solid Coloured(double r, double g, double b, int? face = null) =>
        new(BlacksmithNative.cadaclysm_blacksmith_coloured(Handle, face is int f ? Index(f) : Blacksmith.None, r, g, b));

    /// <summary><see cref="Coloured(double, double, double, int?)"/> from `"#rgb"`, `"#rrggbb"` or a CSS colour name.</summary>
    public Solid Coloured(string colour, int? face = null) { var c = Blacksmith.Rgb(colour, "coloured"); return Coloured(c[0], c[1], c[2], face); }

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

    /// <summary><see cref="EdgesColoured(double, double, double, IEnumerable{int})"/> from `"#rgb"`, `"#rrggbb"` or a CSS colour name.</summary>
    public Solid EdgesColoured(string colour, IEnumerable<int>? edges = null)
    { var c = Blacksmith.Rgb(colour, "coloured"); return EdgesColoured(c[0], c[1], c[2], edges); }

    /// <summary><see cref="EdgesColoured(IEnumerable{Edge}, double, double, double)"/> from `"#rgb"`, `"#rrggbb"` or a CSS colour name.</summary>
    public Solid EdgesColoured(IEnumerable<Edge> edges, string colour)
    { var c = Blacksmith.Rgb(colour, "coloured"); return EdgesColoured(edges, c[0], c[1], c[2]); }

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
    public unsafe double[]?[] EdgePolylineColours(double? tolerance = 0.05)
    {
        var raw = BlacksmithNative.cadaclysm_blacksmith_edge_polyline_colours(Handle, Blacksmith.Tol(tolerance));
        if (raw.Rgb == IntPtr.Zero && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("edge_polyline_colours");
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

    /// <summary>This solid with `edges` rounded to `radius`. `radiusEnd` (spline edges only), given
    /// and different from `radius`, runs the radius linearly from `radius` to it in arc length
    /// along the edge, `radius` at the end where the edge's curve starts.</summary>
    public Solid Fillet(IEnumerable<Edge> edges, double radius, double? tolerance = 1e-6, double? radiusEnd = null) =>
        Fillet(edges.Select(e => e.Index), radius, Blacksmith.Tol(tolerance), radiusEnd);

    /// <summary><see cref="Fillet(IEnumerable{Edge}, double, double)"/> by edge index.</summary>
    public Solid Fillet(IEnumerable<int> edges, double radius, double? tolerance = 1e-6, double? radiusEnd = null)
    {
        var which = Indices(edges);
        if (radiusEnd is { } end && end != radius)
            return new Solid(BlacksmithNative.cadaclysm_blacksmith_fillet_varying(Handle, which, (nuint)which.Length, radius, end, Blacksmith.Tol(tolerance)));
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_fillet(Handle, which, (nuint)which.Length, radius, Blacksmith.Tol(tolerance),
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary>A chain of spline edges rounded with the radius following a law along it: `law`
    /// is the radius at stations along the chain, each `(Share, Radius)` -- the share of the
    /// chain's arc length from its start, 0 to 1 -- run through smoothly by a monotone cubic, so
    /// the radius never swings past its stations, and held flat before the first station and
    /// after the last. `edges` must run end to end into one open chain, each running on tangent
    /// into the next; the chain runs the way the first edge's curve does. One edge is a chain of
    /// one. `tolerance` is the fillet surfaces' fit.</summary>
    public Solid FilletLaw(IEnumerable<Edge> edges, IEnumerable<(double Share, double Radius)> law, double? tolerance = 1e-6) =>
        FilletLaw(edges.Select(e => e.Index), law, tolerance);

    /// <summary><see cref="FilletLaw(IEnumerable{Edge}, IEnumerable{ValueTuple{double, double}}, double?)"/> by edge index.</summary>
    public Solid FilletLaw(IEnumerable<int> edges, IEnumerable<(double Share, double Radius)> law, double? tolerance = 1e-6)
    {
        var which = Indices(edges);
        var stations = law.ToArray();
        var shares = stations.Select(s => s.Share).ToArray();
        var radii = stations.Select(s => s.Radius).ToArray();
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_fillet_law(Handle, which, (nuint)which.Length, shares, radii, (nuint)stations.Length, Blacksmith.Tol(tolerance)));
    }

    /// <summary><see cref="Fillet(IEnumerable{Edge}, double, double)"/> with a flat bevel:
    /// each edge cut back `distance` along both its faces.</summary>
    public Solid Chamfer(IEnumerable<Edge> edges, double distance, double? tolerance = 1e-6) =>
        Chamfer(edges.Select(e => e.Index), distance, Blacksmith.Tol(tolerance));

    public Solid Chamfer(IEnumerable<int> edges, double distance, double? tolerance = 1e-6)
    {
        var which = Indices(edges);
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_chamfer(Handle, which, (nuint)which.Length, distance, Blacksmith.Tol(tolerance)));
    }

    // -- sheets from curves: one face on one NURBS surface

    /// <summary>The largest distance from this sheet to the curves it was fitted to, set on the
    /// sheets of <see cref="SweepRail"/>, <see cref="SweepTwoRails"/>, <see cref="EdgeSurface"/>,
    /// <see cref="NetworkSurface"/>, <see cref="FilletSurfaces"/>, <see cref="Faired(double?, int, ValueTuple{int, int}?, int?, string?, int)"/>, <see cref="Flange(IEnumerable{Edge}, NurbsCurve, double?, bool)"/>
    /// and <see cref="ExtrudeTo(IEnumerable{Edge}, ValueTuple{double, double, double}?, Solid, double?, bool)"/>; null on any other solid.</summary>
    public double? SheetError { get; private init; }

    /// <summary>How well the patch <see cref="NSidedPatch"/> made meets its neighbours; null on any
    /// other solid.</summary>
    public PatchReport? PatchReport { get; private init; }

    private static readonly string[] SheetSides = { "u0", "u1", "v0", "v1" };

    private static uint SheetSide(string side)
    {
        var code = Array.IndexOf(SheetSides, side);
        return code >= 0 ? (uint)code : throw new ArgumentException($"a side is 'u0', 'u1', 'v0' or 'v1', not '{side}'");
    }

    private static NurbsCurve[] CurveList(IEnumerable<NurbsCurve> curves)
    {
        ArgumentNullException.ThrowIfNull(curves);
        return curves.Select(c => c ?? throw new ArgumentNullException(nameof(curves), "a curve is null")).ToArray();
    }

    private static IntPtr[] CurveHandles(NurbsCurve[] curves) => curves.Select(c => c.Handle.DangerousGetHandle()).ToArray();

    private static double[]? Vec3((double X, double Y, double Z)? v) => v is { } p ? new[] { p.X, p.Y, p.Z } : null;

    /// <summary>The sheet lofted through <paramref name="sections"/>, <paramref name="degree"/>
    /// across them (lowered to fit); <paramref name="loose"/> shapes it by them instead, through
    /// the first and last only; <paramref name="closed"/> makes it periodic across them, the last
    /// section back to the first.</summary>
    public static Solid LoftCurves(IEnumerable<NurbsCurve> sections, int degree = 3, bool loose = false, bool closed = false)
    {
        var owners = CurveList(sections);
        var raw = CurveHandles(owners);
        var h = BlacksmithNative.cadaclysm_blacksmith_loft_curves(raw, (nuint)raw.Length, Index(degree), loose, closed);
        GC.KeepAlive(owners);
        return new Solid(Blacksmith.Checked(h, "loft_curves"));
    }

    /// <summary><paramref name="sections"/> swept along <paramref name="rail"/>, each carried by the
    /// rail's frame from the rail point nearest its centre and blended between:
    /// <paramref name="frame"/> "rmf" rotation-minimising, "fixed" keeping <paramref name="up"/>
    /// upright. Fitted within <paramref name="tolerance"/>; <see cref="SheetError"/> says how close.</summary>
    public static Solid SweepRail(NurbsCurve rail, IEnumerable<NurbsCurve> sections, string frame = "rmf",
                                  (double X, double Y, double Z)? up = null, double? tolerance = 1e-3)
    {
        var kind = frame switch
        {
            "rmf" => 0u,
            "fixed" => 1u,
            _ => throw new ArgumentException($"sweep_rail: frame is 'rmf' or 'fixed', not '{frame}'"),
        };
        var owners = CurveList(sections);
        var raw = CurveHandles(owners);
        var h = BlacksmithNative.cadaclysm_blacksmith_sweep_rail(rail.Handle, raw, (nuint)raw.Length, kind, Vec3(up), Blacksmith.Tol(tolerance), out var error);
        GC.KeepAlive(owners);
        GC.KeepAlive(rail);
        return new Solid(Blacksmith.Checked(h, "sweep_rail")) { SheetError = error };
    }

    /// <summary><paramref name="sections"/> swept between two rails: each section's first end on
    /// <paramref name="railA"/> and last on <paramref name="railB"/>, carried by the rotation and
    /// uniform scale that keep them there, the rails matched by arc length. Fitted within
    /// <paramref name="tolerance"/> (<see cref="SheetError"/>).</summary>
    public static Solid SweepTwoRails(NurbsCurve railA, NurbsCurve railB, IEnumerable<NurbsCurve> sections, double? tolerance = 1e-3)
    {
        var owners = CurveList(sections);
        var raw = CurveHandles(owners);
        var h = BlacksmithNative.cadaclysm_blacksmith_sweep_two_rails(railA.Handle, railB.Handle, raw, (nuint)raw.Length, Blacksmith.Tol(tolerance), out var error);
        GC.KeepAlive(owners);
        GC.KeepAlive(railA);
        GC.KeepAlive(railB);
        return new Solid(Blacksmith.Checked(h, "sweep_two_rails")) { SheetError = error };
    }

    /// <summary>The Coons sheet of 2, 3 or 4 boundary curves meeting end to end within
    /// <paramref name="tolerance"/> (in order round the boundary, each either way round): exact for
    /// non-rational boundaries, rational ones fitted first (<see cref="SheetError"/>).</summary>
    public static Solid EdgeSurface(IEnumerable<NurbsCurve> curves, double? tolerance = 1e-3)
    {
        var owners = CurveList(curves);
        var raw = CurveHandles(owners);
        var h = BlacksmithNative.cadaclysm_blacksmith_edge_surface(raw, (nuint)raw.Length, Blacksmith.Tol(tolerance), out var error);
        GC.KeepAlive(owners);
        return new Solid(Blacksmith.Checked(h, "edge_surface")) { SheetError = error };
    }

    /// <summary>The Gordon sheet of a curve network: <paramref name="uCurves"/> (in order across the
    /// other way) and <paramref name="vCurves"/>, every one of the first crossing every one of the
    /// second within <paramref name="tolerance"/>. <see cref="SheetError"/> is the largest distance
    /// from the sheet to the curves given.</summary>
    public static Solid NetworkSurface(IEnumerable<NurbsCurve> uCurves, IEnumerable<NurbsCurve> vCurves, double? tolerance = 1e-3)
    {
        var uOwners = CurveList(uCurves);
        var vOwners = CurveList(vCurves);
        var u = CurveHandles(uOwners);
        var v = CurveHandles(vOwners);
        var h = BlacksmithNative.cadaclysm_blacksmith_network_surface(u, (nuint)u.Length, v, (nuint)v.Length, Blacksmith.Tol(tolerance), out var error);
        GC.KeepAlive(uOwners);
        GC.KeepAlive(vOwners);
        return new Solid(Blacksmith.Checked(h, "network_surface")) { SheetError = error };
    }

    /// <summary>How well face <paramref name="face"/>'s side <paramref name="side"/> ("u0", "u1",
    /// "v0" or "v1": a boundary isocurve of its NURBS surface) meets <paramref name="other"/>'s face
    /// <paramref name="otherFace"/> along <paramref name="otherSide"/>.</summary>
    public Continuity Continuity(string side, Solid other, string otherSide, int face = 0, int otherFace = 0, int samples = 64)
    {
        var sa = SheetSide(side);
        var sb = SheetSide(otherSide);
        if (!BlacksmithNative.cadaclysm_blacksmith_continuity(Handle, Index(face), sa, other.Handle, Index(otherFace), sb, Index(samples), out var raw))
            throw Blacksmith.Failure("continuity");
        return global::Cadaclysm.Blacksmith.Continuity.Of(raw);
    }

    /// <summary>How well the two faces of edge <paramref name="edge"/> meet along it:
    /// <paramref name="samples"/> points along the edge, each projected onto both faces, and the
    /// largest gap between the two, angle between the faces' normals (each the way its face
    /// faces: a square crease reads pi/2) and difference of their normal curvatures across the
    /// edge -- <see cref="Continuity"/>'s figures for any two faces of one body, of any kind of
    /// surface. A G1 seam reads an angle near 0, a G2 one a curvature near 0 too.</summary>
    public Continuity EdgeContinuity(int edge, int samples = 64)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_edge_continuity(Handle, Index(edge), Index(samples), out var raw))
            throw Blacksmith.Failure("edge_continuity");
        return global::Cadaclysm.Blacksmith.Continuity.Of(raw);
    }

    /// <summary><see cref="EdgeContinuity(int, int)"/> for an <see cref="Edge"/> of this solid.</summary>
    public Continuity EdgeContinuity(Edge edge, int samples = 64) => EdgeContinuity(edge.Index, samples);

    /// <summary>Face <paramref name="face"/> faired, as a sheet of its own: the smoothest surface
    /// within <paramref name="tolerance"/> of its NURBS surface -- least squares plus its third
    /// derivatives squared (what a zebra's ripple costs), weighed as heavily as the tolerance
    /// allows. A sheet lofted through traced sections wobbles between them; this spends the
    /// tolerance on smoothness. <paramref name="controls"/> null fairs on the face's own net, its
    /// degree raised to <paramref name="degree"/> (3 to 7) and its spans split to a dozen each way
    /// at least, so a kept side is kept exactly; <c>(U, V)</c> fairs on a uniform net that size,
    /// its kept sides within the tolerance. <paramref name="keep"/> is what every side keeps: null
    /// free to move, 0 its position, 1 the tangent plane across it, 2 the curvature too (what
    /// <see cref="Matched"/> gave it with a neighbour); the overload taking a tuple keeps per side.
    /// <paramref name="noInflection"/> <c>"u"</c>, <c>"v"</c> or <c>"uv"</c> holds the isocurves
    /// along those directions from turning their curvature over, which turns a roof lofted through
    /// wobbly sections into a dome. Throws <see cref="BuildException"/> where no such fair is
    /// within the tolerance. Its <see cref="SheetError"/> is the largest distance found between
    /// the two surfaces.</summary>
    public Solid Faired(double? tolerance = 1e-3, int degree = 3, (int U, int V)? controls = null, int? keep = 2,
                        string? noInflection = null, int face = 0) =>
        Faired((keep, keep, keep, keep), tolerance, degree, controls, noInflection, face);

    /// <summary><see cref="Faired(double?, int, ValueTuple{int, int}?, int?, string?, int)"/> keeping
    /// each side its own level, in side order (<c>u0</c>, <c>u1</c>, <c>v0</c>, <c>v1</c>); null
    /// leaves that side free.</summary>
    public Solid Faired((int? U0, int? U1, int? V0, int? V1) keep, double? tolerance = 1e-3, int degree = 3, (int U, int V)? controls = null,
                        string? noInflection = null, int face = 0)
    {
        uint held = noInflection switch
        {
            null or "" => 0, "u" => 1, "v" => 2, "uv" or "vu" => 3,
            _ => throw new ArgumentException($"noInflection is 'u', 'v', 'uv' or null, not '{noInflection}'"),
        };
        var levels = new[] { keep.U0 ?? -1, keep.U1 ?? -1, keep.V0 ?? -1, keep.V1 ?? -1 };
        var (cu, cv) = controls ?? (0, 0);
        var h = BlacksmithNative.cadaclysm_blacksmith_surface_faired(Handle, Index(face), Blacksmith.Tol(tolerance), Index(degree),
            Index(cu), Index(cv), levels, held, out var error);
        return new Solid(Blacksmith.Checked(h, "surface_faired")) { SheetError = error };
    }

    /// <summary>Where face <paramref name="face"/>'s Gaussian and mean curvature change sign, on a
    /// grid of <paramref name="samples"/> steps each way over its surface (8 at fewest): how many
    /// separate areas of each sign, and the points between opposite signs. A dome or a saddle
    /// reads one area of one sign and no turn; a sheet whose sections wobble reads several -- the
    /// surface's form of <see cref="NurbsCurve.Inflections"/>.</summary>
    public CurvatureTurns CurvatureTurns(int face = 0, int samples = 32)
    {
        uint f = Index(face), n = Index(samples);
        if (!BlacksmithNative.cadaclysm_blacksmith_curvature_turns(Handle, f, n, out var raw)) throw Blacksmith.Failure("curvature_turns");
        List<At> Points(bool mean, uint count) => count == 0 ? new List<At>()
            : Blacksmith.Samples(BlacksmithNative.cadaclysm_blacksmith_curvature_turn_points(Handle, f, n, mean), "curvature_turn_points");
        return global::Cadaclysm.Blacksmith.CurvatureTurns.Of(raw, Points(false, raw.GaussianTurns), Points(true, raw.MeanTurns));
    }

    /// <summary>The worst kink of the highlight lines crossing edge <paramref name="edge"/>, at
    /// <paramref name="samples"/> points along it (16 at fewest): the lines of straight light tubes
    /// parallel to the surface a body's size away, every tube direction tried. They run on through
    /// an edge where the two faces' curvatures agree (G2) and kink where it jumps -- a fillet's seam
    /// with a flat face among them. Beside <see cref="EdgeContinuity(int, int)"/>'s curvature jump,
    /// this is the number a zebra shows. Throws for an edge that does not bound two faces.</summary>
    public HighlightKink HighlightKink(int edge, int samples = 64)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_highlight_kink(Handle, Index(edge), Index(samples), out var raw))
            throw Blacksmith.Failure("highlight_kink");
        return global::Cadaclysm.Blacksmith.HighlightKink.Of(raw);
    }

    /// <summary><see cref="HighlightKink(int, int)"/> for an <see cref="Edge"/> of this solid.</summary>
    public HighlightKink HighlightKink(Edge edge, int samples = 64) => HighlightKink(edge.Index, samples);

    /// <summary>Face <paramref name="face"/> as a sheet of its own, its side <paramref name="side"/>
    /// bent to meet <paramref name="other"/>'s <paramref name="otherSide"/> at G<paramref name="level"/>:
    /// 0 position, 1 tangent plane, 2 curvature. The opposite side stays where it was.</summary>
    public Solid Matched(string side, Solid other, string otherSide, int level = 2, int face = 0, int otherFace = 0)
    {
        var sa = SheetSide(side);
        var sb = SheetSide(otherSide);
        var h = BlacksmithNative.cadaclysm_blacksmith_match_side(Handle, Index(face), sa, other.Handle, Index(otherFace), sb, Index(level));
        return new Solid(Blacksmith.Checked(h, "match_side"));
    }

    /// <summary>A sheet spanning from <paramref name="a"/>'s side to <paramref name="b"/>'s, meeting
    /// each at G<paramref name="level"/> (1 or 2); <paramref name="bulge"/> scales how far it leaves
    /// each edge along its neighbour's tangent.</summary>
    public static Solid BlendSides(Solid a, string sideA, Solid b, string sideB, int level = 2, double bulge = 1.0, int faceA = 0, int faceB = 0)
    {
        var sa = SheetSide(sideA);
        var sb = SheetSide(sideB);
        var h = BlacksmithNative.cadaclysm_blacksmith_blend_sides(a.Handle, Index(faceA), sa, b.Handle, Index(faceB), sb, Index(level), bulge);
        return new Solid(Blacksmith.Checked(h, "blend_sides"));
    }

    /// <summary>The sheet filling a hole of 3 or more sides: N four-sided NURBS faces round a central
    /// point, G1 or G2 to each other. Each boundary, in order round the hole and either way round, is
    /// a <see cref="PatchBoundary"/> (a sheet's side, or a <see cref="NurbsCurve"/> met at G0); the
    /// boundaries must meet end to end within <paramref name="tolerance"/>; <paramref name="bulge"/>
    /// scales how far the patch leaves each neighbour along its tangent. Face i meets boundary i's
    /// second half along its "v0" side and boundary i + 1's first half along its "u1", so
    /// <see cref="Continuity"/> measures each neighbour; <see cref="PatchReport"/> holds the worst
    /// of them.</summary>
    public static Solid NSidedPatch(IEnumerable<PatchBoundary> boundaries, double bulge = 1.0, double? tolerance = 0.01)
    {
        ArgumentNullException.ThrowIfNull(boundaries);
        var list = boundaries.Select(b => b ?? throw new ArgumentNullException(nameof(boundaries), "a boundary is null")).ToArray();
        var rows = new RawBlacksmithPatchBoundary[Math.Max(list.Length, 1)];
        for (var i = 0; i < list.Length; i++)
        {
            var b = list[i];
            rows[i] = b.Curve is not null
                ? new RawBlacksmithPatchBoundary { Sheet = IntPtr.Zero, Face = 0, Side = 0, From = 0.0, To = 1.0, Level = 0, Curve = b.Curve.Handle.DangerousGetHandle() }
                : new RawBlacksmithPatchBoundary
                {
                    Sheet = b.Sheet!.Handle.DangerousGetHandle(), Face = Index(b.Face), Side = SheetSide(b.Side),
                    From = b.From, To = b.To, Level = Index(b.Level), Curve = IntPtr.Zero,
                };
        }
        var h = BlacksmithNative.cadaclysm_blacksmith_n_sided_patch(rows, (nuint)list.Length, bulge, Blacksmith.Tol(tolerance), out var report);
        GC.KeepAlive(list);
        return new Solid(Blacksmith.Checked(h, "n_sided_patch")) { PatchReport = global::Cadaclysm.Blacksmith.PatchReport.Of(report) };
    }

    /// <summary>The rolling-ball fillet between <paramref name="a"/>'s face <paramref name="faceA"/>
    /// and <paramref name="b"/>'s face <paramref name="faceB"/> (their whole NURBS surfaces): the
    /// ball on the side each face's normal points to (<paramref name="flipA"/>,
    /// <paramref name="flipB"/>: the other side), of <paramref name="radius"/>, or running linearly
    /// from <paramref name="radius"/> to <paramref name="radiusEnd"/> along the fillet. Returns the
    /// fillet sheet (its <see cref="SheetError"/> set) and the contact curves on
    /// <paramref name="a"/> and <paramref name="b"/>, to trim them back with
    /// <see cref="TrimByCurve"/> and join with <see cref="JoinSheets"/>; the curves are the
    /// caller's to dispose and outlive the sheets.</summary>
    public static (Solid Sheet, NurbsCurve RailA, NurbsCurve RailB) FilletSurfaces(Solid a, Solid b, double radius, double? radiusEnd = null,
        bool flipA = false, bool flipB = false, double? tolerance = 1e-3, int faceA = 0, int faceB = 0)
    {
        var h = BlacksmithNative.cadaclysm_blacksmith_fillet_surfaces(a.Handle, Index(faceA), b.Handle, Index(faceB), radius, radiusEnd ?? radius,
            flipA, flipB, Blacksmith.Tol(tolerance), out var ra, out var rb, out var error);
        var railA = new NurbsCurveHandle(ra);
        var railB = new NurbsCurveHandle(rb);
        var sheet = new Solid(Blacksmith.Checked(h, "fillet_surfaces")) { SheetError = error };
        return (sheet, NurbsCurve.Of(railA, "fillet_surfaces"), NurbsCurve.Of(railB, "fillet_surfaces"));
    }

    /// <summary>This sheet cut along <paramref name="curve"/> -- one lying on it, say projected or
    /// pulled onto it -- and nothing removed: every face comes back in its pieces outside the
    /// cutter, then its pieces inside, each a face. The cutter is <paramref name="curve"/> run
    /// along <paramref name="direction"/> (null: the mean of the sheet's normals along the curve)
    /// through the whole sheet. A closed curve's inside is the island it bounds; an open curve's is
    /// the side left of its run, seen from where <paramref name="direction"/> points.</summary>
    public Solid SplitByCurve(NurbsCurve curve, (double X, double Y, double Z)? direction = null, double? tolerance = 0.05)
    {
        var h = BlacksmithNative.cadaclysm_blacksmith_split_by_curve(Handle, curve.Handle, Vec3(direction), Blacksmith.Tol(tolerance));
        GC.KeepAlive(curve);
        return new Solid(Blacksmith.Checked(h, "split_by_curve"));
    }

    /// <summary>This sheet cut along <paramref name="curve"/> and one side thrown away (see
    /// <see cref="SplitByCurve"/>): <paramref name="keep"/> "inside" keeps the island a closed curve
    /// bounds, "outside" the sheet with the hole; for an open curve "left" (the same as "inside")
    /// keeps the side left of its run seen from where <paramref name="direction"/> points, "right"
    /// the other. Throws where nothing of the sheet lies on the kept side.</summary>
    public Solid TrimByCurve(NurbsCurve curve, string keep = "outside", (double X, double Y, double Z)? direction = null, double? tolerance = 0.05)
    {
        if (keep is not ("outside" or "inside" or "left" or "right"))
            throw new BuildException($"trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not '{keep}'");
        var h = BlacksmithNative.cadaclysm_blacksmith_trim_by_curve(Handle, curve.Handle, Vec3(direction), keep is "inside" or "left", Blacksmith.Tol(tolerance));
        GC.KeepAlive(curve);
        return new Solid(Blacksmith.Checked(h, "trim_by_curve"));
    }

    /// <summary><paramref name="section"/> swept along each of <paramref name="edges"/> (naked edges
    /// of this sheet) on the face's own frame: at every point of the edge the section's x runs
    /// outward from the face -- square to the edge, in the face's tangent plane -- and its y along
    /// the face's normal, so a section from (0, 0) to (0, -10) turns the edge under by 10 all along
    /// it however the panel curves, (0, 0) to (10, 0) carries the face on, and a lip stands proud
    /// with y &gt; 0. <paramref name="section"/> is a curve in the plane z = 0 starting at the
    /// origin. With <paramref name="join"/> the sweeps come back sewn to this sheet (its faces
    /// first, then one per edge), else alone, sewn to each other. Each sweep is fitted within
    /// <paramref name="tolerance"/>; <see cref="SheetError"/> says how close. Throws for an edge
    /// bordered by two faces, a section not starting at the origin, and sweeps that did not sew on.</summary>
    public Solid Flange(IEnumerable<Edge> edges, NurbsCurve section, double? tolerance = 1e-3, bool join = true) =>
        Flange(edges.Select(e => e.Index), section, tolerance, join);

    /// <summary><see cref="Flange(IEnumerable{Edge}, NurbsCurve, double?, bool)"/> by edge index.</summary>
    public Solid Flange(IEnumerable<int> edges, NurbsCurve section, double? tolerance = 1e-3, bool join = true)
    {
        var which = Indices(edges);
        var h = BlacksmithNative.cadaclysm_blacksmith_flange(Handle, which, (nuint)which.Length, section.Handle, Blacksmith.Tol(tolerance), join, out var error);
        GC.KeepAlive(section);
        return new Solid(Blacksmith.Checked(h, "flange")) { SheetError = error };
    }

    /// <summary>Each of <paramref name="edges"/> (naked edges of this sheet) slid along
    /// <paramref name="direction"/> until it meets <paramref name="target"/>: every point of the
    /// edge travels along the direction to its first hit on <paramref name="target"/>'s faces
    /// (trimmed, not their whole surfaces). One wall per edge -- the edge's own curve swept
    /// straight, bounded by the curve through the hits, fitted within <paramref name="tolerance"/>
    /// of every hit (<see cref="SheetError"/>) -- so a wheel arch cut in a panel runs in to the
    /// well's inner wall as its liner. With <paramref name="join"/> the walls come back sewn to
    /// this sheet (its faces first, then one per edge), else alone, sewn to each other. Throws
    /// naming the point whose line misses the target.</summary>
    public Solid ExtrudeTo(IEnumerable<Edge> edges, (double X, double Y, double Z)? direction, Solid target, double? tolerance = 1e-3, bool join = true) =>
        ExtrudeTo(edges.Select(e => e.Index), direction, target, tolerance, join);

    /// <summary><see cref="ExtrudeTo(IEnumerable{Edge}, ValueTuple{double, double, double}?, Solid, double?, bool)"/> by edge index.</summary>
    public Solid ExtrudeTo(IEnumerable<int> edges, (double X, double Y, double Z)? direction, Solid target, double? tolerance = 1e-3, bool join = true)
    {
        var which = Indices(edges);
        var h = BlacksmithNative.cadaclysm_blacksmith_extrude_to(Handle, which, (nuint)which.Length, Vec3(direction), target.Handle, Blacksmith.Tol(tolerance), join, out var error);
        GC.KeepAlive(target);
        return new Solid(Blacksmith.Checked(h, "extrude_to")) { SheetError = error };
    }

    /// <summary><paramref name="sheets"/> joined into one body, their faces in order, and a
    /// <see cref="JoinReport"/> of what was done: every two naked edges whose ends and curves agree
    /// within <paramref name="tolerance"/> (0: a rounding of the body's size) sewn into one, the
    /// faces turned to agree, and a closed result turned to face out, a solid the booleans,
    /// <see cref="Mass"/> and the writers take. At a tolerance above 0 a T-junction is sewn too.</summary>
    public static (Solid Solid, JoinReport Report) JoinSheets(IEnumerable<Solid> sheets, double? tolerance = 0.0)
    {
        ArgumentNullException.ThrowIfNull(sheets);
        var owners = sheets.Select(s => s ?? throw new ArgumentNullException(nameof(sheets), "a sheet is null")).ToArray();
        var raw = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var h = BlacksmithNative.cadaclysm_blacksmith_join_sheets(raw, (nuint)raw.Length, Blacksmith.Tol(tolerance), out var report);
        GC.KeepAlive(owners);
        return (new Solid(Blacksmith.Checked(h, "join_sheets")), JoinReport.Of(report));
    }

    /// <summary>This sheet cut along curve, a curve lying on it (within ten times tolerance), with no
    /// direction: the cut is made in each face's own parameters, so it follows the curve however
    /// far the sheet rolls, and runs across the seams of a joined sheet. An open curve is carried
    /// on along the sheet past both ends to its boundary; a closed one cuts out the island it
    /// bounds. Nothing is removed. Where the cut lies on the curve the rim is one edge carrying the
    /// curve's own span exactly. Refused where the curve leaves the sheet.</summary>
    public Solid SplitAlongCurve(NurbsCurve curve, double? tolerance = 0.01)
    {
        ArgumentNullException.ThrowIfNull(curve);
        var h = BlacksmithNative.cadaclysm_blacksmith_split_along_curve(Handle, curve.Handle, Blacksmith.Tol(tolerance));
        GC.KeepAlive(curve);
        return new Solid(Blacksmith.Checked(h, "split_along_curve"));
    }

    /// <summary>This sheet parted along curve (lying on it, as for split_along_curve) into two panels with a
    /// shut line between them: each trimmed back gap / 2 from the curve along the sheet, with a
    /// flange flange along the faces' outward normals on its cut edge only (negative turns it
    /// under; 0 for none), ending square where the curve runs off the sheet. The panel left of the
    /// curve's run (seen from the outward side) first, then the right one; a loop run
    /// counter-clockwise from that side has the island on its left. Refused where the curve leaves
    /// the sheet or the gap leaves nothing of a panel.</summary>
    public (Solid Left, Solid Right) PanelGap(NurbsCurve curve, double gap = 4.0, double flange = -10.0, double? tolerance = 0.01)
    {
        ArgumentNullException.ThrowIfNull(curve);
        var raw = new IntPtr[2];
        var ok = BlacksmithNative.cadaclysm_blacksmith_panel_gap(Handle, curve.Handle, gap, flange, Blacksmith.Tol(tolerance), raw);
        GC.KeepAlive(curve);
        if (!ok) throw Blacksmith.Failure("panel_gap");
        return (new Solid(new SolidHandle(raw[0])), new Solid(new SolidHandle(raw[1])));
    }

    /// <summary>This sheet with an opening recessed into it along <paramref name="outline"/> -- a
    /// window, a lamp, a grille or an air intake set into a panel -- and how many of the result's
    /// faces are each part's: (Sheet, Fillet, Walls, Pane), the faces in that order.
    /// <paramref name="outline"/> is a closed curve on the sheet (one face or several joined); each
    /// of its points is found on the sheet, so it may stand a little off it. The walls run back
    /// <paramref name="depth"/> along the sheet's own normal at every point of the rim -- not along
    /// one view -- behind the face (against its normal; negative: in front), leaning in toward the
    /// opening by <paramref name="draft"/> radians (negative: out) and meeting on the mitre at the
    /// outline's corners. <paramref name="fillet"/> above 0 rounds the rim between the sheet and the
    /// walls (the outline must then be smooth). <paramref name="pane"/> closes the back with one
    /// patch whose four sides end where the outline turns most, so it does not twist. Every piece is
    /// sewn to the next: only the sheet's own boundary is left naked, and the walls' foot without a
    /// pane. Throws <see cref="BuildException"/> for an outline that is not closed, a corner with a
    /// fillet, or a fillet deeper than the walls.</summary>
    public (Solid Solid, (int Sheet, int Fillet, int Walls, int Pane) Faces) Recess(NurbsCurve outline, double depth, double draft = 0.0,
        double fillet = 0.0, bool pane = true, double? tolerance = 0.05)
    {
        ArgumentNullException.ThrowIfNull(outline);
        var faces = new uint[4];
        var h = BlacksmithNative.cadaclysm_blacksmith_recess(Handle, outline.Handle, depth, draft, fillet, pane, Blacksmith.Tol(tolerance), faces);
        GC.KeepAlive(outline);
        return (new Solid(Blacksmith.Checked(h, "recess")), ((int)faces[0], (int)faces[1], (int)faces[2], (int)faces[3]));
    }

    /// <summary>This half and its reflection across <paramref name="plane"/> (a frame, its z the
    /// plane's normal) joined into one symmetric body -- half a car, a hull or a bottle modelled
    /// once -- the half's faces first, and a <see cref="SymmetryReport"/> of how well the seam on
    /// the plane meets. With <paramref name="snap"/> above 0, every NURBS face that is its whole
    /// surface and has a side whose control points all lie within <paramref name="snap"/> of the
    /// plane is squared to it first: that side pulled onto the plane, the next row of control
    /// points stood straight off it along the normal (keeping its distance from the plane). The
    /// surface then crosses the plane at 90 degrees, so it meets its mirror tangent and curvature
    /// continuous; nothing past that row moves. <paramref name="snap"/> 0 mirrors the half as it
    /// is, a crease wherever it leans. The halves are sewn within <paramref name="tolerance"/>
    /// (0: a rounding of the body's size). Throws <see cref="BuildException"/> for a half on both
    /// sides of the plane, no edge of it on the plane, or a face that cannot be squared (its next
    /// row on the plane or past it).</summary>
    public (Solid Solid, SymmetryReport Report) MirrorJoin(double[] plane, double snap = 0.0, double? tolerance = 0.0)
    {
        var report = new double[7];
        var h = BlacksmithNative.cadaclysm_blacksmith_mirror_join(Handle, Blacksmith.Frame(plane), snap, Blacksmith.Tol(tolerance), report);
        return (new Solid(Blacksmith.Checked(h, "mirror_join")), SymmetryReport.Of(report));
    }

    /// <summary>Face `face` pushed out by `distance` along its outward normal (pulled in,
    /// negative) as a face extrude does it: the prism over it joined on (cut
    /// out), and the flush faces merged -- a box's top raised is one taller box of six faces.
    /// A face on a cylinder, a cone, a sphere or a torus moves out along its normal instead,
    /// the surface a step out (a boss fatter, a bore or a countersink narrower, a dome fuller),
    /// the flat faces beside it carried along; any other curved face is refused.</summary>
    public Solid PushPull(int face, double distance, double? tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_push_pull(Handle, Index(face), distance, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero));

    /// <summary>Faces `faces` pushed out by `distance` together -- a press-pull on a
    /// selection: each by <see cref="PushPull(int, double, double)"/>'s rule for it, one after
    /// another, each found again after the pushes before it renumbered the faces. A box's top
    /// and a side pushed 5 is the box 5 taller and 5 wider; a face on the same curved surface
    /// as one before it, and joined to it, moved with that one and is not pushed twice.</summary>
    public Solid PushPull(IEnumerable<int> faces, double distance, double? tolerance = 0.05)
    {
        var which = Indices(faces);
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_push_pull_faces(Handle, which, (nuint)which.Length, distance, Blacksmith.Tol(tolerance),
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary>This solid split by `tool` into bodies: a closed
    /// `tool` gives the parts outside it, then the parts inside; a flat sheet splits by the
    /// whole plane it lies on. Each connected part is a body of its own.</summary>
    public IReadOnlyList<Solid> Split(Solid tool, double? tolerance = 0.05)
    {
        using var all = new Solid(BlacksmithNative.cadaclysm_blacksmith_split(Handle, tool.Handle, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero));
        return all.Lumps();
    }

    /// <summary>This solid split by the plane through `plane`'s origin, square to its z (a
    /// frame, twelve numbers): the bodies in front of it first, then those behind.</summary>
    public IReadOnlyList<Solid> SplitByPlane(double[] plane, double? tolerance = 0.05)
    {
        using var all = new Solid(BlacksmithNative.cadaclysm_blacksmith_split_by_plane(Handle, Blacksmith.Frame(plane), Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero));
        return all.Lumps();
    }

    /// <summary>This solid split by the closed `profile` drawn on `frame` (twelve numbers),
    /// pushed straight through it along the frame's z both ways: the bodies outside the
    /// profile first, then those inside. Where the plane lies along z does not matter.</summary>
    public IReadOnlyList<Solid> SplitByProfile(Profile profile, double[] frame, double? tolerance = 0.05)
    {
        using var all = new Solid(BlacksmithNative.cadaclysm_blacksmith_split_by_profile(Handle, profile.Handle, Blacksmith.Frame(frame), Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero));
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

    /// <summary>This solid and <paramref name="other"/> as one body that keeps every piece -- a
    /// union that keeps the inside pieces: its regions are this solid less `other`, the two
    /// together, and `other` less this one (those that are not empty), and the walls between them
    /// are faces of both. The body is non-manifold where a wall meets the outside, so the verbs
    /// that need a manifold solid -- the booleans, fillet, chamfer, shell, thicken, the mass --
    /// refuse it; take its cells with <see cref="Regions"/> and <see cref="RegionSolid"/>. Built
    /// exactly: both solids closed, every face a plane, cylinder, cone, sphere or torus. Walls of
    /// the two lying on one another in part are a case it refuses, in words.</summary>
    public Solid Merge(Solid other, double? tolerance = 0.05) =>
        new(BlacksmithNative.cadaclysm_blacksmith_merge(Handle, other.Handle, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero));

    /// <summary>The regions of space this solid's faces bound, region 0 the infinite one: two for
    /// an ordinary solid (outside, inside), one per cell for a <see cref="Merge"/>'s body, one more
    /// per cavity. Each lists its sides -- a face and its sense, +1 where the region is the side
    /// the face's normal points to, -1 the other -- and its shells, 1 plus one per void inside
    /// it.</summary>
    public List<Region> Regions()
    {
        var list = BlacksmithNative.cadaclysm_blacksmith_regions(Handle);
        if (list == IntPtr.Zero) throw Blacksmith.Failure("regions");
        try
        {
            var n = BlacksmithNative.cadaclysm_blacksmith_regions_count(list);
            var found = new List<Region>((int)Math.Min(n, 1024u));
            for (uint i = 0; i < n; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_regions_at(list, i, out var raw)) throw Blacksmith.Failure("regions_at");
                var sides = new List<FaceSide>((int)Math.Min(raw.Sides, 1024u));
                for (uint k = 0; k < raw.Sides; k++)
                {
                    if (!BlacksmithNative.cadaclysm_blacksmith_regions_side_at(list, i, k, out var side)) throw Blacksmith.Failure("regions_side_at");
                    sides.Add(new FaceSide((int)side.Face, side.Sense));
                }
                found.Add(new Region((int)i, raw.Finite != 0, RegionBox(raw), sides, (int)raw.Shells));
            }
            return found;
        }
        finally { BlacksmithNative.cadaclysm_blacksmith_regions_free(list); }
    }

    private static unsafe Box RegionBox(RawBlacksmithRegion raw) =>
        new(new[] { raw.Min[0], raw.Min[1], raw.Min[2] }, new[] { raw.Max[0], raw.Max[1], raw.Max[2] });

    /// <summary>Finite region <paramref name="region"/> (an index into <see cref="Regions"/>) as a
    /// closed solid of its own: the faces bounding it, each turned to point out of it, each keeping
    /// its colour. Region 0, the infinite one, or a region past the count throws
    /// <see cref="BuildException"/>; a negative one <see cref="ArgumentOutOfRangeException"/>
    /// before the call.</summary>
    public Solid RegionSolid(int region)
    {
        if (region < 0) throw new ArgumentOutOfRangeException(nameof(region), $"region_solid: region is out of range: {region}");
        return new(BlacksmithNative.cadaclysm_blacksmith_region_solid(Handle, (uint)region));
    }

    /// <summary>The round `face` belongs to -- a fillet's bands, balls and rim bands joined to
    /// that face -- made again at `radius`, as a press-pull on a fillet face: taken back to
    /// the sharp edges it replaced, and those rounded again.</summary>
    public Solid Refillet(int face, double radius, double? tolerance = 1e-6) =>
        new(BlacksmithNative.cadaclysm_blacksmith_refillet(Handle, Index(face), radius, Blacksmith.Tol(tolerance)));

    /// <summary>The round `face` belongs to taken off, the faces beside it sharp again --
    /// the delete of a fillet face.</summary>
    public Solid Unfillet(int face) => new(BlacksmithNative.cadaclysm_blacksmith_unfillet(Handle, Index(face)));

    /// <summary>The chamfer `face` belongs to -- its bevels, flat or round a rim, and the corner
    /// triangles joined to that face -- cut again at `distance`, as a press-pull on a chamfer
    /// face: taken back to the sharp edges it cut, and those bevelled again.</summary>
    public Solid Rechamfer(int face, double distance, double? tolerance = 1e-6) =>
        new(BlacksmithNative.cadaclysm_blacksmith_rechamfer(Handle, Index(face), distance, Blacksmith.Tol(tolerance)));

    /// <summary>The chamfer `face` belongs to taken off, the faces beside it sharp again --
    /// the delete of a chamfer face.</summary>
    public Solid Unchamfer(int face) => new(BlacksmithNative.cadaclysm_blacksmith_unchamfer(Handle, Index(face)));

    /// <summary>This solid hollowed to a wall `thickness` thick (inward for a positive
    /// thickness, outward for a negative one), with the faces at `open` removed so the hollow
    /// is reachable.</summary>
    public Solid Shell(double thickness, IEnumerable<int>? open = null, double? tolerance = 1e-6)
    {
        var which = Indices(open ?? Array.Empty<int>());
        return new Solid(BlacksmithNative.cadaclysm_blacksmith_shell(Handle, thickness, which, (nuint)which.Length, Blacksmith.Tol(tolerance),
            IntPtr.Zero, IntPtr.Zero));
    }

    /// <summary>This sheet made a solid `thickness` thick: its faces, their
    /// twins moved `thickness` along the faces' normals (against them for a negative thickness),
    /// and a wall round every open edge. A closed sheet thickens to a hollow.</summary>
    public Solid Thicken(double thickness, double? tolerance = 1e-6) =>
        new(BlacksmithNative.cadaclysm_blacksmith_thicken(Handle, thickness, Blacksmith.Tol(tolerance), IntPtr.Zero, IntPtr.Zero));

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
                "has one (STEP, ACIS, Rhino, OCCT .brep, IGES, IFC, OpenSCAD), not a mesh, a curve or a CSG body");
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
    /// Rhino `.3dm`, OCCT `.brep`, IGES, IFC or OpenSCAD file, read where it draws, in the file's own
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
                "OCCT .brep, IGES, IFC or OpenSCAD body can be a solid, not a mesh, a curve or a CSG body");
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

    private Assembly(AssemblyHandle handle) => _handle = handle;

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

    /// <summary>Declare a rigid link called <paramref name="name"/> over <paramref
    /// name="placements"/>: names of placements of this assembly itself (not of assemblies
    /// placed in it -- give those their own mechanism). A placed assembly in a link moves as
    /// one piece. An empty name, a name taken by another link here, no placements, a placement
    /// named twice, one this assembly does not have, or one already in another link throws
    /// <see cref="BuildException"/>, and the assembly is left as it was. Written as an AP242
    /// kinematic link; a mechanism anywhere in the tree makes AP242 the default schema of
    /// <see cref="StepText"/>, and an explicit schema without the kinematic entities throws.
    /// </summary>
    public void Link(string name, params string[] placements)
    {
        var count = placements.Length;
        var native = count == 0 ? null : new IntPtr[count];
        try
        {
            if (native is not null)
                for (var i = 0; i < count; i++) native[i] = Marshal.StringToCoTaskMemUTF8(placements[i]);
            var ok = BlacksmithNative.cadaclysm_blacksmith_assembly_link(Handle, name, native, (nuint)count);
            GC.KeepAlive(this);
            if (!ok) throw Blacksmith.Failure("assembly_link");
        }
        finally
        {
            if (native is not null) foreach (var p in native) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p);
        }
    }

    /// <summary>Connect this assembly's links <paramref name="start"/> and <paramref
    /// name="end"/>, kept in that order, as a joint called <paramref name="name"/>. An empty
    /// name, a name taken by another joint here, a link this assembly does not have, a link
    /// joined to itself, or a (start, end) pair already joined throws <see
    /// cref="BuildException"/>; the reverse pair is a different joint.</summary>
    public void Joint(string name, string start, string end)
    {
        var ok = BlacksmithNative.cadaclysm_blacksmith_assembly_joint(Handle, name, start, end);
        GC.KeepAlive(this);
        if (!ok) throw Blacksmith.Failure("assembly_joint");
    }

    /// <summary>Give joint <paramref name="joint"/> its pair: <paramref name="kind"/> (a name
    /// of the kind table -- "revolute", "prismatic", "cylindrical", "screw", "spherical",
    /// "spherical_with_pin", "planar", "universal", "homokinetic", "fully_constrained" or
    /// "unconstrained"), the contact frame at rest, an optional <paramref name="endFrame"/>
    /// (the frame the pair reaches at its rest values; <paramref name="frame"/> itself, i.e.
    /// all-zero rest values, when omitted), <paramref name="ranges"/> (one entry per freedom
    /// of <paramref name="kind"/> -- see <see cref="Blacksmith.PairFreedomCount"/> -- either
    /// side null for unbounded; omitted entirely for a kind that allows none), and <paramref
    /// name="pitch"/> (required and non-zero for "screw", refused for any other kind). Throws
    /// <see cref="BuildException"/> with the kernel's own text when a rule refuses it; the
    /// assembly is then unchanged.</summary>
    public void Pair(string joint, string kind, Frame frame, Frame? endFrame = null,
        IReadOnlyList<(double? Lower, double? Upper)>? ranges = null, double? pitch = null)
    {
        double[]? lower = null, upper = null;
        byte[]? hasLower = null, hasUpper = null;
        var freedomCount = ranges is null ? 0 : (nuint)ranges.Count;
        if (ranges is not null)
        {
            lower = new double[ranges.Count];
            upper = new double[ranges.Count];
            hasLower = new byte[ranges.Count];
            hasUpper = new byte[ranges.Count];
            for (var i = 0; i < ranges.Count; i++)
            {
                lower[i] = ranges[i].Lower ?? 0.0;
                upper[i] = ranges[i].Upper ?? 0.0;
                hasLower[i] = (byte)(ranges[i].Lower is not null ? 1 : 0);
                hasUpper[i] = (byte)(ranges[i].Upper is not null ? 1 : 0);
            }
        }
        var ok = BlacksmithNative.cadaclysm_blacksmith_assembly_pair(Handle, joint, kind,
            Blacksmith.Frame(frame), endFrame is null ? null : Blacksmith.Frame(endFrame),
            lower, upper, hasLower, hasUpper, freedomCount, pitch ?? double.NaN);
        GC.KeepAlive(this);
        if (!ok) throw Blacksmith.Failure("assembly_pair");
    }

    /// <summary><see cref="Pair"/> with the kind's own numbers in place of the pitch, for the
    /// coupled pairs: <paramref name="kind"/> any name <see cref="Pair"/> takes, or "gear" or
    /// "rack_and_pinion"; <paramref name="parameters"/> [pitch] for a screw, [pinion_radius]
    /// for a rack and pinion, [radius_first, radius_second, ratio] or those plus [bevel,
    /// helical_angle] (radians) for a gear -- the ratio the second link's rotation over the
    /// first's, signed (two meshing external gears turn opposite ways, so theirs is
    /// negative) -- and none for any other kind. <paramref name="frame"/>, <paramref
    /// name="endFrame"/> and <paramref name="ranges"/> read as in <see cref="Pair"/>. Throws
    /// <see cref="BuildException"/> with the kernel's own text when a rule refuses it (a wrong
    /// number of parameters among them); the assembly is then unchanged.</summary>
    public void PairWith(string joint, string kind, Frame frame, Frame? endFrame = null,
        IReadOnlyList<(double? Lower, double? Upper)>? ranges = null, IEnumerable<double>? parameters = null)
    {
        double[]? lower = null, upper = null;
        byte[]? hasLower = null, hasUpper = null;
        var freedomCount = ranges is null ? 0 : (nuint)ranges.Count;
        if (ranges is not null)
        {
            lower = new double[ranges.Count];
            upper = new double[ranges.Count];
            hasLower = new byte[ranges.Count];
            hasUpper = new byte[ranges.Count];
            for (var i = 0; i < ranges.Count; i++)
            {
                lower[i] = ranges[i].Lower ?? 0.0;
                upper[i] = ranges[i].Upper ?? 0.0;
                hasLower[i] = (byte)(ranges[i].Lower is not null ? 1 : 0);
                hasUpper[i] = (byte)(ranges[i].Upper is not null ? 1 : 0);
            }
        }
        var values = parameters is null ? Array.Empty<double>() : parameters.ToArray();
        var ok = BlacksmithNative.cadaclysm_blacksmith_assembly_pair_with(Handle, joint, kind,
            Blacksmith.Frame(frame), endFrame is null ? null : Blacksmith.Frame(endFrame),
            lower, upper, hasLower, hasUpper, freedomCount, values.Length == 0 ? null : values, (nuint)values.Length);
        GC.KeepAlive(this);
        if (!ok) throw Blacksmith.Failure("assembly_pair_with");
    }

    /// <summary>Add a named state <paramref name="name"/> to this assembly: <paramref
    /// name="rows"/> sets each named joint to its values, in that joint's pair's freedom
    /// order. Throws <see cref="BuildException"/> with the kernel's own text when a rule
    /// refuses it; the assembly is then unchanged.</summary>
    public void State(string name, IEnumerable<(string Joint, IReadOnlyList<double> Values)> rows)
    {
        var list = rows as IReadOnlyList<(string Joint, IReadOnlyList<double> Values)> ?? rows.ToList();
        var count = list.Count;
        var joints = count == 0 ? null : new IntPtr[count];
        var counts = new uint[count];
        var flat = new List<double>();
        try
        {
            for (var i = 0; i < count; i++)
            {
                joints![i] = Marshal.StringToCoTaskMemUTF8(list[i].Joint);
                counts[i] = (uint)list[i].Values.Count;
                flat.AddRange(list[i].Values);
            }
            var ok = BlacksmithNative.cadaclysm_blacksmith_assembly_state(Handle, name, joints, counts,
                flat.Count == 0 ? null : flat.ToArray(), (nuint)count);
            GC.KeepAlive(this);
            if (!ok) throw Blacksmith.Failure("assembly_state");
        }
        finally
        {
            if (joints is not null) foreach (var p in joints) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p);
        }
    }

    /// <summary>A new assembly: this one with the joints in <paramref name="rows"/> moved, every
    /// placement on a moving link carrying its pose, so any writer or reader shows the mechanism
    /// posed. Each row is a joint -- a path of placement names then the joint name, joined by
    /// "/", a "/" or "\" inside a name escaped with "\" -- and its values in that joint's pair's
    /// freedom order; a bare name is enough when it names one joint. <paramref name="state"/>
    /// names a state to pose from first (<paramref name="rows"/> then override it), and
    /// <paramref name="ground"/> the link held still (default: the declared base). This
    /// assembly is unchanged either way. Throws <see cref="BuildException"/> with the kernel's
    /// own text when a rule refuses it (an ambiguous name, a value outside its range, a coupling
    /// given two disagreeing answers, an unknown state).</summary>
    public Assembly Posed(IEnumerable<(string Joint, IReadOnlyList<double> Values)>? rows = null,
        string? state = null, string? ground = null)
    {
        var list = rows is null ? new List<(string Joint, IReadOnlyList<double> Values)>()
            : rows as IReadOnlyList<(string Joint, IReadOnlyList<double> Values)> ?? rows.ToList();
        var count = list.Count;
        var joints = count == 0 ? null : new IntPtr[count];
        var counts = new uint[count];
        var flat = new List<double>();
        try
        {
            for (var i = 0; i < count; i++)
            {
                joints![i] = Marshal.StringToCoTaskMemUTF8(list[i].Joint);
                counts[i] = (uint)list[i].Values.Count;
                flat.AddRange(list[i].Values);
            }
            var posed = BlacksmithNative.cadaclysm_blacksmith_assembly_posed(Handle, joints,
                count == 0 ? null : counts, flat.Count == 0 ? null : flat.ToArray(), (nuint)count, state, ground);
            GC.KeepAlive(this);
            return new Assembly(Blacksmith.Checked(posed, "assembly_posed"));
        }
        finally
        {
            if (joints is not null) foreach (var p in joints) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p);
        }
    }

    /// <summary>The placement path of every solid under this assembly, at any depth: depth first,
    /// placements in order, names joined by "/" with a "/" or "\" inside a name escaped with "\"
    /// (as <see cref="Posed"/>'s keys). The index <see cref="SweptClash"/>'s rows use.</summary>
    public IReadOnlyList<string> Parts()
    {
        var count = BlacksmithNative.cadaclysm_blacksmith_assembly_part_count(Handle);
        var names = new List<string>((int)count);
        for (uint i = 0; i < count; i++)
        {
            var raw = BlacksmithNative.cadaclysm_blacksmith_assembly_part_path(Handle, i);
            if (raw == IntPtr.Zero) throw Blacksmith.Failure("assembly_part_path");
            try
            {
                names.Add(Marshal.PtrToStringUTF8(raw) ?? "");
            }
            finally
            {
                BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
            }
        }
        GC.KeepAlive(this);
        return names;
    }

    /// <summary>Every pair of this assembly's solids (indexed as <see cref="Parts"/> lists them)
    /// that penetrates, touches or comes within <paramref name="clearance"/> of the other anywhere
    /// while this assembly's own mechanism moves through <paramref name="keyframes"/>, as
    /// `SweptClash` rows in pair order. Each keyframe is rows of a joint key and its values, as
    /// <see cref="Posed"/>'s rows are, and every keyframe names the same joints with the same
    /// number of values each (the first fixes their order); time runs in keyframe units, keyframe
    /// `k` at time `k`. Between two keyframes each joint value moves linearly and each link is
    /// posed from those values, so a link swinging about a joint goes round its arc, not along its
    /// chord. Only this assembly's own joints move: a sub-assembly rides the link its placement is
    /// in. <paramref name="ground"/> is one of this assembly's links held fixed (null for its
    /// default); solids in no link stay still. Pairs on two links a joint joins are not tested
    /// unless <paramref name="joined"/>; <paramref name="allowed"/> pairs of part indices (a flat
    /// list) are never tested. <paramref name="tolerance"/> meshes the parts; <paramref
    /// name="resolution"/> and <paramref name="maxSteps"/> as <see cref="Collider.SweptClash"/>.
    /// Throws <see cref="BuildException"/> in the kernel's `swept_clash:` words: here, before the
    /// library is called, for keyframes naming different joints, a joint given twice, a joint
    /// with a different number of values than in keyframe 0, or an odd number of <paramref
    /// name="allowed"/> entries.</summary>
    public IReadOnlyList<SweptClash> SweptClash(IEnumerable<IEnumerable<(string Joint, IReadOnlyList<double> Values)>> keyframes,
        double clearance = 0, double? tolerance = 0.05, double resolution = 1e-3, uint maxSteps = 100000,
        uint[]? allowed = null, string? ground = null, bool joined = false)
    {
        var rows = keyframes.Select(k => k.ToList()).ToList();
        var first = rows.Count == 0 ? new List<(string Joint, IReadOnlyList<double> Values)>() : rows[0];
        var keys = first.Select(r => r.Joint).ToList();
        var counts = first.Select(r => (uint)r.Values.Count).ToArray();
        var flat = first.SelectMany(r => r.Values).ToList();
        for (var k = 1; k < rows.Count; k++)
        {
            // C takes one joint set for every keyframe: a later keyframe naming other joints is
            // refused here, in the kernel's words, before C is called
            var named = rows[k].Select(r => r.Joint).ToList();
            foreach (var j in keys.Concat(named))
            {
                if (!named.Contains(j)) throw new BuildException($"swept_clash: joint '{j}' is in keyframe 0 and not in keyframe {k}");
                if (!keys.Contains(j)) throw new BuildException($"swept_clash: joint '{j}' is in keyframe {k} and not in keyframe 0");
            }
            for (var i = 0; i < named.Count; i++)
                if (named.IndexOf(named[i]) != i) throw new BuildException($"swept_clash: joint '{named[i]}' is given twice");
            for (var i = 0; i < keys.Count; i++)
            {
                var values = rows[k].First(r => r.Joint == keys[i]).Values;
                if (values.Count != counts[i])
                    throw new BuildException($"swept_clash: joint '{keys[i]}' has {counts[i]} values in keyframe 0 and {values.Count} in keyframe {k}");
                flat.AddRange(values);
            }
        }
        var flatAllowed = allowed ?? Array.Empty<uint>();
        if (flatAllowed.Length % 2 != 0) throw new BuildException($"swept_clash: allowed is {flatAllowed.Length} numbers, not pairs");
        var joints = keys.Count == 0 ? null : new IntPtr[keys.Count];
        try
        {
            for (var i = 0; i < keys.Count; i++) joints![i] = Marshal.StringToCoTaskMemUTF8(keys[i]);
            var swept = BlacksmithNative.cadaclysm_blacksmith_assembly_swept_clash(Handle, joints,
                keys.Count == 0 ? null : counts, (nuint)keys.Count, flat.Count == 0 ? null : flat.ToArray(), (uint)rows.Count,
                ground, Blacksmith.Tol(tolerance), clearance, resolution, maxSteps, flatAllowed.Length == 0 ? null : flatAllowed,
                (uint)(flatAllowed.Length / 2), joined);
            GC.KeepAlive(this);
            return Blacksmith.SweptClashesOf(Blacksmith.Checked(swept, "assembly_swept_clash"));
        }
        finally
        {
            if (joints is not null) foreach (var p in joints) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p);
        }
    }

    /// <summary>Add a named motion sequence <paramref name="name"/> over this assembly's states:
    /// <paramref name="segments"/> are (state name, parameter, interpolation) rows, the
    /// parameters non-decreasing, each interpolation one of `"undefined"`, `"discontinuous"`,
    /// `"synchronous"`, `"linear"`. <paramref name="seconds"/> writes the parameter's unit as
    /// the second. Closed or open is the last segment's interpolation (closed unless
    /// `"discontinuous"`). Throws <see cref="BuildException"/> with the kernel's own text when
    /// a rule refuses it; the assembly is then unchanged.</summary>
    public void Sequence(string name, IEnumerable<(string State, double T, string Interpolation)> segments, bool seconds = false)
    {
        var list = segments.ToList();
        var count = list.Count;
        var states = new IntPtr[count];
        var interpolations = new IntPtr[count];
        var ts = new double[count];
        try
        {
            for (var i = 0; i < count; i++)
            {
                states[i] = Marshal.StringToCoTaskMemUTF8(list[i].State);
                interpolations[i] = Marshal.StringToCoTaskMemUTF8(list[i].Interpolation);
                ts[i] = list[i].T;
            }
            var ok = BlacksmithNative.cadaclysm_blacksmith_assembly_sequence(Handle, name, states, ts,
                interpolations, (nuint)count, seconds);
            GC.KeepAlive(this);
            if (!ok) throw Blacksmith.Failure("assembly_sequence");
        }
        finally
        {
            foreach (var p in states) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p);
            foreach (var p in interpolations) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p);
        }
    }

    /// <summary>Declare this assembly's base link. Throws <see cref="BuildException"/> with
    /// the kernel's own text when a rule refuses it; the assembly is then unchanged.</summary>
    public void Base(string link)
    {
        var ok = BlacksmithNative.cadaclysm_blacksmith_assembly_base(Handle, link);
        GC.KeepAlive(this);
        if (!ok) throw Blacksmith.Failure("assembly_base");
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

    /// <summary>This assembly, and everything placed under it, as one Rhino `.3dm`: each
    /// distinct part (as <see cref="StepText"/> counts them) a block holding its body, each
    /// sub-assembly a block of references to what it places -- nested assemblies are nested
    /// blocks -- and this assembly's own placements references at the top of the file, on a
    /// layer named after it. Each reference is named as its placement was. <paramref
    /// name="unit"/> and the warnings as <see cref="Blacksmith.Rhino3dmBytes"/>. Throws, as
    /// <see cref="StepText"/> does, for an assembly reachable from this one that places
    /// nothing.</summary>
    public byte[] Rhino3dmBytes(string unit = "mm")
    {
        var unitCode = Blacksmith.UnitCode(unit);
        var raw = BlacksmithNative.cadaclysm_blacksmith_assembly_3dm_bytes(Handle, unitCode, out var len);
        return Blacksmith.Taken3dm(raw, len, "assembly_3dm_bytes");
    }

    /// <summary><see cref="Rhino3dmBytes"/> written to <paramref name="path"/> by the library
    /// itself, which names the file in its refusal when it cannot.</summary>
    public void Write3dm(string path, string unit = "mm")
    {
        var unitCode = Blacksmith.UnitCode(unit);
        if (!BlacksmithNative.cadaclysm_blacksmith_assembly_3dm(Handle, path, unitCode))
            throw Blacksmith.Failure("assembly_3dm");
        Blacksmith.Warn3dm();
    }

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

    /// <summary>This curve as a value: a line a <see cref="Line"/> from `origin` to
    /// `origin + x`; a circle a <see cref="Circle"/> over a full turn, else the <see cref="Arc"/>
    /// over `t0..t1`; an ellipse its whole <see cref="Ellipse"/> (the range stays here: there is
    /// no elliptical-arc value); any other kind null.</summary>
    public CurveValue? Value
    {
        get
        {
            var frame = Origin.Concat(X).Concat(Y).Concat(Z).ToArray();
            switch (Kind)
            {
                case "line":
                    return new Line((Origin[0], Origin[1], Origin[2]), (Origin[0] + X[0], Origin[1] + X[1], Origin[2] + X[2]));
                case "circle":
                    if (T1 - T0 >= 2 * Math.PI - 1e-12) return new Circle(frame, Radius);
                    return new Arc(frame, Radius, new Interval(T0, T1));
                case "ellipse":
                    return new Ellipse(frame, Radius, Radius2);
                default:
                    return null;
            }
        }
    }

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

    /// <summary>An intersection handle read out, as <see cref="Solid.Intersect"/> and <see
    /// cref="Clash.Intersect"/> return it. The caller frees the handle.</summary>
    internal static Intersection Read(IntersectionHandle found)
    {
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
/// after; each ring closed without repeating its first point) -- empty for a partial overlap of curved faces
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

// ---- collider ---------------------------------------------------------------------------

/// <summary>An axis-aligned box: <see cref="Lo"/> and <see cref="Hi"/>, three numbers each.
/// The broad phase's own shape (<see cref="Solid.BoundsBox"/>, <see cref="Collider"/>'s own
/// boxes): cheap to move and to test against another, before anything is meshed.</summary>
public sealed class Box
{
    public double[] Lo { get; }
    public double[] Hi { get; }

    public Box(double[] lo, double[] hi)
    {
        Lo = Blacksmith.Point(lo, "lo");
        Hi = Blacksmith.Point(hi, "hi");
    }

    internal unsafe Box(RawBlacksmithBox raw)
    {
        Lo = new[] { raw.Lo[0], raw.Lo[1], raw.Lo[2] };
        Hi = new[] { raw.Hi[0], raw.Hi[1], raw.Hi[2] };
    }

    /// <summary>This box moved by <paramref name="frame"/> (rigid), boxed again on the world
    /// axes -- not this box's corners individually moved, which would not in general be a box
    /// at all: the <em>bounding</em> box of the moved corners.</summary>
    public Box Moved(double[] frame)
    {
        var words = Words();
        if (!BlacksmithNative.cadaclysm_blacksmith_box_moved(ref words, Blacksmith.Frame(frame), out var outBox))
            throw Blacksmith.Failure("box_moved");
        return new Box(outBox);
    }

    /// <summary>Whether this box and <paramref name="other"/> share a point (touching counts).
    /// </summary>
    public bool Overlaps(Box other)
    {
        var a = Words();
        var b = other.Words();
        return BlacksmithNative.cadaclysm_blacksmith_box_overlaps(ref a, ref b);
    }

    internal unsafe RawBlacksmithBox Words()
    {
        var raw = new RawBlacksmithBox();
        for (var i = 0; i < 3; i++)
        {
            raw.Lo[i] = Lo[i];
            raw.Hi[i] = Hi[i];
        }
        return raw;
    }

    public override string ToString() => $"Box(lo=({Lo[0]}, {Lo[1]}, {Lo[2]}), hi=({Hi[0]}, {Hi[1]}, {Hi[2]}))";
}

/// <summary>True only if box <paramref name="a"/> at <paramref name="frameA"/> and box
/// <paramref name="b"/> at <paramref name="frameB"/> cannot touch -- a separating axis among
/// the boxes' face normals and edge-direction crosses; touching is not apart. Sharper than
/// moving each box and asking <see cref="Box.Overlaps"/>, which boxes the <em>result</em> on
/// the world axes again and so can call two oriented boxes overlapping when they are not (two
/// unit boxes, the second turned 45 degrees about z and moved 2.3 along x: their world boxes
/// overlap, but the boxes themselves do not touch).</summary>
public static class BoxUtil
{
    public static bool Apart(Box a, double[] frameA, Box b, double[] frameB)
    {
        var ra = a.Words();
        var rb = b.Words();
        if (!BlacksmithNative.cadaclysm_blacksmith_boxes_apart(ref ra, Blacksmith.Frame(frameA), ref rb, Blacksmith.Frame(frameB), out var apart))
            throw Blacksmith.Failure("boxes_apart");
        return apart;
    }
}

/// <summary>Counts of one <see cref="Collider.Check"/> call: the candidate pairs
/// <see cref="Considered"/>, how many of them the world boxes and the oriented boxes cleared,
/// how many the share left to another call, how the rest were answered (<see cref="Cached"/>,
/// <see cref="ClosedForm"/>, <see cref="Meshed"/>), and how many were <see cref="Refused"/>.
/// <see cref="Confirmed"/> is the subset of <see cref="Meshed"/> that were thin mesh-path
/// overlaps sent to <see cref="Solid.Common"/> itself for a final answer.</summary>
public sealed class ColliderStats
{
    public int Considered { get; }
    public int WorldBoxes { get; }
    public int OrientedBoxes { get; }
    public int SkippedShare { get; }
    public int Cached { get; }
    public int ClosedForm { get; }
    public int Meshed { get; }
    public int Refused { get; }
    public int Confirmed { get; }

    internal ColliderStats(RawBlacksmithColliderStats raw)
    {
        Considered = (int)raw.Considered;
        WorldBoxes = (int)raw.WorldBoxes;
        OrientedBoxes = (int)raw.OrientedBoxes;
        SkippedShare = (int)raw.SkippedShare;
        Cached = (int)raw.Cached;
        ClosedForm = (int)raw.ClosedForm;
        Meshed = (int)raw.Meshed;
        Refused = (int)raw.Refused;
        Confirmed = (int)raw.Confirmed;
    }

    public override string ToString() =>
        $"ColliderStats(considered={Considered}, worldBoxes={WorldBoxes}, orientedBoxes={OrientedBoxes}, "
        + $"skippedShare={SkippedShare}, cached={Cached}, closedForm={ClosedForm}, meshed={Meshed}, refused={Refused}, "
        + $"confirmed={Confirmed})";
}

/// <summary>One pair <see cref="Collider.Check"/> found overlapping (<see cref="Overlap"/>
/// true), or could not decide (<see cref="Overlap"/> false; <see cref="Text"/> says why, empty
/// for an overlap). <see cref="Positions"/>/<see cref="Normals"/> are world xyz triples, three
/// per triangle (unwelded); <see cref="Indices"/> indexes them -- all empty for a refused
/// pair. <see cref="Depth"/> is the thinnest side of the overlap's world box, 0 for a refused
/// pair.
///
/// <see cref="Solid"/> rebuilds the exact overlap now, from the frames <see
/// cref="Collider.Check"/> found it at; this keeps the collisions handle behind every hit of
/// one <see cref="Collider.Check"/> call alive until the last of them is collected, freeing it
/// only then. Named <see cref="CollisionHit"/> rather than the plainer `Hit`, which this module
/// already uses for a curve-crossing result (<see cref="Blacksmith.Solid.Hits"/>).</summary>
public sealed class CollisionHit
{
    public int A { get; }
    public int B { get; }
    public bool Overlap { get; }
    /// <summary>"overlap" or "refused" -- the same answer as <see cref="Overlap"/>.</summary>
    public string Kind { get; }
    public double Depth { get; }
    public string Text { get; }
    public double[][] Positions { get; }
    public double[][] Normals { get; }
    public uint[] Indices { get; }

    private readonly CollisionsHandle _collisions;
    private readonly uint _index;

    internal unsafe CollisionHit(RawBlacksmithCollisionHit raw, CollisionsHandle collisions, uint index)
    {
        A = (int)raw.A;
        B = (int)raw.B;
        Overlap = raw.Overlap;
        Kind = raw.Overlap ? "overlap" : "refused";
        Depth = raw.Depth;
        Text = Blacksmith.Text(raw.Text);
        Positions = Blacksmith.PointsAt(raw.Positions, raw.VertexCount);
        Normals = Blacksmith.PointsAt(raw.Normals, raw.VertexCount);
        Indices = raw.Indices == IntPtr.Zero || raw.IndexCount == 0
            ? Array.Empty<uint>()
            : new ReadOnlySpan<uint>((void*)raw.Indices, (int)raw.IndexCount).ToArray();
        _collisions = collisions;
        _index = index;
    }

    /// <summary>The exact overlap of this pair at the frames <see cref="Collider.Check"/>
    /// found it at, as a new solid. Throws <see cref="BuildException"/> for a refused pair
    /// (<see cref="Overlap"/> false) or a collisions handle already closed some other way.
    /// </summary>
    public Solid Solid()
    {
        var solid = BlacksmithNative.cadaclysm_blacksmith_collisions_solid(_collisions, _index);
        GC.KeepAlive(_collisions);
        return new Solid(Blacksmith.Checked(solid, "collisions_solid"));
    }

    public override string ToString() => $"CollisionHit(a={A}, b={B}, overlap={Overlap}, depth={Depth})";
}

/// <summary>One pair <see cref="Collider.Clash"/> or `Blacksmith.Clash` found: <see cref="A"/>,
/// <see cref="B"/> the part indices (for one set or a collider `A &lt; B`; for two sets `A`
/// indexes the first and `B` the second), <see cref="Kind"/> one of "penetrating", "touching"
/// (the boundaries within the tolerance of each other), "too_close" (apart by more than the
/// tolerance but less than the clearance) or "refused" (the pair could not be decided; <see
/// cref="Text"/> says why).
///
/// <see cref="Distance"/> is the gap between the two boundaries (0 for a penetrating or refused
/// pair); <see cref="OnA"/> and <see cref="OnB"/> are world points -- the closest pair, or for a
/// penetrating pair the centre of the overlap's world box. <see cref="KindA"/>, <see
/// cref="IndexA"/>, <see cref="EdgeA"/> (and the B side) say what each point lies on exactly as
/// <see cref="Closest"/> does; for a penetrating or refused pair the kinds are "none" and the
/// indices and edges null. <see cref="Depth"/> is the thinnest side of a penetrating pair's
/// overlap box (0 otherwise).
///
/// <see cref="Solid"/> rebuilds a penetrating pair's shared volume now, <see cref="Intersect"/>
/// where the two parts cross or coincide, both at the placement the pair was found at; this keeps
/// the clashes handle behind every row of one call alive until the last of them is collected,
/// freeing it only then.</summary>
public sealed class Clash
{
    public int A { get; }
    public int B { get; }
    /// <summary>"penetrating", "touching", "too_close" or "refused".</summary>
    public string Kind { get; }
    public double Distance { get; }
    public double[] OnA { get; }
    public double[] OnB { get; }
    /// <summary>What side a's point lies on: "face", "edge", "vertex", or "none" for a
    /// penetrating or refused pair.</summary>
    public string KindA { get; }
    /// <summary>Side a's face, edge or vertex index, by <see cref="KindA"/>; null for kind "none".</summary>
    public uint? IndexA { get; }
    /// <summary>Side a's fillet-table edge (an index into <see cref="Blacksmith.Solid.Edges"/>), or null.</summary>
    public uint? EdgeA { get; }
    public string KindB { get; }
    public uint? IndexB { get; }
    public uint? EdgeB { get; }
    /// <summary>The distance was measured on the exact surfaces.</summary>
    public bool Refined { get; }
    public double Depth { get; }
    public string Text { get; }

    private readonly ClashesHandle _clashes;
    private readonly uint _index;

    internal unsafe Clash(RawBlacksmithClash raw, ClashesHandle clashes, uint index)
    {
        A = (int)raw.A;
        B = (int)raw.B;
        Kind = Blacksmith.Text(raw.Kind);
        Distance = raw.Distance;
        OnA = new[] { raw.OnA[0], raw.OnA[1], raw.OnA[2] };
        OnB = new[] { raw.OnB[0], raw.OnB[1], raw.OnB[2] };
        KindA = Blacksmith.Text(raw.KindA);
        KindB = Blacksmith.Text(raw.KindB);
        var noneA = KindA == "none";
        var noneB = KindB == "none";
        IndexA = noneA ? null : raw.IndexA;
        EdgeA = noneA || raw.EdgeA == uint.MaxValue ? null : raw.EdgeA;
        IndexB = noneB ? null : raw.IndexB;
        EdgeB = noneB || raw.EdgeB == uint.MaxValue ? null : raw.EdgeB;
        Refined = raw.Refined != 0;
        Depth = raw.Depth;
        Text = Blacksmith.Text(raw.Text);
        _clashes = clashes;
        _index = index;
    }

    /// <summary>The exact shared volume of this penetrating pair at the placement it was found
    /// at, as a new solid. Throws <see cref="BuildException"/> for a pair that is not
    /// penetrating.</summary>
    public Solid Solid()
    {
        var solid = BlacksmithNative.cadaclysm_blacksmith_clashes_solid(_clashes, _index);
        GC.KeepAlive(_clashes);
        return new Solid(Blacksmith.Checked(solid, "clashes_solid"));
    }

    /// <summary>Where this pair's two parts cross or coincide at the placement it was found at,
    /// as <see cref="Blacksmith.Solid.Intersect"/> reports it (a touching pair's shared face is an
    /// <see cref="Overlap"/>). Throws <see cref="BuildException"/> for a refused pair.</summary>
    public Intersection Intersect()
    {
        using var found = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_clashes_intersect(_clashes, _index), "clashes_intersect");
        GC.KeepAlive(_clashes);
        return Intersection.Read(found);
    }

    public override string ToString() => $"Clash(a={A}, b={B}, kind={Kind}, distance={Distance:G9})";
}

/// <summary>One pair <see cref="Collider.SweptClash"/> or `Blacksmith.SweptClash` found: <see
/// cref="A"/>, <see cref="B"/> the part indices (for one set or a collider `A &lt; B`; for two sets
/// `A` indexes the first and `B` the second). <see cref="FirstTime"/> is the first time the pair
/// came within the clearance, in pose units (pose `k` at time `k`; for a refused pair the time it
/// was refused at), and <see cref="First"/> the <see cref="Clash"/> there -- its kind, distance,
/// points, features and depth, at the frames the motion places the parts at that time, so its
/// <see cref="Clash.Solid"/> and <see cref="Clash.Intersect"/> rebuild the contact there (it keeps
/// its own clashes handle alive, so they work after the collider has closed). <see
/// cref="Intervals"/> are the time ranges the pair stays in clash, ascending and disjoint (none for
/// a refused pair).</summary>
public sealed record SweptClash(int A, int B, double FirstTime, Clash First, IReadOnlyList<(double Start, double End)> Intervals)
{
    public override string ToString() =>
        $"SweptClash(a={A}, b={B}, first_time={FirstTime:G9}, kind={First.Kind}, intervals=[{string.Join(", ", Intervals.Select(s => $"({s.Start:G9}, {s.End:G9})"))}])";
}

/// <summary>What a verb did to its inputs' faces (or edges), read off the result's ids and
/// origins alone (<see cref="Solid.History"/>, <see cref="Solid.EdgeHistory"/>). An input is named
/// `(Operand, Id)`: the operand its index in the inputs as passed (the verb's operand order: a
/// boolean's target 0, its tool 1), the id its <see cref="Solid.FaceId"/>. Every list is in
/// `(Operand, Id)` order, <see cref="Generated"/> in id order. <see cref="Kept"/>: an input that
/// became exactly one output, keeping its id; <see cref="Modified"/>: an input split, merged or
/// renumbered, with its outputs (a split's first piece, which keeps the id, first);
/// <see cref="Generated"/>: the outputs with no origin; <see cref="Deleted"/>: the inputs no
/// output names. Copied out whole; equal where every list is.</summary>
public sealed record History(
    IReadOnlyList<((int Operand, ulong Id) Input, ulong Output)> Kept,
    IReadOnlyList<((int Operand, ulong Id) Input, IReadOnlyList<ulong> Outputs)> Modified,
    IReadOnlyList<ulong> Generated,
    IReadOnlyList<(int Operand, ulong Id)> Deleted)
{
    /// <summary>The four lists of history handle `h`, read through the C readers; the caller
    /// frees it.</summary>
    internal static History Read(IntPtr h)
    {
        var kept = new List<((int, ulong), ulong)>();
        for (uint i = 0, n = BlacksmithNative.cadaclysm_blacksmith_history_kept_count(h); i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_history_kept_at(h, i, out var operand, out var id, out var outId))
                throw Blacksmith.Failure("history_kept_at");
            kept.Add((((int)operand, id), outId));
        }
        var modified = new List<((int, ulong), IReadOnlyList<ulong>)>();
        for (uint i = 0, n = BlacksmithNative.cadaclysm_blacksmith_history_modified_count(h); i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_history_modified_at(h, i, out var operand, out var id))
                throw Blacksmith.Failure("history_modified_at");
            var m = BlacksmithNative.cadaclysm_blacksmith_history_modified_output_count(h, i);
            if (m == Blacksmith.None) throw Blacksmith.Failure("history_modified_output_count");
            var outs = new ulong[m];
            for (uint j = 0; j < m; j++) outs[j] = BlacksmithNative.cadaclysm_blacksmith_history_modified_output_at(h, i, j);
            modified.Add((((int)operand, id), Array.AsReadOnly(outs)));
        }
        var generated = new ulong[BlacksmithNative.cadaclysm_blacksmith_history_generated_count(h)];
        for (uint i = 0; i < generated.Length; i++) generated[i] = BlacksmithNative.cadaclysm_blacksmith_history_generated_at(h, i);
        var deleted = new List<(int, ulong)>();
        for (uint i = 0, n = BlacksmithNative.cadaclysm_blacksmith_history_deleted_count(h); i < n; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_history_deleted_at(h, i, out var operand, out var id))
                throw Blacksmith.Failure("history_deleted_at");
            deleted.Add(((int)operand, id));
        }
        return new History(kept.AsReadOnly(), modified.AsReadOnly(), Array.AsReadOnly(generated), deleted.AsReadOnly());
    }

    public bool Equals(History? other) =>
        other is not null && Kept.SequenceEqual(other.Kept) && Generated.SequenceEqual(other.Generated)
        && Deleted.SequenceEqual(other.Deleted) && Modified.Count == other.Modified.Count
        && Modified.Zip(other.Modified).All(p => p.First.Input == p.Second.Input && p.First.Outputs.SequenceEqual(p.Second.Outputs));

    public override int GetHashCode() => HashCode.Combine(Kept.Count, Modified.Count, Generated.Count, Deleted.Count);

    public override string ToString() =>
        $"History(kept={Kept.Count}, modified={Modified.Count}, generated={Generated.Count}, deleted={Deleted.Count})";
}

/// <summary>Parts meshed once, asked pose after pose which of them interfere: <paramref
/// name="solids"/> at rest, meshed at <paramref name="tolerance"/>; <paramref name="groups"/>
/// one group index per solid (null: each solid its own group -- <see cref="Check"/> then takes
/// one frame per solid), <paramref name="allowed"/> pairs of part indices never tested
/// (designed contacts, by part index, flat: `(a0, b0, a1, b1, ...)`). <see cref="Dispose"/>
/// frees this handle; so does the garbage collector.</summary>
public sealed class Collider : IDisposable
{
    private readonly ColliderHandle _handle;

    public Collider(IEnumerable<Solid> solids, double? tolerance = 0.05, uint[]? groups = null, uint[]? allowed = null)
    {
        var owners = solids.ToArray();
        if (groups != null && groups.Length != owners.Length)
            throw new BuildException($"Collider: groups must have one entry per solid ({owners.Length} solids, {groups.Length} groups)");
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var flatAllowed = allowed ?? Array.Empty<uint>();
        if (flatAllowed.Length % 2 != 0) throw new BuildException("Collider: allowed must be pairs of part indices");
        var handle = BlacksmithNative.cadaclysm_blacksmith_collider_new(handles, (uint)handles.Length, Blacksmith.Tol(tolerance), groups,
            flatAllowed.Length == 0 ? null : flatAllowed, (uint)(flatAllowed.Length / 2));
        GC.KeepAlive(owners);
        _handle = Blacksmith.Checked(handle, "collider_new");
    }

    public void Dispose() => _handle.Dispose();

    /// <summary>How many groups this collider has -- the highest group index past the
    /// constructor, plus one.</summary>
    public int GroupCount => (int)BlacksmithNative.cadaclysm_blacksmith_collider_group_count(_handle);

    /// <summary>Counts of the last <see cref="Check"/> call (all zero before the first one).
    /// </summary>
    public ColliderStats Stats
    {
        get
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_collider_stats(_handle, out var raw)) throw Blacksmith.Failure("collider_stats");
            return new ColliderStats(raw);
        }
    }

    /// <summary>The pairs that interfere, or could not be decided, with each group placed at
    /// its matching frame in <paramref name="frames"/> (one twelve-number frame per group, in
    /// group order). <paramref name="share"/>: null, every pair past the box filters is
    /// decided now; `(k, n)`, only those whose index is `k` modulo `n` (the shares of one pose
    /// are disjoint and cover it -- split one <see cref="Check"/> across `n` workers).
    /// </summary>
    public IReadOnlyList<CollisionHit> Check(IReadOnlyList<double[]> frames, (uint K, uint N)? share = null)
    {
        var flat = new double[frames.Count * 12];
        for (var i = 0; i < frames.Count; i++) Array.Copy(Blacksmith.Frame(frames[i]), 0, flat, i * 12, 12);
        var (shareK, shareN) = share ?? (0u, 0u);
        var collisions = BlacksmithNative.cadaclysm_blacksmith_collider_check(_handle, flat, (uint)frames.Count, shareK, shareN);
        collisions = Blacksmith.Checked(collisions, "collider_check");
        var count = BlacksmithNative.cadaclysm_blacksmith_collisions_count(collisions);
        var hits = new List<CollisionHit>((int)count);
        for (uint i = 0; i < count; i++)
        {
            if (!BlacksmithNative.cadaclysm_blacksmith_collisions_hit(collisions, i, out var raw)) throw Blacksmith.Failure("collisions_hit");
            hits.Add(new CollisionHit(raw, collisions, i));
        }
        return hits;
    }

    /// <summary>Every pair of parts that penetrates, touches or lies within <paramref
    /// name="clearance"/> of the other, as `Clash` rows in pair order, with each group placed at
    /// its matching frame in <paramref name="frames"/> (as for <see cref="Check"/>). <paramref
    /// name="clearance"/> is zero or more, in model units: a pair apart by more than the
    /// collider's tolerance but less than it is "too_close". <paramref name="share"/> as for <see
    /// cref="Check"/>. The collider keeps each part's closest mesh (at a third of its tolerance)
    /// for its lifetime once a pair needed one. Throws <see cref="BuildException"/> for a negative
    /// or non-finite clearance, the wrong number of frames or a bad share.</summary>
    public IReadOnlyList<Clash> Clash(IReadOnlyList<double[]> frames, double clearance = 0, (uint K, uint N)? share = null)
    {
        var flat = new double[frames.Count * 12];
        for (var i = 0; i < frames.Count; i++) Array.Copy(Blacksmith.Frame(frames[i]), 0, flat, i * 12, 12);
        var (shareK, shareN) = share ?? (0u, 0u);
        var clashes = BlacksmithNative.cadaclysm_blacksmith_collider_clash(_handle, flat, (uint)frames.Count, clearance, shareK, shareN);
        return Blacksmith.ClashesOf(Blacksmith.Checked(clashes, "collider_clash"));
    }

    /// <summary>Every pair of parts that penetrates, touches or comes within <paramref
    /// name="clearance"/> of the other anywhere on the path through <paramref name="poses"/> -- not
    /// only at the poses -- as `SweptClash` rows in pair order. <paramref name="poses"/> is two or
    /// more poses, each the frames <see cref="Clash"/> takes (one frame per group). Between two
    /// poses each group moves rigidly about the centre of its rest box: that point on the straight
    /// line between its two places, the rotation turning at a steady rate the shorter way round.
    /// Time runs in pose units, pose `k` at time `k`.
    ///
    /// No moment where the true gap is below <paramref name="clearance"/> less the collider's
    /// tolerance (for clearance 0: no penetration deeper than the tolerance) falls between two
    /// steps. <paramref name="resolution"/> (in (0, 1], a fraction of a segment) is how closely an
    /// interval's end is found; <paramref name="maxSteps"/> the pose-wise tests one pair may take
    /// -- a pair that needs more is a "refused" row. <paramref name="share"/> as for <see
    /// cref="Check"/>, over the pairs whose swept boxes meet. The pose caches <see cref="Check"/>
    /// and <see cref="Clash"/> keep are neither read nor filled. Throws <see
    /// cref="BuildException"/> for fewer than two poses, the wrong number of frames in a pose, a
    /// bad frame, clearance, resolution or share, or <paramref name="maxSteps"/> 0.</summary>
    public IReadOnlyList<SweptClash> SweptClash(IEnumerable<IEnumerable<double[]>> poses, double clearance = 0, double resolution = 1e-3,
        uint maxSteps = 100000, (uint K, uint N)? share = null)
    {
        var frames = poses.Select(pose => pose.ToArray()).ToArray();
        var frameCount = frames.Length == 0 ? 0 : frames[0].Length;
        if (frames.Any(pose => pose.Length != frameCount))
        {
            // C reads every pose at one frame count: say the first pose that is off, in the
            // kernel's words
            var groups = GroupCount;
            var n = frames.First(pose => pose.Length != groups).Length;
            throw new BuildException($"collider_swept_clash: {n} frames for {groups} groups");
        }
        var flat = Blacksmith.PoseFrames(frames, frameCount);
        var (shareK, shareN) = share ?? (0u, 0u);
        var swept = BlacksmithNative.cadaclysm_blacksmith_collider_swept_clash(_handle, flat, (uint)frames.Length, (uint)frameCount,
            clearance, resolution, maxSteps, shareK, shareN);
        return Blacksmith.SweptClashesOf(Blacksmith.Checked(swept, "collider_swept_clash"));
    }
}

/// <summary>One wall-thickness reading on a solid (<see cref="ThicknessGauge.Thickness"/>,
/// <see cref="ThicknessGauge.ThicknessAt"/>, <see cref="Blacksmith.Thickness"/>). <see cref="Point"/>
/// lies on face <see cref="Face"/> of body <see cref="Body"/> (the body's index in the gauge): at
/// vertex <see cref="Vertex"/> of that body's measuring mesh (<see cref="ThicknessGauge.Mesh"/>), or
/// <see cref="Vertex"/> null for a reading at a point. <see cref="Value"/> is the thickness by the
/// nearest-opposing-wall rule (the nearest triangle that faces against one of the vertex's own faces,
/// with the vertex behind it) on the measuring mesh, to <see cref="Opposite"/> on face
/// <see cref="OppositeFace"/> of body <see cref="OppositeBody"/>; <see cref="Knife"/> marks a knife
/// edge (thickness 0, <see cref="Opposite"/> equal to <see cref="Point"/>).
/// <see cref="ExactOpposite"/> is <see cref="Opposite"/> moved onto its exact face where its foot
/// lies within the tolerance and inside the face's trims, <see cref="ExactThickness"/> the distance
/// to it. <see cref="Sphere"/> is the diameter of the largest ball tangent at <see cref="Point"/>
/// that holds none of the surfaces, null where none under the maximum does (0 on a knife edge).
/// (`Value` is the C ABI's `thickness`: a member cannot share its type's name.)</summary>
public sealed record Thickness(uint Body, uint? Vertex, uint Face, double[] Point, double Value, double[] Opposite, uint OppositeBody,
    uint OppositeFace, bool Knife, double ExactThickness, double[] ExactOpposite, double? Sphere)
{
    internal unsafe Thickness(RawBlacksmithThickness raw) : this(raw.Body, raw.Vertex == Blacksmith.None ? null : raw.Vertex, raw.Face,
        new[] { raw.Point[0], raw.Point[1], raw.Point[2] }, raw.Thickness, new[] { raw.Opposite[0], raw.Opposite[1], raw.Opposite[2] },
        raw.OppositeBody, raw.OppositeFace, raw.Knife, raw.ExactThickness,
        new[] { raw.ExactOpposite[0], raw.ExactOpposite[1], raw.ExactOpposite[2] }, double.IsNaN(raw.Sphere) ? null : raw.Sphere)
    {
    }

    public override string ToString() =>
        $"Thickness(body={Body}, vertex={Vertex}, face={Face}, thickness={Value:G9}, opposite_body={OppositeBody}, knife={Knife})";
}

/// <summary>A face's thickness, found (<see cref="ThicknessGauge.ThicknessAtFace(uint, uint, double[], double)"/>,
/// <see cref="Solid.ThicknessAtFace(uint, double[], double, double)"/>; where nothing is found those
/// answer null): <see cref="Thickness"/> the median of the face's vertex readings (or the reading at
/// the point asked), <see cref="Min"/> and <see cref="Max"/> their extremes, <see cref="Uniform"/>
/// whether `Max - Min` is within the gauge's tolerance.</summary>
public sealed record FaceThickness(double Thickness, double Min, double Max, bool Uniform)
{
    internal FaceThickness(RawBlacksmithFaceThickness raw) : this(raw.Thickness, raw.Min, raw.Max, raw.Uniform)
    {
    }

    public override string ToString() => $"FaceThickness(thickness={Thickness:G9}, min={Min:G9}, max={Max:G9}, uniform={Uniform})";
}

/// <summary>A body's measuring mesh (<see cref="ThicknessGauge.Mesh"/>), copied out of the gauge:
/// <see cref="Positions"/> and <see cref="Normals"/> (unit, outward) one `x, y, z` triple per vertex
/// -- a reading's `Vertex` indexes them; no vertex is shared between two faces --
/// <see cref="Triangles"/> three vertex indices each, and <see cref="Faces"/> the B-rep face of each
/// triangle.</summary>
public sealed record ThicknessMesh(double[][] Positions, double[][] Normals, uint[][] Triangles, uint[] Faces)
{
    public override string ToString() => $"ThicknessMesh(vertices={Positions.Length}, triangles={Triangles.Length})";
}

/// <summary>One reading on a plain mesh (<see cref="Blacksmith.MeshThickness"/>): vertex
/// <see cref="Vertex"/> of mesh <see cref="Mesh"/>, at <see cref="Point"/>, reads
/// <see cref="Thickness"/> to <see cref="Opposite"/> on triangle <see cref="OppositeTriangle"/> of
/// mesh <see cref="OppositeMesh"/> (both indices within that mesh). <see cref="Knife"/>: a knife
/// edge, thickness 0 and <see cref="Opposite"/> equal to <see cref="Point"/>.</summary>
public sealed record MeshThickness(uint Mesh, uint Vertex, double Thickness, double[] Point, double[] Opposite, uint OppositeMesh,
    uint OppositeTriangle, bool Knife)
{
    internal unsafe MeshThickness(RawBlacksmithMeshThickness raw) : this(raw.Mesh, raw.Vertex, raw.Thickness,
        new[] { raw.Point[0], raw.Point[1], raw.Point[2] }, new[] { raw.Opposite[0], raw.Opposite[1], raw.Opposite[2] },
        raw.OppositeMesh, raw.OppositeTriangle, raw.Knife)
    {
    }

    public override string ToString() =>
        $"MeshThickness(mesh={Mesh}, vertex={Vertex}, thickness={Thickness:G9}, opposite_mesh={OppositeMesh}, knife={Knife})";
}

/// <summary>Wall thickness (the nearest-opposing-wall rule: each vertex reads to the nearest
/// triangle that faces against one of its own faces, with the vertex behind it) over
/// <paramref name="solids"/>, measured against each other: each solid meshed once at
/// <paramref name="tolerance"/> -- absolute, model units, default 0.01 -- then asked as often as
/// needed. A reading's `Body` is the solid's index in <paramref name="solids"/>. The gauge keeps its
/// own references to the bodies, so it answers on after they are disposed. <see cref="Dispose"/>
/// frees it; so does the garbage collector. A call after <see cref="Dispose"/> throws
/// <see cref="ObjectDisposedException"/> ("thickness_gauge: closed"). Throws
/// <see cref="BuildException"/> from the constructor for a tolerance not positive and finite.</summary>
public sealed class ThicknessGauge : IDisposable
{
    private readonly ThicknessGaugeHandle _handle;

    public ThicknessGauge(IEnumerable<Solid> solids, double? tolerance = 0.01)
    {
        var owners = solids.ToArray();
        var handles = owners.Select(s => s.Handle.DangerousGetHandle()).ToArray();
        var handle = BlacksmithNative.cadaclysm_blacksmith_thickness_gauge_new(handles, (uint)handles.Length, Blacksmith.Tol(tolerance));
        GC.KeepAlive(owners);
        _handle = Blacksmith.Checked(handle, "thickness_gauge_new");
    }

    public void Dispose() => _handle.Dispose();

    private ThicknessGaugeHandle Live =>
        !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(ThicknessGauge), "thickness_gauge: closed");

    /// <summary>How many bodies the gauge measures.</summary>
    public int Count => (int)BlacksmithNative.cadaclysm_blacksmith_thickness_gauge_body_count(Live);

    /// <summary>The tolerance the gauge meshed its bodies at.</summary>
    public double Tolerance
    {
        get
        {
            var value = BlacksmithNative.cadaclysm_blacksmith_thickness_gauge_tolerance(Live);
            if (double.IsNaN(value)) throw Blacksmith.Failure("thickness_gauge_tolerance");
            return value;
        }
    }

    public override string ToString() => _handle.IsClosed ? "ThicknessGauge(closed)" : $"ThicknessGauge(bodies={Count}, tolerance={Tolerance:G})";

    /// <summary>One reading per measuring-mesh vertex that has one within
    /// <paramref name="maximum"/> (positive and finite), by body then vertex; vertices whose interior
    /// angle is under <paramref name="sharpAngle"/> radians (zero or more) are knife edges. Throws
    /// <see cref="BuildException"/> for a bad limit.</summary>
    public IReadOnlyList<Thickness> Thickness(double maximum, double sharpAngle = 0.0) =>
        Blacksmith.ThicknessesOf(BlacksmithNative.cadaclysm_blacksmith_thickness_gauge_measure(Live, maximum, sharpAngle),
            "thickness_gauge_measure");

    /// <summary>The reading at <paramref name="point"/>'s foot on face <paramref name="face"/> of
    /// body <paramref name="body"/> (its `Vertex` null), or null where the foot lies off the face or
    /// the wall is thicker than <paramref name="maximum"/>. Throws <see cref="BuildException"/> for a
    /// body or face past the end, a point that is not three finite numbers or a bad limit.</summary>
    public Thickness? ThicknessAt(uint body, uint face, double[] point, double maximum, double sharpAngle = 0.0)
    {
        var gauge = Live;
        if ((point?.Length ?? 0) != 3) throw new BuildException($"thickness_gauge_at: a point is 3 numbers, got {point?.Length ?? 0}");
        var rows = Blacksmith.ThicknessesOf(
            BlacksmithNative.cadaclysm_blacksmith_thickness_gauge_at(gauge, body, face, point!, maximum, sharpAngle), "thickness_gauge_at");
        return rows.Count > 0 ? rows[0] : null;
    }

    /// <summary>One thickness for face <paramref name="face"/> of body <paramref name="body"/>:
    /// measured at <paramref name="at"/>'s foot on the face or, with <paramref name="at"/> null,
    /// over the face's vertices; the other bodies are measured with it. Null where nothing is found
    /// (nothing reads under <paramref name="maximum"/>, or the foot lies off the face). Throws
    /// <see cref="BuildException"/> for a body or face past the end, an `at` that is not three
    /// finite numbers or a bad maximum. The maximum has no default.</summary>
    public FaceThickness? ThicknessAtFace(uint body, uint face, double[]? at, double maximum)
    {
        var gauge = Live;
        if (at is not null && at.Length != 3) throw new BuildException($"thickness_gauge_face: a point is 3 numbers, got {at.Length}");
        if (!BlacksmithNative.cadaclysm_blacksmith_thickness_gauge_face(gauge, body, face, at, maximum, out var raw))
            throw Blacksmith.Failure("thickness_gauge_face");
        return raw.Found ? new FaceThickness(raw) : null;
    }

    /// <summary><see cref="ThicknessAtFace(uint, uint, double[], double)"/> over the face's
    /// vertices (no point).</summary>
    public FaceThickness? ThicknessAtFace(uint body, uint face, double maximum) => ThicknessAtFace(body, face, null, maximum);

    /// <summary>Body <paramref name="body"/>'s measuring mesh, copied out (it outlives the gauge).
    /// Throws <see cref="BuildException"/> for a body past the end.</summary>
    public ThicknessMesh Mesh(uint body)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_thickness_gauge_mesh(Live, body, out var raw)) throw Blacksmith.Failure("thickness_gauge_mesh");
        var n = raw.VertexCount;
        var t = raw.TriangleCount;
        var positions = Blacksmith.PointsAt(raw.Positions, n);
        var normals = Blacksmith.PointsAt(raw.Normals, n);
        var flat = Blacksmith.CopyOf<uint>(raw.Indices, 3 * t);
        var triangles = new uint[flat.Length / 3][];
        for (var k = 0; k < triangles.Length; k++) triangles[k] = new[] { flat[3 * k], flat[3 * k + 1], flat[3 * k + 2] };
        return new ThicknessMesh(positions, normals, triangles, Blacksmith.CopyOf<uint>(raw.Faces, t));
    }
}

/// <summary>The reusable answer to "where is this point?": a closed solid meshed once, then asked
/// point after point (<see cref="Solid.Classifier"/>). It keeps its own reference to the body, so
/// it goes on answering after its solid is disposed. <see cref="Dispose"/> frees it; so does the
/// garbage collector. A call after <see cref="Dispose"/> throws <see cref="ObjectDisposedException"/>.</summary>
public sealed class Classifier : IDisposable
{
    private readonly ClassifierHandle _handle;

    internal Classifier(ClassifierHandle handle)
    {
        _handle = Blacksmith.Checked(handle, "classifier_new");
    }

    public void Dispose() => _handle.Dispose();

    /// <summary>"inside", "outside" or "on" for <paramref name="point"/>.</summary>
    public string Contains(double[] point)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_classifier_contains(_handle, Blacksmith.Point(point, "point"), out var code))
            throw Blacksmith.Failure("classifier_contains");
        return Blacksmith.ContainmentOf(code, "classifier_contains");
    }
}

/// <summary>A solid meshed once and asked for its nearest point to point after point
/// (<see cref="Solid.Projector"/>), keeping the mesh, its search tree and each face's trim judge
/// between queries. It keeps its own reference to the body, so it goes on answering after its
/// solid is disposed. Calls on one projector take turns (a lock inside the library).
/// <see cref="Dispose"/> frees it; so does the garbage collector. A call after
/// <see cref="Dispose"/> throws <see cref="ObjectDisposedException"/>.</summary>
public sealed class Projector : IDisposable
{
    private readonly ProjectorHandle _handle;

    internal Projector(ProjectorHandle handle)
    {
        _handle = Blacksmith.Checked(handle, "projector_new");
    }

    public void Dispose() => _handle.Dispose();

    /// <summary>The nearest point of the body's boundary to <paramref name="p"/>, or null beyond
    /// <paramref name="maxDistance"/> (null, NaN or +inf: no limit) -- <see cref="Solid.ClosestPoint"/>'s
    /// answer, at the projector's tolerance.</summary>
    public PointFoot? ClosestPoint(double[] p, double? maxDistance = null)
    {
        var found = BlacksmithNative.cadaclysm_blacksmith_projector_closest_point(_handle, Blacksmith.Point(p, "projector_closest_point"),
            maxDistance ?? double.NaN, out var raw);
        if (found < 0) throw Blacksmith.Failure("projector_closest_point");
        return found == 0 ? null : new PointFoot(raw);
    }

    /// <summary>The nearest points of <paramref name="curve"/> and the body's boundary, or null
    /// beyond <paramref name="maxDistance"/> (null, NaN or +inf: no limit) --
    /// <see cref="Solid.CurveClosestPoints"/>'s answer, at the projector's tolerance. The
    /// projector's lock is held for the whole curve query: other threads asking it wait.</summary>
    public CurveBodyFoot? CurveClosestPoints(NurbsCurve curve, double? maxDistance = null)
    {
        ArgumentNullException.ThrowIfNull(curve);
        var found = BlacksmithNative.cadaclysm_blacksmith_projector_curve_closest_points(_handle, curve.Handle,
            maxDistance ?? double.NaN, out var raw);
        if (found < 0) throw Blacksmith.Failure("projector_curve_closest_points");
        return found == 0 ? null : new CurveBodyFoot(raw);
    }

    /// <summary>The handle, refusing a disposed projector at the call site.</summary>
    internal ProjectorHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Projector));
}

// ---- The R-tree -------------------------------------------------------------------------

/// <summary>A spatial index over boxes with ids (an R*-tree): <see cref="Search"/> a box for the
/// entries it meets, <see cref="Within"/> / <see cref="Nearest"/> a point for the closest,
/// <see cref="Overlaps"/> / <see cref="SelfOverlaps"/> for every pair of boxes that meet. Ids are
/// the caller's own and may repeat; an entry is an id and its box, and the same `(id, box)` twice
/// is two entries. Touching boxes meet. A box is a <see cref="Box"/>; a point (three numbers)
/// stands for a zero box. Answers come in a fixed order: search ids ascending, within / nearest
/// by distance then id, pairs ascending. The tree changes in place (<see cref="Insert(uint, Box)"/>,
/// <see cref="Remove(uint, Box)"/>); calls on one tree must not overlap from two threads.
/// <see cref="Dispose"/> frees it; so does the garbage collector. A call after it throws
/// <see cref="ObjectDisposedException"/> ("rtree: closed").</summary>
public sealed class RTree : IDisposable
{
    private readonly RTreeHandle _handle;

    /// <summary>An empty tree.</summary>
    public RTree() : this(BlacksmithNative.cadaclysm_blacksmith_rtree_new(), "rtree_new")
    {
    }

    internal RTree(RTreeHandle handle, string what)
    {
        _handle = Blacksmith.Checked(handle, what);
    }

    private RTreeHandle Live => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(RTree), "rtree: closed");

    /// <summary>A tree over <paramref name="entries"/> at once, packed (sort-tile-recursive):
    /// fuller and faster to query than the same entries inserted one by one. Throws
    /// <see cref="BuildException"/> for the first entry whose box is not a box (a NaN, an
    /// infinity, min above max), by index.</summary>
    public static RTree FromBoxes(IEnumerable<(uint Id, Box Box)> entries)
    {
        var all = entries.ToArray();
        var ids = new uint[all.Length];
        var flat = new double[6 * all.Length];
        for (var i = 0; i < all.Length; i++)
        {
            if (all[i].Box is null) throw new BuildException($"rtree_from_boxes: entry {i} has no box");
            ids[i] = all[i].Id;
            Array.Copy(Words(all[i].Box), 0, flat, 6 * i, 6);
        }
        return new RTree(BlacksmithNative.cadaclysm_blacksmith_rtree_from_boxes(ids, flat, (uint)all.Length), "rtree_from_boxes");
    }

    /// <summary>A tree over <paramref name="points"/> (three numbers each), each a zero box whose
    /// id is its index. Throws <see cref="BuildException"/> for the first point with a NaN or
    /// infinite coordinate, by index.</summary>
    public static RTree FromPoints(IEnumerable<double[]> points)
    {
        var flat = Blacksmith.PointsFlat(points, "rtree_from_points", "point");
        return new RTree(BlacksmithNative.cadaclysm_blacksmith_rtree_from_points(flat, (uint)(flat.Length / 3)), "rtree_from_points");
    }

    /// <summary>A tree over a mesh's triangles -- RhinoCommon's `RTree.CreateMeshFaceTree`: one
    /// entry per triangle of <paramref name="triangles"/> (three indices into
    /// <paramref name="positions"/>, three numbers each), its id the triangle's index, its box its
    /// three corners' box. Throws <see cref="BuildException"/> for the first corner past the points
    /// or at a point with a NaN or infinite coordinate, by triangle and point; points no triangle
    /// uses are not checked.</summary>
    public static RTree FromTriangles(IEnumerable<double[]> positions, IEnumerable<(uint A, uint B, uint C)> triangles)
    {
        var flat = Blacksmith.PointsFlat(positions, "rtree_from_triangles", "point");
        var indices = triangles.SelectMany(t => new[] { t.A, t.B, t.C }).ToArray();
        return new RTree(BlacksmithNative.cadaclysm_blacksmith_rtree_from_triangles(flat, (uint)(flat.Length / 3), indices, (uint)(indices.Length / 3)), "rtree_from_triangles");
    }

    public void Dispose() => _handle.Dispose();

    /// <summary>How many entries the tree holds.</summary>
    public int Count => (int)BlacksmithNative.cadaclysm_blacksmith_rtree_count(Live);

    /// <summary>The union of every entry's box, or null for an empty tree.</summary>
    public Box? Bounds
    {
        get
        {
            var h = Live;
            if (BlacksmithNative.cadaclysm_blacksmith_rtree_count(h) == 0) return null;
            var o = new double[6];
            if (!BlacksmithNative.cadaclysm_blacksmith_rtree_bounds(h, o)) throw Blacksmith.Failure("rtree_bounds");
            return new Box(new[] { o[0], o[1], o[2] }, new[] { o[3], o[4], o[5] });
        }
    }

    /// <summary>Add the entry `(id, box)`. Throws <see cref="BuildException"/>, leaving the tree
    /// as it was, for a box that is not a box.</summary>
    public void Insert(uint id, Box box)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_rtree_insert(Live, id, Words(box))) throw Blacksmith.Failure("rtree_insert");
    }

    /// <summary>Add the entry `(id, point)`, the point a zero box. Throws <see cref="BuildException"/>,
    /// leaving the tree as it was, for a point that is not finite.</summary>
    public void Insert(uint id, double[] point)
    {
        var p = Blacksmith.Point(point, "rtree_insert_point");
        if (!BlacksmithNative.cadaclysm_blacksmith_rtree_insert_point(Live, id, p)) throw Blacksmith.Failure("rtree_insert_point");
    }

    /// <summary>Take out one entry equal to `(id, box)` -- the box it was inserted with, compared
    /// coordinate by coordinate -- and say whether there was one: false, not an error, when there
    /// is none. With duplicates, one goes per call. Throws <see cref="BuildException"/> for a box
    /// that is not a box.</summary>
    public bool Remove(uint id, Box box) => RemoveWords(id, Words(box));

    /// <summary><see cref="Remove(uint, Box)"/> for an entry inserted as a point (its zero box).</summary>
    public bool Remove(uint id, double[] point)
    {
        var p = Blacksmith.Point(point, "rtree_remove");
        return RemoveWords(id, new[] { p[0], p[1], p[2], p[0], p[1], p[2] });
    }

    private bool RemoveWords(uint id, double[] words)
    {
        if (BlacksmithNative.cadaclysm_blacksmith_rtree_remove(Live, id, words)) return true;
        if (Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("rtree_remove");
        return false;
    }

    /// <summary>The ids of every entry whose box meets <paramref name="box"/> (touching counts),
    /// ascending. Throws <see cref="BuildException"/> for a box that is not a box.</summary>
    public List<uint> Search(Box box) =>
        Hits(BlacksmithNative.cadaclysm_blacksmith_rtree_search(Live, Words(box)), "rtree_search").Select(h => h.Id).ToList();

    /// <summary>Every entry whose box is within <paramref name="r"/> of <paramref name="point"/>
    /// (Euclidean, 0 inside the box), by distance then id. Throws <see cref="BuildException"/> for
    /// a point not finite or an <paramref name="r"/> negative or NaN.</summary>
    public List<RTreeHit> Within(double[] point, double r) =>
        Hits(BlacksmithNative.cadaclysm_blacksmith_rtree_within(Live, Blacksmith.Point(point, "rtree_within"), r), "rtree_within");

    /// <summary>The <paramref name="k"/> entries whose boxes are nearest <paramref name="point"/>,
    /// by distance then id (the smaller ids win a tie); all of them when k is over the count.
    /// Throws <see cref="BuildException"/> for a point not finite or a k above 1,000,000.</summary>
    public List<RTreeHit> Nearest(double[] point, uint k) =>
        Hits(BlacksmithNative.cadaclysm_blacksmith_rtree_nearest(Live, Blacksmith.Point(point, "rtree_nearest"), k), "rtree_nearest");

    /// <summary>Every entry whose box the ray `origin + t * direction`, `0 &lt;= t &lt;= maxT`,
    /// meets, as hits whose <see cref="RTreeHit.Distance"/> is the `t` where the ray enters the
    /// box (0 when <paramref name="origin"/> is inside it), by `t` then id. Touching counts. `t` is
    /// in units of <paramref name="direction"/>'s length, which is not normalised. Throws
    /// <see cref="BuildException"/> for an origin or direction not finite, a zero direction, or a
    /// <paramref name="maxT"/> negative or NaN.</summary>
    public List<RTreeHit> Ray(double[] origin, double[] direction, double maxT = double.PositiveInfinity) =>
        Hits(BlacksmithNative.cadaclysm_blacksmith_rtree_ray(Live, Blacksmith.Point(origin, "rtree_ray: origin"),
            Blacksmith.Point(direction, "rtree_ray: direction"), maxT), "rtree_ray");

    /// <summary>Every pair `(a, b)`, `a` an entry of this tree and `b` one of <paramref name="other"/>
    /// (which may be this tree), whose boxes are at most <paramref name="slack"/> apart on every
    /// axis, ascending. Throws <see cref="BuildException"/> for a slack negative or NaN.</summary>
    public List<RTreePair> Overlaps(RTree other, double slack = 0.0) =>
        Pairs(BlacksmithNative.cadaclysm_blacksmith_rtree_overlaps(Live, other.Live, slack), "rtree_overlaps");

    /// <summary>Every unordered pair of distinct entries at most <paramref name="slack"/> apart,
    /// once each as `(smaller id, larger id)`, ascending. Throws <see cref="BuildException"/> for a
    /// slack negative or NaN.</summary>
    public List<RTreePair> SelfOverlaps(double slack = 0.0) =>
        Pairs(BlacksmithNative.cadaclysm_blacksmith_rtree_self_overlaps(Live, slack), "rtree_self_overlaps");

    public override string ToString() => _handle.IsClosed ? "RTree(closed)" : $"RTree({Count} entries)";

    private static double[] Words(Box box) => new[] { box.Lo[0], box.Lo[1], box.Lo[2], box.Hi[0], box.Hi[1], box.Hi[2] };

    /// <summary>The hits list a query returned, read and freed on every path; null is the
    /// query's refusal, named `what`.</summary>
    private static List<RTreeHit> Hits(IntPtr list, string what)
    {
        if (list == IntPtr.Zero) throw Blacksmith.Failure(what);
        try
        {
            var n = BlacksmithNative.cadaclysm_blacksmith_rtree_hits_count(list);
            var found = new List<RTreeHit>((int)Math.Min(n, 1024u));
            for (uint i = 0; i < n; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_rtree_hits_at(list, i, out var raw)) throw Blacksmith.Failure("rtree_hits_at");
                found.Add(new RTreeHit(raw.Id, raw.Distance));
            }
            return found;
        }
        finally { BlacksmithNative.cadaclysm_blacksmith_rtree_hits_free(list); }
    }

    /// <summary>The pairs list a query returned, read and freed on every path.</summary>
    private static List<RTreePair> Pairs(IntPtr list, string what)
    {
        if (list == IntPtr.Zero) throw Blacksmith.Failure(what);
        try
        {
            var n = BlacksmithNative.cadaclysm_blacksmith_rtree_pairs_count(list);
            var found = new List<RTreePair>((int)Math.Min(n, 1024u));
            for (uint i = 0; i < n; i++)
            {
                if (!BlacksmithNative.cadaclysm_blacksmith_rtree_pairs_at(list, i, out var raw)) throw Blacksmith.Failure("rtree_pairs_at");
                found.Add(new RTreePair(raw.A, raw.B));
            }
            return found;
        }
        finally { BlacksmithNative.cadaclysm_blacksmith_rtree_pairs_free(list); }
    }
}

// ---- Regions ------------------------------------------------------------------------------

/// <summary>One side of one face (<see cref="Solid.Regions"/>): <see cref="Face"/> the face's index
/// in the solid, <see cref="Sense"/> +1 for the side its normal points to, -1 for the other. A
/// solid's inside is behind its faces, at -1.</summary>
public sealed record FaceSide(int Face, int Sense)
{
    public override string ToString() => $"FaceSide({Face}, {Sense:+0;-0})";
}

/// <summary>One region of space a solid's faces bound (<see cref="Solid.Regions"/>): its
/// <see cref="Index"/> (0 the infinite region, whose <see cref="Finite"/> is false), the
/// <see cref="Box"/> round the faces bounding it, its <see cref="Sides"/> ascending by face then
/// sense, and its <see cref="Shells"/> -- 1, plus one per void inside it. Equal by value.
/// <see cref="Solid.RegionSolid"/> takes a finite one as a solid of its own.</summary>
public sealed record Region(int Index, bool Finite, Box Box, IReadOnlyList<FaceSide> Sides, int Shells)
{
    public bool Equals(Region? other) =>
        other is not null && Index == other.Index && Finite == other.Finite && Shells == other.Shells
        && Box.Lo.SequenceEqual(other.Box.Lo) && Box.Hi.SequenceEqual(other.Box.Hi) && Sides.SequenceEqual(other.Sides);

    public override int GetHashCode() => HashCode.Combine(Index, Finite, Shells, Sides.Count);

    public override string ToString() => $"Region({Index}, finite={Finite}, {Box}, {Sides.Count} sides, {Shells} shells)";
}

// ---- The interpolator ---------------------------------------------------------------------

/// <summary>How an <see cref="Interpolator"/> reads between samples: the C constants
/// `CADACLYSM_BLACKSMITH_INTERPOLATE_*`, in their order.</summary>
public enum InterpolatorMode : uint
{
    /// <summary>The sample at `floor(t + 1/2)`.</summary>
    Nearest = 0,
    /// <summary>Straight between the samples either side of `t`.</summary>
    Linear = 1,
    /// <summary>Linear on a cosine ease, flat at every sample.</summary>
    Cosine = 2,
    /// <summary>Bourke's cubic over the four samples about `t`.</summary>
    Cubic = 3,
    /// <summary>The Catmull-Rom spline over the four samples about `t`: through every sample, C1.</summary>
    CatmullRom = 4,
}

/// <summary>A list of samples read at a fractional index, as Rhino's `Interpolator`: `t = 2` is
/// sample 2, `t = 2.5` halfway between samples 2 and 3. Samples are numbers (dimension 1) or
/// equal-length rows of numbers (any dimension, each component read on its own); every answer is
/// a `double[]` of <see cref="Dimension"/> numbers. An open list clamps `t` to `[0, Count - 1]`; a
/// cyclic one wraps `t` with period <see cref="Count"/>. It never changes after it is made.
/// <see cref="Dispose"/> frees it; so does the garbage collector. A call after it throws
/// <see cref="ObjectDisposedException"/> ("interpolator: closed").</summary>
public sealed class Interpolator : IDisposable
{
    private readonly InterpolatorHandle _handle;
    private readonly int _dimension;

    /// <summary>An interpolator over numbers (dimension 1). Throws <see cref="BuildException"/>
    /// for no samples or a sample NaN or infinite.</summary>
    public Interpolator(IEnumerable<double> samples, bool cyclic = false)
    {
        var flat = samples.ToArray();
        _dimension = 1;
        _handle = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_interpolator_new(flat, (uint)flat.Length, 1, cyclic), "interpolator_new");
    }

    /// <summary>An interpolator over rows of numbers, every row as long as the first (the
    /// dimension). Throws <see cref="ArgumentException"/> for rows of unequal length, before the
    /// call; <see cref="BuildException"/> for no samples or a sample NaN or infinite.</summary>
    public Interpolator(IEnumerable<double[]> samples, bool cyclic = false)
    {
        var rows = samples.ToArray();
        if (rows.Any(r => r is null)) throw new ArgumentException("interpolator: a sample is null");
        var dimension = rows.Length > 0 ? rows[0].Length : 1;
        if (rows.Any(r => r.Length != dimension))
            throw new ArgumentException($"interpolator: samples differ in length ([{string.Join(", ", rows.Select(r => r.Length).Distinct().OrderBy(n => n))}])");
        var flat = rows.SelectMany(r => r).ToArray();
        _dimension = dimension;
        _handle = Blacksmith.Checked(
            BlacksmithNative.cadaclysm_blacksmith_interpolator_new(flat, (uint)rows.Length, (uint)dimension, cyclic), "interpolator_new");
    }

    private InterpolatorHandle Live =>
        !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Interpolator), "interpolator: closed");

    public void Dispose() => _handle.Dispose();

    /// <summary>How many samples.</summary>
    public int Count => (int)BlacksmithNative.cadaclysm_blacksmith_interpolator_count(Live);

    /// <summary>How many numbers per sample, and per answer.</summary>
    public int Dimension => (int)BlacksmithNative.cadaclysm_blacksmith_interpolator_dimension(Live);

    /// <summary>Whether `t` wraps round the list (else it is clamped to the ends).</summary>
    public bool Cyclic => BlacksmithNative.cadaclysm_blacksmith_interpolator_cyclic(Live);

    /// <summary>The value at the fractional index <paramref name="t"/> by <paramref name="mode"/>,
    /// <see cref="Dimension"/> numbers. Throws <see cref="BuildException"/> for a `t` NaN or
    /// infinite, or a mode not among the five.</summary>
    public double[] At(double t, InterpolatorMode mode = InterpolatorMode.Linear)
    {
        var h = Live;
        var o = new double[_dimension];
        if (!BlacksmithNative.cadaclysm_blacksmith_interpolator_at(h, t, (uint)mode, o, (uint)o.Length)) throw Blacksmith.Failure("interpolator_at");
        return o;
    }

    /// <summary>The values at every `t` of <paramref name="ts"/> by <paramref name="mode"/>, as
    /// <see cref="At"/> reads each, in one call (none for an empty `ts`). Throws
    /// <see cref="BuildException"/> for a value of `t` NaN or infinite (by its index) and more
    /// than 1,000,000 values.</summary>
    public double[][] Sample(IEnumerable<double> ts, InterpolatorMode mode = InterpolatorMode.Linear)
    {
        var h = Live;
        var values = ts.ToArray();
        if (values.Length == 0) return Array.Empty<double[]>();
        var d = _dimension;
        var flat = new double[checked(values.Length * d)];
        if (!BlacksmithNative.cadaclysm_blacksmith_interpolator_sample(h, values, (uint)values.Length, (uint)mode, flat, (uint)flat.Length))
            throw Blacksmith.Failure("interpolator_sample");
        var answers = new double[values.Length][];
        for (var k = 0; k < values.Length; k++) answers[k] = flat.AsSpan(k * d, d).ToArray();
        return answers;
    }

    /// <summary>The sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap.</summary>
    public double[] Nearest(double t) => At(t, InterpolatorMode.Nearest);

    /// <summary>Straight between the two samples either side of `t`.</summary>
    public double[] Linear(double t) => At(t, InterpolatorMode.Linear);

    /// <summary>Between the two samples either side of `t` on a cosine ease, flat at every sample.</summary>
    public double[] Cosine(double t) => At(t, InterpolatorMode.Cosine);

    /// <summary>Bourke's cubic over the four samples about `t`, through every sample.</summary>
    public double[] Cubic(double t) => At(t, InterpolatorMode.Cubic);

    /// <summary>The Catmull-Rom spline over the four samples about `t`: through every sample, C1.</summary>
    public double[] CatmullRom(double t) => At(t, InterpolatorMode.CatmullRom);

    public override string ToString() =>
        _handle.IsClosed ? "Interpolator(closed)" : $"Interpolator({Count} samples of {_dimension}{(Cyclic ? ", cyclic" : "")})";
}

// ---- The SubD cage ----------------------------------------------------------------------

/// <summary>An edge of a cage: its two vertex ids. <see cref="Subd.Creases"/> and <see
/// cref="Subd.EdgeLoop"/> answer them smaller id first.</summary>
public readonly record struct SubdEdge(uint A, uint B);

/// <summary>The plane a mirrored cage is the positive half across: perpendicular to this axis.
/// </summary>
public enum SubdAxis { X, Y, Z }

/// <summary>What kind of cage element a selection, or a <see cref="Subd.Pick"/>, names.</summary>
public enum SubdElements { Vertices, Edges, Faces }

/// <summary>Cage elements of one kind: vertex or face ids in <see cref="Ids"/>, or edges in
/// <see cref="Edges"/> (the other is empty). What the edit that made a cage touched, and what
/// <see cref="Subd.Transform"/> moves.</summary>
public sealed record SubdSelection(SubdElements Kind, uint[] Ids, SubdEdge[] Edges)
{
    public static SubdSelection OfVertices(params uint[] ids) => new(SubdElements.Vertices, ids, Array.Empty<SubdEdge>());
    public static SubdSelection OfEdges(params SubdEdge[] edges) => new(SubdElements.Edges, Array.Empty<uint>(), edges);
    public static SubdSelection OfFaces(params uint[] ids) => new(SubdElements.Faces, ids, Array.Empty<SubdEdge>());

    /// <summary>Equal when the kinds match and so does every id and edge, in order. A record
    /// would otherwise compare its arrays by reference, so no two selections read back would
    /// ever be equal.</summary>
    public bool Equals(SubdSelection? other) =>
        other is not null && Kind == other.Kind && Ids.SequenceEqual(other.Ids) && Edges.SequenceEqual(other.Edges);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Kind);
        foreach (var id in Ids) hash.Add(id);
        foreach (var edge in Edges) hash.Add(edge);
        return hash.ToHashCode();
    }

    public override string ToString() => Kind == SubdElements.Edges
        ? $"SubdSelection(Edges, [{string.Join(", ", Edges.Select(e => $"({e.A}, {e.B})"))}])"
        : $"SubdSelection({Kind}, [{string.Join(", ", Ids)}])";
}

/// <summary>One level of a cage's smooth surface, as <see cref="Subd.SmoothMesh"/> returns it,
/// copied out of the cage so it outlives it. <see cref="Positions"/> and <see cref="Normals"/>
/// are `3n` doubles -- limit positions and unit outward limit normals; <see cref="Indices"/> is
/// three vertex ids a triangle; <see cref="TriangleFace"/> is one entry a triangle: the face of
/// the **full** cage it lies on (on a mirrored half, face `f` of the half is `f` and its
/// reflection `f` plus the half's face count).</summary>
public sealed class SubdMesh
{
    public double[] Positions { get; }
    public double[] Normals { get; }
    public uint[] Indices { get; }
    public uint[] TriangleFace { get; }

    internal SubdMesh(RawBlacksmithSubdMesh raw)
    {
        Positions = Blacksmith.CopyOf<double>(raw.Positions, 3 * raw.VertexCount);
        Normals = Blacksmith.CopyOf<double>(raw.Normals, 3 * raw.VertexCount);
        Indices = Blacksmith.CopyOf<uint>(raw.Indices, raw.IndexCount);
        TriangleFace = Blacksmith.CopyOf<uint>(raw.TriangleFace, raw.IndexCount / 3);
    }

    public override string ToString() => $"SubdMesh(vertices={Positions.Length / 3}, triangles={Indices.Length / 3})";
}

/// <summary>What <see cref="Subd.ToSolid"/> did and how close it came: <see cref="Regular"/>
/// patches exact from their own net and <see cref="Refined"/> ones from a refined neighbourhood;
/// the Catmull-Clark <see cref="Steps"/> taken first (1 or 2); <see cref="Levels"/>, the deepest
/// local refinement a patch took (0 when none was refined); the largest <see cref="Deviation"/>
/// from the limit surface, as a fraction of the cage's bounding-box diagonal; the largest tangent
/// break <see cref="G1AngleDeg"/> across a side that is not creased, in degrees; and the world
/// points they were measured at, <see cref="DeviationAt"/> and <see cref="G1At"/>.</summary>
public sealed class SubdReport
{
    public uint Regular { get; }
    public uint Refined { get; }
    public uint Steps { get; }
    public uint Levels { get; }
    public double Deviation { get; }
    public double G1AngleDeg { get; }
    public double[] DeviationAt { get; }
    public double[] G1At { get; }

    internal unsafe SubdReport(RawBlacksmithSubdReport raw)
    {
        Regular = raw.Regular;
        Refined = raw.Refined;
        Steps = raw.Steps;
        Levels = raw.Levels;
        Deviation = raw.Deviation;
        G1AngleDeg = raw.G1AngleDeg;
        DeviationAt = new[] { raw.DeviationAt[0], raw.DeviationAt[1], raw.DeviationAt[2] };
        G1At = new[] { raw.G1At[0], raw.G1At[1], raw.G1At[2] };
    }

    public override string ToString() =>
        $"SubdReport(regular={Regular}, refined={Refined}, steps={Steps}, levels={Levels}, deviation={Deviation}, g1AngleDeg={G1AngleDeg}, " +
        $"deviationAt=({string.Join(", ", DeviationAt)}), g1At=({string.Join(", ", G1At)}))";
}

/// <summary>A Catmull-Clark control cage: positions (`3n` doubles), faces, creased edges, pinned
/// vertices, an optional mirror plane, and the selection of the edit that made it. Immutable:
/// every edit returns a new <see cref="Subd"/>, with <see cref="Selection"/> naming what that
/// edit touched, and leaves this one as it was. <see cref="ToSolid"/> turns it into an exact
/// B-rep. <see cref="Dispose"/> frees this handle; so does the garbage collector. A refusal
/// throws <see cref="BuildException"/> with the kernel's own words; a use after
/// <see cref="Dispose"/> throws <see cref="ObjectDisposedException"/>.</summary>
public sealed class Subd : IDisposable
{
    private readonly SubdHandle _handle;

    internal Subd(SubdHandle handle)
    {
        _handle = Blacksmith.Checked(handle, "subd");
    }

    internal SubdHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Subd), "subd: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the cage back. Idempotent. A <see cref="SubdMesh"/> already read owns its
    /// own copy and reads on.</summary>
    public void Dispose() => _handle.Dispose();

    // -- the primitives

    /// <summary>A box of `size` (default 2 x 2 x 2), centred on the origin, with `segments`
    /// quads along each axis (default 1 x 1 x 1; 1 to 1024).</summary>
    public static Subd Cuboid((double X, double Y, double Z)? size = null, (uint X, uint Y, uint Z)? segments = null)
    {
        var (sx, sy, sz) = size ?? (2.0, 2.0, 2.0);
        var (nx, ny, nz) = segments ?? (1u, 1u, 1u);
        return new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_cuboid(sx, sy, sz, nx, ny, nz));
    }

    /// <summary>A cylinder along +Z: one n-gon cap per end with `sides` sides and `rings` bands of
    /// quads between them; with <paramref name="creasedRims"/> the two rim loops are creased, so
    /// the caps stay flat. The rims are creased by default, which is what converts: an uncreased
    /// cylinder of 7 or more sides is refused by <see cref="ToSolid"/> at the default tolerances.
    /// </summary>
    public static Subd Cylinder(double radius = 1.0, double height = 2.0, uint sides = 8, uint rings = 1, bool creasedRims = true) =>
        new(BlacksmithNative.cadaclysm_blacksmith_subd_cylinder(radius, height, sides, rings, creasedRims));

    /// <summary>A quad ball of `radius`: a cube grid with `segments` quads per edge, each vertex
    /// pushed out to the radius.</summary>
    public static Subd Sphere(double radius = 1.0, uint segments = 2) =>
        new(BlacksmithNative.cadaclysm_blacksmith_subd_sphere(radius, segments));

    /// <summary>A torus around +Z: `around` steps about the axis at `major`, `tube` steps round
    /// the tube of `minor`, all quads.</summary>
    public static Subd Torus(double major = 3.0, double minor = 1.0, uint around = 12, uint tube = 8) =>
        new(BlacksmithNative.cadaclysm_blacksmith_subd_torus(major, minor, around, tube));

    /// <summary>A cage from its parts, the lossless inverse of reading them back: `positions`
    /// (`3n` doubles), `faces` lists of vertex ids, `creases` edges, `pins` vertex ids, and
    /// `symmetry` null or the axis and tolerance of a mirrored half, as <see cref="Symmetry"/>
    /// reports it. The new cage selects nothing.</summary>
    public static Subd FromParts(double[] positions, uint[][] faces, IEnumerable<SubdEdge>? creases = null, IEnumerable<uint>? pins = null,
        (SubdAxis Axis, double Tolerance)? symmetry = null)
    {
        if (positions.Length % 3 != 0) throw new BuildException($"from_parts: positions are three numbers a point, not {positions.Length}");
        var sizes = faces.Select(f => (uint)f.Length).ToArray();
        var loop = faces.SelectMany(f => f).ToArray();
        var crease = Flat(creases ?? Array.Empty<SubdEdge>());
        var pin = (pins ?? Array.Empty<uint>()).ToArray();
        var (axis, tolerance) = symmetry is { } s ? (CheckedAxis(s.Axis, "from_parts symmetry"), s.Tolerance) : (-1, 0.0);
        return new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_from_parts(positions, (uint)(positions.Length / 3), sizes, (uint)sizes.Length,
            loop, (uint)loop.Length, crease, (uint)(crease.Length / 2), pin, (uint)pin.Length, axis, tolerance));
    }

    private static uint[] Flat(IEnumerable<SubdEdge> edges)
    {
        var flat = new List<uint>();
        foreach (var e in edges) { flat.Add(e.A); flat.Add(e.B); }
        return flat.ToArray();
    }

    private static int CheckedAxis(SubdAxis axis, string what) =>
        Enum.IsDefined(axis) ? (int)axis : throw new BuildException($"{what}: axis must be X, Y or Z, not {axis}");

    // -- the parts

    /// <summary>`read(parts)` over this cage's parts while their views are alive.</summary>
    private T Parts<T>(Func<RawBlacksmithSubdParts, T> read)
    {
        var h = Handle;
        if (!BlacksmithNative.cadaclysm_blacksmith_subd_parts(h, out var raw)) throw Blacksmith.Failure("subd_parts");
        var answer = read(raw);
        GC.KeepAlive(h);
        return answer;
    }

    /// <summary>The cage's vertices, `3n` doubles of your own: a copy.</summary>
    public double[] Positions => Parts(p => Blacksmith.CopyOf<double>(p.Positions, 3 * p.VertexCount));

    /// <summary>Each face's vertex ids, in loop order.</summary>
    public uint[][] Faces => Parts(p =>
    {
        var sizes = Blacksmith.CopyOf<uint>(p.FaceSizes, p.FaceCount);
        var loop = Blacksmith.CopyOf<uint>(p.FaceIndices, p.IndexCount);
        var faces = new uint[sizes.Length][];
        var at = 0;
        for (var k = 0; k < sizes.Length; k++)
        {
            faces[k] = loop.AsSpan(at, (int)sizes[k]).ToArray();
            at += (int)sizes[k];
        }
        return faces;
    });

    /// <summary>The creased edges, each smaller id first, sorted.</summary>
    public SubdEdge[] Creases => Parts(p => Edges(Blacksmith.CopyOf<uint>(p.Creases, 2 * p.CreaseCount)));

    /// <summary>The pinned vertices: they refine as corners and stay put.</summary>
    public uint[] Pins => Parts(p => Blacksmith.CopyOf<uint>(p.Pins, p.PinCount));

    /// <summary>Null for an ordinary cage; for a mirrored half the plane's axis and how far from
    /// it a vertex counts as on it.</summary>
    public (SubdAxis Axis, double Tolerance)? Symmetry => Parts<(SubdAxis, double)?>(p =>
        p.SymmetryAxis < 0 ? null : ((SubdAxis)p.SymmetryAxis, p.SymmetryTolerance));

    /// <summary>What the edit that made this cage touched; null for a cage no edit selected (a
    /// primitive, <see cref="FromParts"/>, the mirror calls).</summary>
    public SubdSelection? Selection => Parts(p =>
    {
        if (p.SelectionKind > 2) return null;
        if (p.SelectionKind == 1)
            return SubdSelection.OfEdges(Edges(Blacksmith.CopyOf<uint>(p.Selection, 2 * p.SelectionCount)));
        var ids = Blacksmith.CopyOf<uint>(p.Selection, p.SelectionCount);
        return p.SelectionKind == 0 ? SubdSelection.OfVertices(ids) : SubdSelection.OfFaces(ids);
    });

    private static SubdEdge[] Edges(uint[] flat)
    {
        var edges = new SubdEdge[flat.Length / 2];
        for (var k = 0; k < edges.Length; k++) edges[k] = new SubdEdge(flat[2 * k], flat[2 * k + 1]);
        return edges;
    }

    // -- the edits

    /// <summary>A new cage with the selected elements moved by <paramref name="matrix"/>: sixteen
    /// numbers, column-major; a rotation about a point is baked in by the caller. The new cage
    /// selects the same elements.</summary>
    public Subd Transform(SubdSelection selection, double[] matrix)
    {
        if (!Enum.IsDefined(selection.Kind)) throw new BuildException($"transform: kind must be Vertices, Edges or Faces, not {selection.Kind}");
        if (matrix.Length != 16) throw new BuildException($"transform matrix: expected 16 numbers, got {matrix.Length}");
        var ids = selection.Kind == SubdElements.Edges ? Flat(selection.Edges) : selection.Ids;
        var count = (uint)(selection.Kind == SubdElements.Edges ? ids.Length / 2 : ids.Length);
        return new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_transform(Handle, (uint)selection.Kind, ids, count, matrix));
    }

    /// <summary>A new cage with <paramref name="edges"/> creased, or un-creased when <paramref
    /// name="on"/> is false; it selects them.</summary>
    public Subd Crease(IEnumerable<SubdEdge> edges, bool on = true)
    {
        var flat = Flat(edges);
        return new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_set_crease(Handle, flat, (uint)(flat.Length / 2), on));
    }

    /// <summary>A new cage with <paramref name="vertices"/> pinned (they refine as corners and
    /// stay put), or released when <paramref name="on"/> is false; it selects them.</summary>
    public Subd Pin(IEnumerable<uint> vertices, bool on = true)
    {
        var ids = vertices.ToArray();
        return new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_set_pin(Handle, ids, (uint)ids.Length, on));
    }

    /// <summary>A new cage with <paramref name="faces"/> pushed out by <paramref name="distance"/>
    /// along each connected region's average normal, a quad wall on each boundary edge; the moved
    /// faces keep their ids and the new cage selects them.</summary>
    public Subd Extrude(IEnumerable<uint> faces, double distance)
    {
        var ids = faces.ToArray();
        return new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_extrude(Handle, ids, (uint)ids.Length, distance));
    }

    /// <summary>A new cage with <paramref name="faces"/> shrunk by <paramref name="amount"/>, in
    /// (0, 1), within their surface and a ring of quads round each region (each face, with
    /// <paramref name="individual"/>); the new cage selects the inner faces.</summary>
    public Subd Inset(IEnumerable<uint> faces, double amount, bool individual = false)
    {
        var ids = faces.ToArray();
        return new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_inset(Handle, ids, (uint)ids.Length, amount, individual));
    }

    /// <summary>A new cage with <paramref name="faces"/> subdivided once by the Catmull-Clark
    /// rules (the whole cage when no faces are given): each face becomes quads round a new
    /// point, and an unpicked face beside them takes the new edge points as corners. The whole
    /// cage keeps its smooth surface exactly. The new cage selects the new faces.</summary>
    public Subd Subdivide(IEnumerable<uint>? faces = null)
    {
        var ids = faces?.ToArray() ?? Array.Empty<uint>();
        return new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_subdivide(Handle, ids, (uint)ids.Length));
    }

    /// <summary>A new cage with a loop of edges cut across the ring of quads through <paramref
    /// name="edge"/>, at `a + at * (b - a)` with <paramref name="at"/> in (0, 1); it selects the
    /// new loop.</summary>
    public Subd InsertLoop(SubdEdge edge, double at = 0.5) =>
        new(BlacksmithNative.cadaclysm_blacksmith_subd_insert_loop(Handle, edge.A, edge.B, at));

    /// <summary>The loop of edges through <paramref name="edge"/>, straight across each
    /// valence-four vertex, the picked edge first, each smaller id first; empty when it is not an
    /// edge of the cage.</summary>
    public SubdEdge[] EdgeLoop(SubdEdge edge)
    {
        using var looped = new Subd(BlacksmithNative.cadaclysm_blacksmith_subd_edge_loop(Handle, edge.A, edge.B));
        return looped.Selection?.Edges ?? Array.Empty<SubdEdge>();
    }

    /// <summary>The positive half of the cage across the plane perpendicular to <paramref
    /// name="axis"/> as a mirrored cage: every later edit keeps it symmetric.</summary>
    public Subd MirrorOn(SubdAxis axis) =>
        new(BlacksmithNative.cadaclysm_blacksmith_subd_mirror_on(Handle, (uint)CheckedAxis(axis, "mirror_on")));

    /// <summary>The mirror baked: the whole cage as an ordinary one, no longer mirrored.</summary>
    public Subd MirrorOff() => new(BlacksmithNative.cadaclysm_blacksmith_subd_mirror_off(Handle));

    /// <summary>The whole cage of a mirrored half -- the half's vertices first, then the
    /// reflections of those off the plane -- or a copy of an ordinary cage.</summary>
    public Subd Full() => new(BlacksmithNative.cadaclysm_blacksmith_subd_full(Handle));

    // -- the surface

    /// <summary>The smooth surface refined <paramref name="levels"/> times (1 to 6), as a
    /// <see cref="SubdMesh"/> of copies.</summary>
    public SubdMesh SmoothMesh(uint levels = 3)
    {
        var h = Handle;
        if (!BlacksmithNative.cadaclysm_blacksmith_subd_smooth_mesh(h, levels, out var raw)) throw Blacksmith.Failure("subd_smooth_mesh");
        var mesh = new SubdMesh(raw);
        GC.KeepAlive(h);
        return mesh;
    }

    /// <summary>The cage element of <paramref name="kind"/> under <paramref name="point"/> (three
    /// numbers), a point on or near the smooth surface: a vertex or face id, or an edge with the
    /// smaller id first, as a one-element <see cref="SubdSelection"/>. Null when nothing is within
    /// 0.05 of the cage's diagonal -- not an error.</summary>
    public SubdSelection? Pick(double[] point, SubdElements kind)
    {
        if (point.Length != 3) throw new BuildException($"pick point: expected 3 numbers, got {point.Length}");
        if (!Enum.IsDefined(kind)) throw new BuildException($"pick: kind must be Vertices, Edges or Faces, not {kind}");
        var found = new uint[2];
        if (!BlacksmithNative.cadaclysm_blacksmith_subd_pick(Handle, point, (uint)kind, found))
        {
            if (Blacksmith.LastError().Length == 0) return null;
            throw Blacksmith.Failure("subd_pick");
        }
        return kind switch
        {
            SubdElements.Edges => SubdSelection.OfEdges(new SubdEdge(found[0], found[1])),
            SubdElements.Faces => SubdSelection.OfFaces(found[0]),
            _ => SubdSelection.OfVertices(found[0]),
        };
    }

    /// <summary>The cage as an exact solid, one NURBS face per patch, that every solid call takes,
    /// and a <see cref="SubdReport"/> of what the conversion did. <paramref name="tolerance"/> is
    /// the largest deviation from the limit surface as a fraction of the cage's diagonal,
    /// <paramref name="g1Angle"/> the largest tangent break across an uncreased side in degrees,
    /// <paramref name="maxLevels"/> the deepest local refinement (2 to 6). A tolerance or angle of
    /// 0 or less, or a <paramref name="maxLevels"/> of 0, takes the default; any other
    /// <paramref name="maxLevels"/> outside 2 to 6 is refused. A cage that cannot be held within
    /// them is refused with the figures it measured.</summary>
    public (Solid Solid, SubdReport Report) ToSolid(double tolerance = 1e-4, double g1Angle = 0.1, uint maxLevels = 6)
    {
        var h = Handle;
        var handle = BlacksmithNative.cadaclysm_blacksmith_subd_to_solid(h, tolerance, g1Angle, maxLevels, out var raw);
        GC.KeepAlive(h);
        var solid = new Solid(handle);
        return (solid, new SubdReport(raw));
    }
}

// ---- the 2D constraint sketcher ------------------------------------------------------------

/// <summary>What a solve did (<see cref="Sketch.Solve"/>, <see cref="Sketch.Drag"/>,
/// <see cref="Sketch.SetValue"/>, <see cref="Sketch.SetDriving"/>, <see cref="Sketch.UpdateReference"/>):
/// its <see cref="Status"/> ("converged", "conflicting" or "diverged"), how many
/// <see cref="Iterations"/>, the largest constraint residual left (<see cref="MaxResidual"/>), and
/// <see cref="Ids"/>: the constraints a conflict ran into, or the worst ones of a diverged solve
/// (empty when it converged). Plain data.</summary>
public sealed class SolveReport
{
    public string Status { get; }
    public int Iterations { get; }
    public double MaxResidual { get; }
    public IReadOnlyList<uint> Ids { get; }

    internal SolveReport(string status, int iterations, double maxResidual, IReadOnlyList<uint> ids)
    {
        Status = status;
        Iterations = iterations;
        MaxResidual = maxResidual;
        Ids = ids;
    }

    /// <summary>Whether <see cref="Status"/> is "converged".</summary>
    public bool Converged => Status == "converged";

    public override string ToString() =>
        $"SolveReport(status={Status}, iterations={Iterations}, maxResidual={MaxResidual}, ids=[{string.Join(", ", Ids)}])";
}

/// <summary>One independent part of a diagnosed sketch: its <see cref="Params"/> (unknowns), how many
/// stay <see cref="Free"/>, its <see cref="State"/> ("under", "full" or "over"), its
/// <see cref="Constraints"/>, the <see cref="Redundant"/> and <see cref="Conflicting"/> ones among them,
/// and its <see cref="FreeEntities"/>. Plain data.</summary>
public sealed class PartDof
{
    public int Params { get; }
    public int Free { get; }
    public string State { get; }
    public IReadOnlyList<uint> Constraints { get; }
    public IReadOnlyList<uint> Redundant { get; }
    public IReadOnlyList<uint> Conflicting { get; }
    public IReadOnlyList<uint> FreeEntities { get; }

    internal PartDof(int parameters, int free, string state, IReadOnlyList<uint> constraints, IReadOnlyList<uint> redundant,
        IReadOnlyList<uint> conflicting, IReadOnlyList<uint> freeEntities)
    {
        Params = parameters;
        Free = free;
        State = state;
        Constraints = constraints;
        Redundant = redundant;
        Conflicting = conflicting;
        FreeEntities = freeEntities;
    }

    public override string ToString() => $"PartDof(params={Params}, free={Free}, state={State})";
}

/// <summary>A sketch's degrees of freedom (<see cref="Sketch.Diagnose"/>): how many are
/// <see cref="Free"/>, its <see cref="State"/> ("under", "full" or "over"), the
/// <see cref="Redundant"/> and <see cref="Conflicting"/> constraint ids, the <see cref="FreeEntities"/>
/// (entities that can still move), and the independent <see cref="Parts"/> it splits into.
/// Plain data.</summary>
public sealed class Dof
{
    public int Free { get; }
    public string State { get; }
    public IReadOnlyList<uint> Redundant { get; }
    public IReadOnlyList<uint> Conflicting { get; }
    public IReadOnlyList<uint> FreeEntities { get; }
    public IReadOnlyList<PartDof> Parts { get; }

    internal Dof(int free, string state, IReadOnlyList<uint> redundant, IReadOnlyList<uint> conflicting,
        IReadOnlyList<uint> freeEntities, IReadOnlyList<PartDof> parts)
    {
        Free = free;
        State = state;
        Redundant = redundant;
        Conflicting = conflicting;
        FreeEntities = freeEntities;
        Parts = parts;
    }

    public override string ToString() => $"Dof(free={Free}, state={State}, parts={Parts.Count})";
}

/// <summary>A 2D sketch of points, lines, circles, arcs and free curves held by geometric constraints
/// and dimensions, solved on request:
/// <code>
/// using var s = new Sketch();
/// var (corners, sides) = s.AddRect((0, 0), (40, 30));
/// s.Fix(corners[0]);
/// s.Length(sides[0], 60);
/// s.Solve();
/// using var plate = Solid.Extrude(s.Profiles()[0], Frame.Xy().ToArray(), 10);
/// </code>
/// Entities and constraints are named by <c>uint</c> ids. Entity kinds are "point", "line", "circle",
/// "arc" and "free_curve"; constraint kinds the snake_case names of the methods that add them
/// ("point_line_distance", ...) -- but for <see cref="RadiusOf"/>, whose kind is "radius", as in
/// Python. Senses are "auto", "positive" or "negative"; ends "start" or "end"; a name outside those is
/// refused with a <see cref="BuildException"/> naming the call and the parameter.
/// A refused call throws <see cref="BuildException"/> with the library's text and, as its
/// <see cref="BuildException.Ids"/>, the ids the refusal names (the constraints a new constraint, value or
/// reference conflicts with, the entities still using a point; empty when it names none). The
/// <see cref="SolveReport"/>s of <see cref="Solve"/>, <see cref="Drag"/>, <see cref="SetValue"/>,
/// <see cref="SetDriving"/> and <see cref="UpdateReference"/> carry a returned report's ids the same way.
/// <see cref="Dispose"/> frees the handle; so does the garbage collector. A use after
/// <see cref="Dispose"/> throws <see cref="ObjectDisposedException"/>.</summary>
public sealed class Sketch : IDisposable
{
    private static readonly string[] EntityKinds = { "point", "line", "circle", "arc", "free_curve" };
    private static readonly string[] ConstraintKinds =
    {
        "coincident", "point_on_line", "point_on_circle", "horizontal", "vertical", "parallel", "perpendicular",
        "collinear", "tangent", "tangent_at_end", "concentric", "equal_length", "equal_radius", "midpoint",
        "symmetric", "fix", "distance", "point_line_distance", "line_distance", "circle_line_distance",
        "circle_distance", "horizontal_distance", "vertical_distance", "length", "angle", "radius", "diameter",
    };
    private static readonly string[] SenseNames = { "auto", "positive", "negative" };
    private static readonly string[] EndNames = { "start", "end" };
    private static readonly string[] StatusNames = { "converged", "conflicting", "diverged" };
    private static readonly string[] StateNames = { "under", "full", "over" };
    // `sketch_dof_list`'s and `sketch_dof_part_list`'s `which`
    private const uint DofRedundant = 0, DofConflicting = 1, DofFreeEntities = 2;
    private const uint PartConstraints = 0, PartRedundant = 1, PartConflicting = 2, PartFreeEntities = 3;
    private const uint None = uint.MaxValue;

    private readonly SketchHandle _handle;

    /// <summary>A new, empty sketch.</summary>
    public Sketch()
    {
        _handle = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_sketch_new(), "sketch_new");
    }

    private Sketch(SketchHandle handle)
    {
        _handle = Blacksmith.Checked(handle, "sketch_from_profile");
    }

    internal SketchHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Sketch), "sketch: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the sketch back. Idempotent; the runtime does it for a sketch never disposed.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>A sketch of <paramref name="profile"/>'s lines, arcs and curves joined end to end, holes
    /// included; with <paramref name="infer"/> the obvious constraints (horizontal, vertical, tangent
    /// joints, ...) too. Ends within <paramref name="tolerance"/> count as joined.</summary>
    public static Sketch FromProfile(Profile profile, bool infer = true, double? tolerance = 1e-6) =>
        new(BlacksmithNative.cadaclysm_blacksmith_sketch_from_profile(profile.Handle, infer, Blacksmith.Tol(tolerance)));

    // -- helpers

    private uint[] Copied(IntPtr at, nuint count, string what)
    {
        if (at == IntPtr.Zero) throw Blacksmith.Failure(what);
        var copy = Blacksmith.CopyOf<uint>(at, checked((uint)count));   // before any other call on this sketch
        GC.KeepAlive(_handle);
        return copy;
    }

    /// <summary>The refusal of a call that can name ids: the reason first (read before any other call),
    /// then the ids `report_ids` holds.</summary>
    private BuildException Refused(string what)
    {
        var reason = Blacksmith.LastError();
        var at = BlacksmithNative.cadaclysm_blacksmith_sketch_report_ids(Handle, out var n);
        var ids = Blacksmith.CopyOf<uint>(at, checked((uint)n));
        GC.KeepAlive(_handle);
        return new BuildException(reason.Length > 0 ? reason : what, ids);
    }

    private IReadOnlyList<uint> ReportIds() =>
        Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_report_ids(Handle, out var n), n, "sketch_report_ids");

    private static uint Id(uint value, string what) => value != None ? value : throw Blacksmith.Failure(what);

    private static string Named(string[] table, uint code, string what) =>
        code != None && code < table.Length ? table[code] : throw Blacksmith.Failure(what);

    private static string Named(string[] table, int code, string what) =>
        code >= 0 && code < table.Length ? table[code] : throw Blacksmith.Failure(what);

    /// <summary>A count or code the library reports as a double, converted exactly: a whole number that
    /// fits an int, else an error naming the call (a NaN or a fraction never reads as a code).</summary>
    internal static int Exact(double value, string what)
    {
        if (double.IsNaN(value) || value != Math.Floor(value) || value < int.MinValue || value > int.MaxValue)
            throw new BuildException($"{what}: the library reported {value.ToString(System.Globalization.CultureInfo.InvariantCulture)}, which is not a whole number that fits an int");
        return (int)value;
    }

    /// <summary>The moves of a drag in ascending id order (the order the library is given); a point named
    /// twice is refused.</summary>
    internal static (uint[] Points, double[] Xy) DragOrder(IEnumerable<KeyValuePair<uint, (double X, double Y)>> moves)
    {
        var list = moves.OrderBy(m => m.Key).ToArray();
        for (var i = 1; i < list.Length; i++)
            if (list[i].Key == list[i - 1].Key) throw new BuildException($"sketch_drag: point {list[i].Key} given twice");
        return (list.Select(m => m.Key).ToArray(), list.SelectMany(m => new[] { m.Value.X, m.Value.Y }).ToArray());
    }

    private static uint Code(string[] table, string name, string call, string param)
    {
        var at = Array.IndexOf(table, name);
        if (at < 0)
            throw new BuildException($"{call}: {param} must be one of {string.Join(", ", table.Select(t => $"'{t}'"))}, not '{name}'");
        return (uint)at;
    }

    private static void Ok(bool done, string what)
    {
        if (!done) throw Blacksmith.Failure(what);
    }

    private SolveReport Solved(bool done, double[] report, string what)
    {
        if (!done) throw Refused(what);
        var ids = ReportIds();
        return new SolveReport(Named(StatusNames, Exact(report[0], what), what), Exact(report[1], what), report[2], ids);
    }

    // -- entities

    /// <summary>A free point at (<paramref name="x"/>, <paramref name="y"/>); a coordinate that is not finite is refused.</summary>
    public uint AddPoint(double x, double y)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_add_point(Handle, x, y);
        GC.KeepAlive(_handle);
        return Id(got, "sketch_add_point");
    }

    /// <summary>A line between the points <paramref name="a"/> and <paramref name="b"/>.</summary>
    public uint AddLine(uint a, uint b)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_add_line(Handle, a, b);
        GC.KeepAlive(_handle);
        return Id(got, "sketch_add_line");
    }

    /// <summary>A circle of radius <paramref name="r"/> about the point <paramref name="centre"/>.</summary>
    public uint AddCircle(uint centre, double r)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_add_circle(Handle, centre, r);
        GC.KeepAlive(_handle);
        return Id(got, "sketch_add_circle");
    }

    /// <summary>A counter-clockwise arc about the point <paramref name="centre"/> from the point
    /// <paramref name="start"/> to the point <paramref name="end"/>.</summary>
    public uint AddArc(uint centre, uint start, uint end)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_add_arc(Handle, centre, start, end);
        GC.KeepAlive(_handle);
        return Id(got, "sketch_add_arc");
    }

    /// <summary>A cubic Bezier free curve from the point <paramref name="start"/> through the controls
    /// <paramref name="c1"/> and <paramref name="c2"/> to a new end point at <paramref name="to"/>; the
    /// curve owns its control points.</summary>
    public uint AddBezier(uint start, (double X, double Y) c1, (double X, double Y) c2, (double X, double Y) to)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_add_bezier(Handle, start, c1.X, c1.Y, c2.X, c2.Y, to.X, to.Y);
        GC.KeepAlive(_handle);
        return Id(got, "sketch_add_bezier");
    }

    /// <summary>A rational quadratic (conic) free curve from the point <paramref name="start"/> with the
    /// control <paramref name="control"/> of <paramref name="weight"/> to a new end point at <paramref name="to"/>.</summary>
    public uint AddConic(uint start, (double X, double Y) control, (double X, double Y) to, double weight)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_add_conic(Handle, start, control.X, control.Y, to.X, to.Y, weight);
        GC.KeepAlive(_handle);
        return Id(got, "sketch_add_conic");
    }

    /// <summary>A NURBS free curve of <paramref name="degree"/> from the point <paramref name="start"/> through
    /// the control <paramref name="points"/> after it, on <paramref name="knots"/>; <paramref name="weights"/>
    /// null for a plain B-spline, or one per control point counting the start (`points.Count + 1`).</summary>
    public uint AddNurbs(uint start, IEnumerable<(double X, double Y)> points, IEnumerable<double> knots, uint degree = 3,
        IEnumerable<double>? weights = null)
    {
        var flat = new List<double>();
        foreach (var (x, y) in points) { flat.Add(x); flat.Add(y); }
        var n = flat.Count / 2;
        var knotList = knots.ToArray();
        // The library reads exactly `n + 1` weights whatever the list holds: check here.
        var w = weights?.ToArray();
        if (w is not null && w.Length != n + 1)
            throw new BuildException($"sketch_add_nurbs: {w.Length} weights for {n + 1} control points (the start and {n} given); give one per point");
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_add_nurbs(Handle, start, degree, flat.ToArray(), (nuint)n, w, knotList, (nuint)knotList.Length);
        GC.KeepAlive(_handle);
        return Id(got, "sketch_add_nurbs");
    }

    /// <summary>The rectangle with opposite corners <paramref name="a"/> and <paramref name="b"/>: its four
    /// corner points, counter-clockwise from <paramref name="a"/>, and its four sides (side `i` from
    /// corner `i`).</summary>
    public (uint[] Corners, uint[] Sides) AddRect((double X, double Y) a, (double X, double Y) b)
    {
        var ids = Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_add_rect(Handle, a.X, a.Y, b.X, b.Y, out var n), n, "sketch_add_rect");
        return (ids[..4], ids[4..]);
    }

    /// <summary>The kind of entity <paramref name="id"/>: "point", "line", "circle", "arc" or "free_curve".</summary>
    public string Kind(uint id)
    {
        var code = BlacksmithNative.cadaclysm_blacksmith_sketch_kind(Handle, id);
        GC.KeepAlive(_handle);
        return Named(EntityKinds, code, "sketch_kind");
    }

    /// <summary>The live entity ids, ascending.</summary>
    public uint[] Entities() => Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_entities(Handle, out var n), n, "sketch_entities");

    /// <summary>The point <paramref name="id"/>'s position.</summary>
    public (double X, double Y) Point(uint id)
    {
        var xy = new double[2];
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_point(Handle, id, xy);
        GC.KeepAlive(_handle);
        Ok(done, "sketch_point");
        return (xy[0], xy[1]);
    }

    /// <summary>Moves the point <paramref name="id"/> to (<paramref name="x"/>, <paramref name="y"/>) without solving.</summary>
    public void SetPoint(uint id, double x, double y)
    {
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_set_point(Handle, id, x, y);
        GC.KeepAlive(_handle);
        Ok(done, "sketch_set_point");
    }

    /// <summary>The radius of the circle or arc <paramref name="id"/> (the RADIUS constraint is <see cref="RadiusOf"/>).</summary>
    public double Radius(uint id)
    {
        var r = BlacksmithNative.cadaclysm_blacksmith_sketch_radius(Handle, id);
        GC.KeepAlive(_handle);
        return !double.IsNaN(r) ? r : throw Blacksmith.Failure("sketch_radius");
    }

    /// <summary>Sets the circle <paramref name="id"/>'s radius to <paramref name="r"/> without solving.</summary>
    public void SetRadius(uint id, double r)
    {
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_set_radius(Handle, id, r);
        GC.KeepAlive(_handle);
        Ok(done, "sketch_set_radius");
    }

    /// <summary>The centre point of the circle or arc <paramref name="id"/>.</summary>
    public uint Centre(uint id)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_centre(Handle, id);
        GC.KeepAlive(_handle);
        return Id(got, "sketch_centre");
    }

    /// <summary>The points entity <paramref name="id"/> runs between: a line's `[a, b]`, an arc's
    /// `[start, end]`, a free curve's `[start, controls..., end]`.</summary>
    public uint[] Ends(uint id) => Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_ends(Handle, id, out var n), n, "sketch_ends");

    /// <summary>Marks entity <paramref name="id"/> as construction geometry (kept out of profiles), or back.</summary>
    public void SetConstruction(uint id, bool on = true)
    {
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_set_construction(Handle, id, on);
        GC.KeepAlive(_handle);
        Ok(done, "sketch_set_construction");
    }

    /// <summary>Whether entity <paramref name="id"/> is construction geometry (false for an unknown id).</summary>
    public bool IsConstruction(uint id)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_is_construction(Handle, id);
        GC.KeepAlive(_handle);
        return got;
    }

    /// <summary>Whether entity <paramref name="id"/> is a reference copy of another sketch's (false for an unknown id).</summary>
    public bool IsReference(uint id)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_is_reference(Handle, id);
        GC.KeepAlive(_handle);
        return got;
    }

    /// <summary>Removes entity <paramref name="id"/> and the constraints on it: the removed constraint ids.
    /// Refused for a point that lines or circles still use.</summary>
    public uint[] RemoveEntity(uint id)
    {
        var at = BlacksmithNative.cadaclysm_blacksmith_sketch_remove_entity(Handle, id, out var n);
        if (at == IntPtr.Zero) throw Refused("sketch_remove_entity");
        return Copied(at, n, "sketch_remove_entity");
    }

    /// <summary>A fixed construction copy of <paramref name="other"/>'s entity <paramref name="entity"/>, kept in
    /// step by <see cref="UpdateReference"/>. <paramref name="other"/> must be another sketch.</summary>
    public uint Reference(Sketch other, uint entity)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_reference(Handle, other.Handle, entity);
        GC.KeepAlive(_handle);
        GC.KeepAlive(other._handle);
        return Id(got, "sketch_reference");
    }

    /// <summary>Refreshes the reference <paramref name="id"/> from <paramref name="other"/> and re-solves.</summary>
    public SolveReport UpdateReference(uint id, Sketch other)
    {
        var report = new double[3];
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_update_reference(Handle, id, other.Handle, report);
        GC.KeepAlive(_handle);
        GC.KeepAlive(other._handle);
        return Solved(done, report, "sketch_update_reference");
    }

    // -- constraints: each returns the new constraint's id

    private uint Constrain(string kind, uint[] refs, double value = 0.0, bool driving = true, string sense = "auto", string end = "start")
    {
        var senseCode = Code(SenseNames, sense, kind, "sense");
        var endCode = Code(EndNames, end, kind, "end");
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_constrain(Handle, (uint)Array.IndexOf(ConstraintKinds, kind), refs,
            (nuint)refs.Length, value, driving, senseCode, endCode);
        GC.KeepAlive(_handle);
        return got != None ? got : throw Refused("sketch_constrain");
    }

    public uint Coincident(uint a, uint b) => Constrain("coincident", new[] { a, b });

    public uint PointOnLine(uint point, uint line) => Constrain("point_on_line", new[] { point, line });

    /// <summary><paramref name="circle"/> a circle or an arc.</summary>
    public uint PointOnCircle(uint point, uint circle) => Constrain("point_on_circle", new[] { point, circle });

    /// <summary>The points <paramref name="a"/> and <paramref name="b"/> level with each other.</summary>
    public uint Horizontal(uint a, uint b) => Constrain("horizontal", new[] { a, b });

    /// <summary>The points <paramref name="a"/> and <paramref name="b"/> one above the other.</summary>
    public uint Vertical(uint a, uint b) => Constrain("vertical", new[] { a, b });

    public uint Parallel(uint a, uint b) => Constrain("parallel", new[] { a, b });

    public uint Perpendicular(uint a, uint b) => Constrain("perpendicular", new[] { a, b });

    public uint Collinear(uint a, uint b) => Constrain("collinear", new[] { a, b });

    public uint Tangent(uint a, uint b, string sense = "auto") => Constrain("tangent", new[] { a, b }, sense: sense);

    /// <summary>The free curve <paramref name="curve"/> tangent to <paramref name="other"/> at its
    /// <paramref name="end"/> ("start" or "end").</summary>
    public uint TangentAtEnd(uint curve, uint other, string end = "start") => Constrain("tangent_at_end", new[] { curve, other }, end: end);

    public uint Concentric(uint a, uint b) => Constrain("concentric", new[] { a, b });

    public uint EqualLength(uint a, uint b) => Constrain("equal_length", new[] { a, b });

    public uint EqualRadius(uint a, uint b) => Constrain("equal_radius", new[] { a, b });

    public uint Midpoint(uint point, uint line) => Constrain("midpoint", new[] { point, line });

    /// <summary>The points <paramref name="a"/> and <paramref name="b"/> mirror images across the line <paramref name="about"/>.</summary>
    public uint Symmetric(uint a, uint b, uint about) => Constrain("symmetric", new[] { a, b, about });

    public uint Fix(uint entity) => Constrain("fix", new[] { entity });

    public uint Distance(uint a, uint b, double value, bool driving = true) => Constrain("distance", new[] { a, b }, value, driving);

    public uint PointLineDistance(uint point, uint line, double value, bool driving = true, string sense = "auto") =>
        Constrain("point_line_distance", new[] { point, line }, value, driving, sense);

    public uint LineDistance(uint a, uint b, double value, bool driving = true, string sense = "auto") =>
        Constrain("line_distance", new[] { a, b }, value, driving, sense);

    public uint CircleLineDistance(uint circle, uint line, double value, bool driving = true, string sense = "auto") =>
        Constrain("circle_line_distance", new[] { circle, line }, value, driving, sense);

    public uint CircleDistance(uint a, uint b, double value, bool driving = true) => Constrain("circle_distance", new[] { a, b }, value, driving);

    public uint HorizontalDistance(uint a, uint b, double value, bool driving = true) =>
        Constrain("horizontal_distance", new[] { a, b }, value, driving);

    public uint VerticalDistance(uint a, uint b, double value, bool driving = true) =>
        Constrain("vertical_distance", new[] { a, b }, value, driving);

    public uint Length(uint line, double value, bool driving = true) => Constrain("length", new[] { line }, value, driving);

    /// <summary>The angle from line <paramref name="a"/> to line <paramref name="b"/>, in radians.</summary>
    public uint Angle(uint a, uint b, double value, bool driving = true) => Constrain("angle", new[] { a, b }, value, driving);

    /// <summary>The RADIUS dimension (kind "radius") -- <see cref="Radius"/> reads a radius instead.</summary>
    public uint RadiusOf(uint circle, double value, bool driving = true) => Constrain("radius", new[] { circle }, value, driving);

    public uint Diameter(uint circle, double value, bool driving = true) => Constrain("diameter", new[] { circle }, value, driving);

    /// <summary>The live constraint ids, ascending.</summary>
    public uint[] Constraints() => Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_constraints(Handle, out var n), n, "sketch_constraints");

    /// <summary>The kind of constraint <paramref name="id"/>, e.g. "point_line_distance".</summary>
    public string ConstraintKind(uint id)
    {
        var code = BlacksmithNative.cadaclysm_blacksmith_sketch_constraint_kind(Handle, id);
        GC.KeepAlive(_handle);
        return Named(ConstraintKinds, code, "sketch_constraint_kind");
    }

    /// <summary>The entity ids constraint <paramref name="id"/> was made on, in the order given.</summary>
    public uint[] ConstraintRefs(uint id) =>
        Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_constraint_refs(Handle, id, out var n), n, "sketch_constraint_refs");

    /// <summary>The value of the dimension <paramref name="id"/>; null for a constraint that is not a dimension.</summary>
    public double? ConstraintValue(uint id)
    {
        var v = BlacksmithNative.cadaclysm_blacksmith_sketch_constraint_value(Handle, id);
        GC.KeepAlive(_handle);
        if (!double.IsNaN(v)) return v;
        if (Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("sketch_constraint_value");
        return null;
    }

    /// <summary>Whether the dimension <paramref name="id"/> drives the geometry (false for a constraint that is
    /// not a dimension).</summary>
    public bool ConstraintDriving(uint id)
    {
        var driving = BlacksmithNative.cadaclysm_blacksmith_sketch_constraint_driving(Handle, id);
        GC.KeepAlive(_handle);
        if (!driving && Blacksmith.LastError().Length > 0) throw Blacksmith.Failure("sketch_constraint_driving");
        return driving;
    }

    /// <summary>The sense of constraint <paramref name="id"/>; "auto" for a kind without one.</summary>
    public string ConstraintSense(uint id)
    {
        var code = BlacksmithNative.cadaclysm_blacksmith_sketch_constraint_sense(Handle, id);
        GC.KeepAlive(_handle);
        return Named(SenseNames, code, "sketch_constraint_sense");
    }

    /// <summary>The end ("start" or "end") of the free curve a `tangent_at_end` constraint
    /// <paramref name="id"/> holds; "start" for a kind without one.</summary>
    public string ConstraintEnd(uint id)
    {
        var code = BlacksmithNative.cadaclysm_blacksmith_sketch_constraint_end(Handle, id);
        GC.KeepAlive(_handle);
        return Named(EndNames, code, "sketch_constraint_end");
    }

    /// <summary>Whether the tangent constraint <paramref name="id"/> joins two curves end to end.</summary>
    public bool IsJointTangent(uint id)
    {
        var got = BlacksmithNative.cadaclysm_blacksmith_sketch_is_joint_tangent(Handle, id);
        GC.KeepAlive(_handle);
        return got;
    }

    /// <summary>Removes the constraint <paramref name="id"/>.</summary>
    public void Remove(uint id)
    {
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_remove(Handle, id);
        GC.KeepAlive(_handle);
        Ok(done, "sketch_remove");
    }

    /// <summary>Sets the dimension <paramref name="id"/> to <paramref name="value"/> and re-solves.</summary>
    public SolveReport SetValue(uint id, double value)
    {
        var report = new double[3];
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_set_value(Handle, id, value, report);
        GC.KeepAlive(_handle);
        return Solved(done, report, "sketch_set_value");
    }

    /// <summary>Makes the dimension <paramref name="id"/> drive the geometry (true) or only report it, and re-solves.</summary>
    public SolveReport SetDriving(uint id, bool driving)
    {
        var report = new double[3];
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_set_driving(Handle, id, driving, report);
        GC.KeepAlive(_handle);
        return Solved(done, report, "sketch_set_driving");
    }

    /// <summary>What the geometry measures for the dimension <paramref name="id"/> right now.</summary>
    public double Measure(uint id)
    {
        var v = BlacksmithNative.cadaclysm_blacksmith_sketch_measure(Handle, id);
        GC.KeepAlive(_handle);
        return !double.IsNaN(v) ? v : throw Blacksmith.Failure("sketch_measure");
    }

    // -- solving and diagnosis

    /// <summary>Solves the sketch. A conflicting or diverged solve is reported, not thrown.</summary>
    public SolveReport Solve()
    {
        var report = new double[3];
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_solve(Handle, report);
        GC.KeepAlive(_handle);
        return Solved(done, report, "sketch_solve");
    }

    /// <summary>Drags each point id in <paramref name="moves"/> towards its (x, y) while the constraints hold, as a
    /// live gesture would. Refused for an id that is not a point. The moves go to the library in ascending
    /// id order; a point named twice is refused ("sketch_drag: point N given twice").</summary>
    public SolveReport Drag(IEnumerable<KeyValuePair<uint, (double X, double Y)>> moves)
    {
        var (points, xy) = DragOrder(moves);
        var report = new double[3];
        var done = BlacksmithNative.cadaclysm_blacksmith_sketch_drag(Handle, points, xy, (nuint)points.Length, report);
        GC.KeepAlive(_handle);
        return Solved(done, report, "sketch_drag");
    }

    /// <summary>The sketch's degrees of freedom, whole and per independent part.</summary>
    public Dof Diagnose()
    {
        var h = Handle;
        var output = new double[3];
        Ok(BlacksmithNative.cadaclysm_blacksmith_sketch_diagnose(h, output), "sketch_diagnose");
        var free = Exact(output[0], "sketch_diagnose");
        var state = Named(StateNames, Exact(output[1], "sketch_diagnose"), "sketch_diagnose");
        var partCount = Exact(output[2], "sketch_diagnose");
        var redundant = Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_dof_list(h, DofRedundant, out var n1), n1, "sketch_dof_list");
        var conflicting = Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_dof_list(h, DofConflicting, out var n2), n2, "sketch_dof_list");
        var freeEntities = Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_dof_list(h, DofFreeEntities, out var n3), n3, "sketch_dof_list");
        var parts = new List<PartDof>(partCount);
        var part = new double[3];
        for (var i = 0; i < partCount; i++)
        {
            Ok(BlacksmithNative.cadaclysm_blacksmith_sketch_dof_part(h, (uint)i, part), "sketch_dof_part");
            uint[] List(uint which) =>
                Copied(BlacksmithNative.cadaclysm_blacksmith_sketch_dof_part_list(h, (uint)i, which, out var n), n, "sketch_dof_part_list");
            var constraints = List(PartConstraints);
            var partRedundant = List(PartRedundant);
            var partConflicting = List(PartConflicting);
            var partFree = List(PartFreeEntities);
            parts.Add(new PartDof(Exact(part[0], "sketch_dof_part"), Exact(part[1], "sketch_dof_part"), Named(StateNames, Exact(part[2], "sketch_dof_part"), "sketch_dof_part"), constraints, partRedundant,
                partConflicting, partFree));
        }
        GC.KeepAlive(h);
        return new Dof(free, state, redundant, conflicting, freeEntities, parts);
    }

    /// <summary>The closed loops as profiles (nested loops become holes; construction geometry left out); ends
    /// within <paramref name="tolerance"/> join.</summary>
    public IReadOnlyList<Profile> Profiles(double? tolerance = 1e-6)
    {
        var list = BlacksmithNative.cadaclysm_blacksmith_sketch_profiles(Handle, Blacksmith.Tol(tolerance));
        GC.KeepAlive(_handle);
        return Profile.ProfileList(list, "sketch_profiles");
    }

    /// <summary>The paths that do not close, as profiles; ends within <paramref name="tolerance"/> join.</summary>
    public IReadOnlyList<Profile> OpenChains(double? tolerance = 1e-6)
    {
        var list = BlacksmithNative.cadaclysm_blacksmith_sketch_open_chains(Handle, Blacksmith.Tol(tolerance));
        GC.KeepAlive(_handle);
        return Profile.ProfileList(list, "sketch_open_chains");
    }
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

    /// <summary>The same plane facing the other way: x and y swapped, z reversed.</summary>
    public Frame Flipped() => new(Origin, Y, X, (-_v[9], -_v[10], -_v[11]));

    /// <summary>This frame turned `radians` about `axis` through its origin, right-handed
    /// (<see cref="Transform.Rotation"/>).</summary>
    public Frame Rotated(double radians, (double X, double Y, double Z) axis)
    {
        var r = Transform.Rotation(Origin, axis, radians).Rows;
        (double X, double Y, double Z) Turn((double X, double Y, double Z) d) =>
            (r[0] * d.X + r[1] * d.Y + r[2] * d.Z, r[4] * d.X + r[5] * d.Y + r[6] * d.Z, r[8] * d.X + r[9] * d.Y + r[10] * d.Z);
        return new Frame(Origin, Turn(X), Turn(Y), Turn(Z));
    }

    /// <summary>The point `p` in this frame's coordinates.</summary>
    public (double X, double Y, double Z) ToLocal((double X, double Y, double Z) p)
    {
        var d = (p.X - _v[0], p.Y - _v[1], p.Z - _v[2]);
        return (Dot(d, X), Dot(d, Y), Dot(d, Z));
    }

    /// <summary>How far `p` lies above the frame's plane, along its z: negative below.</summary>
    public double DistanceTo((double X, double Y, double Z) p) => Dot((p.X - _v[0], p.Y - _v[1], p.Z - _v[2]), Z);

    /// <summary>The point `p` dropped onto the frame's plane along its z.</summary>
    public (double X, double Y, double Z) ClosestPoint((double X, double Y, double Z) p)
    {
        var d = DistanceTo(p);
        return (p.X - d * _v[9], p.Y - d * _v[10], p.Z - d * _v[11]);
    }

    /// <summary>The least-squares plane through `points` (three or more, not all on one line)
    /// as a frame, and the largest distance any point lies off it. Fewer points, or points on
    /// one line, throw <see cref="BuildException"/>.</summary>
    public static (Frame Frame, double Deviation) Fit(IEnumerable<(double X, double Y, double Z)> points)
    {
        var xyz = ValueCalls.FlatPoints(points);
        var raw = new double[12];
        if (!BlacksmithNative.cadaclysm_blacksmith_frame_fit(xyz, (nuint)(xyz.Length / 3), raw, out var deviation))
            throw Blacksmith.Failure("frame_fit");
        return (Of(raw), deviation);
    }

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

/// <summary><see cref="Transform.DecomposeRigid"/>'s split: the map is `p -> Orthogonal(p) +
/// Translation`.</summary>
public sealed record RigidParts((double X, double Y, double Z) Translation, Transform Orthogonal);

/// <summary><see cref="Transform.DecomposeSimilarity"/>'s split: the map is
/// `p -> K * Orthogonal(p) + Translation`.</summary>
public sealed record SimilarityParts((double X, double Y, double Z) Translation, Transform Orthogonal, double K);

/// <summary><see cref="Transform.DecomposeAffine"/>'s polar split: the linear part is
/// `Rotation * Axes * diag(Stretch) * Axesᵀ` -- `Rotation` carrying the mirror, `Axes` a proper
/// rotation whose columns are the stretch directions, the stretches largest first.</summary>
public sealed record AffineParts((double X, double Y, double Z) Translation, Transform Rotation, Transform Axes,
    (double X, double Y, double Z) Stretch);

/// <summary>An affine map of space: a 4x4 matrix, row-major, its bottom row `0 0 0 1`.
/// Immutable, with nothing to free; converts to its 16 numbers, so it goes wherever 16 numbers
/// do. `a * b` (and <see cref="Compose"/>) is `a` after `b`. The constructors and the
/// decompositions are the library's own, so every wrapper computes them alike. A frame argument
/// is a <see cref="Frame"/> or its 12 numbers; one within 1e-6 of right-handed and orthonormal
/// is squared up, any other throws <see cref="BuildException"/>.</summary>
public sealed class Transform : IEquatable<Transform>
{
    /// <summary>How far from rigid, or from a similarity, a map may be and still be told one,
    /// by default.</summary>
    public const double MapTolerance = 1e-9;

    private static readonly double[] IdentityRows = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

    private readonly double[] _rows;

    /// <summary>The identity.</summary>
    public Transform() : this(IdentityRows) { }

    /// <summary>The map 16 numbers state, row-major. Throws <see cref="BuildException"/> for a
    /// wrong count, a value not finite, or a bottom row other than `0 0 0 1`.</summary>
    public Transform(double[] rows)
    {
        var got = rows?.Length ?? 0;
        if (rows is null || got != 16) throw new BuildException($"Transform: a matrix is 16 numbers, got {got}");
        var r = new double[16];
        for (var i = 0; i < 16; i++) r[i] = rows[i] + 0.0; // no -0.0 to print or compare
        if (!r.All(double.IsFinite)) throw new BuildException("Transform: not finite");
        if (r[12] != 0 || r[13] != 0 || r[14] != 0 || r[15] != 1)
            throw new BuildException("Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)");
        _rows = r;
    }

    /// <summary>The map 16 numbers state, row-major.</summary>
    public static Transform FromRows(double[] rows) => new(rows);

    /// <summary>The map four rows of four state.</summary>
    public static Transform FromRows(double[,] rows)
    {
        if (rows is null || rows.GetLength(0) != 4 || rows.GetLength(1) != 4)
            throw new BuildException($"Transform: a matrix is 16 numbers, got {rows?.Length ?? 0}");
        var flat = new double[16];
        for (var i = 0; i < 16; i++) flat[i] = rows[i / 4, i % 4];
        return new Transform(flat);
    }

    public static Transform Identity() => new();

    private static Transform Made(string what, Func<double[], bool> call)
    {
        var raw = new double[16];
        if (!call(raw)) throw Blacksmith.Failure(what);
        return new Transform(raw);
    }

    private static double[] Xyz((double X, double Y, double Z) p) => new[] { p.X, p.Y, p.Z };

    /// <summary>`p + v`.</summary>
    public static Transform Translation((double X, double Y, double Z) v) =>
        Made("transform_translation", raw => BlacksmithNative.cadaclysm_blacksmith_transform_translation(Xyz(v), raw));

    /// <summary>A turn of `radians` about the line through `point` along `direction`,
    /// right-handed.</summary>
    public static Transform Rotation((double X, double Y, double Z) point, (double X, double Y, double Z) direction, double radians) =>
        Made("transform_rotation", raw => BlacksmithNative.cadaclysm_blacksmith_transform_rotation(
            new[] { point.X, point.Y, point.Z, direction.X, direction.Y, direction.Z }, radians, raw));

    /// <summary>The reflection across `plane` (its z the normal).</summary>
    public static Transform Mirror(double[] plane) =>
        Made("transform_mirror", raw => BlacksmithNative.cadaclysm_blacksmith_transform_mirror(Blacksmith.Frame(plane), raw));

    /// <summary>A uniform scale by `k` about `centre`.</summary>
    public static Transform Scale((double X, double Y, double Z) centre, double k) =>
        Made("transform_scale", raw => BlacksmithNative.cadaclysm_blacksmith_transform_scale(Xyz(centre), k, raw));

    /// <summary>A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin.</summary>
    public static Transform ScaleXyz(double[] frame, double sx, double sy, double sz) =>
        Made("transform_scale_xyz", raw => BlacksmithNative.cadaclysm_blacksmith_transform_scale_xyz(Blacksmith.Frame(frame), sx, sy, sz, raw));

    /// <summary>Every point slid along `direction` by `factor` times its height above `plane`.
    /// `direction` is normalised -- `factor` alone sets the slide -- and must lie in the
    /// plane.</summary>
    public static Transform Shear(double[] plane, (double X, double Y, double Z) direction, double factor) =>
        Made("transform_shear", raw => BlacksmithNative.cadaclysm_blacksmith_transform_shear(Blacksmith.Frame(plane), Xyz(direction), factor, raw));

    /// <summary>The rigid map sending frame `a` onto frame `b`.</summary>
    public static Transform PlaneToPlane(double[] a, double[] b) =>
        Made("transform_plane_to_plane", raw => BlacksmithNative.cadaclysm_blacksmith_transform_plane_to_plane(Blacksmith.Frame(a), Blacksmith.Frame(b), raw));

    /// <summary>Coordinates in frame `from` to coordinates in frame `to`: a change of
    /// basis.</summary>
    public static Transform ChangeBasis(double[] from, double[] to) =>
        Made("transform_change_basis", raw => BlacksmithNative.cadaclysm_blacksmith_transform_change_basis(Blacksmith.Frame(from), Blacksmith.Frame(to), raw));

    /// <summary>The orthogonal projection onto `plane` -- singular by design.</summary>
    public static Transform PlanarProjection(double[] plane) =>
        Made("transform_planar_projection", raw => BlacksmithNative.cadaclysm_blacksmith_transform_planar_projection(Blacksmith.Frame(plane), raw));

    /// <summary>The parallel projection onto `plane` along `direction`, which must not lie in
    /// it.</summary>
    public static Transform ProjectAlong(double[] plane, (double X, double Y, double Z) direction) =>
        Made("transform_project_along", raw => BlacksmithNative.cadaclysm_blacksmith_transform_project_along(Blacksmith.Frame(plane), Xyz(direction), raw));

    /// <summary>The 16 numbers, row-major -- a copy.</summary>
    public double[] Rows => (double[])_rows.Clone();

    /// <summary>A map goes wherever 16 numbers do.</summary>
    public static implicit operator double[](Transform t) => t?.Rows!;

    /// <summary>Where the map takes the point `p`.</summary>
    public (double X, double Y, double Z) Point((double X, double Y, double Z) p)
    {
        var r = _rows;
        return (r[0] * p.X + r[1] * p.Y + r[2] * p.Z + r[3],
                r[4] * p.X + r[5] * p.Y + r[6] * p.Z + r[7],
                r[8] * p.X + r[9] * p.Y + r[10] * p.Z + r[11]);
    }

    /// <summary>This map after `other`: `(a.Compose(b)).Point(p) == a.Point(b.Point(p))`.</summary>
    public Transform Compose(Transform other)
    {
        ArgumentNullException.ThrowIfNull(other);
        return Made("transform_compose", raw => BlacksmithNative.cadaclysm_blacksmith_transform_compose(_rows, other._rows, raw));
    }

    /// <summary>`a` after `b`, as <see cref="Compose"/>.</summary>
    public static Transform operator *(Transform a, Transform b) => a.Compose(b);

    /// <summary>The map undoing this one; throws <see cref="BuildException"/> for a singular
    /// map.</summary>
    public Transform Inverse() =>
        Made("transform_inverse", raw => BlacksmithNative.cadaclysm_blacksmith_transform_inverse(_rows, raw));

    /// <summary>Whether the linear part is orthogonal (`AᵀA = I` to `tolerance`): a rotation or
    /// a mirror. <see cref="Solid.Transform(Transform)"/> is looser: it applies a map within
    /// 1e-6 of a similarity as that similarity.</summary>
    public bool IsRigid(double tolerance = MapTolerance)
    {
        var r = BlacksmithNative.cadaclysm_blacksmith_transform_is_rigid(_rows, tolerance);
        if (r == Blacksmith.None) throw Blacksmith.Failure("transform_is_rigid");
        return r == 1;
    }

    /// <summary>The scale `k` where the linear part is `k` times an orthogonal one
    /// (`AᵀA = k²I` to `tolerance`, relative to `k²`), else null.</summary>
    public double? IsSimilarity(double tolerance = MapTolerance)
    {
        var k = BlacksmithNative.cadaclysm_blacksmith_transform_is_similarity(_rows, tolerance);
        if (double.IsNaN(k)) throw Blacksmith.Failure("transform_is_similarity");
        return k > 0 ? k : null;
    }

    private static (double X, double Y, double Z) Triple(double[] v, int at) => (v[at], v[at + 1], v[at + 2]);

    private static Transform Block(double[] v, int at) => new(v[at..(at + 16)]);

    /// <summary>The translation and orthogonal part of a rigid map, else null.</summary>
    public RigidParts? DecomposeRigid(double tolerance = MapTolerance)
    {
        if (!IsRigid(tolerance)) return null;
        var raw = new double[19];
        if (!BlacksmithNative.cadaclysm_blacksmith_transform_decompose_rigid(_rows, tolerance, raw)) throw Blacksmith.Failure("transform_decompose_rigid");
        return new RigidParts(Triple(raw, 0), Block(raw, 3));
    }

    /// <summary>The translation, orthogonal part and scale `k` of a similarity, else
    /// null.</summary>
    public SimilarityParts? DecomposeSimilarity(double tolerance = MapTolerance)
    {
        if (IsSimilarity(tolerance) is null) return null;
        var raw = new double[20];
        if (!BlacksmithNative.cadaclysm_blacksmith_transform_decompose_similarity(_rows, tolerance, raw)) throw Blacksmith.Failure("transform_decompose_similarity");
        return new SimilarityParts(Triple(raw, 0), Block(raw, 3), raw[19]);
    }

    /// <summary>The polar split of the map (see <see cref="AffineParts"/>); null for a singular
    /// map or one stretched past 1e7:1, which has no unique split.</summary>
    public AffineParts? DecomposeAffine()
    {
        var raw = new double[38];
        if (!BlacksmithNative.cadaclysm_blacksmith_transform_decompose_affine(_rows, raw)) return null;
        return new AffineParts(Triple(raw, 0), Block(raw, 3), Block(raw, 19), Triple(raw, 35));
    }

    public bool Equals(Transform? other) => other is not null && _rows.AsSpan().SequenceEqual(other._rows);
    public override bool Equals(object? obj) => Equals(obj as Transform);
    public static bool operator ==(Transform? a, Transform? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(Transform? a, Transform? b) => !(a == b);
    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var v in _rows) h.Add(v);
        return h.ToHashCode();
    }

    public override string ToString() => $"Transform([{string.Join(", ", _rows)}])";
}

/// <summary>A rotation as `w + xi + yj + zk`. Immutable. `q` and `-q` are the same rotation; a
/// non-unit one is normalised wherever it becomes a rotation, a zero one throws
/// <see cref="BuildException"/> there. `a * b` turns by `b`, then `a`. Equality is by
/// components, so `q != -q` although the two are the same rotation: to ask whether two turn
/// alike, compare their <see cref="ToTransform"/> rows to a tolerance.</summary>
public sealed class Quaternion : IEquatable<Quaternion>
{
    private readonly double[] _q;

    /// <summary>`w + xi + yj + zk`; by default the identity. Throws
    /// <see cref="BuildException"/> for a value not finite.</summary>
    public Quaternion(double w = 1, double x = 0, double y = 0, double z = 0)
    {
        _q = new[] { w + 0.0, x + 0.0, y + 0.0, z + 0.0 }; // no -0.0 to print or compare
        if (!_q.All(double.IsFinite)) throw new BuildException("Quaternion: not finite");
    }

    private static Quaternion Made(string what, Func<double[], bool> call)
    {
        var raw = new double[4];
        if (!call(raw)) throw Blacksmith.Failure(what);
        return new Quaternion(raw[0], raw[1], raw[2], raw[3]);
    }

    /// <summary>A turn of `radians` about `direction`, right-handed.</summary>
    public static Quaternion FromAxisAngle((double X, double Y, double Z) direction, double radians) =>
        Made("quaternion_from_axis_angle", raw => BlacksmithNative.cadaclysm_blacksmith_quaternion_from_axis_angle(
            new[] { direction.X, direction.Y, direction.Z }, radians, raw));

    /// <summary>The rotation in `t`'s linear part (its translation ignored); throws
    /// <see cref="BuildException"/> unless that is a proper rotation, orthogonal to 1e-9. Take
    /// `t.DecomposeAffine().Rotation` first for a map rounded to float32.</summary>
    public static Quaternion FromTransform(Transform t)
    {
        ArgumentNullException.ThrowIfNull(t);
        return Made("quaternion_from_transform", raw => BlacksmithNative.cadaclysm_blacksmith_quaternion_from_transform(t.Rows, raw));
    }

    /// <summary>From `a` (`s = 0`) to `b` (`s = 1`) the shorter way.</summary>
    public static Quaternion Slerp(Quaternion a, Quaternion b, double s) =>
        Made("quaternion_slerp", raw => BlacksmithNative.cadaclysm_blacksmith_quaternion_slerp(a._q, b._q, s, raw));

    /// <summary>This rotation as a <see cref="Transform"/> fixing `centre` (by default the
    /// origin).</summary>
    public Transform ToTransform((double X, double Y, double Z) centre = default)
    {
        var raw = new double[16];
        if (!BlacksmithNative.cadaclysm_blacksmith_quaternion_to_transform(_q, new[] { centre.X, centre.Y, centre.Z }, raw))
            throw Blacksmith.Failure("quaternion_to_transform");
        return new Transform(raw);
    }

    public double W => _q[0];
    public double X => _q[1];
    public double Y => _q[2];
    public double Z => _q[3];

    /// <summary>`w, x, y, z` -- a copy.</summary>
    public double[] ToArray() => (double[])_q.Clone();

    private static double MaxAbs(ReadOnlySpan<double> vs)
    {
        var big = 0.0;
        foreach (var v in vs) big = Math.Max(big, Math.Abs(v));
        return big;
    }

    /// <summary>The length of `vs`, scaled by its largest component first, as the ABI's
    /// `quaternion_from` does: squaring 1e200 overflows and 1e-170 underflows.</summary>
    private static double Norm(ReadOnlySpan<double> vs)
    {
        var big = MaxAbs(vs);
        if (big == 0) return 0.0;
        var sum = 0.0;
        foreach (var v in vs) sum += (v / big) * (v / big);
        return big * Math.Sqrt(sum);
    }

    public double Length => Norm(_q);

    /// <summary>The turn, in `[0, 2π]`.</summary>
    public double Angle => 2.0 * Math.Atan2(Norm(_q.AsSpan(1)), W);

    /// <summary>The turn's axis, null for the identity.</summary>
    public (double X, double Y, double Z)? Axis
    {
        get
        {
            var big = MaxAbs(_q.AsSpan(1));
            if (big == 0) return null;
            double x = X / big, y = Y / big, z = Z / big;
            var n = Math.Sqrt(x * x + y * y + z * z);
            return (x / n, y / n, z / n);
        }
    }

    public Quaternion Conjugate() => new(W, -X, -Y, -Z);

    /// <summary>The same rotation at unit length, scaled by its largest component before the
    /// square root (as the ABI's `quaternion_from` does), so 1e200 and 1e-170 normalise.</summary>
    public Quaternion Normalized()
    {
        var big = MaxAbs(_q);
        if (big == 0) throw new BuildException("Quaternion.normalized: the quaternion is zero");
        double w = W / big, x = X / big, y = Y / big, z = Z / big;
        var n = Math.Sqrt(w * w + x * x + y * y + z * z);
        return new Quaternion(w / n, x / n, y / n, z / n);
    }

    /// <summary>The Hamilton product: turns by `b`, then `a`.</summary>
    public static Quaternion operator *(Quaternion a, Quaternion b)
    {
        var p = a._q;
        var q = b._q;
        return new Quaternion(p[0] * q[0] - p[1] * q[1] - p[2] * q[2] - p[3] * q[3],
                              p[0] * q[1] + p[1] * q[0] + p[2] * q[3] - p[3] * q[2],
                              p[0] * q[2] - p[1] * q[3] + p[2] * q[0] + p[3] * q[1],
                              p[0] * q[3] + p[1] * q[2] - p[2] * q[1] + p[3] * q[0]);
    }

    public bool Equals(Quaternion? other) => other is not null && _q.AsSpan().SequenceEqual(other._q);
    public override bool Equals(object? obj) => Equals(obj as Quaternion);
    public static bool operator ==(Quaternion? a, Quaternion? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(Quaternion? a, Quaternion? b) => !(a == b);
    public override int GetHashCode() => HashCode.Combine(_q[0], _q[1], _q[2], _q[3]);

    public override string ToString() => $"Quaternion({W}, {X}, {Y}, {Z})";
}

/// <summary>A parameter range `t0..t1`, in either order: <see cref="Length"/> and
/// <see cref="Swapped"/> keep the order, the set operations (<see cref="Grown"/>,
/// <see cref="Union"/>, <see cref="Intersect"/>) answer increasing. Immutable, equal by value;
/// a pair `(t0, t1)` converts to one, so two numbers go wherever an `Interval` does. The values'
/// angle and height ranges and the surfaces' domains are intervals.</summary>
public sealed class Interval : IEquatable<Interval>
{
    /// <summary>The range `t0..t1`; a value not finite throws <see cref="BuildException"/>.</summary>
    public Interval(double t0, double t1)
    {
        T0 = t0 + 0.0; // no -0.0 to print or compare
        T1 = t1 + 0.0;
        if (!double.IsFinite(T0) || !double.IsFinite(T1)) throw new BuildException("Interval: not finite");
    }

    /// <summary>Two numbers as an `Interval`; any other count throws
    /// <see cref="BuildException"/>.</summary>
    public static Interval Of(double[] values)
    {
        var got = values?.Length ?? 0;
        if (values is null || got != 2) throw new BuildException($"Interval: an interval is 2 numbers, got {got}");
        return new Interval(values[0], values[1]);
    }

    /// <summary>A pair `(t0, t1)` goes wherever an `Interval` does.</summary>
    public static implicit operator Interval((double T0, double T1) t) => new(t.T0, t.T1);

    /// <summary>The two ends, as given.</summary>
    public double T0 { get; }
    public double T1 { get; }

    /// <summary>`t1 - t0`: negative for a decreasing interval.</summary>
    public double Length => T1 - T0;

    /// <summary>The middle, `(t0 + t1) / 2`.</summary>
    public double Mid => 0.5 * (T0 + T1);

    /// <summary>The smaller and the larger end.</summary>
    public double Min => Math.Min(T0, T1);
    public double Max => Math.Max(T0, T1);

    /// <summary>Whether `t0 &lt; t1`.</summary>
    public bool IsIncreasing => T0 < T1;

    /// <summary>Whether `t0 == t1`.</summary>
    public bool IsSingleton => T0 == T1;

    /// <summary>The interval `t1..t0`.</summary>
    public Interval Swapped() => new(T1, T0);

    /// <summary>The increasing interval holding this one and `t`.</summary>
    public Interval Grown(double t) => new(Math.Min(Min, t), Math.Max(Max, t));

    /// <summary>The increasing interval holding this one and `o`.</summary>
    public Interval Union(Interval o)
    {
        ArgumentNullException.ThrowIfNull(o);
        return new Interval(Math.Min(Min, o.Min), Math.Max(Max, o.Max));
    }

    /// <summary>The increasing overlap with `o`; null where the two are apart. Two that touch
    /// give a singleton.</summary>
    public Interval? Intersect(Interval o)
    {
        ArgumentNullException.ThrowIfNull(o);
        double t0 = Math.Max(Min, o.Min), t1 = Math.Min(Max, o.Max);
        return t0 <= t1 ? new Interval(t0, t1) : null;
    }

    /// <summary>Whether `t` lies in the closed range, in either order.</summary>
    public bool Contains(double t) => Min <= t && t <= Max;

    /// <summary>`t0 + s (t1 - t0)`: the fraction `s` of the way from `t0`; outside 0..1
    /// extrapolates.</summary>
    public double ParameterAt(double s) => T0 + s * (T1 - T0);

    /// <summary>The fraction of the way `t` lies from `t0` toward `t1`; null for a
    /// singleton.</summary>
    public double? NormalizedParameterAt(double t)
    {
        var length = Length;
        return length != 0.0 ? (t - T0) / length : null;
    }

    /// <summary>`t0, t1` -- a fresh array.</summary>
    public double[] ToArray() => new[] { T0, T1 };

    public void Deconstruct(out double t0, out double t1)
    {
        t0 = T0;
        t1 = T1;
    }

    public bool Equals(Interval? other) => other is not null && T0.Equals(other.T0) && T1.Equals(other.T1);
    public override bool Equals(object? obj) => Equals(obj as Interval);
    public static bool operator ==(Interval? a, Interval? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(Interval? a, Interval? b) => !(a == b);
    public override int GetHashCode() => HashCode.Combine("Interval", T0, T1);

    public override string ToString() => $"Interval({T0}, {T1})";
}

/// <summary>The closest point of a curve value: its parameter `T`, the `Point`, and `Unique` --
/// false where several points lie equally near and `Point` is a fixed pick among them (a point
/// on a circle's axis, one equidistant from an arc's ends).</summary>
public sealed record CurveFoot(double T, (double X, double Y, double Z) Point, bool Unique);

/// <summary>The closest point of a surface value: its parameters `U`, `V`, the `Point`, and
/// `Unique` -- false where several points lie equally near and `Point` is a fixed pick among
/// them (a sphere's centre, a point on an axis).</summary>
public sealed record SurfaceFoot(double U, double V, (double X, double Y, double Z) Point, bool Unique);

/// <summary>The value calls' shared plumbing: the kinds' names, the size check, the out
/// arrays.</summary>
internal static class ValueCalls
{
    /// <summary>CADACLYSM_BLACKSMITH_VALUE_*'s names, by kind.</summary>
    internal static readonly string[] Names = { "line", "circle", "arc", "ellipse", "sphere", "cylinder", "cone", "torus", "cuboid",
        "rectangle", "triangle", "ray" };

    internal static double[] Xyz((double X, double Y, double Z) p) => new[] { p.X, p.Y, p.Z };

    internal static (double X, double Y, double Z) Triple(double[] v, int at) => (v[at], v[at + 1], v[at + 2]);

    internal static double Distance((double X, double Y, double Z) a, (double X, double Y, double Z) b)
    {
        double dx = a.X - b.X, dy = a.Y - b.Y, dz = a.Z - b.Z;
        return Math.Sqrt(dx * dx + dy * dy + dz * dz);
    }

    /// <summary>Points as one flat xyz array.</summary>
    internal static double[] FlatPoints(IEnumerable<(double X, double Y, double Z)> points)
    {
        ArgumentNullException.ThrowIfNull(points);
        return points.SelectMany(p => new[] { p.X, p.Y, p.Z }).ToArray();
    }

    /// <summary>`count` doubles a call writes, or its refusal thrown in the library's
    /// words.</summary>
    internal static double[] Call(string what, int count, Func<double[], bool> call)
    {
        var raw = new double[count];
        if (!call(raw)) throw Blacksmith.Failure(what);
        return raw;
    }

    /// <summary>`values` squared up by `value_check`: a wrong count refused here in the
    /// library's sentence, anything else by the library.</summary>
    internal static double[] Check(uint kind, double[]? values)
    {
        var size = (int)BlacksmithNative.cadaclysm_blacksmith_value_size(kind);
        var got = values?.Length ?? 0;
        if (values is null || got != size) throw new BuildException($"value_check: a {Names[kind]} is {size} numbers, got {got}");
        return Call("value_check", size, raw => BlacksmithNative.cadaclysm_blacksmith_value_check(kind, values, raw));
    }

    /// <summary>A frame's twelve numbers followed by `rest`.</summary>
    internal static double[] OnFrame(double[] frame, params double[] rest) => Blacksmith.Frame(frame).Concat(rest).ToArray();

    internal static Frame FrameOf(double[] v) => Frame.Of(v[..12]);
}

/// <summary>What every value shares: its canonical array (squared up by the library's
/// `value_check` at construction, so a refusal is the library's), immutability, equality and
/// hashing by kind and array, and <see cref="Bounds"/>. Immutable, with nothing to
/// free.</summary>
public abstract class GeometryValue : IEquatable<GeometryValue>
{
    private protected readonly uint K;
    private protected readonly double[] V;

    private protected GeometryValue(uint kind, double[] values, bool check)
    {
        K = kind;
        V = check ? ValueCalls.Check(kind, values) : (double[])values.Clone();
    }

    /// <summary>The value's numbers (see the C header's value table) -- a copy.</summary>
    public double[] Values => (double[])V.Clone();

    /// <summary>The exact world box, `(Min, Max)`, from the closed form rather than from
    /// samples.</summary>
    public ((double X, double Y, double Z) Min, (double X, double Y, double Z) Max) Bounds()
    {
        var b = ValueCalls.Call("value_bounds", 6, raw => BlacksmithNative.cadaclysm_blacksmith_value_bounds(K, V, raw));
        return (ValueCalls.Triple(b, 0), ValueCalls.Triple(b, 3));
    }

    /// <summary>This value's array under `t`, for each class's own `Transform`.</summary>
    private protected double[] Mapped(Transform t)
    {
        ArgumentNullException.ThrowIfNull(t);
        return ValueCalls.Call("value_transform", V.Length, raw => BlacksmithNative.cadaclysm_blacksmith_value_transform(K, V, t.Rows, raw));
    }

    public bool Equals(GeometryValue? other) =>
        other is not null && other.GetType() == GetType() && other.K == K && V.AsSpan().SequenceEqual(other.V);
    public override bool Equals(object? obj) => Equals(obj as GeometryValue);
    public static bool operator ==(GeometryValue? a, GeometryValue? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(GeometryValue? a, GeometryValue? b) => !(a == b);
    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(K);
        foreach (var v in V) h.Add(v);
        return h.ToHashCode();
    }
}

/// <summary>A curve value: a <see cref="Line"/>, <see cref="Circle"/>, <see cref="Arc"/> or
/// <see cref="Ellipse"/> -- what <see cref="Curve.Value"/> gives -- or a
/// <see cref="Rectangle"/>'s boundary.</summary>
public abstract class CurveValue : GeometryValue
{
    private protected CurveValue(uint kind, double[] values, bool check) : base(kind, values, check) { }

    /// <summary>The point at `t`: a line's fraction 0..1 from start to end, a circle's and an
    /// arc's angle in radians from the frame's x toward its y, an ellipse's eccentric
    /// angle.</summary>
    public (double X, double Y, double Z) PointAt(double t) =>
        ValueCalls.Triple(ValueCalls.Call("curve_value_point_at", 3, raw => BlacksmithNative.cadaclysm_blacksmith_curve_value_point_at(K, V, t, raw)), 0);

    /// <summary>The unit tangent at `t`, the way `t` grows.</summary>
    public (double X, double Y, double Z) TangentAt(double t) =>
        ValueCalls.Triple(ValueCalls.Call("curve_value_tangent_at", 3, raw => BlacksmithNative.cadaclysm_blacksmith_curve_value_tangent_at(K, V, t, raw)), 0);

    /// <summary>The length (an ellipse's perimeter, in closed form).</summary>
    public double Length() =>
        ValueCalls.Call("curve_value_length", 1, raw => BlacksmithNative.cadaclysm_blacksmith_curve_value_length(K, V, raw))[0];

    /// <summary>The <see cref="CurveFoot"/> nearest `p`, exact for every kind. `Unique` is
    /// false where the answer is a fixed pick among equally near points.</summary>
    public CurveFoot ClosestPoint((double X, double Y, double Z) p)
    {
        var f = ValueCalls.Call("curve_value_closest_point", 5,
            raw => BlacksmithNative.cadaclysm_blacksmith_curve_value_closest_point(K, V, ValueCalls.Xyz(p), raw));
        return new CurveFoot(f[0], ValueCalls.Triple(f, 1), f[4] != 0.0);
    }

    /// <summary>How far `p` lies from the curve: the distance to its
    /// <see cref="ClosestPoint"/>.</summary>
    public double DistanceTo((double X, double Y, double Z) p) => ValueCalls.Distance(ClosestPoint(p).Point, p);

    /// <summary>The curve's exact NURBS form: a line is degree 1, a circle, an arc or an ellipse
    /// an exact rational curve.</summary>
    public NurbsCurve ToNurbs() =>
        NurbsCurve.Of(BlacksmithNative.cadaclysm_blacksmith_curve_value_to_nurbs(K, V), "curve_value_to_nurbs");
}

/// <summary>A closed shape value: containment, area, volume and the B-rep solid.</summary>
public abstract class SolidValue : GeometryValue
{
    private protected SolidValue(uint kind, double[] values, bool check) : base(kind, values, check) { }

    /// <summary>The <see cref="Frame"/> the value is placed on.</summary>
    public Frame Frame => ValueCalls.FrameOf(V);

    /// <summary>Whether `p` lies inside the closed shape or within `tolerance` of it. NaN is
    /// unset: the shape's own effective tolerance (`tolerance.relative` times its diagonal); 0 is
    /// exact.</summary>
    public bool Contains((double X, double Y, double Z) p, double tolerance = 1e-9)
    {
        var r = BlacksmithNative.cadaclysm_blacksmith_solid_value_contains(K, V, ValueCalls.Xyz(p), tolerance);
        if (r == Blacksmith.None) throw Blacksmith.Failure("solid_value_contains");
        return r != 0;
    }

    /// <summary>The boundary's area, in closed form: a cylinder's and a cone's caps
    /// included.</summary>
    public double Area() => ValueCalls.Call("solid_value_area", 1, raw => BlacksmithNative.cadaclysm_blacksmith_solid_value_area(K, V, raw))[0];

    /// <summary>The volume enclosed, in closed form.</summary>
    public double Volume() => ValueCalls.Call("solid_value_volume", 1, raw => BlacksmithNative.cadaclysm_blacksmith_solid_value_volume(K, V, raw))[0];

    /// <summary>The shape as a closed exact B-rep <see cref="Solid"/>, to join, cut and
    /// write.</summary>
    public Solid ToSolid() =>
        new(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_solid_value_to_solid(K, V), "solid_value_to_solid"));
}

/// <summary>A surface value: a <see cref="Sphere"/>, <see cref="Cylinder"/>,
/// <see cref="Cone"/> or <see cref="Torus"/>.</summary>
public abstract class SurfaceValue : SolidValue
{
    private protected SurfaceValue(uint kind, double[] values, bool check) : base(kind, values, check) { }

    /// <summary>The point at `(u, v)`, in the ranges <see cref="Domain"/> gives.</summary>
    public (double X, double Y, double Z) PointAt(double u, double v) =>
        ValueCalls.Triple(ValueCalls.Call("surface_value_point_at", 3, raw => BlacksmithNative.cadaclysm_blacksmith_surface_value_point_at(K, V, u, v, raw)), 0);

    /// <summary>The outward unit normal at `(u, v)`.</summary>
    public (double X, double Y, double Z) NormalAt(double u, double v) =>
        ValueCalls.Triple(ValueCalls.Call("surface_value_normal_at", 3, raw => BlacksmithNative.cadaclysm_blacksmith_surface_value_normal_at(K, V, u, v, raw)), 0);

    /// <summary>The <see cref="SurfaceFoot"/> nearest `p` on the surface (a cylinder's and a
    /// cone's side, not their caps), exact for every kind. `Unique` is false where the answer
    /// is a fixed pick among equally near points.</summary>
    public SurfaceFoot ClosestPoint((double X, double Y, double Z) p)
    {
        var f = ValueCalls.Call("surface_value_closest_point", 6,
            raw => BlacksmithNative.cadaclysm_blacksmith_surface_value_closest_point(K, V, ValueCalls.Xyz(p), raw));
        return new SurfaceFoot(f[0], f[1], ValueCalls.Triple(f, 2), f[5] != 0.0);
    }

    /// <summary>How far `p` lies from the surface: the distance to its
    /// <see cref="ClosestPoint"/>.</summary>
    public double DistanceTo((double X, double Y, double Z) p) => ValueCalls.Distance(ClosestPoint(p).Point, p);

    /// <summary>The `u` and `v` ranges.</summary>
    public (Interval U, Interval V) Domain()
    {
        var d = ValueCalls.Call("surface_value_domain", 4, raw => BlacksmithNative.cadaclysm_blacksmith_surface_value_domain(K, V, raw));
        return (new Interval(d[0], d[1]), new Interval(d[2], d[3]));
    }

    /// <summary>The surface alone, as an open sheet on its exact NURBS form.</summary>
    public Solid ToNurbsSheet() =>
        new(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_surface_value_nurbs_sheet(K, V), "surface_value_nurbs_sheet"));
}

/// <summary>The segment from <see cref="Start"/> to <see cref="End"/>, as a value; its
/// parameter runs 0..1.</summary>
public sealed class Line : CurveValue
{
    public Line((double X, double Y, double Z) start, (double X, double Y, double Z) end)
        : base(BlacksmithNative.ValueLine, new[] { start.X, start.Y, start.Z, end.X, end.Y, end.Z }, true) { }

    private Line(double[] values, bool check) : base(BlacksmithNative.ValueLine, values, check) { }

    /// <summary>A line from its 6 numbers, checked as the constructor checks.</summary>
    public static Line FromValues(double[] values) => new(values, true);

    /// <summary>The two ends.</summary>
    public (double X, double Y, double Z) Start => ValueCalls.Triple(V, 0);
    public (double X, double Y, double Z) End => ValueCalls.Triple(V, 3);

    /// <summary>This line under `t`: any map keeping its ends apart.</summary>
    public Line Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Line Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Line(start={Start}, end={End})";
}

/// <summary>The circle of <see cref="Radius"/> about the frame's origin in its x-y plane,
/// counter-clockwise about its z from its x, as a value.</summary>
public sealed class Circle : CurveValue
{
    public Circle(double[] frame, double radius) : base(BlacksmithNative.ValueCircle, ValueCalls.OnFrame(frame, radius), true) { }

    private Circle(double[] values, bool check) : base(BlacksmithNative.ValueCircle, values, check) { }

    /// <summary>A circle from its 13 numbers, checked as the constructor checks.</summary>
    public static Circle FromValues(double[] values) => new(values, true);

    /// <summary>The circle through `a`, `b` and `c`: its x toward `a`, turning `a`, `b`, `c`
    /// counter-clockwise.</summary>
    public static Circle Through((double X, double Y, double Z) a, (double X, double Y, double Z) b, (double X, double Y, double Z) c) =>
        new(ValueCalls.Call("circle_through", 13, raw => BlacksmithNative.cadaclysm_blacksmith_circle_through(
            ValueCalls.Xyz(a), ValueCalls.Xyz(b), ValueCalls.Xyz(c), raw)), false);

    /// <summary>The frame the circle lies on: its centre, the x its angles start from, its
    /// normal.</summary>
    public Frame Frame => ValueCalls.FrameOf(V);

    public double Radius => V[12];

    /// <summary>This circle under `t`, a similarity (<see cref="Ellipse.FromCircle"/> first for
    /// any other map).</summary>
    public Circle Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Circle Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Circle(frame={Frame}, radius={Radius})";
}

/// <summary>The part of a circle over <see cref="Angle"/> (increasing, by at most a full
/// turn), as a value.</summary>
public sealed class Arc : CurveValue
{
    public Arc(double[] frame, double radius, Interval angle)
        : base(BlacksmithNative.ValueArc, ValueCalls.OnFrame(frame, radius, NotNull(angle).T0, angle.T1), true) { }

    private Arc(double[] values, bool check) : base(BlacksmithNative.ValueArc, values, check) { }

    private static Interval NotNull(Interval angle)
    {
        ArgumentNullException.ThrowIfNull(angle);
        return angle;
    }

    /// <summary>An arc from its 15 numbers, checked as the constructor checks.</summary>
    public static Arc FromValues(double[] values) => new(values, true);

    /// <summary>The arc from `a` through `b` to `c`.</summary>
    public static Arc Through((double X, double Y, double Z) a, (double X, double Y, double Z) b, (double X, double Y, double Z) c) =>
        new(ValueCalls.Call("arc_through", 15, raw => BlacksmithNative.cadaclysm_blacksmith_arc_through(
            ValueCalls.Xyz(a), ValueCalls.Xyz(b), ValueCalls.Xyz(c), raw)), false);

    /// <summary>The arc leaving `a` along `tangent` and ending at `c`.</summary>
    public static Arc FromStartTangentEnd((double X, double Y, double Z) a, (double X, double Y, double Z) tangent, (double X, double Y, double Z) c) =>
        new(ValueCalls.Call("arc_from_start_tangent_end", 15, raw => BlacksmithNative.cadaclysm_blacksmith_arc_from_start_tangent_end(
            ValueCalls.Xyz(a), ValueCalls.Xyz(tangent), ValueCalls.Xyz(c), raw)), false);

    /// <summary>The frame of the arc's circle.</summary>
    public Frame Frame => ValueCalls.FrameOf(V);

    public double Radius => V[12];

    /// <summary>The angle range.</summary>
    public Interval Angle => new(V[13], V[14]);

    /// <summary>The points at the start, the end and halfway along.</summary>
    public (double X, double Y, double Z) Start => PointAt(V[13]);
    public (double X, double Y, double Z) End => PointAt(V[14]);
    public (double X, double Y, double Z) Mid => PointAt(0.5 * (V[13] + V[14]));

    /// <summary>This arc under `t`, a similarity.</summary>
    public Arc Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Arc Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Arc(frame={Frame}, radius={Radius}, angle={Angle})";
}

/// <summary>The ellipse of radius <see cref="R1"/> along the frame's x and <see cref="R2"/>
/// along its y, as a value.</summary>
public sealed class Ellipse : CurveValue
{
    public Ellipse(double[] frame, double r1, double r2) : base(BlacksmithNative.ValueEllipse, ValueCalls.OnFrame(frame, r1, r2), true) { }

    private Ellipse(double[] values, bool check) : base(BlacksmithNative.ValueEllipse, values, check) { }

    /// <summary>An ellipse from its 14 numbers, checked as the constructor checks.</summary>
    public static Ellipse FromValues(double[] values) => new(values, true);

    /// <summary>`circle` as an ellipse of two equal radii -- which takes any map that keeps it
    /// one.</summary>
    public static Ellipse FromCircle(Circle circle)
    {
        ArgumentNullException.ThrowIfNull(circle);
        return new Ellipse(ValueCalls.Call("ellipse_from_circle", 14,
            raw => BlacksmithNative.cadaclysm_blacksmith_ellipse_from_circle(circle.Values, raw)), false);
    }

    /// <summary>The frame the ellipse lies on.</summary>
    public Frame Frame => ValueCalls.FrameOf(V);

    /// <summary>The radii along the frame's x and y.</summary>
    public double R1 => V[12];
    public double R2 => V[13];

    /// <summary>This ellipse under `t`: any map keeping it an ellipse.</summary>
    public Ellipse Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Ellipse Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Ellipse(frame={Frame}, r1={R1}, r2={R2})";
}

/// <summary>The sphere of <see cref="Radius"/> about the frame's origin, as a value: `u` the
/// longitude from the frame's x, `v` the latitude toward its z.</summary>
public sealed class Sphere : SurfaceValue
{
    public Sphere(double[] frame, double radius) : base(BlacksmithNative.ValueSphere, ValueCalls.OnFrame(frame, radius), true) { }

    private Sphere(double[] values, bool check) : base(BlacksmithNative.ValueSphere, values, check) { }

    /// <summary>A sphere from its 13 numbers, checked as the constructor checks.</summary>
    public static Sphere FromValues(double[] values) => new(values, true);

    public double Radius => V[12];

    /// <summary>This sphere under `t`, a similarity.</summary>
    public Sphere Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Sphere Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Sphere(frame={Frame}, radius={Radius})";
}

/// <summary>The capped cylinder of <see cref="Radius"/> about the frame's z over
/// <see cref="Height"/> (increasing, along z), as a value: `u` the angle from the frame's x,
/// `v` the height.</summary>
public sealed class Cylinder : SurfaceValue
{
    public Cylinder(double[] frame, double radius, Interval height)
        : base(BlacksmithNative.ValueCylinder, ValueCalls.OnFrame(frame, radius, NotNull(height).T0, height.T1), true) { }

    private Cylinder(double[] values, bool check) : base(BlacksmithNative.ValueCylinder, values, check) { }

    private static Interval NotNull(Interval height)
    {
        ArgumentNullException.ThrowIfNull(height);
        return height;
    }

    /// <summary>A cylinder from its 15 numbers, checked as the constructor checks.</summary>
    public static Cylinder FromValues(double[] values) => new(values, true);

    public double Radius => V[12];

    /// <summary>The range along the frame's z.</summary>
    public Interval Height => new(V[13], V[14]);

    /// <summary>This cylinder under `t`, a similarity.</summary>
    public Cylinder Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Cylinder Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Cylinder(frame={Frame}, radius={Radius}, height={Height})";
}

/// <summary>The capped cone of base <see cref="Radius"/> on the frame's x-y plane, its apex
/// <see cref="Height"/> up its z, as a value: `u` the angle from the frame's x, `v` the
/// height.</summary>
public sealed class Cone : SurfaceValue
{
    public Cone(double[] frame, double radius, double height) : base(BlacksmithNative.ValueCone, ValueCalls.OnFrame(frame, radius, height), true) { }

    private Cone(double[] values, bool check) : base(BlacksmithNative.ValueCone, values, check) { }

    /// <summary>A cone from its 14 numbers, checked as the constructor checks.</summary>
    public static Cone FromValues(double[] values) => new(values, true);

    /// <summary>The base radius.</summary>
    public double Radius => V[12];

    /// <summary>How far up the frame's z the apex lies.</summary>
    public double Height => V[13];

    /// <summary>This cone under `t`, a similarity.</summary>
    public Cone Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Cone Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Cone(frame={Frame}, radius={Radius}, height={Height})";
}

/// <summary>The torus of <see cref="Major"/> radius about the frame's z and <see cref="Minor"/>
/// radius about that circle, as a value: `u` the angle about the z from the frame's x, `v` the
/// angle about the tube.</summary>
public sealed class Torus : SurfaceValue
{
    public Torus(double[] frame, double major, double minor) : base(BlacksmithNative.ValueTorus, ValueCalls.OnFrame(frame, major, minor), true) { }

    private Torus(double[] values, bool check) : base(BlacksmithNative.ValueTorus, values, check) { }

    /// <summary>A torus from its 14 numbers, checked as the constructor checks.</summary>
    public static Torus FromValues(double[] values) => new(values, true);

    /// <summary>The radius of the tube's centre circle, and the tube's own.</summary>
    public double Major => V[12];
    public double Minor => V[13];

    /// <summary>This torus under `t`, a similarity.</summary>
    public Torus Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Torus Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Torus(frame={Frame}, major={Major}, minor={Minor})";
}

/// <summary>The box over <see cref="X"/>, <see cref="Y"/>, <see cref="Z"/> (increasing) along
/// its frame's axes, as a value: an oriented bounding box, a region to test points against, a
/// block to make a solid of.</summary>
public sealed class Cuboid : SolidValue
{
    public Cuboid(double[] frame, Interval x, Interval y, Interval z)
        : base(BlacksmithNative.ValueCuboid, Ranges(frame, x, y, z), true) { }

    private Cuboid(double[] values, bool check) : base(BlacksmithNative.ValueCuboid, values, check) { }

    private static double[] Ranges(double[] frame, Interval x, Interval y, Interval z)
    {
        ArgumentNullException.ThrowIfNull(x);
        ArgumentNullException.ThrowIfNull(y);
        ArgumentNullException.ThrowIfNull(z);
        return ValueCalls.OnFrame(frame, x.T0, x.T1, y.T0, y.T1, z.T0, z.T1);
    }

    /// <summary>A cuboid from its 18 numbers, checked as the constructor checks.</summary>
    public static Cuboid FromValues(double[] values) => new(values, true);

    /// <summary>The world-aligned box from `min` to `max`.</summary>
    public static Cuboid FromBounds((double X, double Y, double Z) min, (double X, double Y, double Z) max) =>
        new(ValueCalls.Call("cuboid_from_bounds", 18, raw => BlacksmithNative.cadaclysm_blacksmith_cuboid_from_bounds(
            ValueCalls.Xyz(min), ValueCalls.Xyz(max), raw)), false);

    /// <summary>The tightest box holding `points`, aligned to `frame`.</summary>
    public static Cuboid Around(double[] frame, IEnumerable<(double X, double Y, double Z)> points)
    {
        var f = Blacksmith.Frame(frame);
        var xyz = ValueCalls.FlatPoints(points);
        return new Cuboid(ValueCalls.Call("cuboid_around", 18,
            raw => BlacksmithNative.cadaclysm_blacksmith_cuboid_around(f, xyz, (nuint)(xyz.Length / 3), raw)), false);
    }

    /// <summary>The three ranges along the frame's axes.</summary>
    public Interval X => new(V[12], V[13]);
    public Interval Y => new(V[14], V[15]);
    public Interval Z => new(V[16], V[17]);

    /// <summary>The eight corners: the `z0` face counter-clockwise about the frame's z from
    /// `(x0, y0)`, then the `z1` face in the same order.</summary>
    public (double X, double Y, double Z)[] Corners()
    {
        var c = ValueCalls.Call("cuboid_corners", 24, raw => BlacksmithNative.cadaclysm_blacksmith_cuboid_corners(V, raw));
        return Enumerable.Range(0, 8).Select(k => ValueCalls.Triple(c, 3 * k)).ToArray();
    }

    /// <summary>The point the fractions `sx`, `sy`, `sz` of the way along each range.</summary>
    public (double X, double Y, double Z) PointAt(double sx, double sy, double sz) =>
        ValueCalls.Triple(ValueCalls.Call("cuboid_point_at", 3, raw => BlacksmithNative.cadaclysm_blacksmith_cuboid_point_at(V, sx, sy, sz, raw)), 0);

    /// <summary>The closest point of the solid box to `p`: `p` itself where it lies
    /// inside.</summary>
    public (double X, double Y, double Z) ClosestPoint((double X, double Y, double Z) p) =>
        ValueCalls.Triple(ValueCalls.Call("cuboid_closest_point", 3,
            raw => BlacksmithNative.cadaclysm_blacksmith_cuboid_closest_point(V, ValueCalls.Xyz(p), raw)), 0);

    /// <summary>This box under `t`, a similarity.</summary>
    public Cuboid Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Cuboid Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Cuboid(frame={Frame}, x={X}, y={Y}, z={Z})";
}

/// <summary>The rectangle over <see cref="X"/> and <see cref="Y"/> (increasing) in its frame's
/// x-y plane, as a value. As a curve it is its boundary: `t` runs 0..4, one unit a side from
/// corner `(x0, y0)` counter-clockwise about the frame's z, clamped outside that range;
/// <see cref="CurveValue.ClosestPoint"/> is the boundary's, not unique on a tie (the
/// centre).</summary>
public sealed class Rectangle : CurveValue
{
    public Rectangle(double[] frame, Interval x, Interval y) : base(BlacksmithNative.ValueRectangle, Ranges(frame, x, y), true) { }

    private Rectangle(double[] values, bool check) : base(BlacksmithNative.ValueRectangle, values, check) { }

    private static double[] Ranges(double[] frame, Interval x, Interval y)
    {
        ArgumentNullException.ThrowIfNull(x);
        ArgumentNullException.ThrowIfNull(y);
        return ValueCalls.OnFrame(frame, x.T0, x.T1, y.T0, y.T1);
    }

    /// <summary>A rectangle from its 16 numbers, checked as the constructor checks.</summary>
    public static Rectangle FromValues(double[] values) => new(values, true);

    /// <summary>The frame the rectangle lies on: its ranges run along the frame's x and y.</summary>
    public Frame Frame => ValueCalls.FrameOf(V);

    /// <summary>The two ranges along the frame's x and y.</summary>
    public Interval X => new(V[12], V[13]);
    public Interval Y => new(V[14], V[15]);

    /// <summary>The four corners: `(x0, y0)`, `(x1, y0)`, `(x1, y1)`, `(x0, y1)`.</summary>
    public (double X, double Y, double Z)[] Corners()
    {
        var c = ValueCalls.Call("rectangle_corners", 12, raw => BlacksmithNative.cadaclysm_blacksmith_rectangle_corners(V, raw));
        return Enumerable.Range(0, 4).Select(k => ValueCalls.Triple(c, 3 * k)).ToArray();
    }

    /// <summary>The filled rectangle's area.</summary>
    public double Area() => ValueCalls.Call("rectangle_area", 1, raw => BlacksmithNative.cadaclysm_blacksmith_rectangle_area(V, raw))[0];

    /// <summary>`p` projected onto the plane and clamped into the filled rectangle when
    /// `includeInterior`, else the boundary's closest point.</summary>
    public (double X, double Y, double Z) ClosestPointIn((double X, double Y, double Z) p, bool includeInterior = true) =>
        ValueCalls.Triple(ValueCalls.Call("rectangle_closest_point", 3,
            raw => BlacksmithNative.cadaclysm_blacksmith_rectangle_closest_point(V, ValueCalls.Xyz(p), includeInterior, raw)), 0);

    /// <summary>Where `p`, projected onto the plane, lies: "inside", "outside", or "on" within
    /// `tolerance` of the boundary. Null (or NaN) is unset: the rectangle's own effective
    /// tolerance (`tolerance.relative` times its diagonal); 0 is exact.</summary>
    public string Contains((double X, double Y, double Z) p, double? tolerance = null)
    {
        var r = BlacksmithNative.cadaclysm_blacksmith_rectangle_contains(V, ValueCalls.Xyz(p), Blacksmith.Tol(tolerance));
        if (r == Blacksmith.None) throw Blacksmith.Failure("rectangle_contains");
        return Blacksmith.ContainmentOf(r, "rectangle_contains");
    }

    /// <summary>The filled rectangle as a one-face planar sheet facing the frame's z.</summary>
    public Solid ToSheet() =>
        new(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_rectangle_to_sheet(V), "rectangle_to_sheet"));

    /// <summary>This rectangle under `t`: any map keeping its sides square (no shear in its
    /// plane).</summary>
    public Rectangle Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Rectangle Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Rectangle(frame={Frame}, x={X}, y={Y})";
}

/// <summary>The triangle <see cref="A"/>, <see cref="B"/>, <see cref="C"/>, as a value. A
/// degenerate one (collinear or coincident points) is refused.</summary>
public sealed class Triangle : GeometryValue
{
    public Triangle((double X, double Y, double Z) a, (double X, double Y, double Z) b, (double X, double Y, double Z) c)
        : base(BlacksmithNative.ValueTriangle, new[] { a.X, a.Y, a.Z, b.X, b.Y, b.Z, c.X, c.Y, c.Z }, true) { }

    private Triangle(double[] values, bool check) : base(BlacksmithNative.ValueTriangle, values, check) { }

    /// <summary>A triangle from its 9 numbers, checked as the constructor checks.</summary>
    public static Triangle FromValues(double[] values) => new(values, true);

    /// <summary>The three vertices.</summary>
    public (double X, double Y, double Z) A => ValueCalls.Triple(V, 0);
    public (double X, double Y, double Z) B => ValueCalls.Triple(V, 3);
    public (double X, double Y, double Z) C => ValueCalls.Triple(V, 6);

    public double Area() => ValueCalls.Call("triangle_area", 1, raw => BlacksmithNative.cadaclysm_blacksmith_triangle_area(V, raw))[0];

    public double Perimeter() =>
        ValueCalls.Call("triangle_perimeter", 1, raw => BlacksmithNative.cadaclysm_blacksmith_triangle_perimeter(V, raw))[0];

    /// <summary>The area centroid, the vertices' mean.</summary>
    public (double X, double Y, double Z) Centroid() =>
        ValueCalls.Triple(ValueCalls.Call("triangle_centroid", 3, raw => BlacksmithNative.cadaclysm_blacksmith_triangle_centroid(V, raw)), 0);

    /// <summary>The circle through `A`, `B`, `C`: its x toward `A`, turning them
    /// counter-clockwise.</summary>
    public Circle Circumcircle() =>
        Circle.FromValues(ValueCalls.Call("triangle_circumcircle", 13, raw => BlacksmithNative.cadaclysm_blacksmith_triangle_circumcircle(V, raw)));

    /// <summary>The point of barycentric weights `wa`, `wb`, `wc`, used as given.</summary>
    public (double X, double Y, double Z) PointAt(double wa, double wb, double wc) =>
        ValueCalls.Triple(ValueCalls.Call("triangle_point_at", 3, raw => BlacksmithNative.cadaclysm_blacksmith_triangle_point_at(V, wa, wb, wc, raw)), 0);

    /// <summary>The weights `(wa, wb, wc)`, summing to 1, of `p` projected onto the plane.</summary>
    public (double X, double Y, double Z) Barycentric((double X, double Y, double Z) p) =>
        ValueCalls.Triple(ValueCalls.Call("triangle_barycentric", 3,
            raw => BlacksmithNative.cadaclysm_blacksmith_triangle_barycentric(V, ValueCalls.Xyz(p), raw)), 0);

    /// <summary>The closest point of the filled triangle to `p`, exact.</summary>
    public (double X, double Y, double Z) ClosestPoint((double X, double Y, double Z) p) =>
        ValueCalls.Triple(ValueCalls.Call("triangle_closest_point", 3,
            raw => BlacksmithNative.cadaclysm_blacksmith_triangle_closest_point(V, ValueCalls.Xyz(p), raw)), 0);

    /// <summary>How far `p` lies from the filled triangle.</summary>
    public double DistanceTo((double X, double Y, double Z) p) => ValueCalls.Distance(ClosestPoint(p), p);

    /// <summary>Edge `i` as a line: 0 `A` to `B`, 1 `B` to `C`, 2 `C` to `A`.</summary>
    public Line Edge(uint i) =>
        Line.FromValues(ValueCalls.Call("triangle_edge", 6, raw => BlacksmithNative.cadaclysm_blacksmith_triangle_edge(V, i, raw)));

    /// <summary>The filled triangle as a one-face planar sheet, its normal turning `A`, `B`, `C`
    /// counter-clockwise.</summary>
    public Solid ToSheet() =>
        new(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_triangle_to_sheet(V), "triangle_to_sheet"));

    /// <summary>This triangle under `t`: any affine map keeping it a triangle.</summary>
    public Triangle Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Triangle Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Triangle(a={A}, b={B}, c={C})";
}

/// <summary>The half-line from <see cref="Position"/> along <see cref="Direction"/>, as a value.
/// The direction is kept as given, not unitised, so `t` counts lengths of it. A ray has no
/// <see cref="GeometryValue.Bounds"/>: the library refuses it.</summary>
public sealed class Ray : GeometryValue
{
    public Ray((double X, double Y, double Z) position, (double X, double Y, double Z) direction)
        : base(BlacksmithNative.ValueRay, new[] { position.X, position.Y, position.Z, direction.X, direction.Y, direction.Z }, true) { }

    private Ray(double[] values, bool check) : base(BlacksmithNative.ValueRay, values, check) { }

    /// <summary>A ray from its 6 numbers, checked as the constructor checks.</summary>
    public static Ray FromValues(double[] values) => new(values, true);

    /// <summary>The start and the direction.</summary>
    public (double X, double Y, double Z) Position => ValueCalls.Triple(V, 0);
    public (double X, double Y, double Z) Direction => ValueCalls.Triple(V, 3);

    /// <summary>`Position + t * Direction`, any `t` (behind the start too).</summary>
    public (double X, double Y, double Z) PointAt(double t) =>
        ValueCalls.Triple(ValueCalls.Call("ray_point_at", 3, raw => BlacksmithNative.cadaclysm_blacksmith_ray_point_at(V, t, raw)), 0);

    /// <summary>The <see cref="CurveFoot"/> on the ray nearest `p`: `T` clamped at 0, so a point
    /// behind the start answers the start. Always unique.</summary>
    public CurveFoot ClosestPoint((double X, double Y, double Z) p)
    {
        var f = ValueCalls.Call("ray_closest_point", 4, raw => BlacksmithNative.cadaclysm_blacksmith_ray_closest_point(V, ValueCalls.Xyz(p), raw));
        return new CurveFoot(f[0], ValueCalls.Triple(f, 1), true);
    }

    /// <summary>How far `p` lies from the ray.</summary>
    public double DistanceTo((double X, double Y, double Z) p) => ValueCalls.Distance(ClosestPoint(p).Point, p);

    /// <summary>This ray under `t`: any affine map keeping its direction.</summary>
    public Ray Transform(Transform t) => new(Mapped(t), false);

    /// <summary><see cref="Transform(Transform)"/> with the map as 16 numbers, row-major.</summary>
    public Ray Transform(double[] matrix) => Transform(new Transform(matrix));

    public override string ToString() => $"Ray(position={Position}, direction={Direction})";
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

// ---- machining --------------------------------------------------------------------------

/// <summary>A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and
/// `fluteLength` in mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into
/// its cuts at `rampAngle` degrees. Immutable; a job keeps its own copy, so disposing a tool a
/// job has used changes nothing there. Owns a handle: dispose it, or let the runtime.</summary>
public sealed class Tool : IDisposable
{
    private readonly ToolHandle _handle;

    private Tool(ToolHandle handle, string what)
    {
        _handle = Blacksmith.Checked(handle, what);
    }

    internal ToolHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Tool), "tool: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the tool back. Idempotent.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>A tool the library made, turned to `rampAngle` when that is not the library's
    /// own 3 degrees -- the unramped handle freed at once, not left to the collector.</summary>
    private static Tool Ramped(ToolHandle made, double rampAngle, string what)
    {
        var tool = new Tool(made, what);
        if (rampAngle == 3.0) return tool;   // the library's own default: no second handle
        using (tool)
            return new Tool(BlacksmithNative.cadaclysm_blacksmith_tool_with_ramp_angle(tool.Handle, rampAngle), "tool_with_ramp_angle");
    }

    /// <summary>A flat end mill. Throws <see cref="BuildException"/> for a `number` outside
    /// 1..255, a size, feed or speed not positive and finite, or a `rampAngle` outside (0, 90].
    /// </summary>
    public static Tool Flat(int number, double diameter, double fluteLength, double feed, double plunge, double rpm,
                            double rampAngle = 3.0) =>
        Ramped(BlacksmithNative.cadaclysm_blacksmith_tool_flat((uint)Math.Max(0, number), diameter, fluteLength, feed, plunge, rpm),
               rampAngle, "tool_flat");

    /// <summary>A ball end mill, as <see cref="Flat"/> but its tip a half sphere of the
    /// diameter; in 2.5D it cuts where a flat does, `bottom` being the tip.</summary>
    public static Tool Ball(int number, double diameter, double fluteLength, double feed, double plunge, double rpm,
                            double rampAngle = 3.0) =>
        Ramped(BlacksmithNative.cadaclysm_blacksmith_tool_ball((uint)Math.Max(0, number), diameter, fluteLength, feed, plunge, rpm),
               rampAngle, "tool_ball");

    /// <summary>A drill, plunging at `feed`. A job takes it for <see cref="Job.Drill"/> (and
    /// <see cref="Job.Machine"/>'s holes) only.</summary>
    public static Tool Drill(int number, double diameter, double fluteLength, double feed, double rpm) =>
        new(BlacksmithNative.cadaclysm_blacksmith_tool_drill((uint)Math.Max(0, number), diameter, fluteLength, feed, rpm), "tool_drill");
}

/// <summary>The block of material a job cuts, an axis-aligned box. Immutable; a job keeps its
/// own copy. Owns a handle: dispose it, or let the runtime.</summary>
public sealed class Stock : IDisposable
{
    private readonly StockHandle _handle;

    private Stock(StockHandle handle, string what)
    {
        _handle = Blacksmith.Checked(handle, what);
    }

    internal StockHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Stock), "stock: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the stock back. Idempotent.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>The box from `min` (x, y, z) to `max`. Throws <see cref="BuildException"/>
    /// unless every min is below its max and all six are finite.</summary>
    public static Stock Box((double X, double Y, double Z) min, (double X, double Y, double Z) max) =>
        new(BlacksmithNative.cadaclysm_blacksmith_stock_box(min.X, min.Y, min.Z, max.X, max.Y, max.Z), "stock_box");

    /// <summary>`solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at
    /// the solid's lowest Z. Throws <see cref="BuildException"/> for a `margin` negative or not
    /// finite.</summary>
    public static Stock Around(Solid solid, double margin = 0.0) =>
        new(BlacksmithNative.cadaclysm_blacksmith_stock_around(solid.Handle, margin), "stock_around");
}

/// <summary>One file a job wrote: a Grbl program (`Tool` its `T` number, `Name`
/// `&lt;job name&gt;-T&lt;n&gt;`, or `&lt;job name&gt;-&lt;k&gt;-T&lt;n&gt;` for a repeated
/// tool) from <see cref="Job.Gcode"/>. Read-only. Python's name, kept: the type lives in
/// `Cadaclysm.Blacksmith`, but a project's top-level statements make the compiler declare a
/// `Program` class in the global namespace, which an unqualified `Program` finds before this
/// one even after `using Cadaclysm.Blacksmith;`. In such a file spell it
/// `Cadaclysm.Blacksmith.Program`, or alias it
/// (`using GcodeProgram = Cadaclysm.Blacksmith.Program;`); `var` and `Job.Gcode()` need no
/// spelling at all.</summary>
public sealed record Program(int Tool, string Name, string Text)
{
    public override string ToString() => $"Program(tool={Tool}, name={Name}, {Text.Length} characters)";
}

/// <summary>One operation of a <see cref="Job"/>, read back by <see cref="Job.Operations"/>:
/// `Kind` ("face", "contour", "pocket" or "drill"), `Tool` (its Grbl T number) and `Params`, in
/// the kind-specific order the operation stores them. Every param is the library's own number:
/// `side` 0 outside, 1 inside, 2 on its line; `climb` and `open` 1 or 0; `points` a count; a
/// `peck` of none is null. Read-only.</summary>
public sealed record Operation(string Kind, int Tool, IReadOnlyDictionary<string, double?> Params)
{
    public override string ToString() =>
        $"Operation(kind={Kind}, tool={Tool}, params={{{string.Join(", ", Params.Select(p => $"{p.Key}: {p.Value?.ToString() ?? "null"}"))}}})";
}

/// <summary>One thing <see cref="Job.Machine"/> left uncut: `Kind` ("corner", "hole", "slope",
/// "undercut", "too_deep" or "relief"), `At` (x, y, z), `Size` (its meaning per `Kind`),
/// `Reason` (one sentence naming the tool involved), and `Region` (its XY area, as profiles
/// of their own), `Top` and `Bottom` (the Z range the item spans, `Top` &gt;= `Bottom`).
/// Read-only.</summary>
public sealed record ReportItem(string Kind, (double X, double Y, double Z) At, double Size, string Reason,
                                IReadOnlyList<Profile> Region, double Top, double Bottom)
{
    public override string ToString() =>
        $"ReportItem(kind={Kind}, at=({At.X}, {At.Y}, {At.Z}), size={Size}, reason={Reason}, top={Top}, bottom={Bottom}, region={Region.Count} profile(s))";
}

/// <summary>What <see cref="Job.Machine"/> could not make: a read-only list of
/// <see cref="ReportItem"/>, in order, read once when `Machine` returns. <see cref="Text"/>
/// (and `ToString()`) is the kernel's own report -- one line per item, or "nothing left
/// uncut".</summary>
public sealed class Report : IReadOnlyList<ReportItem>
{
    private readonly IReadOnlyList<ReportItem> _items;

    internal Report(IReadOnlyList<ReportItem> items, string text)
    {
        _items = items;
        Text = text;
    }

    /// <summary>The kernel's own report: one line per item, or "nothing left uncut".</summary>
    public string Text { get; }

    public int Count => _items.Count;

    public ReportItem this[int index] => _items[index];

    public IEnumerator<ReportItem> GetEnumerator() => _items.GetEnumerator();

    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();

    public override string ToString() => Text;
}

/// <summary>A machining job on a <see cref="Stock"/>: operations kept in the order they are
/// added, written as one Grbl 1.1 program per run of operations sharing a tool. Mutable --
/// each operation is added in place, and a refused one leaves the job as it was. `safeZ` is
/// the absolute Z of rapids between operations and at a program's start and end, above the
/// stock's top; an operation enters and leaves its passes `clearance` above its top;
/// `tolerance` fits free-form sides and offsets; `name` names the programs
/// (`&lt;name&gt;-T&lt;n&gt;`); every program waits `spindleDwell` seconds after starting the
/// spindle; `resolution` is the CAMotics project's voxel size in mm. The constructor throws
/// <see cref="BuildException"/> for a `safeZ` not above the stock, or a setting the job
/// refuses. Owns a handle: dispose it (a `using`), after which every call throws
/// `ObjectDisposedException` -- what Python's `Job.__del__` frees.</summary>
public sealed class Job : IDisposable
{
    /// <summary>What the kernel says of a name with a control character in it -- a NUL, which
    /// the UTF-8 marshaller would otherwise cut the name short at, is refused here with it.
    /// </summary>
    private const string NulName =
        "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |";

    private static readonly Dictionary<string, uint> Sides = new(StringComparer.Ordinal)
    {
        ["outside"] = 0,
        ["inside"] = 1,
        ["on"] = 2,
    };

    private readonly JobHandle _handle;

    public Job(Stock stock, double safeZ, double clearance = 1.0, double tolerance = 0.01, string name = "job",
               double spindleDwell = 2.0, double resolution = 0.1)
    {
        if (name.Contains('\0')) throw new BuildException(NulName);
        _handle = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_job_new(stock.Handle, safeZ), "job_new");
        try
        {
            // the library starts at the same defaults, so only what differs is set
            if (clearance != 1.0) Ok(BlacksmithNative.cadaclysm_blacksmith_job_set_clearance(_handle, clearance), "job_set_clearance");
            if (tolerance != 0.01) Ok(BlacksmithNative.cadaclysm_blacksmith_job_set_tolerance(_handle, tolerance), "job_set_tolerance");
            if (spindleDwell != 2.0) Ok(BlacksmithNative.cadaclysm_blacksmith_job_set_spindle_dwell(_handle, spindleDwell), "job_set_spindle_dwell");
            if (resolution != 0.1) Ok(BlacksmithNative.cadaclysm_blacksmith_job_set_resolution(_handle, resolution), "job_set_resolution");
            if (name != "job") Ok(BlacksmithNative.cadaclysm_blacksmith_job_set_name(_handle, name), "job_set_name");
        }
        catch
        {
            _handle.Dispose();   // refused after job_new: the handle is freed on the way out
            throw;
        }
    }

    internal JobHandle Handle => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Job), "job: closed");

    /// <summary>Whether the job has been disposed.</summary>
    public bool Closed => _handle.IsClosed;

    /// <summary>Give the job back. Idempotent; the lists it wrote are copies and outlive it.
    /// </summary>
    public void Dispose() => _handle.Dispose();

    private static void Ok(bool done, string what)
    {
        if (!done) throw Blacksmith.Failure(what);
    }

    /// <summary>Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and
    /// passes at most `stepdown` deep. Throws <see cref="BuildException"/> for a drill, a `z`
    /// above the stock's top, a stepover past the tool's diameter, ...</summary>
    public void Face(Tool tool, double z, double stepover, double stepdown) =>
        Ok(BlacksmithNative.cadaclysm_blacksmith_job_face(Handle, tool.Handle, z, stepover, stepdown), "job_face");

    /// <summary>Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep:
    /// `side` "outside" the profile, "inside" it, or "on" its line; `climb` for climb milling,
    /// else conventional; `open` to cut the outline as an open chain (only "on" its line, and
    /// with no holes). Throws `ArgumentException` for any other `side`,
    /// <see cref="BuildException"/> for what the job refuses.</summary>
    public void Contour(Tool tool, Profile profile, double top, double bottom, string side = "outside", double stepdown = 1.0,
                        bool climb = true, bool open = false)
    {
        if (!Sides.TryGetValue(side, out var code))
            throw new ArgumentException("side must be 'outside', 'inside' or 'on'");
        Ok(BlacksmithNative.cadaclysm_blacksmith_job_contour(Handle, tool.Handle, profile.Handle, top, bottom, code, stepdown,
            climb, open), "job_contour");
    }

    /// <summary>Clear `profile` -- its holes left standing as islands -- from `top` to `bottom`,
    /// in rings `stepover` apart (at most the tool's radius) and passes at most `stepdown` deep.
    /// Throws <see cref="BuildException"/> for what the job refuses; a pocket too small for the
    /// tool is refused by <see cref="Gcode"/>, naming the operation.</summary>
    public void Pocket(Tool tool, Profile profile, double top, double bottom, double stepover, double stepdown) =>
        Ok(BlacksmithNative.cadaclysm_blacksmith_job_pocket(Handle, tool.Handle, profile.Handle, top, bottom, stepover, stepdown),
            "job_pocket");

    /// <summary>Drill a hole at each (x, y) of `points` from `top` to `bottom`, pecking `peck`
    /// deep at a time (retracting between pecks), or straight to depth for null. Throws
    /// <see cref="BuildException"/> for what the job refuses (a tool that is not a drill, no
    /// points, ...).</summary>
    public void Drill(Tool tool, IEnumerable<(double X, double Y)> points, double top, double bottom, double? peck = null)
    {
        var xy = points.SelectMany(p => new[] { p.X, p.Y }).ToArray();
        Ok(BlacksmithNative.cadaclysm_blacksmith_job_drill(Handle, tool.Handle, xy, (nuint)(xy.Length / 2), top, bottom,
            peck ?? double.NaN), "job_drill");
    }

    /// <summary>Recognise `part` and append the operations that make it: faced, contoured and
    /// pocketed with `endMill`, its holes drilled with whichever of `drills` fits each -- a tool
    /// per required diameter. `stepover` and `stepdown` default to the kernel's own (null asks
    /// for that); `skin` (at least 0, default 0.3) is how far above the part's lowest point the
    /// outline stops, so the part stays attached to the stock -- `0` cuts through; `peck`
    /// defaults to none (a drill straight to depth). Returns a <see cref="Report"/> of what
    /// could not be cut. Throws <see cref="BuildException"/> for what the kernel refuses (a
    /// drill as `endMill`, a null drill, ...); the job changes only on success -- a refusal
    /// leaves it exactly as it was.</summary>
    public Report Machine(Solid part, Tool endMill, IEnumerable<Tool>? drills = null, double? stepover = null,
                          double? stepdown = null, double skin = 0.3, double? peck = null)
    {
        // Raw pointers, as WriteStepText passes its solids: the owners kept reachable until
        // the call has returned. A null drill goes over as a null pointer, for the library's
        // own "null drill <i>".
        var owners = drills?.ToArray() ?? Array.Empty<Tool>();
        var handles = owners.Select(t => t is null ? IntPtr.Zero : t.Handle.DangerousGetHandle()).ToArray();
        var made = BlacksmithNative.cadaclysm_blacksmith_job_machine(Handle, part.Handle, endMill.Handle, handles,
            (nuint)handles.Length, stepover ?? double.NaN, stepdown ?? double.NaN, skin, peck ?? double.NaN);
        GC.KeepAlive(owners);
        using var report = Blacksmith.Checked(made, "job_machine");
        return ReadReport(report);
    }

    /// <summary>As <see cref="Machine"/>, with a list of end mills, the largest first, each
    /// smaller one resuming where the one before could not reach (rest machining); the other
    /// arguments are as for `Machine`. Each <see cref="ReportItem"/> names the tool that left
    /// it and its Z range (`Top`, `Bottom`). Throws <see cref="BuildException"/> for what the
    /// kernel refuses (an empty list, one not smaller than the one before, two sharing a
    /// number, a drill among them, a null element, ...); a refusal leaves the job as it was.
    /// With `cornerRelief` true, each inside corner the smallest end mill leaves is instead
    /// relieved with a dog-bone -- a cut along the corner's bisector until the cutter touches
    /// the corner -- and reported as an item of kind "relief" in place of the "corner" one;
    /// false (the default) is the call without it.</summary>
    public Report MachineWith(Solid part, IEnumerable<Tool> endMills, IEnumerable<Tool>? drills = null,
                              double? stepover = null, double? stepdown = null, double skin = 0.3, double? peck = null,
                              bool cornerRelief = false)
    {
        // As Machine: raw pointers, the owners kept reachable until the call has returned; a
        // null element goes over as a null pointer, for the library's own "null end mill <i>".
        var mills = endMills.ToArray();
        var millHandles = mills.Select(t => t is null ? IntPtr.Zero : t.Handle.DangerousGetHandle()).ToArray();
        var owners = drills?.ToArray() ?? Array.Empty<Tool>();
        var handles = owners.Select(t => t is null ? IntPtr.Zero : t.Handle.DangerousGetHandle()).ToArray();
        // False keeps calling job_machine_with itself, so nothing existing changes.
        var made = cornerRelief
            ? BlacksmithNative.cadaclysm_blacksmith_job_machine_relieved(Handle, part.Handle, millHandles,
                (nuint)millHandles.Length, handles, (nuint)handles.Length, stepover ?? double.NaN,
                stepdown ?? double.NaN, skin, peck ?? double.NaN, true)
            : BlacksmithNative.cadaclysm_blacksmith_job_machine_with(Handle, part.Handle, millHandles,
                (nuint)millHandles.Length, handles, (nuint)handles.Length, stepover ?? double.NaN,
                stepdown ?? double.NaN, skin, peck ?? double.NaN);
        GC.KeepAlive(mills);
        GC.KeepAlive(owners);
        using var report = Blacksmith.Checked(made, cornerRelief ? "job_machine_relieved" : "job_machine_with");
        return ReadReport(report);
    }

    private static Report ReadReport(ReportHandle report)
    {
        var n = BlacksmithNative.cadaclysm_blacksmith_report_count(report);
        var items = new List<ReportItem>((int)n);
        for (uint i = 0; i < n; i++)
        {
            var at = new double[3];
            if (!BlacksmithNative.cadaclysm_blacksmith_report_at(report, i, at)) throw Blacksmith.Failure("report_at");
            items.Add(new ReportItem(
                Blacksmith.Text(BlacksmithNative.cadaclysm_blacksmith_report_kind(report, i)),
                (at[0], at[1], at[2]),
                BlacksmithNative.cadaclysm_blacksmith_report_size(report, i),
                Blacksmith.Text(BlacksmithNative.cadaclysm_blacksmith_report_reason(report, i)),
                Profile.ProfileList(BlacksmithNative.cadaclysm_blacksmith_report_region(report, i), "report_region"),
                BlacksmithNative.cadaclysm_blacksmith_report_top(report, i),
                BlacksmithNative.cadaclysm_blacksmith_report_bottom(report, i)));
        }
        return new Report(items, Blacksmith.Text(BlacksmithNative.cadaclysm_blacksmith_report_text(report)));
    }

    /// <summary>Every operation added to this job so far, in order -- whether added by
    /// <see cref="Face"/>/<see cref="Contour"/>/<see cref="Pocket"/>/<see cref="Drill"/> or by
    /// <see cref="Machine"/>.</summary>
    public IReadOnlyList<Operation> Operations()
    {
        using var list = Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_job_operations(Handle), "job_operations");
        var n = BlacksmithNative.cadaclysm_blacksmith_operations_count(list);
        var found = new List<Operation>((int)n);
        for (uint i = 0; i < n; i++)
        {
            var paramCount = BlacksmithNative.cadaclysm_blacksmith_operations_param_count(list, i);
            var parameters = new Dictionary<string, double?>((int)paramCount, StringComparer.Ordinal);
            for (uint k = 0; k < paramCount; k++)
            {
                var value = BlacksmithNative.cadaclysm_blacksmith_operations_param_value(list, i, k);
                parameters[Blacksmith.Text(BlacksmithNative.cadaclysm_blacksmith_operations_param_name(list, i, k))] =
                    double.IsNaN(value) ? null : value;
            }
            found.Add(new Operation(Blacksmith.Text(BlacksmithNative.cadaclysm_blacksmith_operations_kind(list, i)),
                (int)BlacksmithNative.cadaclysm_blacksmith_operations_tool(list, i), parameters));
        }
        return found;
    }

    /// <summary>The job as Grbl 1.1 programs, one per run of consecutive operations sharing a
    /// tool (T1, T2, T1 gives three), each named `&lt;name&gt;-T&lt;n&gt;` (or
    /// `&lt;name&gt;-&lt;k&gt;-T&lt;n&gt;` for run `k` of a repeated tool); an empty list for a
    /// job with no operations. Throws <see cref="BuildException"/> for an operation whose
    /// geometry the tool cannot cut (named by its index and kind).</summary>
    public IReadOnlyList<Program> Gcode() =>
        Programs(BlacksmithNative.cadaclysm_blacksmith_job_gcode(Handle), "job_gcode");

    /// <summary>A CAMotics project at `path` and its files beside it, named after the project's
    /// file stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each
    /// program, a simulation copy of it (`.sim.nc`, which the project lists), and the project
    /// last. Creates the directory. Returns the paths written, the project last. Throws
    /// <see cref="BuildException"/> for a path with no file stem, what <see cref="Gcode"/>
    /// refuses, or a file that cannot be written.</summary>
    public IReadOnlyList<string> WriteCamotics(string path)
    {
        var stem = System.IO.Path.GetFileNameWithoutExtension(path);
        // Python's Path(".camotics").stem is ".camotics"; .NET's is empty
        if (stem.Length == 0) stem = System.IO.Path.GetFileName(path);
        if (stem.Contains('\0')) throw new BuildException(NulName);
        var files = Programs(BlacksmithNative.cadaclysm_blacksmith_job_camotics(Handle, stem), "job_camotics");
        // written here rather than by the library, as Python writes them: byte for byte, UTF-8
        // with no byte-order mark and no CRLF
        var folder = System.IO.Path.GetDirectoryName(path) ?? "";
        var written = new List<string>(files.Count);
        try
        {
            if (folder.Length > 0) Directory.CreateDirectory(folder);
            for (var i = 0; i < files.Count; i++)
            {
                var at = i == files.Count - 1 ? path : System.IO.Path.Combine(folder, files[i].Name);
                File.WriteAllText(at, files[i].Text, new UTF8Encoding(false));
                written.Add(at);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new BuildException($"job_camotics: {path}: {e.Message}");
        }
        return written;
    }

    private static IReadOnlyList<Program> Programs(ProgramsHandle handle, string what)
    {
        using var list = Blacksmith.Checked(handle, what);
        var n = BlacksmithNative.cadaclysm_blacksmith_programs_count(list);
        var found = new List<Program>((int)n);
        for (uint i = 0; i < n; i++)
            found.Add(new Program((int)BlacksmithNative.cadaclysm_blacksmith_programs_tool(list, i),
                Blacksmith.Text(BlacksmithNative.cadaclysm_blacksmith_programs_name(list, i)),
                Blacksmith.Text(BlacksmithNative.cadaclysm_blacksmith_programs_text(list, i))));
        return found;
    }
}

/// <summary>One free edge, as plain data (<see cref="HealthReport.FreeEdges"/>): a side only one
/// face bounds -- its <c>Trim</c> (the face's side), the <c>Edge</c> it lies on (null for a side
/// with no edge), the <c>Face</c> and free <c>Wire</c> it is on, its nearest <c>Partner</c>
/// across the gap as an index into <see cref="HealthReport.FreeEdges"/> (null if there is none),
/// how many of its two ends it shares with that partner (<c>SharedEnds</c>: 2 is what sewing
/// joins), its <c>Length</c> and the <c>Gap</c> to the partner (infinite without one).</summary>
public sealed record FreeEdge(uint Trim, uint? Edge, uint Face, uint Wire, uint? Partner, uint SharedEnds, double Length, double Gap);

/// <summary>A chain of free edges end to end (<see cref="HealthReport.Wires"/>): the rows
/// <c>First</c> to <c>First + Count</c> of <see cref="HealthReport.FreeEdges"/>, whether it
/// <c>Closed</c> on itself, its total <c>Length</c> and the <c>WidestGap</c> to any partner.</summary>
public sealed record FreeWire(uint First, uint Count, bool Closed, double Length, double WidestGap);

/// <summary>Something below the tolerance (<see cref="HealthReport.Small"/>): <c>Kind</c> is
/// "short_edge", "collapsed_edge", "sliver_face", "tiny_face", "tiny_body" or "small_hole";
/// <c>Index</c> its edge, face or body number (a small hole's is its loop number); <c>Size</c>
/// how small.</summary>
public sealed record SmallFeature(string Kind, uint Index, double Size);

/// <summary>What a mesh of the body shows (<see cref="HealthReport.Cracks"/>, asked for with
/// <c>mesh</c>): whether it is <c>Watertight</c>, how many mesh edges are <c>Open</c> or
/// <c>Folded</c>, how many <c>Crossings</c>, and the body's <c>Edges</c> the cracks lie along.
/// Only a closed body is counted: an open one's census is empty by design.</summary>
public sealed record Cracks(bool Watertight, uint Open, uint Folded, uint Crossings, IReadOnlyList<uint> Edges);

/// <summary>What is wrong with a body, as plain data (<see cref="Solid.Health"/>): the
/// <c>Tolerance</c> and <c>Rounding</c> it judged at and the body's <c>Extent</c>; the free
/// edges, their wires, the features below the tolerance; the loose edges (<c>WorstLoose</c> the
/// widest gap); what sewing would do (<c>SewPairs</c> joined, <c>SewRefused</c>,
/// <c>SewWorstGap</c>); the mesh's <c>Cracks</c> if asked for, else null; and
/// <c>WorstGap</c>, the widest gap between a free edge and its partner.</summary>
public sealed record HealthReport(double Tolerance, double Rounding, double Extent, IReadOnlyList<FreeEdge> FreeEdges,
                                  IReadOnlyList<FreeWire> Wires, IReadOnlyList<SmallFeature> Small, uint LooseEdges,
                                  double WorstLoose, uint SewPairs, uint SewRefused, double SewWorstGap, Cracks? Cracks,
                                  double WorstGap)
{
    /// <summary>The free edges of wire number <c>wire</c> (an index into <see cref="Wires"/>), in order.</summary>
    public IReadOnlyList<FreeEdge> WireEdges(int wire)
    {
        var w = Wires[wire];
        return FreeEdges.Skip((int)w.First).Take((int)w.Count).ToArray();
    }

    internal static readonly string[] Kinds = { "short_edge", "collapsed_edge", "sliver_face", "tiny_face", "tiny_body", "small_hole" };

    /// <summary>The flat rows of the health C ABI as a report: counts 18, sizes 8, free edges
    /// 6 ids + 2 sizes a row, wires 3 + 2, small features 2 + 1, the crack edge ids.</summary>
    internal static HealthReport FromRows(uint[] counts, double[] sizes, uint[] freeIds, double[] freeSizes, uint[] wireRuns,
                                          double[] wireSizes, uint[] smallItems, double[] smallSizes, uint[] crackEdges)
    {
        const uint none = 0xFFFFFFFF;
        var free = new FreeEdge[freeIds.Length / 6];
        for (var i = 0; i < free.Length; i++)
        {
            var edge = freeIds[6 * i + 1];
            var partner = freeIds[6 * i + 4];
            free[i] = new FreeEdge(freeIds[6 * i], edge == none ? null : edge, freeIds[6 * i + 2], freeIds[6 * i + 3],
                                   partner == none ? null : partner, freeIds[6 * i + 5], freeSizes[2 * i], freeSizes[2 * i + 1]);
        }
        var wires = new FreeWire[wireRuns.Length / 3];
        for (var i = 0; i < wires.Length; i++)
            wires[i] = new FreeWire(wireRuns[3 * i], wireRuns[3 * i + 1], wireRuns[3 * i + 2] != 0, wireSizes[2 * i], wireSizes[2 * i + 1]);
        var small = new SmallFeature[smallSizes.Length];
        for (var i = 0; i < small.Length; i++)
            small[i] = new SmallFeature(Kinds[smallItems[2 * i]], smallItems[2 * i + 1], smallSizes[i]);
        var cracks = counts[12] == 1 ? new Cracks(counts[13] != 0, counts[14], counts[15], counts[16], (uint[])crackEdges.Clone()) : null;
        return new HealthReport(sizes[0], sizes[1], sizes[2], free, wires, small, counts[9], sizes[4], counts[10], counts[11],
                                sizes[5], cracks, sizes[3]);
    }
}

/// <summary>One small feature <see cref="Solid.Healed"/> removed (<see cref="HealReport.Fixes"/>):
/// its <c>Kind</c> (as <see cref="SmallFeature.Kind"/>), its <c>Index</c> in the input (the edge,
/// face or loop number <see cref="Solid.Health"/> gave it), its <c>Size</c>, and how far the
/// vertices it merged <c>Moved</c>.</summary>
public sealed record HealFix(string Kind, uint Index, double Size, double Moved);

/// <summary>One small feature <see cref="Solid.Healed"/> left, and why
/// (<see cref="HealReport.Refused"/>): <c>Kind</c> and <c>Index</c> as in <see cref="HealFix"/>;
/// <c>Why</c> is "would_empty_loop", "closed", "seam", "chain" (a chain wider than the
/// tolerance), "neighbours_part" (a sliver's neighbours part), "uneven" (uneven sliver sides),
/// "non_manifold", "has_holes", "body_guard" (the fix made the body's health worse), "toggled"
/// (its kind switched off) or "unsupported"; <c>Figure</c> the chain's width or the neighbours'
/// gap, else 0.</summary>
public sealed record HealRefusal(string Kind, uint Index, string Why, double Figure);

/// <summary>What <see cref="Solid.Healed"/> did, as plain data: the <c>Tolerance</c> it healed
/// at, the furthest any trim <c>Moved</c>, whether the body guard refused fixes
/// (<c>Guarded</c>), the <c>Fixes</c> made and the features <c>Refused</c>; and the body's
/// health before and after at that tolerance -- its small features, free edges, whether it is
/// closed, and its non-manifold edges.</summary>
public sealed record HealReport(double Tolerance, double Moved, bool Guarded, IReadOnlyList<HealFix> Fixes,
                                IReadOnlyList<HealRefusal> Refused, uint SmallBefore, uint SmallAfter, uint FreeBefore,
                                uint FreeAfter, bool ClosedBefore, bool ClosedAfter, uint NonmanifoldBefore,
                                uint NonmanifoldAfter)
{
    internal static readonly string[] Whys = { "would_empty_loop", "closed", "seam", "chain", "neighbours_part", "uneven",
                                               "non_manifold", "has_holes", "body_guard", "toggled", "unsupported" };

    /// <summary>The flat rows of the heal C ABI as a report: counts 11, sizes 2, fixes 2 items +
    /// 2 sizes a row, refusals 3 items + 1 size.</summary>
    internal static HealReport FromRows(uint[] counts, double[] sizes, uint[] fixItems, double[] fixSizes, uint[] refusedItems,
                                        double[] refusedSizes)
    {
        var fixes = new HealFix[fixItems.Length / 2];
        for (var i = 0; i < fixes.Length; i++)
            fixes[i] = new HealFix(HealthReport.Kinds[fixItems[2 * i]], fixItems[2 * i + 1], fixSizes[2 * i], fixSizes[2 * i + 1]);
        var refused = new HealRefusal[refusedSizes.Length];
        for (var i = 0; i < refused.Length; i++)
            refused[i] = new HealRefusal(HealthReport.Kinds[refusedItems[3 * i]], refusedItems[3 * i + 1], Whys[refusedItems[3 * i + 2]],
                                         refusedSizes[i]);
        return new HealReport(sizes[0], sizes[1], counts[2] != 0, fixes, refused, counts[3], counts[4], counts[5], counts[6],
                              counts[7] != 0, counts[8] != 0, counts[9], counts[10]);
    }
}

// ---- documents ---------------------------------------------------------------------------

/// <summary>A model as data: a graph of nodes (`profile.rect`, `solid.extrude`,
/// `measure.mass`, ...), each a blacksmith verb reading other nodes by id, with named parameters
/// any number can be an `"=expression"` of, evaluated incrementally, and edited by ops that are
/// undoable and branch. Every edit is one commit; the whole thing -- nodes, parameters, history,
/// branches -- saves as JSON text and loads back to the same document. <see cref="Kinds"/> lists
/// the node kinds.
///
/// <code>
/// using var doc = new Document("mm");
/// var held = doc.AddSolid(Solid.Cuboid(10, 10, 10).Coloured("#d33"));
/// var text = doc.Save();                                // write it to a file yourself
/// using var back = Document.Load(text);
/// using var solid = back.ResultSolid(held);             // an ordinary Solid of your own
/// Console.WriteLine($"{solid.Faces} faces, {back.ResultKind(held)}");
/// </code>
///
/// A refused op throws <see cref="BuildException"/> with the library's reason
/// (`document_apply: r1 is read by x1`), and the document is unchanged. Ops, the changed sets,
/// the statuses, the parameters, the branch list, the log, `Errors` and `Value` are JSON text,
/// as the C ABI has them -- read them with `System.Text.Json`. `Result*`, `Value`, `Errors` and
/// `ResultKind` bring the nodes up to date first, so the answer is always the current
/// document's; each <see cref="Solid"/>, <see cref="Profile"/>, <see cref="NurbsCurve"/> and
/// <see cref="Subd"/> a result gives is the caller's own and outlives later edits and the
/// document. Owns a handle (a `SafeHandle`): dispose it, or let the runtime free it; a call on a
/// disposed document throws <see cref="ObjectDisposedException"/> ("document: closed"). One
/// thread at a time.</summary>
public sealed class Document : IDisposable
{
    private readonly DocumentHandle _handle;

    private Document(DocumentHandle handle, string what)
    {
        _handle = Blacksmith.Checked(handle, what);
    }

    /// <summary>An empty document counting lengths in <paramref name="units"/> (`mm`, `cm`,
    /// `m`, `in` or `ft`).</summary>
    public Document(string units = "mm") : this(BlacksmithNative.cadaclysm_blacksmith_document_new(units), "document_new")
    {
    }

    /// <summary>The document <see cref="Save"/> wrote as <paramref name="text"/>: its nodes,
    /// parameters, history and branches.</summary>
    public static Document Load(string text) => new(BlacksmithNative.cadaclysm_blacksmith_document_load(text), "document_load");

    /// <summary>The document saved in the file <paramref name="path"/>.</summary>
    public static Document Open(string path) => Load(File.ReadAllText(path, Encoding.UTF8));

    /// <summary>Every node kind the library knows, as the JSON text of an array of rows
    /// (`name`, `inputs`, `output`, `cost`, `help`). Needs no document.</summary>
    public static string Kinds() => Blacksmith.OwnedText(BlacksmithNative.cadaclysm_blacksmith_document_kinds(), "document_kinds");

    /// <summary>An empty building document: the blacksmith kinds and the `bim.*` ones, holding a
    /// hidden `bim.project` node whose random guid seeds every IFC GlobalId it exports.</summary>
    public static Document NewBim(string units = "mm") => new(BlacksmithNative.cadaclysm_bim_document_new(units), "bim_document_new");

    /// <summary>A building document <see cref="Save"/> wrote as <paramref name="text"/>, opened
    /// with the `bim.*` kinds.</summary>
    public static Document LoadBim(string text) => new(BlacksmithNative.cadaclysm_bim_document_load(text), "bim_document_load");

    /// <summary>The building document saved in the file <paramref name="path"/>.</summary>
    public static Document OpenBim(string path) => LoadBim(File.ReadAllText(path, Encoding.UTF8));

    /// <summary>Every node kind a building document knows, the blacksmith's and the `bim.*`
    /// ones, as the JSON text <see cref="Kinds"/> gives. Needs no document.</summary>
    public static string BimKinds() => Blacksmith.OwnedText(BlacksmithNative.cadaclysm_bim_kinds(), "bim_kinds");

    /// <summary>The handle, refusing a disposed document at the call site.</summary>
    internal DocumentHandle Live => !_handle.IsClosed ? _handle : throw new ObjectDisposedException(nameof(Document), "document: closed");

    public bool Closed => _handle.IsClosed;

    /// <summary>Give the document back. Idempotent. Results already read are the caller's own
    /// and live on.</summary>
    public void Dispose() => _handle.Dispose();

    public override string ToString() => _handle.IsClosed ? "Document(closed)" : "Document()";

    private string Text(IntPtr raw, string what) => Blacksmith.OwnedText(raw, "document_" + what);

    // -- saving

    /// <summary>The document as JSON text: write it to a file yourself.</summary>
    public string Save() => Text(BlacksmithNative.cadaclysm_blacksmith_document_save(Live), "save");

    /// <summary>The building as IFC text. <paramref name="options"/> is C's JSON, null for every
    /// default: `{"schema": "IFC4" | "IFC2X3", "geometry": "parametric" | "exact",
    /// "timestamp": unix seconds (default now), "name": the IfcProject's}`. A refused export
    /// throws with C's text verbatim: `bim_document_export_ifc: {"refusals": [{"node", "reason"}]}`,
    /// every reason at once, `node` null for one on the whole document.</summary>
    public string ExportIfc(string? options = null) =>
        Blacksmith.OwnedText(BlacksmithNative.cadaclysm_bim_document_export_ifc(Live, options), "bim_document_export_ifc");

    // -- editing

    /// <summary>Applies one op, as JSON text (`{"op": "add", "node": {...}}`, `set`, `remove`,
    /// `rename`, `param`), and records it as one commit with <paramref name="message"/>. The
    /// changed set's JSON text, `{"added": [ids], "changed": [ids], "removed": [ids], "params":
    /// [names]}`.</summary>
    public string Apply(string op, string? message = null) =>
        Text(BlacksmithNative.cadaclysm_blacksmith_document_apply(Live, op, string.IsNullOrEmpty(message) ? null : message), "apply");

    /// <summary>A node holding <paramref name="solid"/> exactly as it is -- one made in code or
    /// read from a file -- for other nodes to read like any built one: a `solid.body` (a
    /// `sheet.body` with <paramref name="sheet"/>) carrying the kernel's own B-rep
    /// (<see cref="Solid.DocumentBody"/>), in this document's units. Its colours are kept, its
    /// name is not. The new id.</summary>
    public string AddSolid(Solid solid, bool sheet = false) =>
        AddHolding("{\"op\": \"add\", \"node\": {\"kind\": \"" + (sheet ? "sheet.body" : "solid.body") + "\", \"body\": " + solid.DocumentBody() + "}}");

    /// <summary>A `profile.path` node holding <paramref name="profile"/> exactly
    /// (<see cref="Profile.DocumentPath"/>: arcs and NURBS as they are, holes included, its
    /// colour kept), in this document's units. The new id.</summary>
    public string AddProfile(Profile profile) =>
        AddHolding("{\"op\": \"add\", \"node\": {\"kind\": \"profile.path\", \"path\": " + profile.DocumentPath() + "}}");

    private string AddHolding(string op)
    {
        var changed = Apply(op);
        using var json = System.Text.Json.JsonDocument.Parse(changed);
        if (json.RootElement.TryGetProperty("added", out var added) && added.GetArrayLength() > 0)
            return added[0].GetString()!;
        throw new BuildException($"document_apply: no node was added ({changed})");
    }

    /// <summary>The parameters' JSON text, name to value (a number, or an `"=expression"`).
    /// Read-only: set one with a `param` op through <see cref="Apply"/>.</summary>
    public string Params() => Text(BlacksmithNative.cadaclysm_blacksmith_document_params(Live), "params");

    /// <summary>Runs <paramref name="body"/> with a batch open: the ops it applies are live and
    /// recorded as one commit with <paramref name="message"/> (nothing for none). An exception
    /// out of it takes every op of the batch back and is passed on -- the body's own, even when
    /// the clean-up is refused.</summary>
    public void Batch(string? message, Action body)
    {
        ArgumentNullException.ThrowIfNull(body);
        if (!BlacksmithNative.cadaclysm_blacksmith_document_batch_begin(Live, string.IsNullOrEmpty(message) ? null : message))
            throw Blacksmith.Failure("document_batch_begin");
        try
        {
            body();
        }
        catch
        {
            try { Text(BlacksmithNative.cadaclysm_blacksmith_document_batch_abort(Live), "batch_abort"); }
            catch (BuildException) { }           // the body's exception is the one to report,
            catch (ObjectDisposedException) { }  // not a refused clean-up
            throw;
        }
        Text(BlacksmithNative.cadaclysm_blacksmith_document_batch_end(Live), "batch_end");
    }

    /// <summary><see cref="Batch(string?, Action)"/> with no message.</summary>
    public void Batch(Action body) => Batch(null, body);

    /// <summary>Runs <paramref name="body"/> with a preview open: the ops it applies evaluate but
    /// are never recorded, and are taken back on leaving, normally or by an exception (passed on,
    /// the body's own even when the clean-up is refused): a what-if.</summary>
    public void Preview(Action body)
    {
        ArgumentNullException.ThrowIfNull(body);
        if (!BlacksmithNative.cadaclysm_blacksmith_document_preview_begin(Live))
            throw Blacksmith.Failure("document_preview_begin");
        try
        {
            body();
        }
        catch
        {
            try { EndPreview(); }
            catch (BuildException) { }
            catch (ObjectDisposedException) { }
            throw;
        }
        EndPreview();
    }

    /// <summary>One frame of a drag: applies <paramref name="op"/> (JSON text) without recording
    /// it, after taking back the frame before, so each frame is relative to the state before the
    /// drag. The changed set's JSON text. Needs no scope; <see cref="EndPreview"/> takes the drag
    /// back.</summary>
    public string PreviewFrame(string op) => Text(BlacksmithNative.cadaclysm_blacksmith_document_preview(Live, op), "preview");

    /// <summary>Takes back an open preview or drag; the changed set's JSON text.</summary>
    public string EndPreview() => Text(BlacksmithNative.cadaclysm_blacksmith_document_end_preview(Live), "end_preview");

    // -- history

    /// <summary>Takes back the head commit. False when there was nothing to take back.</summary>
    public bool Undo() => Text(BlacksmithNative.cadaclysm_blacksmith_document_undo(Live), "undo").Trim() != "null";

    /// <summary>Puts back the commit <see cref="Undo"/> took back. False when there was nothing
    /// to put back.</summary>
    public bool Redo() => Text(BlacksmithNative.cadaclysm_blacksmith_document_redo(Live), "redo").Trim() != "null";

    /// <summary>The branch list's JSON text: `{"branches": {name: commit id}, "branch": the
    /// current name or null (a detached head), "head": commit id, "unnamed": [commit ids],
    /// "can_undo": bool, "can_redo": bool}`.</summary>
    public string Branches() => Text(BlacksmithNative.cadaclysm_blacksmith_document_branch_list(Live), "branch_list");

    /// <summary>A new branch <paramref name="name"/>. Without <paramref name="at"/> it starts at
    /// the head and the document switches onto it; with a commit id it starts there.</summary>
    public void BranchNew(string name, string? at = null) =>
        Text(BlacksmithNative.cadaclysm_blacksmith_document_branch_new(Live, name, string.IsNullOrEmpty(at) ? null : at), "branch_new");

    /// <summary>Moves the head to the branch of that name, else to the commit of that id (which
    /// detaches the head). The nodes follow.</summary>
    public void Switch(string nameOrCommitId) =>
        Text(BlacksmithNative.cadaclysm_blacksmith_document_branch_switch(Live, nameOrCommitId), "branch_switch");

    /// <summary>Renames branch <paramref name="old"/> to <paramref name="new"/>; refused when
    /// the old name is missing or the new one is taken.</summary>
    public void BranchRename(string old, string @new)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_document_branch_rename(Live, old, @new))
            throw Blacksmith.Failure("document_branch_rename");
    }

    /// <summary>Deletes branch <paramref name="name"/>; the current branch is refused. Its
    /// commits stay, as tips.</summary>
    public void BranchDelete(string name)
    {
        if (!BlacksmithNative.cadaclysm_blacksmith_document_branch_delete(Live, name))
            throw Blacksmith.Failure("document_branch_delete");
    }

    /// <summary>The tips of the lines no branch names, as the JSON text of whole commits
    /// (`[{"id", "parents", "message"?, "author"?, "time"?, "ops"}]`).</summary>
    public string Tips() => Text(BlacksmithNative.cadaclysm_blacksmith_document_tips(Live), "tips");

    /// <summary>The commits of <paramref name="branch"/>'s line (null: from the head back to
    /// the root), newest first, as JSON text, `[{"id", "parents", "message"?, "author"?,
    /// "time"?, "ops"}]`.</summary>
    public string Log(string? branch = null) =>
        Text(BlacksmithNative.cadaclysm_blacksmith_document_log(Live, string.IsNullOrEmpty(branch) ? null : branch), "log");

    // -- evaluating and reading back

    /// <summary>Evaluates the nodes that are stale (only the cheap kinds with
    /// <paramref name="cheapOnly"/>); the statuses' JSON text, `[{"id", "state":
    /// "ok"|"error"|"blocked"|"pending", ...}]`.</summary>
    public string Evaluate(bool cheapOnly = false) =>
        Text(BlacksmithNative.cadaclysm_blacksmith_document_evaluate(Live, cheapOnly), "evaluate");

    /// <summary><see cref="Evaluate"/>, every kernel call's progress heard by
    /// <paramref name="progress"/>(node, phase, done, total): node the id of the node being
    /// built (a progress bar, or a note of which node was being built when the process died).
    /// The same statuses; a cheap-only pass reports nothing. <paramref name="progress"/> runs on
    /// this thread, often, and must not touch the document; null is silent. An exception it
    /// throws is rethrown once the call has returned, never through the library's frames.</summary>
    public string EvaluateWith(Action<string, string, long, long>? progress, bool cheapOnly = false)
    {
        if (progress is null)
            return Text(BlacksmithNative.cadaclysm_blacksmith_document_evaluate_with(Live, cheapOnly, null, IntPtr.Zero), "evaluate_with");
        Exception? thrown = null;
        BlacksmithNative.DocumentProgress heard = (node, phase, done, total, _) =>
        {
            if (thrown is not null) return;
            try { progress(Blacksmith.Text(node), Blacksmith.Text(phase), (long)done.ToUInt64(), (long)total.ToUInt64()); }
            catch (Exception e) { thrown = e; }
        };
        var raw = BlacksmithNative.cadaclysm_blacksmith_document_evaluate_with(Live, cheapOnly, heard, IntPtr.Zero);
        GC.KeepAlive(heard);
        if (thrown is not null)
        {
            if (raw != IntPtr.Zero) BlacksmithNative.cadaclysm_blacksmith_string_free(raw);
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(thrown).Throw();
        }
        return Text(raw, "evaluate_with");
    }

    private void UpToDate() => Evaluate();

    /// <summary>The nodes the evaluation left in error or blocked, as JSON text, `[{"id",
    /// "state", "message"}]`.</summary>
    public string Errors()
    {
        UpToDate();
        return Text(BlacksmithNative.cadaclysm_blacksmith_document_errors(Live), "errors");
    }

    /// <summary>Node <paramref name="id"/>'s value as JSON text: a number, a point or list, a
    /// record, text. Throws for a node with none (missing, or in error).</summary>
    public string Value(string id)
    {
        UpToDate();
        return Text(BlacksmithNative.cadaclysm_blacksmith_document_value(Live, id), "value");
    }

    /// <summary>What node <paramref name="id"/> evaluated to: "solid", "sheet", "profile",
    /// "profiles", "nurbs", "subd", "curve", "list" (a node run over a list: its items are
    /// `id#0`, `id#1`, ...), "value", or "none" (no such node, or one that failed). Read it with
    /// the matching `Result*`, or <see cref="Value"/>.</summary>
    public string ResultKind(string id)
    {
        UpToDate();
        return Text(BlacksmithNative.cadaclysm_blacksmith_document_result_kind(Live, id), "result_kind");
    }

    /// <summary>Node <paramref name="id"/>'s solid or sheet, a <see cref="Solid"/> of the
    /// caller's own. Throws when it is not an evaluated solid or sheet.</summary>
    public Solid ResultSolid(string id)
    {
        UpToDate();
        return new Solid(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_document_result_solid(Live, id), "document_result_solid"));
    }

    /// <summary>Node <paramref name="id"/>'s profile, a <see cref="Profile"/> of the caller's
    /// own. Throws when it is not an evaluated profile.</summary>
    public Profile ResultProfile(string id)
    {
        UpToDate();
        return new Profile(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_document_result_profile(Live, id), "document_result_profile"));
    }

    /// <summary>Node <paramref name="id"/>'s profiles, when it is a list of profiles (or a
    /// sketch), each of the caller's own. Throws otherwise.</summary>
    public IReadOnlyList<Profile> ResultProfiles(string id)
    {
        UpToDate();
        var count = BlacksmithNative.cadaclysm_blacksmith_document_result_profile_count(Live, id);
        if (count == Blacksmith.None) throw Blacksmith.Failure("document_result_profile_count");
        var profiles = new List<Profile>((int)Math.Min(count, 1024u));
        try
        {
            for (uint i = 0; i < count; i++)
                profiles.Add(new Profile(Blacksmith.Checked(
                    BlacksmithNative.cadaclysm_blacksmith_document_result_profile_at(Live, id, i), "document_result_profile_at")));
        }
        catch
        {
            foreach (var p in profiles) p.Dispose();
            throw;
        }
        return profiles;
    }

    /// <summary>Node <paramref name="id"/>'s NURBS curve, a <see cref="NurbsCurve"/> of the
    /// caller's own. Throws when it is not one.</summary>
    public NurbsCurve ResultNurbsCurve(string id)
    {
        UpToDate();
        return NurbsCurve.Of(BlacksmithNative.cadaclysm_blacksmith_document_result_nurbs_curve(Live, id), "document_result_nurbs_curve");
    }

    /// <summary>Node <paramref name="id"/>'s subdivision cage, a <see cref="Subd"/> of the
    /// caller's own. Throws when it is not one.</summary>
    public Subd ResultSubd(string id)
    {
        UpToDate();
        return new Subd(Blacksmith.Checked(BlacksmithNative.cadaclysm_blacksmith_document_result_subd(Live, id), "document_result_subd"));
    }
}
