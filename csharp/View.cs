// Drawing through cadaclysm_view.h: the terminal by default, the GPU window with
// ViewLibrary.UseWgpu(), a host's window with View.InWindow, or offscreen with View.Offscreen.
//
//     ViewLibrary.UseWgpu();
//     using var part = Solid.Cuboid(20, 20, 20);
//     part.Show();                                   // blocks until the window is closed
//     using var v = View.Offscreen(800, 600);        // no display needed
//     v.ShowSolid(part); v.Standard("iso"); v.Frame(); v.Save("part.png");
//
// Compile it with Cad.cs and Blacksmith.cs: each refers to the others (Cad.cs's Scene.Show and
// Scene.Close call into this file). Solids and scenes are shown by handle; an Item holds the
// object it shows. The view library is bound under the name "cadaclysm_view" through Cad.cs's
// resolver, once per process: choose it with ViewLibrary before the first view (or LoadFont, which
// binds it too); a later Use of another library is refused. A view belongs to the thread that made it: every call from another
// thread is refused, and a scene a live view of another thread still shows cannot be closed (it
// stays open, with the reason). A view nobody disposes is destroyed when the runtime collects it.
using System.IO.Compression;
using System.Runtime.InteropServices;
using Cadaclysm.Blacksmith;

namespace Cadaclysm.Viewing;

/// <summary>What a view library refused, in its own words.</summary>
public sealed class ViewException : Exception
{
    public ViewException(string message) : base(message) { }
}

// ---- the ABI's structs, one field per line (tests/bindings.rs reads them) ------------------

internal struct RawViewWindow
{
    public uint Size;
    public uint Kind;
    public IntPtr Window;
    public ulong WindowId;
    public IntPtr Display;
    public uint Width;
    public uint Height;
}

internal struct RawViewOptions
{
    public uint Size;
    public uint Surfaces;
    public uint Backend;
    public uint YUp;
    public IntPtr Title;
    public uint Width;
    public uint Height;
    public uint Offscreen;
}

internal unsafe struct RawViewCamera
{
    public uint Size;
    public fixed float Eye[3];
    public fixed float Target[3];
    public fixed float Up[3];
    public uint Orthographic;
}

internal unsafe struct RawViewPick
{
    public uint Size;
    public uint Item;
    public uint Node;
    public uint Face;
    public uint Clicks;
    public uint HasPoint;
    public fixed float Point[3];
}

internal struct RawViewLod
{
    public uint Size;
    public uint MinTriangles;
    public uint Motion;
}

internal unsafe struct RawViewViewport
{
    public uint Size;
    public fixed uint Rect[4];
    public fixed float View[16];
    public fixed float Projection[16];
    public fixed float Eye[3];
    public uint Grid;
    public uint LayerMask;
}

internal struct RawViewEvent
{
    public uint Size;
    public uint Kind;
    public uint PointerId;
    public uint Pointer;
    public uint Button;
    public uint Shift;
    public float X;
    public float Y;
    public float WheelY;
    public IntPtr Key;
    public uint KeyDown;
    public double TimeMs;
    public uint Alt;
}

internal struct RawViewMesh
{
    public uint Size;
    public IntPtr Positions;
    public uint VertexCount;
    public IntPtr Normals;
    public IntPtr Indices;
    public uint IndexCount;
    public IntPtr Edges;
    public uint EdgeCount;
    public IntPtr Rgb;
}

internal unsafe struct RawViewImage
{
    public uint Size;
    public fixed float Corners[12];
    public IntPtr Rgba;
    public uint Width;
    public uint Height;
    public float Opacity;
    public uint FlipX;
    public uint FlipY;
}

internal unsafe struct RawViewText
{
    public uint Size;
    public IntPtr Text;
    public uint Mode;
    public fixed float At[3];
    public fixed float Right[3];
    public fixed float Up[3];
    public float Height;
    public fixed float Rgb[3];
    public uint Align;
    public fixed float Offset[2];
    public fixed float BoxRgba[4];
    public float BoxPadding;
    public uint OnTop;
    public uint Font;
}

internal unsafe struct RawViewProgram
{
    public uint Size;
    public uint ToolNumber;
    public uint ToolShape;
    public double ToolDiameter;
    public double ToolFluteLength;
    public double ToolAngle;
    public double ToolCornerRadius;
    public IntPtr Gcode;
}

internal unsafe struct RawViewMachining
{
    public uint Size;
    public uint ProgramCount;
    public IntPtr Programs;
    public fixed double StockMin[3];
    public fixed double StockMax[3];
    public IntPtr PartPositions;
    public IntPtr PartIndices;
    public uint PartVertexCount;
    public uint PartIndexCount;
    public double Cell;
    public double Tolerance;
    public double Skin;
    public double RapidRate;
    public uint SkinSet;
}

internal unsafe struct RawViewMachiningInfo
{
    public uint Size;
    public uint Moves;
    public uint Move;
    public uint Nx;
    public uint Ny;
    public float Cell;
    public fixed float Min[2];
    public double CycleTime;
}

// 1.10, bound only: nothing in this file fills one yet (C#'s viewport-camera API comes later).
#pragma warning disable CS0649
internal unsafe struct RawViewViewportCamera
{
    public uint Size;
    public uint Kind;
    public fixed uint Rect[4];
    public fixed float View[16];
    public fixed float Projection[16];
    public fixed float Eye[3];
    public fixed float Target[3];
    public float Distance;
    public float Yaw;
    public float Pitch;
    public uint Orthographic;
    public float Speed;
    public float Radius;
    public float Height;
    public fixed float AxisView[3];
    public fixed float AxisRight[3];
    public fixed float AxisUp[3];
}
#pragma warning restore CS0649

internal sealed class ViewHandle : CadaclysmHandle
{
    public ViewHandle() { }

    /// <summary>Tests: called just before the destroy.</summary>
    internal static Action? Destroying { get; set; }

    protected override bool ReleaseHandle()
    {
        Destroying?.Invoke();
        ViewNative.cadaclysm_view_destroy(handle);
        return true;
    }
}

/// <summary>Every call of `cadaclysm_view.h`, bound under the one name the resolver maps to the
/// chosen library.</summary>
internal static unsafe class ViewNative
{
    private const string Lib = "cadaclysm_view";

    static ViewNative()
    {
        Loader.View = ViewLibrary.Bind;
        Loader.Register();
    }

    [DllImport(Lib)] internal static extern uint cadaclysm_view_abi_version();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_view_last_error();
    [DllImport(Lib)] internal static extern IntPtr cadaclysm_view_name();
    // 1.5: colour text as three floats in 0..1; false, with the reason in last_error, for text that is no colour.
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_parse_colour([MarshalAs(UnmanagedType.LPUTF8Str)] string text, float* rgb);
    [DllImport(Lib)] internal static extern ViewHandle cadaclysm_view_create(RawViewWindow* window, RawViewOptions* options);
    [DllImport(Lib)] internal static extern void cadaclysm_view_destroy(IntPtr view);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_pump(ViewHandle view, uint timeoutMs);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_run(ViewHandle view, RawViewCamera* camera, RawViewPick* pick);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_resize(ViewHandle view, uint width, uint height);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_needs_draw(ViewHandle view);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_draw(ViewHandle view);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show(ViewHandle view, SceneHandle scene);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_remove(ViewHandle view, uint item);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_surfaces(ViewHandle view, uint surfaces);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_surfaces(ViewHandle view);
    [DllImport(Lib)] internal static extern void cadaclysm_view_orbit(ViewHandle view, float dx, float dy);
    [DllImport(Lib)] internal static extern void cadaclysm_view_pan(ViewHandle view, float dx, float dy);
    [DllImport(Lib)] internal static extern void cadaclysm_view_zoom(ViewHandle view, float steps);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_frame(ViewHandle view, uint item);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_standard(ViewHandle view, uint which);
    [DllImport(Lib)] internal static extern void cadaclysm_view_set_orthographic(ViewHandle view, [MarshalAs(UnmanagedType.I1)] bool on);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_layer(ViewHandle view, uint layer, [MarshalAs(UnmanagedType.I1)] bool on);
    [DllImport(Lib)] internal static extern void cadaclysm_view_set_background(ViewHandle view, float* rgb);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_lod(ViewHandle view, RawViewLod* lod);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_wake_ms(ViewHandle view);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_node_visible(ViewHandle view, uint item, uint node, [MarshalAs(UnmanagedType.I1)] bool visible);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_node_color(ViewHandle view, uint item, uint node, float* rgba);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_node_highlight(ViewHandle view, uint item, uint node, float* rgba);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_viewports(ViewHandle view, RawViewViewport* viewports, uint count);
    [DllImport(Lib)] internal static extern void cadaclysm_view_request_pick(ViewHandle view, uint x, uint y);
    [DllImport(Lib)] internal static extern void cadaclysm_view_request_pick_in(ViewHandle view, uint viewport, uint x, uint y);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_pick_result(ViewHandle view, RawViewPick* output);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_frame_node(ViewHandle view, uint item, uint node);
    [DllImport(Lib)] internal static extern void cadaclysm_view_look(ViewHandle view, float dx, float dy);
    [DllImport(Lib)] internal static extern void cadaclysm_view_dolly(ViewHandle view, float ratio);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_input(ViewHandle view, RawViewEvent* ev);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show_mesh(ViewHandle view, RawViewMesh* mesh);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show_lines(ViewHandle view, float* segments, uint segmentCount, float* rgb);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show_points(ViewHandle view, float* positions, uint pointCount, float* rgb, float sizePx);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show_curves(ViewHandle view, float* beziers, uint curveCount, float* rgb);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show_image(ViewHandle view, RawViewImage* image);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_colour(ViewHandle view, uint item, float* rgb);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_xray(ViewHandle view, uint item, [MarshalAs(UnmanagedType.I1)] bool on);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_occluded(ViewHandle view, uint item, uint mode);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_finish(ViewHandle view, uint item, uint finish);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_face_colours(ViewHandle view, uint item, uint* faces, float* rgba, uint count);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_placement(ViewHandle view, uint item, double* matrix);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_node_transforms(ViewHandle view, uint item, double* transforms, uint count);
    // 1.7: the machining and the timeline.
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show_machining(ViewHandle view, RawViewMachining* machining);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_machining_seek(ViewHandle view, uint item, uint to);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_machining_colour_by(ViewHandle view, uint item, uint mode);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_machining_overlays(ViewHandle view, uint item, [MarshalAs(UnmanagedType.I1)] bool path, [MarshalAs(UnmanagedType.I1)] bool tool);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_machining_info(ViewHandle view, uint item, RawViewMachiningInfo* info);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_machining_heights(ViewHandle view, uint item, float* heights, nuint capacity);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_timeline_play(ViewHandle view, double speed);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_timeline_pause(ViewHandle view);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_timeline_seek(ViewHandle view, double seconds);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_timeline_set_loop(ViewHandle view, [MarshalAs(UnmanagedType.I1)] bool on);
    [DllImport(Lib)] internal static extern double cadaclysm_view_timeline_time(ViewHandle view);
    [DllImport(Lib)] internal static extern double cadaclysm_view_timeline_duration(ViewHandle view);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)] internal static extern bool cadaclysm_view_timeline_playing(ViewHandle view);
    [DllImport(Lib)] internal static extern nuint cadaclysm_view_timeline_status(ViewHandle view, byte* text, nuint capacity);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show_solid(ViewHandle view, SolidHandle solid, double tolerance, float* rgb);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_image(ViewHandle view, byte* rgba, nuint capacity);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_size(ViewHandle view, uint* width, uint* height);
    // 1.6: text.
    [DllImport(Lib)] internal static extern uint cadaclysm_view_load_font(byte* bytes, nuint length);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_show_text(ViewHandle view, RawViewText* text);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_text(ViewHandle view, uint item, [MarshalAs(UnmanagedType.LPUTF8Str)] string text);
    // 1.8: the double-click opt-in, focus, the navigation mode.
    [DllImport(Lib)] internal static extern void cadaclysm_view_set_double_click_frames(ViewHandle view, [MarshalAs(UnmanagedType.I1)] bool on);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_focus(ViewHandle view, float* point);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_navigation(ViewHandle view);
    // 1.9: the lighting.
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_lighting(ViewHandle view, uint lighting);
    [DllImport(Lib)] internal static extern uint cadaclysm_view_lighting(ViewHandle view);
    // 1.10: the viewport cameras (bound; C#'s own API for them comes later).
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_viewport_camera(ViewHandle view, uint viewport, RawViewViewportCamera* camera);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_viewport_camera(ViewHandle view, uint viewport, RawViewViewportCamera* camera);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_viewport_rects(ViewHandle view, uint* rects, uint count);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_aim(ViewHandle view, uint viewport, float* direction, float* up);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_pivot(ViewHandle view, uint viewport, float* point);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_set_tap(ViewHandle view, float px, double ms);
    [DllImport(Lib)] internal static extern void cadaclysm_view_orbit_in(ViewHandle view, uint viewport, float dx, float dy);
    [DllImport(Lib)] internal static extern void cadaclysm_view_pan_in(ViewHandle view, uint viewport, float dx, float dy);
    [DllImport(Lib)] internal static extern void cadaclysm_view_zoom_in(ViewHandle view, uint viewport, float steps);
    [DllImport(Lib)] internal static extern void cadaclysm_view_look_in(ViewHandle view, uint viewport, float dx, float dy);
    [DllImport(Lib)] internal static extern void cadaclysm_view_dolly_in(ViewHandle view, uint viewport, float ratio);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_frame_in(ViewHandle view, uint viewport, uint item);
    [DllImport(Lib)] [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool cadaclysm_view_standard_in(ViewHandle view, uint viewport, uint which);

    internal static string LastError() => Marshal.PtrToStringUTF8(cadaclysm_view_last_error()) ?? "";

    /// <summary>A colour's text as r, g, b in 0..1 -- `"#rgb"`, `"#rrggbb"` (the `#` optional) or one of
    /// the 148 CSS colour names, any case -- read by the view library's own `cadaclysm_view_parse_colour`
    /// (Python's `_colour`), so every wrapper takes the same forms; null stays null. A ViewException with
    /// the library's message for text that is no colour.</summary>
    internal static float[]? Colour(string? text)
    {
        if (text is null) return null;
        var rgb = new float[3];
        fixed (float* c = rgb) if (cadaclysm_view_parse_colour(text, c)) return rgb;
        var why = LastError();
        throw new ViewException(why.Length == 0 ? $"colour '{text}'" : why);
    }

    /// <summary>Colour text as four floats, alpha 1 (text carries none); null stays null.</summary>
    internal static float[]? Rgba(string? text) => Colour(text) is { } c ? new[] { c[0], c[1], c[2], 1f } : null;

    /// <summary>The text, or a ViewException for one holding a NUL (the C string would end there).</summary>
    internal static string TextOf(string text) => text is null ? throw new ViewException("text: a string, not null") : text.Contains('\0')
        ? throw new ViewException($"text \"{text}\": a NUL character cannot be shown (the C string ends there)")
        : text;

    /// <summary>The library's own reason, bare; Python's fallback when it gave none.</summary>
    internal static ViewException Failure()
    {
        var why = LastError();
        return new ViewException(why.Length == 0 ? "the view library failed" : why);
    }
}

/// <summary>Which view library draws: the terminal (default), the wgpu window library, or a path.
/// The runtime binds a `DllImport` name once per process, so the choice is fixed at the first
/// view (asking <see cref="Name"/> or <see cref="Kind"/> fixes nothing): after that a `Use*` naming
/// another library is refused.</summary>
public static unsafe class ViewLibrary
{
    private static readonly object Gate = new();
    private static IntPtr _handle;
    private static string? _path;
    private static string _name = "";
    private static bool _bound;

    private static string FileName(string b) =>
        OperatingSystem.IsWindows() ? $"{b}.dll" : OperatingSystem.IsMacOS() ? $"lib{b}.dylib" : $"lib{b}.so";

    /// <summary>The variable (a file or a directory), beside this assembly, then lib/ and target/{release,debug} above it.</summary>
    internal static string Find(string b, string variable) =>
        Find(b, variable, Environment.GetEnvironmentVariable(variable), System.IO.Path.GetDirectoryName(typeof(ViewLibrary).Assembly.Location));

    /// <summary>Find with the variable's value and this assembly's folder given (tests).</summary>
    internal static string Find(string b, string variable, string? env, string? here)
    {
        var name = FileName(b);
        var terminal = b.EndsWith("_terminal");
        if (!string.IsNullOrEmpty(env))
        {
            var directory = Directory.Exists(env);
            var c = directory ? System.IO.Path.Combine(env, name) : env;
            if (File.Exists(c)) return c;
            // Python's words: the terminal's variable also says which file a directory lacks.
            throw new ViewException($"{variable}={env} names nothing that exists"
                + (terminal && directory ? $" (no {name} in that directory)" : ""));
        }
        var searched = SearchOrder(here, name);
        foreach (var c in searched) if (File.Exists(c)) return c;
        var where = string.Join(", ", searched);
        throw new ViewException(terminal
            ? $"no view library: the terminal library was not found (searched: {where}) "
                + "-- reinstall cadaclysm, set CADACLYSM_TERMINAL_LIBRARY to the library, or set CADACLYSM_VIEW"
            : $"no view library: {name} was not found (searched: {where}) "
                + $"-- reinstall cadaclysm, set {variable} to it, or ViewLibrary.UseTerminal()");
    }

    /// <summary>Where a library named `name` is looked for from `here`: beside it, then every ancestor's
    /// lib/, and only then every ancestor's target/release and target/debug (Node's, Java's and Lua's order).</summary>
    internal static List<string> SearchOrder(string? here, string name)
    {
        var searched = new List<string>();
        if (string.IsNullOrEmpty(here)) return searched;
        searched.Add(System.IO.Path.Combine(here, name));
        var ancestors = new List<string>();
        for (var dir = here; !string.IsNullOrEmpty(dir); dir = System.IO.Path.GetDirectoryName(dir)) ancestors.Add(dir);
        foreach (var dir in ancestors) searched.Add(System.IO.Path.Combine(dir, "lib", name));
        foreach (var dir in ancestors)
        {
            searched.Add(System.IO.Path.Combine(dir, "target", "release", name));
            searched.Add(System.IO.Path.Combine(dir, "target", "debug", name));
        }
        return searched;
    }

    /// <summary>Draw with the terminal library (the default). Before the first view only.</summary>
    public static string UseTerminal() => Use(Find("cadaclysm" + "_terminal", "CADACLYSM_TERMINAL_LIBRARY"));

    /// <summary>Draw with the GPU window library, cadaclysm_view. Before the first view only.</summary>
    public static string UseWgpu() => Use(Find("cadaclysm" + "_view", "CADACLYSM_VIEW_LIBRARY"));

    /// <summary>A TTF/OTF font for every view of the bound library; its id for TextOptions.Font (0 is the bundled Liberation Sans).
    /// Choose the library first (UseWgpu/UseTerminal/Use): a font id belongs to the library that loaded it. LoadFont
    /// binds the library, as the first view does, so a UseWgpu or UseTerminal naming another library afterwards is refused.</summary>
    public static uint LoadFont(byte[] bytes)
    {
        if (bytes is null) throw new ViewException("LoadFont: font bytes, not null");
        Bind();
        fixed (byte* b = bytes)
        {
            uint id = ViewNative.cadaclysm_view_load_font(b, (nuint)bytes.Length);
            return id != 0 ? id : throw ViewNative.Failure();
        }
    }

    /// <summary><see cref="LoadFont(byte[])"/> from a file; a path that cannot be read is a ViewException naming it.</summary>
    public static uint LoadFont(string path)
    {
        if (path is null) throw new ViewException("LoadFont: a font path, not null");
        byte[] bytes;
        try { bytes = File.ReadAllBytes(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException or System.Security.SecurityException)
        {
            throw new ViewException($"{path}: the font could not be read: {e.Message}");
        }
        return LoadFont(bytes);
    }

    /// <summary>Why the library at `path`, answering `version` from cadaclysm_view_abi_version, is
    /// refused -- null when this wrapper takes it (1.18 or a later 1.x).</summary>
    internal static string? AbiRefusal(string path, uint version)
    {
        uint major = version >> 16, minor = version & 0xFFFF;
        // 1.6: text -- show_text, set_text, load_font and the text layer. 1.7: the machining and
        // timeline calls (bound: ShowMachining, Machining, the transport). 1.8: the pick's clicks and point,
        // set_double_click_frames, focus, navigation. 1.9: set_lighting and lighting. 1.10: the
        // viewport cameras (bound; C#'s own API for them comes later). 1.11: show_points. 1.13: set_occluded.
        // 1.18: set_finish.
        return major != 1 || minor < 18 ? $"{path}: view ABI {major}.{minor}, this wrapper needs 1.18 or a later 1.x" : null;
    }

    private static bool SamePath(string a, string? b) =>
        string.Equals(a, b, OperatingSystem.IsWindows() || OperatingSystem.IsMacOS() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    /// <summary>Draw with the library at `path`; answers its name. Before the first view only: the
    /// runtime binds the library once, so a different one is refused afterwards.</summary>
    public static string Use(string path)
    {
        lock (Gate)
        {
            var full = System.IO.Path.GetFullPath(path);
            if (_bound)
            {
                if (SamePath(full, _path)) return _name;
                throw new ViewException($"the view library is already bound ({_name}); choose it before the first view or LoadFont");
            }
            if (!NativeLibrary.TryLoad(full, out var h)) throw new ViewException($"{full}: could not load the view library");
            if (!NativeLibrary.TryGetExport(h, "cadaclysm_view_abi_version", out var abi)
                || !NativeLibrary.TryGetExport(h, "cadaclysm_view_name", out var nameFn))
            {
                NativeLibrary.Free(h);
                throw new ViewException($"{full}: not a view library (no cadaclysm_view_abi_version or cadaclysm_view_name)");
            }
            var refusal = AbiRefusal(full, ((delegate* unmanaged<uint>)abi)());
            if (refusal is not null)
            {
                NativeLibrary.Free(h);
                throw new ViewException(refusal);
            }
            var name = Marshal.PtrToStringUTF8(((delegate* unmanaged<IntPtr>)nameFn)()) ?? "";
            if (_handle != IntPtr.Zero) NativeLibrary.Free(_handle);   // a choice made and changed before any view
            (_handle, _path, _name) = (h, full, name);
            return _name;
        }
    }

    /// <summary>The library's name, choosing the default (`CADACLYSM_VIEW`, else the terminal) if none was.
    /// Asking binds nothing: another library may still be chosen until the first view.</summary>
    public static string Name { get { Choose(); return _name; } }

    /// <summary>"wgpu" (cadaclysm_view), "terminal" (cadaclysm_terminal), or "other" -- Python's Library.kind.</summary>
    public static string Kind => Name.StartsWith("cadaclysm-view ", StringComparison.Ordinal) ? "wgpu"
        : Name.StartsWith("cadaclysm-terminal ", StringComparison.Ordinal) ? "terminal" : "other";

    /// <summary>The handle the resolver gives `cadaclysm_view`; from here the choice is fixed.</summary>
    internal static IntPtr Bind()
    {
        lock (Gate)
        {
            Choose();
            _bound = true;
            return _handle;
        }
    }

    /// <summary>Loads the default library (`CADACLYSM_VIEW`, else the terminal) when none was chosen; binds nothing.</summary>
    private static void Choose()
    {
        lock (Gate)
        {
            if (_handle != IntPtr.Zero) return;
            var chosen = Environment.GetEnvironmentVariable("CADACLYSM_VIEW");
            if (chosen == "wgpu") UseWgpu();
            else if (string.IsNullOrEmpty(chosen) || chosen == "terminal") UseTerminal();
            else Use(chosen);
        }
    }

    /// <summary>Handles every open window's events of this thread, draws what is owed, waits at most
    /// `timeoutMs` (on the first window), and answers how many windows are still open -- for a
    /// program's own loop. With no window of this thread's own it just waits, so a loop around it
    /// does not spin. Every window's state is taken before a refusal is thrown.</summary>
    public static int Pump(uint timeoutMs = 0) => View.PumpAll(timeoutMs);
}

public sealed record ViewOptions(string? Title = null, uint Width = 0, uint Height = 0, string Surfaces = "exact", string Up = "z", uint Backend = 0);

/// <summary>What Show() and View() on a Solid, Scene, Node or Pose take. `Up` null is the scene's own
/// up axis ("z" for a solid); `Tolerance` null is 0.05 for a solid and refused for a document, which
/// is drawn at the tolerance it was read with. The colour is `Rgb` (three numbers in 0..1) or `RgbText`
/// (`"#rgb"`, `"#rrggbb"` or a CSS colour name, read by the view library), which wins when both are given.</summary>
public sealed record ShowOptions(string View = "iso", double? Azimuth = null, double? Elevation = null, double? Zoom = null, string? Up = null,
    bool Edges = true, uint Width = 0, uint Height = 0, string? Title = null, double? Tolerance = null, float[]? Rgb = null,
    string? RgbText = null);

/// <summary>ShowText's options: a white 12 px label, bottom-left on its anchor, by default.</summary>
public sealed class TextOptions
{
    /// <summary>"label" (pixels, facing the camera) or "world" (model units, in the plane of Right and Up).</summary>
    public string Mode { get; init; } = "label";
    public float Size { get; init; } = 12f;
    /// <summary>The glyphs' colour as text ("#rgb", "#rrggbb", a CSS name); it wins over Colour when both are set, as ShowOptions' RgbText does.</summary>
    public string? ColourText { get; init; }
    public float[]? Colour { get; init; }
    public string Align { get; init; } = "bottom-left";
    public float[]? Offset { get; init; }
    /// <summary>The label's background box as text (alpha 1); it wins over Box (3 or 4 numbers) when both are set; none by default.</summary>
    public string? BoxText { get; init; }
    public float[]? Box { get; init; }
    public float Padding { get; init; } = 4f;
    public bool OnTop { get; init; }
    public uint Font { get; init; }
    public float[]? Right { get; init; }
    public float[]? Up { get; init; }
}

/// <summary>A host's window: kind 1 win32, 2 xlib, 3 xcb, 4 wayland, 5 appkit.</summary>
public sealed record ViewWindow(uint Kind, IntPtr Window, ulong WindowId, IntPtr Display, uint Width, uint Height);

/// <summary>Type: pointer_down, pointer_move, pointer_up, pointer_cancel, wheel or key (Python's names); TimeMs 0 means now.</summary>
public sealed record ViewEvent(string Type, float X = 0, float Y = 0, uint Button = 0, bool Shift = false, uint PointerId = 0,
    string Pointer = "mouse", float WheelY = 0, string? Key = null, bool KeyDown = true, double TimeMs = 0);

/// <summary>Rect is x, y, w, h in physical pixels, the matrices column-major; Grid: none, top, front or right.</summary>
public sealed record Viewport(uint[] Rect, float[] View, float[] Projection, float[] Eye, string Grid = "none");

/// <summary>A CAM tool: Shape is flat, ball, drill, vbit or bullnose; the flute length, a V-bit's angle and a bull-nose's corner radius are 0 where they mean nothing.</summary>
public sealed record MachiningTool(uint Number, string Shape, double Diameter, double FluteLength = 0, double Angle = 0, double CornerRadius = 0);

/// <summary>One program of a job: the tool that runs it and its G-code.</summary>
public sealed record MachiningProgram(MachiningTool Tool, string Gcode);

/// <summary>The finished part, for colouring by deviation: x y z floats a vertex, three indices a triangle.</summary>
public sealed record MachiningPart(float[] Positions, uint[] Indices);

/// <summary>The library's own default for any null. Skin, once given, is used even at 0.</summary>
public sealed record MachiningOptions(double? Cell = null, double? Tolerance = null, double? Skin = null, double? RapidRate = null);

/// <summary>Machining.Info(): the move the timeline is at of the job's moves, the height grid and the cycle time in seconds.</summary>
public sealed record MachiningInfo(uint Moves, uint Move, uint Nx, uint Ny, float Cell, float[] Min, double CycleTime);

/// <summary>A CAM job shown in a View (View.ShowMachining): the stock is this item; the view's timeline plays it.</summary>
public sealed unsafe class Machining : Item
{
    internal Machining(View view, uint id) : base(view, id, null) { }

    private static readonly string[] Modes = { "height", "tool", "deviation" };

    /// <summary>Jump the timeline to the end of move `move` (0: the untouched stock).</summary>
    public void SeekMove(uint move) =>
        Ok(ViewNative.cadaclysm_view_machining_seek(View.Live("cadaclysm_view_machining_seek"), Id, move));

    /// <summary>"height", "tool" or "deviation" (needs the part given to ShowMachining).</summary>
    public void ColourBy(string mode)
    {
        var m = mode is null ? -1 : Array.IndexOf(Modes, mode);
        if (m < 0) throw new ViewException($"mode '{mode}': one of {string.Join(", ", Modes)}");
        Ok(ViewNative.cadaclysm_view_machining_colour_by(View.Live("cadaclysm_view_machining_colour_by"), Id, (uint)m));
    }

    /// <summary>The toolpath and the tool, each on or off.</summary>
    public void Overlays(bool path = true, bool tool = true) =>
        Ok(ViewNative.cadaclysm_view_machining_overlays(View.Live("cadaclysm_view_machining_overlays"), Id, path, tool));

    public MachiningInfo Info()
    {
        var raw = new RawViewMachiningInfo { Size = (uint)sizeof(RawViewMachiningInfo) };
        Ok(ViewNative.cadaclysm_view_machining_info(View.Live("cadaclysm_view_machining_info"), Id, &raw));
        return new MachiningInfo(raw.Moves, raw.Move, raw.Nx, raw.Ny, raw.Cell, new[] { raw.Min[0], raw.Min[1] }, raw.CycleTime);
    }

    /// <summary>The stock's heights now, Nx * Ny floats, row y then x; waits for the GPU.</summary>
    public float[] Heights()
    {
        var info = Info();
        var n = (ulong)info.Nx * info.Ny;
        if (n > int.MaxValue) throw new ViewException($"heights: {info.Nx} x {info.Ny} cells is too large");
        var z = new float[Math.Max((int)n, 1)];
        fixed (float* p = z) Ok(ViewNative.cadaclysm_view_machining_heights(View.Live("cadaclysm_view_machining_heights"), Id, p, (nuint)n));
        return n == (ulong)z.Length ? z : Array.Empty<float>();
    }
}

/// <summary>A pick answer: the item, node and face hit; Clicks 2 for a double click, else 1; Point where
/// the ray met the model (x, y, z, in the coordinates the items were shown in), or null where the
/// library read no depth (a machining stock, the terminal library).</summary>
public sealed record Pick(uint Item, uint Node, uint Face, uint Clicks = 1, float[]? Point = null);

public sealed record Camera(float[] Eye, float[] Target, float[] Up, bool Orthographic, double Azimuth, double Elevation, Pick? Pick);

/// <summary>RGBA8, rows from the top.</summary>
public sealed record ViewImage(int Width, int Height, byte[] Rgba);

/// <summary>One thing a view shows. It holds the object it shows.</summary>
public unsafe class Item
{
    internal Item(View view, uint id, object? shown) { View = view; Id = id; Shown = shown; }
    public View View { get; }
    public uint Id { get; }
    public object? Shown { get; internal set; }

    internal void Ok(bool done) { if (!done) throw ViewNative.Failure(); }

    public void Remove()
    {
        Ok(ViewNative.cadaclysm_view_remove(View.Live("cadaclysm_view_remove"), Id));
        lock (View.Items) View.Items.Remove(Id);
        Shown = null;
    }

    /// <summary>Poses a shown scene: one world transform per node (sixteen doubles each, column-major,
    /// Pose.RawTransform's layout -- every node of the scene, in index order), drawn in place of each
    /// node's rest transform. null restores the rest pose.</summary>
    public void NodeTransforms(IReadOnlyList<double[]>? transforms)
    {
        if (transforms is null) { Ok(ViewNative.cadaclysm_view_set_node_transforms(View.Live("cadaclysm_view_set_node_transforms"), Id, null, 0)); return; }
        var flat = new double[16 * transforms.Count];
        for (var k = 0; k < transforms.Count; k++)
        {
            View.Exact(transforms[k], 16, $"transform {k}");
            transforms[k].CopyTo(flat, 16 * k);
        }
        var h = View.Live("cadaclysm_view_set_node_transforms");
        fixed (double* m = View.NonNull(flat)) Ok(ViewNative.cadaclysm_view_set_node_transforms(h, Id, m, (uint)transforms.Count));
    }

    /// <summary>Recolours the item: `"#rgb"`, `"#rrggbb"` or a CSS colour name, any case.</summary>
    public void Colour(string rgb)
    {
        if (rgb is null) throw new ViewException("colour: 3 numbers, not none");
        Colour(ViewNative.Colour(rgb)!);
    }

    public void Colour(float[] rgb)
    {
        if (rgb is null) throw new ViewException("colour: 3 numbers, not none");
        View.Exact(rgb, 3, "colour");
        var h = View.Live("cadaclysm_view_set_colour");
        fixed (float* c = rgb) Ok(ViewNative.cadaclysm_view_set_colour(h, Id, c));
    }

    /// <summary>Sixteen doubles, column-major; null puts it back.</summary>
    public void Placement(double[]? matrix)
    {
        View.Exact(matrix, 16, "placement");
        var h = View.Live("cadaclysm_view_set_placement");
        fixed (double* m = matrix) Ok(ViewNative.cadaclysm_view_set_placement(h, Id, m));
    }

    /// <summary>`faces` (pick numbers) coloured by `colours`, one text a face (alpha 1); null faces clears every one.</summary>
    public void FaceColours(uint[]? faces, string[] colours)
    {
        if (faces is null) { FaceColours(null, (float[]?)null); return; }
        var rgba = new float[4 * (colours?.Length ?? 0)];
        for (var k = 0; k < rgba.Length / 4; k++)
            (ViewNative.Rgba(colours![k]) ?? throw new ViewException($"faceColours: colour {k} is null")).CopyTo(rgba, 4 * k);
        FaceColours(faces, rgba);
    }

    /// <summary>`faces` (pick numbers) in `rgba`, four floats a face; null faces clears every one.</summary>
    public void FaceColours(uint[]? faces, float[]? rgba)
    {
        if (faces is not null && (rgba is null || rgba.Length != 4 * faces.Length))
            throw new ViewException($"faceColours: {4 * faces.Length} numbers (rgba, 4 a face), not {rgba?.Length ?? 0}");
        var h = View.Live("cadaclysm_view_set_face_colours");
        if (faces is null) { Ok(ViewNative.cadaclysm_view_set_face_colours(h, Id, null, null, 0)); return; }
        fixed (uint* f = View.NonNull(faces)) fixed (float* c = View.NonNull(rgba!))
            Ok(ViewNative.cadaclysm_view_set_face_colours(h, Id, f, c, (uint)faces.Length));
    }

    public void Frame() => Ok(ViewNative.cadaclysm_view_frame(View.Live("cadaclysm_view_frame"), Id));

    /// <summary>The text item's string replaced, nothing else changed (cadaclysm_view_set_text).</summary>
    public void SetText(string text)
    {
        var h = View.Live("cadaclysm_view_set_text");
        Ok(ViewNative.cadaclysm_view_set_text(h, Id, ViewNative.TextOf(text)));
    }

    public void Xray(bool on) => Ok(ViewNative.cadaclysm_view_set_xray(View.Live("cadaclysm_view_set_xray"), Id, on));

    /// <summary>How the item's lines and points draw where a surface hides them: "off" (not drawn; an
    /// item shows with this until it is set), "solid" (drawn through) or "dashed" (dashed and dimmed).</summary>
    public void Occluded(string mode)
    {
        if (mode is null || !View.OccludedModes.TryGetValue(mode, out uint m))
            throw new ViewException($"occluded: '{mode}' is not 'off', 'solid' or 'dashed'");
        Ok(ViewNative.cadaclysm_view_set_occluded(View.Live("cadaclysm_view_set_occluded"), Id, m));
    }

    /// <summary>The item's finish: "gloss" (an item shows with this until it is set) -- under the
    /// showroom lighting a clear coat mirroring the room, silver at a grazing angle -- "satin" (a
    /// weaker, blurred coat) or "matte" (no mirror, a faint sheen: rubber, cloth). Uploads the scene
    /// again, as a show does: set it as each item is shown rather than over a finished scene item by
    /// item.</summary>
    public void Finish(string finish)
    {
        if (finish is null || !View.Finishes.TryGetValue(finish, out uint f))
            throw new ViewException($"finish: '{finish}' is not 'gloss', 'satin' or 'matte'");
        Ok(ViewNative.cadaclysm_view_set_finish(View.Live("cadaclysm_view_set_finish"), Id, f));
    }

    public void NodeVisible(uint node, bool on) => Ok(ViewNative.cadaclysm_view_set_node_visible(View.Live("cadaclysm_view_set_node_visible"), Id, node, on));

    /// <summary><see cref="NodeColour(uint, float[])"/> with the colour as text (alpha 1); null clears.</summary>
    public void NodeColour(uint node, string? rgba) => NodeColour(node, ViewNative.Rgba(rgba));

    /// <summary>Three or four numbers (alpha 1 when three); null clears.</summary>
    public void NodeColour(uint node, float[]? rgba)
    {
        var four = View.Rgba(rgba, "nodeColour");
        var h = View.Live("cadaclysm_view_set_node_color");
        fixed (float* c = four) Ok(ViewNative.cadaclysm_view_set_node_color(h, Id, node, c));
    }

    /// <summary><see cref="NodeHighlight(uint, float[])"/> with the colour as text: alpha 1, the colour itself; null clears.</summary>
    public void NodeHighlight(uint node, string? rgba) => NodeHighlight(node, ViewNative.Rgba(rgba));

    /// <summary>Tint `node` toward rgba's colour by its alpha (three or four numbers); null clears.</summary>
    public void NodeHighlight(uint node, float[]? rgba)
    {
        var four = View.Rgba(rgba, "nodeHighlight");
        var h = View.Live("cadaclysm_view_set_node_highlight");
        fixed (float* c = four) Ok(ViewNative.cadaclysm_view_set_node_highlight(h, Id, node, c));
    }

    public void FrameNode(uint node) => Ok(ViewNative.cadaclysm_view_frame_node(View.Live("cadaclysm_view_frame_node"), Id, node));
}

public sealed unsafe class View : IDisposable
{
    private static readonly Dictionary<string, uint> Standards = new() { ["top"] = 0, ["front"] = 1, ["right"] = 2, ["iso"] = 3 };
    private static readonly Dictionary<string, uint> Layers = new() { ["surfaces"] = 0, ["edges"] = 1, ["curves"] = 2, ["isocurves"] = 3, ["grid"] = 4, ["text"] = 5 };
    private static readonly Dictionary<string, uint> Aligns = new()
    {
        ["top-left"] = 0, ["top"] = 1, ["top-right"] = 2, ["left"] = 3, ["centre"] = 4, ["center"] = 4,
        ["right"] = 5, ["bottom-left"] = 6, ["bottom"] = 7, ["bottom-right"] = 8,
    };
    internal static readonly Dictionary<string, uint> OccludedModes = new() { ["off"] = 0, ["solid"] = 1, ["dashed"] = 2 };
    internal static readonly Dictionary<string, uint> Finishes = new() { ["gloss"] = 0, ["satin"] = 1, ["matte"] = 2 };
    private static readonly Dictionary<string, uint> TextModes = new() { ["label"] = 0, ["world"] = 1 };
    private static readonly Dictionary<string, uint> Events = new()
    {
        ["pointer_down"] = 1, ["pointer_move"] = 2, ["pointer_up"] = 3, ["pointer_cancel"] = 4, ["wheel"] = 5, ["key"] = 6,
    };
    private static readonly Dictionary<string, uint> Grids = new() { ["none"] = 0, ["top"] = 1, ["front"] = 2, ["right"] = 3 };
    private static readonly Dictionary<string, uint> LodMotion = new() { ["detailed"] = 0, ["smooth"] = 1 };
    private static readonly Dictionary<string, uint> SurfaceKinds = new() { ["exact"] = 0, ["triangles"] = 1 };
    private static readonly Dictionary<string, uint> LightingKinds = new() { ["headlight"] = 0, ["studio"] = 1 };
    private static readonly Dictionary<string, uint> Pointers = new() { ["mouse"] = 0, ["touch"] = 1, ["pen"] = 2 };
    private static readonly Dictionary<string, (double Az, double El)> Views = new()
    {
        ["front"] = (-90, 0), ["back"] = (90, 0), ["left"] = (180, 0), ["right"] = (0, 0),
        ["top"] = (-90, 90), ["bottom"] = (-90, -90), ["iso"] = (-50, 28),
    };
    private const uint InputClose = 1, NoneComing = 0xFFFFFFFF;
    private const uint NavigationFly = 1;   // CADACLYSM_VIEW_NAVIGATION_FLY (ORBIT is 0)
    private const double OrbitPerPixel = 0.01, ZoomPerStep = 0.9;

    /// <summary>Every live view, weakly: <see cref="Release"/> walks it when a scene closes.</summary>
    private static readonly List<WeakReference<View>> Alive = new();
    /// <summary>Views with a window of their own on a window library, in the order made.</summary>
    private static readonly List<View> Open = new();

    private readonly ViewHandle _handle;
    private readonly bool _own, _yUp;
    private bool _windowClosed;
    private bool _drawn;
    private readonly int _thread = Environment.CurrentManagedThreadId;
    internal readonly Dictionary<uint, Item> Items = new();

    /// <summary>Tests only: makes the view `Show()`/`View()` draw into, in place of a window of the
    /// library's own (so a test opens none on a desktop).</summary>
    internal static Func<ViewOptions, View>? OwnView { get; set; }

    /// <summary>Tests only: what `Show()`/`View()` run the view with, in place of `Run()`.</summary>
    internal static Func<View, Camera>? RunOwn { get; set; }

    /// <summary>A window of the library's own.</summary>
    public View(ViewOptions? options = null) : this(options ?? new ViewOptions(), null, false) { }

    public static View Offscreen(uint width, uint height, ViewOptions? options = null) =>
        new((options ?? new ViewOptions()) with { Width = width, Height = height }, null, true);

    /// <summary>A view in a host's window; the host forwards input and resizes and calls Draw.</summary>
    public static View InWindow(ViewWindow window, ViewOptions? options = null)
    {
        if (window.Width == 0 || window.Height == 0)
            throw new ViewException("a host's window needs width and height: its client size in physical pixels");
        if (window.Kind < 1 || window.Kind > 5)
            throw new ViewException($"kind {window.Kind}: 1 (win32) to 5 (appkit)");
        if (window.Kind is >= 2 and <= 4 && window.Display == IntPtr.Zero)
            throw new ViewException($"kind {window.Kind} needs Display (the Display*, xcb_connection_t* or wl_display*)");
        return new((options ?? new ViewOptions()) with { Width = window.Width, Height = window.Height }, window, false);
    }

    private View(ViewOptions o, ViewWindow? window, bool offscreen)
    {
        var up = (o.Up ?? "z").ToLowerInvariant();
        if (up != "y" && up != "z") throw new ViewException($"up \"{o.Up}\": 'y' or 'z'");
        var surfaces = Named(SurfaceKinds, o.Surfaces, "surfaces");
        _yUp = up == "y";
        ViewLibrary.Bind();   // a view fixes the choice: the library is loaded, with its own errors, before any call
        var kind = ViewLibrary.Kind;
        var title = Marshal.StringToCoTaskMemUTF8(string.IsNullOrEmpty(o.Title) ? "Cadaclysm" : o.Title);
        try
        {
            var raw = new RawViewOptions
            {
                Size = (uint)sizeof(RawViewOptions), Surfaces = surfaces, Backend = o.Backend,
                YUp = _yUp ? 1u : 0u, Title = title, Width = o.Width, Height = o.Height, Offscreen = offscreen ? 1u : 0u,
            };
            if (window is null)
            {
                _handle = ViewNative.cadaclysm_view_create(null, &raw);
            }
            else
            {
                var w = new RawViewWindow
                {
                    Size = (uint)sizeof(RawViewWindow), Kind = window.Kind, Window = window.Window, WindowId = window.WindowId,
                    Display = window.Display, Width = window.Width, Height = window.Height,
                };
                _handle = ViewNative.cadaclysm_view_create(&w, &raw);
            }
        }
        finally
        {
            Marshal.FreeCoTaskMem(title);
        }
        if (_handle.IsInvalid)
        {
            var message = ViewNative.LastError();
            if (message.Length == 0) message = "the view library failed";
            if (message.Contains("no display"))
                message += " -- draw without a display with View.Offscreen(width, height), or use the terminal (ViewLibrary.UseTerminal())";
            throw new ViewException(message);
        }
        _own = window is null && !offscreen;
        lock (Alive) Alive.Add(new WeakReference<View>(this));
        if (_own && kind == "wgpu") lock (Open) Open.Add(this);
    }

    /// <summary>The live handle for the C call `call`, refusing another thread's, a closed view and a closed window.</summary>
    internal ViewHandle Live(string call)
    {
        if (Environment.CurrentManagedThreadId != _thread) throw new ViewException($"{call}: a view belongs to the thread that made it");
        if (_handle.IsClosed) throw new ViewException($"{call}: the view is closed");
        if (_windowClosed) throw new ViewException($"{call}: the window is closed");
        return _handle;
    }

    public bool Closed => _handle.IsClosed || _windowClosed;

    private static void Ok(bool done) { if (!done) throw ViewNative.Failure(); }

    /// <summary>A call with no result: a refusal is the library's last error (Python's _void).</summary>
    internal void Void(string call, Action<ViewHandle> body)
    {
        body(Live(call));
        var why = ViewNative.LastError();
        if (why.Length > 0) throw new ViewException(why);
    }

    private Item NewItem(uint id, object? shown)
    {
        if (id == 0) throw ViewNative.Failure();
        var item = new Item(this, id, shown);
        lock (Items) Items[id] = item;
        return item;
    }

    // ---- checks on what is handed to C

    internal static uint Named(Dictionary<string, uint> table, string? value, string what) =>
        value is not null && table.TryGetValue(value, out var found) ? found
            : throw new ViewException($"{what} {(value is null ? "null" : $"\"{value}\"")}: one of {string.Join(", ", table.Keys.Order(StringComparer.Ordinal))}");

    /// <summary>Exactly `n` numbers, or null: C reads that many.</summary>
    internal static T[]? Exact<T>(T[]? values, int n, string what) =>
        values is not null && values.Length != n ? throw new ViewException($"{what}: {n} numbers, not {values.Length}") : values;

    /// <summary>Three or four numbers as four floats (alpha 1 where only three were given); null stays null.</summary>
    internal static float[]? Rgba(float[]? values, string what)
    {
        if (values is null) return null;
        if (values.Length != 3 && values.Length != 4) throw new ViewException($"{what}: 3 or 4 numbers, not {values.Length}");
        return new[] { values[0], values[1], values[2], values.Length > 3 ? values[3] : 1f };
    }

    /// <summary>width x height x 4 bytes in checked arithmetic: a size nobody can allocate is the wrapper's error.</summary>
    internal static long PixelBytes(ulong width, ulong height, string what)
    {
        try
        {
            return checked((long)(width * height * 4));
        }
        catch (OverflowException)
        {
            throw new ViewException($"{what}: {width} x {height} pixels is too large");
        }
    }

    // ---- showing

    /// <summary>A blacksmith Solid, a Scene or a Node, by handle.</summary>
    public Item Show(object obj, float[]? rgb = null, double tolerance = 0.05) => obj switch
    {
        Solid solid => ShowSolid(solid, tolerance, rgb),
        Scene scene => ShowScene(scene),
        Node node => ShowNode(node),
        _ => throw new ViewException($"show: a Solid, Scene or Node, not {obj?.GetType().Name ?? "null"}"),
    };

    /// <summary><see cref="Show(object, float[], double)"/> with the colour as text (`"#rgb"`, `"#rrggbb"`, a CSS name).</summary>
    public Item Show(object obj, string rgb, double tolerance = 0.05) => Show(obj, ViewNative.Colour(rgb), tolerance);

    /// <summary><see cref="ShowSolid(Solid, double, float[])"/> with the colour as text.</summary>
    public Item ShowSolid(Solid solid, double tolerance, string rgb) => ShowSolid(solid, tolerance, ViewNative.Colour(rgb));

    public Item ShowSolid(Solid solid, double tolerance = 0.05, float[]? rgb = null)
    {
        Exact(rgb, 3, "showSolid rgb");
        var h = Live("cadaclysm_view_show_solid");
        fixed (float* c = rgb) return NewItem(ViewNative.cadaclysm_view_show_solid(h, solid.Handle, tolerance, c), solid);
    }

    public Item ShowScene(Scene scene) => ShowScene(scene, scene);

    private Item ShowScene(Scene scene, object shown)
    {
        var h = Live("cadaclysm_view_show");
        return NewItem(ViewNative.cadaclysm_view_show(h, scene.Handle), shown);
    }

    /// <summary>The node's scene by handle, every node outside this one hidden.</summary>
    public Item ShowNode(Node node)
    {
        var item = ShowScene(node.Scene, node);
        var chain = new List<Node>();
        for (Node? at = node; at is not null; at = at.Parent) chain.Insert(0, at);
        IReadOnlyList<Node> level = node.Scene.Roots;
        foreach (var on in chain)
        {
            foreach (var other in level) if (other.Index != on.Index) item.NodeVisible(other.Index, false);
            level = on.Children;
        }
        return item;
    }

    /// <summary>`fixed` pins an empty array as NULL, which the library reads as "none" (no faces: clear
    /// them all; no transforms: the rest pose; no segments: refused). Python hands it an empty array that
    /// is not NULL, so an empty list stays an empty list here too; the count passed is still 0.</summary>
    internal static T[] NonNull<T>(T[] a) where T : unmanaged => a.Length == 0 ? new T[1] : a;

    /// <summary><see cref="ShowMesh(float[], uint[], float[], float[], float[])"/> with the colour as text.</summary>
    public Item ShowMesh(float[] positions, uint[] indices, float[]? normals, float[]? edges, string rgb) =>
        ShowMesh(positions, indices, normals, edges, ViewNative.Colour(rgb));

    /// <summary>Three floats a vertex, three indices a triangle; normals (one a position) and edges (six floats a segment) may be null.</summary>
    public Item ShowMesh(float[] positions, uint[] indices, float[]? normals = null, float[]? edges = null, float[]? rgb = null)
    {
        if (positions is null || indices is null) throw new ViewException("showMesh: positions and indices are required");
        if (normals is not null && normals.Length != positions.Length)
            throw new ViewException($"showMesh: {positions.Length / 3} positions but {normals.Length / 3} normals");
        if (edges is not null && edges.Length % 6 != 0)
            throw new ViewException($"showMesh: edges are two points a segment (6 numbers), not {edges.Length}");
        Exact(rgb, 3, "showMesh rgb");
        var h = Live("cadaclysm_view_show_mesh");
        fixed (float* p = positions) fixed (uint* i = indices) fixed (float* n = normals) fixed (float* e = edges) fixed (float* c = rgb)
        {
            var m = new RawViewMesh
            {
                Size = (uint)sizeof(RawViewMesh), Positions = (IntPtr)p, VertexCount = (uint)positions.Length / 3, Normals = (IntPtr)n,
                Indices = (IntPtr)i, IndexCount = (uint)indices.Length, Edges = (IntPtr)e, EdgeCount = (uint)(edges?.Length ?? 0) / 6, Rgb = (IntPtr)c,
            };
            return NewItem(ViewNative.cadaclysm_view_show_mesh(h, &m), null);
        }
    }

    /// <summary><see cref="ShowLines(float[], float[])"/> with the colour as text.</summary>
    public Item ShowLines(float[] segments, string rgb) => ShowLines(segments, ViewNative.Colour(rgb));

    /// <summary>Six floats a segment.</summary>
    public Item ShowLines(float[] segments, float[]? rgb = null)
    {
        if (segments.Length % 6 != 0) throw new ViewException($"showLines: 6 numbers a segment, not {segments.Length}");
        Exact(rgb, 3, "showLines rgb");
        var h = Live("cadaclysm_view_show_lines");
        fixed (float* s = NonNull(segments)) fixed (float* c = rgb)
            return NewItem(ViewNative.cadaclysm_view_show_lines(h, s, (uint)segments.Length / 6, c), null);
    }

    /// <summary><see cref="ShowPoints(float[], float[], float)"/> with the colour as text.</summary>
    public Item ShowPoints(float[] positions, string rgb, float sizePx = 8f) => ShowPoints(positions, ViewNative.Colour(rgb), sizePx);

    /// <summary>Points as three floats each: a disc <paramref name="sizePx"/> device pixels across
    /// (1 to 64) at each, in <paramref name="rgb"/> (null: the edge colour), as one item. A point
    /// does not pick. The library refuses a number that is not finite and a size outside 1..64.</summary>
    public Item ShowPoints(float[] positions, float[]? rgb = null, float sizePx = 8f)
    {
        if (positions.Length % 3 != 0) throw new ViewException($"showPoints: three numbers a point, not {positions.Length}");
        Exact(rgb, 3, "showPoints rgb");
        var h = Live("cadaclysm_view_show_points");
        fixed (float* p = NonNull(positions)) fixed (float* c = rgb)
            return NewItem(ViewNative.cadaclysm_view_show_points(h, p, (uint)positions.Length / 3, c, sizePx), null);
    }

    private static readonly string[] ToolShapes = { "flat", "ball", "drill", "vbit", "bullnose" };

    private static double FiniteOr0(double? value, string what) =>
        value is null ? 0 : double.IsFinite(value.Value) ? value.Value : throw new ViewException($"{what}: a finite number, not {value}");

    private static void FiniteAll(double[]? values, int n, string what)
    {
        if (values is null || values.Length != n) throw new ViewException($"{what}: {n} finite numbers, not {values?.Length ?? 0}");
        foreach (var d in values) if (!double.IsFinite(d)) throw new ViewException($"{what}: {n} finite numbers");
    }

    /// <summary>A CAM job on a stock, paused at its start: `programs` in run order, the stock's two
    /// corners, the finished `part` (null: none; ColourBy("deviation") needs it) and the options (null,
    /// or a null in them: the library's defaults). Play it with Play(). A shape is one of flat, ball,
    /// drill, vbit, bullnose; a part's positions are x y z triples and its indices whole triangles
    /// inside them. Anything wrong is refused before the library is called.</summary>
    public unsafe Machining ShowMachining(IReadOnlyList<MachiningProgram> programs, double[] stockMin, double[] stockMax,
        MachiningPart? part = null, MachiningOptions? options = null)
    {
        if (programs is null) throw new ViewException("programs: a list, not null");
        foreach (var program in programs)
        {
            var tool = program?.Tool;
            if (tool is null || tool.Shape is null) throw new ViewException("tool needs number, shape and diameter");
            if (Array.IndexOf(ToolShapes, tool.Shape) < 0) throw new ViewException($"shape '{tool.Shape}': one of {string.Join(", ", ToolShapes)}");
            if (program!.Gcode is null) throw new ViewException("a program needs its gcode, not null");
            if (program.Gcode.Contains('\0')) throw new ViewException("a program's G-code cannot hold a NUL character (the C string ends there)");
            FiniteAll(new[] { tool.Diameter, tool.FluteLength, tool.Angle, tool.CornerRadius }, 4, "tool diameter, flute length, angle and corner radius");
        }
        FiniteAll(stockMin, 3, "stock min");
        FiniteAll(stockMax, 3, "stock max");
        var o = options ?? new MachiningOptions();
        double cell = FiniteOr0(o.Cell, "cell"), tolerance = FiniteOr0(o.Tolerance, "tolerance"),
            skin = FiniteOr0(o.Skin, "skin"), rapidRate = FiniteOr0(o.RapidRate, "rapid_rate");
        var positions = part?.Positions ?? Array.Empty<float>();
        var indices = part?.Indices ?? Array.Empty<uint>();
        if (part is not null)
        {
            if (positions.Length % 3 != 0) throw new ViewException($"part positions: {positions.Length} numbers is not a whole number of x y z triples");
            foreach (var f in positions) if (!float.IsFinite(f)) throw new ViewException("part positions: finite numbers");
            if (indices.Length % 3 != 0) throw new ViewException($"part indices: {indices.Length} is not a whole number of triangles");
            uint top = 0;
            foreach (var k in indices) if (k > top) top = k;
            if (indices.Length > 0 && top >= (uint)(positions.Length / 3)) throw new ViewException($"part indices: {top} is past the last of {positions.Length / 3} vertices");
        }
        var h = Live("cadaclysm_view_show_machining");
        var n = programs.Count;
        var texts = new IntPtr[n];
        var list = new RawViewProgram[Math.Max(n, 1)];
        try
        {
            for (var k = 0; k < n; k++)
            {
                var tool = programs[k].Tool;
                texts[k] = Marshal.StringToCoTaskMemUTF8(programs[k].Gcode);
                list[k] = new RawViewProgram
                {
                    Size = (uint)sizeof(RawViewProgram), ToolNumber = tool.Number, ToolShape = (uint)Array.IndexOf(ToolShapes, tool.Shape),
                    ToolDiameter = tool.Diameter, ToolFluteLength = tool.FluteLength, ToolAngle = tool.Angle, ToolCornerRadius = tool.CornerRadius,
                    Gcode = texts[k],
                };
            }
            var raw = new RawViewMachining { Size = (uint)sizeof(RawViewMachining), ProgramCount = (uint)n,
                Cell = cell, Tolerance = tolerance, Skin = skin, RapidRate = rapidRate, SkinSet = o.Skin is null ? 0u : 1u };
            for (var k = 0; k < 3; k++) { raw.StockMin[k] = stockMin[k]; raw.StockMax[k] = stockMax[k]; }
            fixed (RawViewProgram* programsPtr = list) fixed (float* pp = NonNull(positions)) fixed (uint* ip = NonNull(indices))
            {
                raw.Programs = n == 0 ? IntPtr.Zero : (IntPtr)programsPtr;
                if (part is not null)
                {
                    raw.PartPositions = (IntPtr)pp; raw.PartIndices = (IntPtr)ip;
                    raw.PartVertexCount = (uint)(positions.Length / 3); raw.PartIndexCount = (uint)indices.Length;
                }
                var id = ViewNative.cadaclysm_view_show_machining(h, &raw);
                if (id == 0) throw ViewNative.Failure();
                var shown = new Machining(this, id);
                lock (Items) Items[id] = shown;
                return shown;
            }
        }
        finally { foreach (var t in texts) if (t != IntPtr.Zero) Marshal.FreeCoTaskMem(t); }
    }

    // ---- the timeline (1.7): one per view, shared by whatever it shows

    /// <summary>Play the timeline at `speed` times real time, from where it is (from the start once it has ended).</summary>
    public void Play(double speed = 1) => Ok(ViewNative.cadaclysm_view_timeline_play(Live("cadaclysm_view_timeline_play"), speed));

    public void Pause() => Ok(ViewNative.cadaclysm_view_timeline_pause(Live("cadaclysm_view_timeline_pause")));

    /// <summary>Set the clock, clamped to [0, Duration]; the next draw shows it.</summary>
    public void Seek(double seconds) => Ok(ViewNative.cadaclysm_view_timeline_seek(Live("cadaclysm_view_timeline_seek"), seconds));

    /// <summary>Whether the timeline starts over at its end.</summary>
    public void Loop(bool on = true) => Ok(ViewNative.cadaclysm_view_timeline_set_loop(Live("cadaclysm_view_timeline_set_loop"), on));

    /// <summary>Seconds into the timeline, as of the last draw.</summary>
    public double Time => ViewNative.cadaclysm_view_timeline_time(Live("cadaclysm_view_timeline_time"));

    /// <summary>The timeline's length in seconds; 0 with nothing to play.</summary>
    public double Duration => ViewNative.cadaclysm_view_timeline_duration(Live("cadaclysm_view_timeline_duration"));

    public bool Playing => ViewNative.cadaclysm_view_timeline_playing(Live("cadaclysm_view_timeline_playing"));

    /// <summary>What the timeline is doing, one line a track (for example "move 3 of 9 ..."); empty with no tracks.</summary>
    public unsafe IReadOnlyList<string> Status()
    {
        var h = Live("cadaclysm_view_timeline_status");
        var n = ViewNative.cadaclysm_view_timeline_status(h, null, 0);
        while (n != 0)
        {
            var buf = new byte[(int)n + 1];
            nuint got;
            fixed (byte* b = buf) got = ViewNative.cadaclysm_view_timeline_status(h, b, (nuint)buf.Length);
            if (got < (nuint)buf.Length)
            {
                if (got == 0) return Array.Empty<string>();
                return System.Text.Encoding.UTF8.GetString(buf, 0, (int)got).Split('\n');
            }
            n = got;   // the line grew between the two calls: ask again with room for it
        }
        return Array.Empty<string>();
    }

    /// <summary><see cref="ShowCurves(float[], float[])"/> with the colour as text.</summary>
    public Item ShowCurves(float[] beziers, string rgb) => ShowCurves(beziers, ViewNative.Colour(rgb));

    /// <summary>Sixteen floats a rational cubic: four control points as x, y, z, w.</summary>
    public Item ShowCurves(float[] beziers, float[]? rgb = null)
    {
        if (beziers.Length % 16 != 0) throw new ViewException($"showCurves: 16 numbers a curve, not {beziers.Length}");
        Exact(rgb, 3, "showCurves rgb");
        var h = Live("cadaclysm_view_show_curves");
        fixed (float* b = NonNull(beziers)) fixed (float* c = rgb)
            return NewItem(ViewNative.cadaclysm_view_show_curves(h, b, (uint)beziers.Length / 16, c), null);
    }

    /// <summary>`corners`: twelve floats, bottom-left, bottom-right, top-right, top-left; rgba rows from the top, w * h * 4 bytes.</summary>
    public Item ShowImage(float[] corners, byte[] rgba, uint width, uint height, float opacity = 1)
    {
        if (corners is null || corners.Length != 12) throw new ViewException($"showImage: corners are 12 numbers, not {corners?.Length ?? 0}");
        var need = PixelBytes(width, height, "showImage");
        if (need != rgba.Length) throw new ViewException($"showImage: {width} x {height} pixels need {need} bytes (w * h * 4), not {rgba.Length}");
        var h = Live("cadaclysm_view_show_image");
        fixed (byte* px = rgba)
        {
            var img = new RawViewImage { Size = (uint)sizeof(RawViewImage), Rgba = (IntPtr)px, Width = width, Height = height, Opacity = opacity };
            for (var k = 0; k < 12; k++) img.Corners[k] = corners[k];
            return NewItem(ViewNative.cadaclysm_view_show_image(h, &img), null);
        }
    }

    /// <summary>Text shown as one item (cadaclysm_view_show_text): a label anchored to <paramref name="at"/>, or world text.</summary>
    public Item ShowText(string text, float[] at, TextOptions? options = null)
    {
        var o = options ?? new TextOptions();
        uint mode = Named(TextModes, o.Mode, "mode"), align = Named(Aligns, o.Align, "align");
        if (at is null || at.Length != 3) throw new ViewException($"showText at: 3 numbers, not {at?.Length ?? 0}");
        var rgb = Exact(o.ColourText is not null ? ViewNative.Colour(o.ColourText) : o.Colour ?? ViewNative.Colour("white"), 3, "showText colour")!;
        var right = Exact(o.Right, 3, "showText right");
        var up = Exact(o.Up, 3, "showText up");
        var offset = Exact(o.Offset, 2, "showText offset");
        var box = o.BoxText is not null ? ViewNative.Rgba(o.BoxText) : Rgba(o.Box, "showText box");
        var h = Live("cadaclysm_view_show_text");
        IntPtr utf8 = Marshal.StringToCoTaskMemUTF8(ViewNative.TextOf(text));
        try
        {
            var t = new RawViewText { Size = (uint)sizeof(RawViewText), Text = utf8, Mode = mode, Height = o.Size, Align = align,
                                      BoxPadding = o.Padding, OnTop = o.OnTop ? 1u : 0u, Font = o.Font };
            for (int k = 0; k < 3; k++)
            {
                t.At[k] = at[k];
                t.Rgb[k] = rgb[k];
                if (right is not null) t.Right[k] = right[k];
                if (up is not null) t.Up[k] = up[k];
            }
            if (offset is not null) { t.Offset[0] = offset[0]; t.Offset[1] = offset[1]; }
            if (box is not null) for (int k = 0; k < 4; k++) t.BoxRgba[k] = box[k];
            return NewItem(ViewNative.cadaclysm_view_show_text(h, &t), null);
        }
        finally { Marshal.FreeCoTaskMem(utf8); }
    }

    // ---- the camera

    public void Orbit(float dx, float dy) => Void("cadaclysm_view_orbit", h => ViewNative.cadaclysm_view_orbit(h, dx, dy));
    public void Pan(float dx, float dy) => Void("cadaclysm_view_pan", h => ViewNative.cadaclysm_view_pan(h, dx, dy));
    public void Zoom(float steps) => Void("cadaclysm_view_zoom", h => ViewNative.cadaclysm_view_zoom(h, steps));
    public void Look(float dx, float dy) => Void("cadaclysm_view_look", h => ViewNative.cadaclysm_view_look(h, dx, dy));
    public void Dolly(float ratio) => Void("cadaclysm_view_dolly", h => ViewNative.cadaclysm_view_dolly(h, ratio));

    /// <summary>top, front, right or iso.</summary>
    public void Standard(string name)
    {
        var which = Named(Standards, name, "standard view");
        Ok(ViewNative.cadaclysm_view_standard(Live("cadaclysm_view_standard"), which));
    }

    /// <summary>Fit the camera to everything shown.</summary>
    public void Frame() => Ok(ViewNative.cadaclysm_view_frame(Live("cadaclysm_view_frame"), 0));

    public void Orthographic(bool on) => Void("cadaclysm_view_set_orthographic", h => ViewNative.cadaclysm_view_set_orthographic(h, on));

    /// <summary>Whether a double click frames what it hit (off by default: it is a pick answered with
    /// Clicks 2 and the camera stays). Applies where the view takes the pick itself (its own window,
    /// pump, Run); a host reading picks frames if it chooses.</summary>
    public void SetDoubleClickFrames(bool on) =>
        Void("cadaclysm_view_set_double_click_frames", h => ViewNative.cadaclysm_view_set_double_click_frames(h, on));

    /// <summary>Moves the orbit point to `point` (x, y, z, as a pick's Point): the eye keeps its direction
    /// and distance from it, so the camera moves sideways and does not turn. Leaves fly mode. Other than
    /// three numbers is refused before the call; the library refuses a point that is not finite, or
    /// while viewports are set, with its own reason.</summary>
    public void Focus(float[] point)
    {
        if (point is null) throw new ViewException("focus: 3 numbers, not null");
        Exact(point, 3, "focus");
        var h = Live("cadaclysm_view_focus");
        fixed (float* p = point) Ok(ViewNative.cadaclysm_view_focus(h, p));
    }

    /// <summary>How a left drag moves the camera: "orbit" (about the target) or "fly" (the view turns
    /// about the eye). A fly key (W, A, S, D, E, Q) sent through Input enters fly mode and it stays
    /// after the key is let go; Tab toggles it; Frame, Standard and Focus leave it.</summary>
    public string Navigation => ViewNative.cadaclysm_view_navigation(Live("cadaclysm_view_navigation")) == NavigationFly ? "fly" : "orbit";

    public void Viewports(IReadOnlyList<Viewport> list)
    {
        var grids = new uint[list.Count];
        for (var i = 0; i < list.Count; i++)
        {
            Exact(list[i].Rect, 4, "viewport rect");
            Exact(list[i].View, 16, "viewport view");
            Exact(list[i].Projection, 16, "viewport projection");
            Exact(list[i].Eye, 3, "viewport eye");
            grids[i] = Named(Grids, list[i].Grid ?? "none", "grid");
        }
        var handle = Live("cadaclysm_view_set_viewports");
        var raw = new RawViewViewport[list.Count];
        fixed (RawViewViewport* p = raw)
        {
            for (var i = 0; i < list.Count; i++)
            {
                p[i].Size = (uint)sizeof(RawViewViewport);
                for (var k = 0; k < 4; k++) p[i].Rect[k] = list[i].Rect[k];
                for (var k = 0; k < 16; k++) { p[i].View[k] = list[i].View[k]; p[i].Projection[k] = list[i].Projection[k]; }
                for (var k = 0; k < 3; k++) p[i].Eye[k] = list[i].Eye[k];
                p[i].Grid = grids[i];
                p[i].LayerMask = 0xFFFFFFFFu; // every user layer
            }
            Ok(ViewNative.cadaclysm_view_set_viewports(handle, p, (uint)raw.Length));
        }
    }

    /// <summary>surfaces, edges, curves, isocurves or grid.</summary>
    public void Layer(string name, bool on)
    {
        var which = Named(Layers, name, "layer");
        Ok(ViewNative.cadaclysm_view_set_layer(Live("cadaclysm_view_set_layer"), which, on));
    }

    /// <summary>The clear colour as text: `"#rgb"`, `"#rrggbb"` or a CSS colour name.</summary>
    public void Background(string rgb)
    {
        if (rgb is null) throw new ViewException("background: 3 numbers, not none");
        Background(ViewNative.Colour(rgb)!);
    }

    /// <summary>Three numbers, the clear colour.</summary>
    public void Background(float[] rgb)
    {
        if (rgb is null) throw new ViewException("background: 3 numbers, not none");
        Exact(rgb, 3, "background");
        Void("cadaclysm_view_set_background", h => { fixed (float* c = rgb) ViewNative.cadaclysm_view_set_background(h, c); });
    }

    public string Surfaces
    {
        get => ViewNative.cadaclysm_view_surfaces(Live("cadaclysm_view_surfaces")) == 1 ? "triangles" : "exact";
        set => Ok(ViewNative.cadaclysm_view_set_surfaces(Live("cadaclysm_view_set_surfaces"), Named(SurfaceKinds, value, "surfaces")));
    }

    /// <summary>How plain parts are lit, as Python's View.lighting: "headlight" (the default) --
    /// whatever faces the camera is bright -- or "studio", a key light fixed above the scene with
    /// an ambient and a camera fill. Another name is refused before the library is called.</summary>
    public string Lighting
    {
        get => ViewNative.cadaclysm_view_lighting(Live("cadaclysm_view_lighting")) == 1 ? "studio" : "headlight";
        set => Ok(ViewNative.cadaclysm_view_set_lighting(Live("cadaclysm_view_set_lighting"), Named(LightingKinds, value, "lighting")));
    }

    public bool NeedsDraw => ViewNative.cadaclysm_view_needs_draw(Live("cadaclysm_view_needs_draw"));

    // ---- the rest

    /// <summary>What is under pixel (x, y) of `viewport`, or null for nothing.</summary>
    /// <remarks>A view never drawn is drawn first: the library answers a pick from the frame it
    /// has drawn. A failure other than "no answer yet" throws at once with the library's own message.</remarks>
    public Pick? Pick(uint x, uint y, uint viewport = 0)
    {
        if (!_drawn) Draw();
        var h = Live("cadaclysm_view_request_pick_in");
        Void("cadaclysm_view_request_pick_in", v => ViewNative.cadaclysm_view_request_pick_in(v, viewport, x, y));
        var output = new RawViewPick { Size = (uint)sizeof(RawViewPick) };
        var waiting = "";
        for (var i = 0; i < 200; i++)
        {
            Draw();
            if (ViewNative.cadaclysm_view_pick_result(h, &output)) return PickOf(output);
            waiting = ViewNative.LastError();
            if (waiting.Length > 0 && !waiting.EndsWith("no pick result", StringComparison.Ordinal)) throw new ViewException(waiting);
            Thread.Sleep(10);
        }
        throw new ViewException($"pick: the answer never landed ({(waiting.Length > 0 ? waiting : "no error reported")})");
    }

    /// <summary>The newest pick answer that has landed, without asking or waiting (Python's
    /// `last_pick`): a click or tap in the view's own window (`Pump` lands them as it draws), a
    /// double click's (`Clicks` 2), or one an `Input` asked for, landed by the draws after it.
    /// False while none has; true with `pick` null for a click on nothing, or the pick for a hit.
    /// Each answer is read once, and a newer one replaces one not read yet.</summary>
    /// <remarks>A failure other than "no answer yet" throws the library's own message.</remarks>
    public bool LastPick(out Pick? pick)
    {
        var output = new RawViewPick { Size = (uint)sizeof(RawViewPick) };
        if (ViewNative.cadaclysm_view_pick_result(Live("cadaclysm_view_pick_result"), &output))
        {
            pick = PickOf(output);
            return true;
        }
        var waiting = ViewNative.LastError();
        if (waiting.Length > 0 && !waiting.EndsWith("no pick result", StringComparison.Ordinal)) throw new ViewException(waiting);
        pick = null;
        return false;
    }

    public void Draw() { Ok(ViewNative.cadaclysm_view_draw(Live("cadaclysm_view_draw"))); _drawn = true; }

    /// <summary>Blocks until the window is closed; the camera it ended on and the last pick.</summary>
    public Camera Run()
    {
        var h = Live("cadaclysm_view_run");
        var cam = new RawViewCamera { Size = (uint)sizeof(RawViewCamera) };
        var pick = new RawViewPick { Size = (uint)sizeof(RawViewPick) };
        Ok(ViewNative.cadaclysm_view_run(h, &cam, &pick));
        MarkClosed();
        float[] eye = { cam.Eye[0], cam.Eye[1], cam.Eye[2] }, target = { cam.Target[0], cam.Target[1], cam.Target[2] }, up = { cam.Up[0], cam.Up[1], cam.Up[2] };
        return CameraOf(eye, target, up, cam.Orthographic != 0, PickOf(pick), _yUp);
    }

    /// <summary>A CadaclysmViewPick as the answer: null for no item; Point only where the library set
    /// has_point (Python's `_pick_dict`).</summary>
    internal static Pick? PickOf(RawViewPick raw) =>
        raw.Item == 0 ? null : new Pick(raw.Item, raw.Node, raw.Face, raw.Clicks,
            raw.HasPoint != 0 ? new[] { raw.Point[0], raw.Point[1], raw.Point[2] } : null);

    /// <summary>The buffer a frame of `width` x `height` is read into: a size nobody can allocate is the wrapper's error.</summary>
    internal static byte[] FrameBuffer(ulong width, ulong height)
    {
        var n = PixelBytes(width, height, "image");
        if (n > Array.MaxLength) throw new ViewException($"image: {width} x {height} pixels ({n} bytes) is too large to read back");
        return new byte[n];
    }

    /// <summary>One frame read back, RGBA8, rows from the top.</summary>
    public ViewImage Image()
    {
        var h = Live("cadaclysm_view_image");
        uint w, ht;
        Ok(ViewNative.cadaclysm_view_size(h, &w, &ht));   // the size the next frame is drawn at
        var rgba = FrameBuffer(w, ht);
        fixed (byte* p = rgba) Ok(ViewNative.cadaclysm_view_image(h, p, (nuint)rgba.Length));
        return new ViewImage((int)w, (int)ht, rgba);
    }

    /// <summary>The frame as a PNG, through System.IO.Compression -- no imaging library.</summary>
    public void Save(string path)
    {
        var img = Image();
        var stride = img.Width * 4;
        var raw = new byte[(stride + 1) * img.Height];
        for (var y = 0; y < img.Height; y++) Buffer.BlockCopy(img.Rgba, y * stride, raw, y * (stride + 1) + 1, stride);
        using var z = new MemoryStream();
        using (var deflate = new ZLibStream(z, CompressionLevel.Optimal, leaveOpen: true)) deflate.Write(raw);
        using var png = new MemoryStream();
        png.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
        var ihdr = new byte[13];
        Be32(ihdr, 0, (uint)img.Width); Be32(ihdr, 4, (uint)img.Height); ihdr[8] = 8; ihdr[9] = 6;
        Chunk(png, "IHDR", ihdr);
        Chunk(png, "IDAT", z.ToArray());
        Chunk(png, "IEND", Array.Empty<byte>());
        File.WriteAllBytes(path, png.ToArray());
    }

    private static readonly uint[] Crc = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    private static void Be32(byte[] b, int at, uint v) { b[at] = (byte)(v >> 24); b[at + 1] = (byte)(v >> 16); b[at + 2] = (byte)(v >> 8); b[at + 3] = (byte)v; }

    private static void Chunk(Stream s, string type, byte[] data)
    {
        var head = new byte[4]; Be32(head, 0, (uint)data.Length); s.Write(head);
        var body = new byte[4 + data.Length];
        System.Text.Encoding.ASCII.GetBytes(type).CopyTo(body, 0);
        data.CopyTo(body, 4);
        s.Write(body);
        var c = 0xFFFFFFFFu;
        foreach (var b in body) c = Crc[(c ^ b) & 0xFF] ^ (c >> 8);
        var tail = new byte[4]; Be32(tail, 0, c ^ 0xFFFFFFFFu); s.Write(tail);
    }

    /// <summary>Hands the gesture handler one event; the INPUT_* bits it asks of the host.</summary>
    public uint Input(ViewEvent e)
    {
        var kind = Named(Events, e.Type, "event type");
        var pointer = Named(Pointers, e.Pointer ?? "mouse", "pointer");
        var h = Live("cadaclysm_view_input");
        var key = e.Key is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(e.Key);
        try
        {
            var raw = new RawViewEvent
            {
                Size = (uint)sizeof(RawViewEvent), Kind = kind,
                PointerId = e.PointerId, Pointer = pointer, Button = e.Button, Shift = e.Shift ? 1u : 0u,
                X = e.X, Y = e.Y, WheelY = e.WheelY, Key = key, KeyDown = e.KeyDown ? 1u : 0u,
                TimeMs = e.TimeMs == 0 ? Environment.TickCount64 : e.TimeMs,
            };
            var bits = ViewNative.cadaclysm_view_input(h, &raw);
            if (bits == 0 && ViewNative.LastError().Length > 0) throw ViewNative.Failure();
            // Escape on a window of the view's own ends it as the user closing it does; Dispose still owes the destroy.
            if ((bits & InputClose) != 0 && _own) MarkClosed();
            return bits;
        }
        finally
        {
            if (key != IntPtr.Zero) Marshal.FreeCoTaskMem(key);
        }
    }

    public void Resize(uint width, uint height) => Ok(ViewNative.cadaclysm_view_resize(Live("cadaclysm_view_resize"), width, height));

    /// <summary>What Image() reads, in physical pixels.</summary>
    public (uint Width, uint Height) Size
    {
        get
        {
            var h = Live("cadaclysm_view_size");
            uint w, ht;
            Ok(ViewNative.cadaclysm_view_size(h, &w, &ht));
            return (w, ht);
        }
    }

    /// <summary>Levels of detail: parts of `minTriangles` or more (0: the library's 2,048) get coarser
    /// levels, built in the background after each show; a moving frame draws as `motion` says --
    /// "detailed" or "smooth" (refines once the camera rests, see <see cref="WakeMs"/>). null turns levels off.</summary>
    public void Lod(string? motion = "detailed", uint minTriangles = 0)
    {
        if (motion is null) { Ok(ViewNative.cadaclysm_view_set_lod(Live("cadaclysm_view_set_lod"), null)); return; }
        var lod = new RawViewLod { Size = (uint)sizeof(RawViewLod), MinTriangles = minTriangles, Motion = Named(LodMotion, motion, "motion") };
        Ok(ViewNative.cadaclysm_view_set_lod(Live("cadaclysm_view_set_lod"), &lod));
    }

    /// <summary>Milliseconds until NeedsDraw turns true by itself; 0 when a draw is owed now, null when none is coming.</summary>
    public uint? WakeMs { get { var ms = ViewNative.cadaclysm_view_wake_ms(Live("cadaclysm_view_wake_ms")); return ms == NoneComing ? null : ms; } }

    /// <summary>The window closed (its close button, Escape, the end of Run): calls now throw "the window is closed".</summary>
    private void MarkClosed()
    {
        _windowClosed = true;
        lock (Open) Open.Remove(this);
    }

    /// <summary>Destroy the view and its window. Idempotent.</summary>
    public void Dispose()
    {
        if (!_handle.IsClosed && Environment.CurrentManagedThreadId != _thread)
            throw new ViewException("close: a view belongs to the thread that made it");
        lock (Open) Open.Remove(this);
        _handle.Dispose();   // destroy first: the library lets go of what it shows, then the items drop it
        lock (Items)
        {
            foreach (var item in Items.Values) item.Shown = null;
            Items.Clear();
        }
    }

    /// <summary>Removes every item that shows `obj` (a Scene, directly or through one of its nodes) from
    /// every live view before its handle is freed: a shown scene must stay open until its item is removed
    /// or the view destroyed. Scene.Close() calls it first. A view of this thread whose window the user
    /// closed is disposed instead. A view made on another thread cannot be called from this one: when one
    /// still shows `obj`, this throws after this thread's views are done, and the scene stays open
    /// (it leaks rather than crashes) -- Python's rule. Loads no library: only a view that exists is touched.</summary>
    internal static void Release(object obj)
    {
        List<View> views;
        lock (Alive)
        {
            Alive.RemoveAll(r => !r.TryGetTarget(out var v) || v._handle.IsClosed);
            views = Alive.Select(r => r.TryGetTarget(out var v) ? v : null).OfType<View>().ToList();
        }
        var foreign = 0;
        foreach (var v in views)
        {
            if (v._handle.IsClosed) continue;
            List<Item> showing;
            lock (v.Items) showing = v.Items.Values.Where(i => ReferenceEquals(i.Shown, obj) || (i.Shown is Node n && ReferenceEquals(n.Scene, obj))).ToList();
            if (showing.Count == 0) continue;
            if (v._thread != Environment.CurrentManagedThreadId) foreign++;
            else if (v._windowClosed) v.Dispose();
            else foreach (var i in showing) i.Remove();
        }
        if (foreign > 0)
            throw new ViewException($"{foreign} view(s) made on another thread still show this -- close them from their own thread first; it stays open until then");
    }

    internal static int PumpAll(uint timeoutMs)
    {
        View[] alive;
        lock (Open) alive = Open.Where(v => !v._handle.IsClosed && !v._windowClosed && v._thread == Environment.CurrentManagedThreadId).ToArray();
        if (alive.Length == 0)
        {
            if (timeoutMs > 0) Thread.Sleep((int)Math.Min(timeoutMs, int.MaxValue));   // with no window of its own, a loop around Pump does not spin
        }
        else
        {
            var wait = timeoutMs;
            ViewException? first = null;
            foreach (var v in alive)
            {
                var answer = ViewNative.cadaclysm_view_pump(v._handle, wait);
                wait = 0;
                if (answer == 2) v.MarkClosed();
                else if (answer != 1) first ??= ViewNative.Failure();
            }
            if (first is not null) throw first;
        }
        lock (Open) return Open.Count(v => !v._windowClosed);
    }

    // ---- show() and view() on the objects

    /// <summary>cadaclysm_view.py's _camera: azimuth and elevation as Show takes them.</summary>
    internal static Camera CameraOf(float[] eye, float[] target, float[] up, bool ortho, Pick? pick, bool yUp)
    {
        double[] d = { eye[0] - target[0], eye[1] - target[1], eye[2] - target[2] };
        double[] u = { up[0], up[1], up[2] };
        if (yUp) { d = new[] { d[0], -d[2], d[1] }; u = new[] { u[0], -u[2], u[1] }; }
        var length = Math.Sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        if (length == 0) length = 1;
        for (var i = 0; i < 3; i++) d[i] /= length;
        double azimuth;
        if (Math.Sqrt(d[0] * d[0] + d[1] * d[1]) < 1e-4)
        {
            var sign = d[2] < 0 ? -1.0 : 1.0;
            azimuth = Math.Atan2(-sign * u[1], -sign * u[0]) * 180 / Math.PI;
        }
        else azimuth = Math.Atan2(d[1], d[0]) * 180 / Math.PI;
        var elevation = Math.Asin(Math.Clamp(d[2], -1, 1)) * 180 / Math.PI;
        return new Camera(eye, target, up, ortho, azimuth, elevation, pick);
    }

    /// <summary>The camera the options ask for, as Python's _aim and _zoom: the top view straight down,
    /// any other angle an orbit from the front, then frame(0), then `fit` (a node's FrameNode), and only
    /// then the zoom, since framing resets the distance a zoom sets. The camera calls are not checked, as
    /// Python's are; `fit`'s own refusals are.</summary>
    internal void Aim(ShowOptions o, Action fit)
    {
        var b = Views[o.View];
        var az = o.Azimuth ?? b.Az;
        var el = o.Elevation ?? b.El;
        var h = Live("cadaclysm_view_standard");
        if (el >= 90 && az == -90) ViewNative.cadaclysm_view_standard(h, Standards["top"]);
        else
        {
            ViewNative.cadaclysm_view_standard(h, Standards["front"]);
            var dx = (float)(-((az + 90) * Math.PI / 180) / OrbitPerPixel);
            var dy = (float)(el * Math.PI / 180 / OrbitPerPixel);
            if (dx != 0 || dy != 0) ViewNative.cadaclysm_view_orbit(h, dx, dy);
        }
        ViewNative.cadaclysm_view_frame(h, 0);
        fit();
        if (o.Zoom is > 0) ViewNative.cadaclysm_view_zoom(h, (float)(Math.Log(o.Zoom.Value) / -Math.Log(ZoomPerStep)));
    }

    private static Scene? SceneOf(object obj) => obj as Scene ?? (obj as Node)?.Scene;

    /// <summary>The scene's file name (a node is titled by its scene, as Python's present is); "Solid" for a solid.</summary>
    internal static string TitleOf(object obj) => SceneOf(obj) is { } scene ? System.IO.Path.GetFileName(scene.Path) : "Solid";

    /// <summary>obj.Show() (`orbit` false) and obj.View() (true): a fresh view; on a window library it
    /// runs until the window is closed, on the terminal Show() prints a still.</summary>
    /// <remarks>`transforms`, for a scene: one posed world transform per node (Pose.Show), set on its item before drawing.</remarks>
    internal static Camera? Present(object obj, ShowOptions? options, bool orbit, IReadOnlyList<double[]>? transforms = null)
    {
        var o = options ?? new ShowOptions();
        var kind = transforms is not null ? "Pose" : obj is Scene ? "Scene" : obj is Node ? "Node" : "Solid";
        if (o.Tolerance is not null && kind != "Solid")
            throw new ViewException($"{kind}.{(orbit ? "View" : "Show")} takes no tolerance: a document is drawn at the tolerance it was read with");
        if (o.View is null || !Views.ContainsKey(o.View))
            throw new ViewException($"view \"{o.View}\": one of {string.Join(", ", Views.Keys.Order(StringComparer.Ordinal))}");
        var up = (o.Up ?? SceneOf(obj)?.DefaultUp ?? "z").ToLowerInvariant();
        if (up != "y" && up != "z") throw new ViewException($"up \"{o.Up}\": 'y' or 'z'");
        var wgpu = ViewLibrary.Kind == "wgpu";
        var viewOptions = new ViewOptions(o.Title ?? TitleOf(obj), o.Width, o.Height, "exact", up);
        // What the program printed goes out before the library writes a still (or a window's
        // messages) to the same output, as Python's present flushes.
        Console.Out.Flush();
        Console.Error.Flush();
        using var v = OwnView is null ? new View(viewOptions) : OwnView(viewOptions);
        var item = o.RgbText is not null ? v.Show(obj, o.RgbText, o.Tolerance ?? 0.05) : v.Show(obj, o.Rgb, o.Tolerance ?? 0.05);
        if (transforms is not null) item.NodeTransforms(transforms);
        v.Layer("edges", o.Edges);
        v.Aim(o, obj is Node node ? () => item.FrameNode(node.Index) : () => { });
        if (!orbit && !wgpu) { v.Draw(); return null; }
        var camera = RunOwn is null ? v.Run() : RunOwn(v);
        return orbit ? camera : null;
    }
}
