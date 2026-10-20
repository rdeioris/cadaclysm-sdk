// Drawing through cadaclysm_view.h: the terminal by default, the GPU window with
// View.useWgpu(), a host's window with View.inWindow, or offscreen with View.offscreen.
//
//     View.useWgpu();
//     try (Blacksmith.Solid part = Blacksmith.Solid.cuboid(20, 20, 20)) {
//         part.show();                                    // blocks until the window is closed
//     }
//     try (View v = View.offscreen(800, 600)) {           // no display needed
//         v.showSolid(part); v.standard("iso"); v.frame(); v.save(Path.of("part.png"));
//     }
//
// Compile it with Cad.java and Blacksmith.java: each refers to the others. Solids and scenes
// are shown by handle, read in place; an Item holds the object it shows. show() blocks on a
// window library and prints a still on the terminal; view() returns the camera it was left at.
// View is AutoCloseable; a cleaner also destroys a view nobody holds (a view with a window of
// its own only on the thread that made it -- elsewhere the library keeps it, with the reason).
// A view belongs to the thread that made it: every call from another thread is refused, and a
// scene a live view of another thread still shows cannot be closed (it stays open, with the reason).
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.lang.ref.Cleaner;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.WeakHashMap;
import java.util.zip.CRC32;
import java.util.zip.Deflater;

public final class View implements AutoCloseable {

    /** What a view library refused, in its own words. */
    public static final class ViewException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public ViewException(String message) {
            super(message);
        }
    }

    static final int ABI_MAJOR = 1;
    /**
     * 1.6: text -- {@code cadaclysm_view_show_text}, {@code _set_text}, {@code _load_font} and the text layer.
     * 1.7: the machining and timeline calls (not bound here yet).
     * 1.8: the pick's {@code clicks} and {@code point}, {@code cadaclysm_view_set_double_click_frames},
     * {@code _focus}, {@code _navigation}.
     * 1.9: {@code cadaclysm_view_set_lighting} and {@code _lighting} (headlight or studio).
     * 1.10: the viewport cameras (bound; Java's own API for them comes later).
     * 1.11: {@code cadaclysm_view_show_points}.
     */
    static final int ABI_MINOR = 11;
    /** CADACLYSM_VIEW_NAVIGATION_FLY (ORBIT is 0). */
    static final int NAVIGATION_FLY = 1;
    static final int OPEN = 1;
    static final int CLOSED = 2;
    public static final int WINDOW_WIN32 = 1;
    public static final int WINDOW_XLIB = 2;
    public static final int WINDOW_XCB = 3;
    public static final int WINDOW_WAYLAND = 4;
    public static final int WINDOW_APPKIT = 5;
    static final Map<String, Integer> STANDARD = Map.of("top", 0, "front", 1, "right", 2, "iso", 3);
    static final Map<String, Integer> LAYERS = Map.of("surfaces", 0, "edges", 1, "curves", 2, "isocurves", 3, "grid", 4,
            "text", 5);
    /** cadaclysm_view.h's CADACLYSM_VIEW_ALIGN_*: where the anchor sits on the text ("center" is "centre"). */
    static final Map<String, Integer> ALIGN = Map.of("top-left", 0, "top", 1, "top-right", 2, "left", 3, "centre", 4,
            "center", 4, "right", 5, "bottom-left", 6, "bottom", 7, "bottom-right", 8);
    static final Map<String, Integer> TEXT_MODES = Map.of("label", 0, "world", 1);
    static final Map<String, Integer> EVENTS = Map.of("pointer_down", 1, "pointer_move", 2, "pointer_up", 3,
            "pointer_cancel", 4, "wheel", 5, "key", 6);
    static final Map<String, Integer> GRIDS = Map.of("none", 0, "top", 1, "front", 2, "right", 3);
    static final Map<String, Integer> LOD_MOTION = Map.of("detailed", 0, "smooth", 1);
    static final Map<String, Integer> SURFACES = Map.of("exact", 0, "triangles", 1);
    static final Map<String, Integer> LIGHTING = Map.of("headlight", 0, "studio", 1);
    static final int INPUT_CLOSE = 1;
    static final Map<String, Integer> POINTERS = Map.of("mouse", 0, "touch", 1, "pen", 2);
    static final Map<String, double[]> VIEWS = Map.of(
            "front", new double[]{-90, 0}, "back", new double[]{90, 0}, "left", new double[]{180, 0},
            "right", new double[]{0, 0}, "top", new double[]{-90, 90}, "bottom", new double[]{-90, -90},
            "iso", new double[]{-50, 28});
    static final double ORBIT_PER_PIXEL = 0.01;
    static final double ZOOM_PER_STEP = 0.9;

    // ---- the ABI's structs, one field per line (tests/bindings.rs reads them) -------------

    static final MemoryLayout WINDOW = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            ValueLayout.JAVA_INT.withName("kind"),
            ValueLayout.ADDRESS.withName("window"),
            ValueLayout.JAVA_LONG.withName("window_id"),
            ValueLayout.ADDRESS.withName("display"),
            ValueLayout.JAVA_INT.withName("width"),
            ValueLayout.JAVA_INT.withName("height"));
    static final MemoryLayout OPTIONS = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            ValueLayout.JAVA_INT.withName("surfaces"),
            ValueLayout.JAVA_INT.withName("backend"),
            ValueLayout.JAVA_INT.withName("y_up"),
            ValueLayout.ADDRESS.withName("title"),
            ValueLayout.JAVA_INT.withName("width"),
            ValueLayout.JAVA_INT.withName("height"),
            ValueLayout.JAVA_INT.withName("offscreen"),
            MemoryLayout.paddingLayout(4));
    static final MemoryLayout CAMERA = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("eye"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("target"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("up"),
            ValueLayout.JAVA_INT.withName("orthographic"));
    static final MemoryLayout PICK = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            ValueLayout.JAVA_INT.withName("item"),
            ValueLayout.JAVA_INT.withName("node"),
            ValueLayout.JAVA_INT.withName("face"),
            ValueLayout.JAVA_INT.withName("clicks"),
            ValueLayout.JAVA_INT.withName("has_point"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("point"));
    static final MemoryLayout LOD = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            ValueLayout.JAVA_INT.withName("min_triangles"),
            ValueLayout.JAVA_INT.withName("motion"));
    static final MemoryLayout VIEWPORT = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_INT).withName("rect"),
            MemoryLayout.sequenceLayout(16, ValueLayout.JAVA_FLOAT).withName("view"),
            MemoryLayout.sequenceLayout(16, ValueLayout.JAVA_FLOAT).withName("projection"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("eye"),
            ValueLayout.JAVA_INT.withName("grid"));
    static final MemoryLayout EVENT = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            ValueLayout.JAVA_INT.withName("kind"),
            ValueLayout.JAVA_INT.withName("pointer_id"),
            ValueLayout.JAVA_INT.withName("pointer"),
            ValueLayout.JAVA_INT.withName("button"),
            ValueLayout.JAVA_INT.withName("shift"),
            ValueLayout.JAVA_FLOAT.withName("x"),
            ValueLayout.JAVA_FLOAT.withName("y"),
            ValueLayout.JAVA_FLOAT.withName("wheel_y"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("key"),
            ValueLayout.JAVA_INT.withName("key_down"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.JAVA_DOUBLE.withName("time_ms"),
            ValueLayout.JAVA_INT.withName("alt"),
            MemoryLayout.paddingLayout(4));
    static final MemoryLayout MESH = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.JAVA_INT.withName("vertex_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("normals"),
            ValueLayout.ADDRESS.withName("indices"),
            ValueLayout.JAVA_INT.withName("index_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("edges"),
            ValueLayout.JAVA_INT.withName("edge_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("rgb"));
    static final MemoryLayout IMAGE = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            MemoryLayout.sequenceLayout(12, ValueLayout.JAVA_FLOAT).withName("corners"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("rgba"),
            ValueLayout.JAVA_INT.withName("width"),
            ValueLayout.JAVA_INT.withName("height"),
            ValueLayout.JAVA_FLOAT.withName("opacity"),
            ValueLayout.JAVA_INT.withName("flip_x"),
            ValueLayout.JAVA_INT.withName("flip_y"),
            MemoryLayout.paddingLayout(4));
    static final MemoryLayout TEXT = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("text"),
            ValueLayout.JAVA_INT.withName("mode"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("at"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("right"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("up"),
            ValueLayout.JAVA_FLOAT.withName("height"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("rgb"),
            ValueLayout.JAVA_INT.withName("align"),
            MemoryLayout.sequenceLayout(2, ValueLayout.JAVA_FLOAT).withName("offset"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_FLOAT).withName("box_rgba"),
            ValueLayout.JAVA_FLOAT.withName("box_padding"),
            ValueLayout.JAVA_INT.withName("on_top"),
            ValueLayout.JAVA_INT.withName("font"));
    static final MemoryLayout VIEWPORT_CAMERA = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            ValueLayout.JAVA_INT.withName("kind"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_INT).withName("rect"),
            MemoryLayout.sequenceLayout(16, ValueLayout.JAVA_FLOAT).withName("view"),
            MemoryLayout.sequenceLayout(16, ValueLayout.JAVA_FLOAT).withName("projection"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("eye"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("target"),
            ValueLayout.JAVA_FLOAT.withName("distance"),
            ValueLayout.JAVA_FLOAT.withName("yaw"),
            ValueLayout.JAVA_FLOAT.withName("pitch"),
            ValueLayout.JAVA_INT.withName("orthographic"),
            ValueLayout.JAVA_FLOAT.withName("speed"),
            ValueLayout.JAVA_FLOAT.withName("radius"),
            ValueLayout.JAVA_FLOAT.withName("height"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("axis_view"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("axis_right"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("axis_up"));

    static long off(MemoryLayout layout, String field) {
        return layout.byteOffset(MemoryLayout.PathElement.groupElement(field));
    }

    @FunctionalInterface
    interface Invocation<T> {
        T run() throws Throwable;
    }

    static <T> T call(Invocation<T> body) {
        try {
            return body.run();
        } catch (RuntimeException e) {
            throw e;
        } catch (Throwable t) {
            throw new ViewException(t.toString());
        }
    }

    @SuppressWarnings("restricted") // downcallHandle: the library this file binds.
    private static MethodHandle bind(Linker linker, SymbolLookup lib, String name, FunctionDescriptor fd) {
        MemorySegment symbol = lib.find(name).orElseThrow(() -> new ViewException("not a view library (no " + name + ")"));
        return linker.downcallHandle(symbol, fd);
    }

    @SuppressWarnings("restricted") // reinterpret: a NUL-terminated string the library owns.
    static String text(MemorySegment p) {
        return p.address() == 0 ? "" : p.reinterpret(Long.MAX_VALUE).getString(0);
    }

    /** The library's own reason, bare; Python's fallback when it gave none (cadaclysm_view.py's _error). */
    static String reason(String lastError) {
        return lastError.isEmpty() ? "the view library failed" : lastError;
    }

    // ---- the library ------------------------------------------------------------------

    /** One loaded view library, every call of the header bound. The handles are replaceable so a test can wrap one. */
    public static final class Library {
        private final String name;
        private final String path;
        MethodHandle lastError, create, destroy, pump, run, resize, needsDraw, draw, show, remove, setSurfaces,
                surfaces, orbit, pan, zoom, frame, standard, setOrthographic, setLayer, setBackground, setNodeVisible,
                setNodeColor, setNodeHighlight, setViewports, requestPick, requestPickIn, pickResult, frameNode, look,
                dolly, input, showMesh, showLines, showPoints, showCurves, showImage, setColour, setXray, setFaceColours,
                setPlacement, showSolid, image, size, setLod, wakeMs, setNodeTransforms, parseColour, loadFont, showText,
                setText, setDoubleClickFrames, focus, navigation, setLighting, lighting, viewportCamera,
                setViewportCamera, setViewportRects, aim, setPivot, setTap, orbitIn, panIn, zoomIn, lookIn, dollyIn,
                frameIn, standardIn;

        @SuppressWarnings("restricted") // libraryLookup: the view library chosen.
        Library(Path file) {
            path = file.toString();
            SymbolLookup lib;
            try {
                lib = SymbolLookup.libraryLookup(file, Cad.Loader.ARENA);
            } catch (IllegalArgumentException e) {
                throw new ViewException(path + ": could not load the view library: " + e.getMessage());
            }
            Linker linker = Linker.nativeLinker();
            final ValueLayout I = ValueLayout.JAVA_INT, F = ValueLayout.JAVA_FLOAT, A = ValueLayout.ADDRESS;
            final ValueLayout B = ValueLayout.JAVA_BOOLEAN, D = ValueLayout.JAVA_DOUBLE, L = ValueLayout.JAVA_LONG;
            MethodHandle abi = bind(linker, lib, "cadaclysm_view_abi_version", FunctionDescriptor.of(I));
            int version = View.<Integer>call(() -> (int) abi.invoke());
            String refusal = abiRefusal(path, version);
            if (refusal != null) throw new ViewException(refusal);
            MethodHandle nameFn = bind(linker, lib, "cadaclysm_view_name", FunctionDescriptor.of(A));
            lastError = bind(linker, lib, "cadaclysm_view_last_error", FunctionDescriptor.of(A));
            parseColour = bind(linker, lib, "cadaclysm_view_parse_colour", FunctionDescriptor.of(B, A, A));
            create = bind(linker, lib, "cadaclysm_view_create", FunctionDescriptor.of(A, A, A));
            destroy = bind(linker, lib, "cadaclysm_view_destroy", FunctionDescriptor.ofVoid(A));
            pump = bind(linker, lib, "cadaclysm_view_pump", FunctionDescriptor.of(I, A, I));
            run = bind(linker, lib, "cadaclysm_view_run", FunctionDescriptor.of(B, A, A, A));
            resize = bind(linker, lib, "cadaclysm_view_resize", FunctionDescriptor.of(B, A, I, I));
            needsDraw = bind(linker, lib, "cadaclysm_view_needs_draw", FunctionDescriptor.of(B, A));
            draw = bind(linker, lib, "cadaclysm_view_draw", FunctionDescriptor.of(B, A));
            show = bind(linker, lib, "cadaclysm_view_show", FunctionDescriptor.of(I, A, A));
            remove = bind(linker, lib, "cadaclysm_view_remove", FunctionDescriptor.of(B, A, I));
            setSurfaces = bind(linker, lib, "cadaclysm_view_set_surfaces", FunctionDescriptor.of(B, A, I));
            surfaces = bind(linker, lib, "cadaclysm_view_surfaces", FunctionDescriptor.of(I, A));
            orbit = bind(linker, lib, "cadaclysm_view_orbit", FunctionDescriptor.ofVoid(A, F, F));
            pan = bind(linker, lib, "cadaclysm_view_pan", FunctionDescriptor.ofVoid(A, F, F));
            zoom = bind(linker, lib, "cadaclysm_view_zoom", FunctionDescriptor.ofVoid(A, F));
            frame = bind(linker, lib, "cadaclysm_view_frame", FunctionDescriptor.of(B, A, I));
            standard = bind(linker, lib, "cadaclysm_view_standard", FunctionDescriptor.of(B, A, I));
            setOrthographic = bind(linker, lib, "cadaclysm_view_set_orthographic", FunctionDescriptor.ofVoid(A, B));
            setLayer = bind(linker, lib, "cadaclysm_view_set_layer", FunctionDescriptor.of(B, A, I, B));
            setBackground = bind(linker, lib, "cadaclysm_view_set_background", FunctionDescriptor.ofVoid(A, A));
            setLod = bind(linker, lib, "cadaclysm_view_set_lod", FunctionDescriptor.of(B, A, A));
            wakeMs = bind(linker, lib, "cadaclysm_view_wake_ms", FunctionDescriptor.of(I, A));
            setNodeVisible = bind(linker, lib, "cadaclysm_view_set_node_visible", FunctionDescriptor.of(B, A, I, I, B));
            setNodeColor = bind(linker, lib, "cadaclysm_view_set_node_color", FunctionDescriptor.of(B, A, I, I, A));
            setNodeHighlight = bind(linker, lib, "cadaclysm_view_set_node_highlight", FunctionDescriptor.of(B, A, I, I, A));
            setViewports = bind(linker, lib, "cadaclysm_view_set_viewports", FunctionDescriptor.of(B, A, A, I));
            requestPick = bind(linker, lib, "cadaclysm_view_request_pick", FunctionDescriptor.ofVoid(A, I, I));
            requestPickIn = bind(linker, lib, "cadaclysm_view_request_pick_in", FunctionDescriptor.ofVoid(A, I, I, I));
            pickResult = bind(linker, lib, "cadaclysm_view_pick_result", FunctionDescriptor.of(B, A, A));
            frameNode = bind(linker, lib, "cadaclysm_view_frame_node", FunctionDescriptor.of(B, A, I, I));
            look = bind(linker, lib, "cadaclysm_view_look", FunctionDescriptor.ofVoid(A, F, F));
            dolly = bind(linker, lib, "cadaclysm_view_dolly", FunctionDescriptor.ofVoid(A, F));
            input = bind(linker, lib, "cadaclysm_view_input", FunctionDescriptor.of(I, A, A));
            showMesh = bind(linker, lib, "cadaclysm_view_show_mesh", FunctionDescriptor.of(I, A, A));
            showLines = bind(linker, lib, "cadaclysm_view_show_lines", FunctionDescriptor.of(I, A, A, I, A));
            showPoints = bind(linker, lib, "cadaclysm_view_show_points", FunctionDescriptor.of(I, A, A, I, A, F));
            showCurves = bind(linker, lib, "cadaclysm_view_show_curves", FunctionDescriptor.of(I, A, A, I, A));
            showImage = bind(linker, lib, "cadaclysm_view_show_image", FunctionDescriptor.of(I, A, A));
            setColour = bind(linker, lib, "cadaclysm_view_set_colour", FunctionDescriptor.of(B, A, I, A));
            setXray = bind(linker, lib, "cadaclysm_view_set_xray", FunctionDescriptor.of(B, A, I, B));
            setFaceColours = bind(linker, lib, "cadaclysm_view_set_face_colours", FunctionDescriptor.of(B, A, I, A, A, I));
            setPlacement = bind(linker, lib, "cadaclysm_view_set_placement", FunctionDescriptor.of(B, A, I, A));
            setNodeTransforms = bind(linker, lib, "cadaclysm_view_set_node_transforms", FunctionDescriptor.of(B, A, I, A, I));
            showSolid = bind(linker, lib, "cadaclysm_view_show_solid", FunctionDescriptor.of(I, A, A, D, A));
            image = bind(linker, lib, "cadaclysm_view_image", FunctionDescriptor.of(B, A, A, L));
            size = bind(linker, lib, "cadaclysm_view_size", FunctionDescriptor.of(B, A, A, A));
            loadFont = bind(linker, lib, "cadaclysm_view_load_font", FunctionDescriptor.of(I, A, L));
            showText = bind(linker, lib, "cadaclysm_view_show_text", FunctionDescriptor.of(I, A, A));
            setText = bind(linker, lib, "cadaclysm_view_set_text", FunctionDescriptor.of(B, A, I, A));
            setDoubleClickFrames = bind(linker, lib, "cadaclysm_view_set_double_click_frames", FunctionDescriptor.ofVoid(A, B));
            focus = bind(linker, lib, "cadaclysm_view_focus", FunctionDescriptor.of(B, A, A));
            navigation = bind(linker, lib, "cadaclysm_view_navigation", FunctionDescriptor.of(I, A));
            setLighting = bind(linker, lib, "cadaclysm_view_set_lighting", FunctionDescriptor.of(B, A, I));
            lighting = bind(linker, lib, "cadaclysm_view_lighting", FunctionDescriptor.of(I, A));
            // 1.10: bound only; the viewport cameras get a Java API in a later wrappers plan.
            viewportCamera = bind(linker, lib, "cadaclysm_view_viewport_camera", FunctionDescriptor.of(B, A, I, A));
            setViewportCamera = bind(linker, lib, "cadaclysm_view_set_viewport_camera", FunctionDescriptor.of(B, A, I, A));
            setViewportRects = bind(linker, lib, "cadaclysm_view_set_viewport_rects", FunctionDescriptor.of(B, A, A, I));
            aim = bind(linker, lib, "cadaclysm_view_aim", FunctionDescriptor.of(B, A, I, A, A));
            setPivot = bind(linker, lib, "cadaclysm_view_set_pivot", FunctionDescriptor.of(B, A, I, A));
            setTap = bind(linker, lib, "cadaclysm_view_set_tap", FunctionDescriptor.of(B, A, F, D));
            orbitIn = bind(linker, lib, "cadaclysm_view_orbit_in", FunctionDescriptor.ofVoid(A, I, F, F));
            panIn = bind(linker, lib, "cadaclysm_view_pan_in", FunctionDescriptor.ofVoid(A, I, F, F));
            zoomIn = bind(linker, lib, "cadaclysm_view_zoom_in", FunctionDescriptor.ofVoid(A, I, F));
            lookIn = bind(linker, lib, "cadaclysm_view_look_in", FunctionDescriptor.ofVoid(A, I, F, F));
            dollyIn = bind(linker, lib, "cadaclysm_view_dolly_in", FunctionDescriptor.ofVoid(A, I, F));
            frameIn = bind(linker, lib, "cadaclysm_view_frame_in", FunctionDescriptor.of(B, A, I, I));
            standardIn = bind(linker, lib, "cadaclysm_view_standard_in", FunctionDescriptor.of(B, A, I, I));
            name = text(View.<MemorySegment>call(() -> (MemorySegment) nameFn.invoke()));
        }

        public String name() {
            return name;
        }

        public String path() {
            return path;
        }

        /** "wgpu" (cadaclysm_view), "terminal" (cadaclysm_terminal), or "other" -- Python's Library.kind. */
        public String kind() {
            return name.startsWith("cadaclysm-view ") ? "wgpu" : name.startsWith("cadaclysm-terminal ") ? "terminal" : "other";
        }

        String lastErrorText() {
            return text(View.<MemorySegment>call(() -> (MemorySegment) lastError.invoke()));
        }

        /**
         * A colour's text as r, g, b in 0..1 -- {@code "#rgb"}, {@code "#rrggbb"} (the {@code #}
         * optional) or one of the 148 CSS colour names, any case -- read by the library's own
         * {@code cadaclysm_view_parse_colour} (Python's {@code _colour}), so every wrapper takes the
         * same forms; null stays null. A ViewException with the library's message for text that
         * is no colour. Needs no view.
         */
        public float[] colour(String text) {
            if (text == null) return null;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment t = arena.allocateFrom(text), out = arena.allocate(ValueLayout.JAVA_FLOAT, 3);
                boolean ok = View.<Boolean>call(() -> (boolean) parseColour.invoke(t, out));
                if (!ok) {
                    String why = lastErrorText();
                    throw new ViewException(why.isEmpty() ? "colour '" + text + "'" : why);
                }
                return out.toArray(ValueLayout.JAVA_FLOAT);
            }
        }

        /** A TTF/OTF font for every view of this library; its id (0 is the bundled font, never returned). */
        public int loadFont(byte[] bytes) {
            if (bytes == null) throw new ViewException("loadFont: font bytes, not null");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment b = arena.allocateFrom(ValueLayout.JAVA_BYTE, bytes);
                long length = bytes.length;
                int id = View.<Integer>call(() -> (int) loadFont.invoke(b, length));
                if (id == 0) throw failure("loadFont");
                return id;
            }
        }

        /** The library's own reason, bare (Python's _error); {@code what} names the call for the reader of the code only. */
        ViewException failure(String what) {
            return new ViewException(reason(lastErrorText()));
        }
    }

    private static Library current;

    private static String fileName(String base) {
        String os = System.getProperty("os.name", "").toLowerCase();
        return os.contains("win") ? base + ".dll" : os.contains("mac") ? "lib" + base + ".dylib" : "lib" + base + ".so";
    }

    /** {@code variable} (a file or a directory), then beside this class, then lib/ and target/{release,debug} above it. */
    static Path find(String base, String variable) {
        Path start = Cad.Loader.codeLocation();
        return find(base, variable, System.getenv(variable), start == null || Files.isDirectory(start) ? start : start.getParent());
    }

    /** {@link #find(String, String)} with the variable's value and this class's folder given (tests). */
    static Path find(String base, String variable, String override, Path here) {
        String name = fileName(base);
        boolean terminal = base.endsWith("_terminal");
        if (override != null && !override.isEmpty()) {
            Path candidate = Path.of(override);
            boolean directory = Files.isDirectory(candidate);
            if (directory) candidate = candidate.resolve(name);
            if (Files.exists(candidate)) return candidate;
            // Python's words: the terminal's variable also says which file a directory lacks.
            throw new ViewException(variable + "=" + override + " names nothing that exists"
                + (terminal && directory ? " (no " + name + " in that directory)" : ""));
        }
        List<Path> ancestors = new ArrayList<>();
        for (Path at = here; at != null; at = at.getParent()) ancestors.add(at);
        List<Path> searched = new ArrayList<>();
        if (here != null) searched.add(here.resolve(name));
        for (Path at : ancestors) searched.add(at.resolve("lib").resolve(name));
        for (Path at : ancestors) {
            searched.add(at.resolve("target").resolve("release").resolve(name));
            searched.add(at.resolve("target").resolve("debug").resolve(name));
        }
        for (Path candidate : searched) if (Files.exists(candidate)) return candidate;
        String where = String.join(", ", searched.stream().map(Path::toString).toList());
        throw new ViewException(terminal
            ? "no view library: the terminal library was not found (searched: " + where + ") "
                + "-- reinstall cadaclysm, set CADACLYSM_TERMINAL_LIBRARY to the library, or set CADACLYSM_VIEW"
            : "no view library: " + name + " was not found (searched: " + where + ") "
                + "-- reinstall cadaclysm, set " + variable + " to it, or View.useTerminal()");
    }

    /** Draw with the terminal library (the default) from now on. */
    public static synchronized Library useTerminal() {
        return current = new Library(find("cadaclysm" + "_terminal", "CADACLYSM_TERMINAL_LIBRARY"));
    }

    /** Draw with the GPU window library, cadaclysm_view, from now on. */
    public static synchronized Library useWgpu() {
        return current = new Library(find("cadaclysm" + "_view", "CADACLYSM_VIEW_LIBRARY"));
    }

    /**
     * A TTF/OTF font for every view of the library in use; its id for {@link TextOptions#font} (0 is the bundled font).
     * Choose the library first ({@link #useWgpu}, {@link #useTerminal}, {@link #use}): a font id belongs to the library
     * that loaded it, and means nothing -- or another font -- to a library chosen afterwards.
     */
    public static int loadFont(byte[] bytes) {
        if (bytes == null) throw new ViewException("loadFont: font bytes, not null");
        return current().loadFont(bytes);
    }

    /** {@link #loadFont(byte[])} from a file; a file that cannot be read is a ViewException naming it and why. */
    public static int loadFont(Path path) {
        if (path == null) throw new ViewException("loadFont: a font path, not null");
        byte[] bytes;
        try {
            bytes = Files.readAllBytes(path);
        } catch (IOException | SecurityException e) {
            String detail = e.getMessage();
            String why = e.getClass().getSimpleName() + (detail == null || detail.equals(path.toString()) ? "" : ": " + detail);
            throw new ViewException(path + ": the font could not be read (" + why + ")");
        }
        return loadFont(bytes);
    }

    /** Draw with the view library at {@code path} from now on. */
    public static synchronized Library use(String path) {
        return current = new Library(Path.of(path));
    }

    /** The library in use: the last use*(), else CADACLYSM_VIEW (terminal, wgpu or a path), else the terminal. */
    public static synchronized Library current() {
        if (current != null) return current;
        String chosen = System.getenv("CADACLYSM_VIEW");
        if ("wgpu".equals(chosen)) return useWgpu();
        if (chosen == null || chosen.isEmpty() || "terminal".equals(chosen)) return useTerminal();
        return use(chosen);
    }

    // ---- the plain records the calls take and give ------------------------------------

    /** Own-window and offscreen options. */
    public static final class Options {
        String title;
        int width;
        int height;
        String surfaces = "exact";
        String up = "z";
        int backend;

        public Options title(String value) { title = value; return this; }
        public Options width(int value) { width = value; return this; }
        public Options height(int value) { height = value; return this; }
        public Options surfaces(String value) { surfaces = value; return this; }
        public Options up(String value) { up = value; return this; }
        public Options backend(int value) { backend = value; return this; }
    }

    /**
     * What show() and view() on a solid, scene, node or pose take: Rust's ViewOptions fields.
     * {@code up} null is the scene's own up axis ("z" for a solid); {@code tolerance} null is
     * 0.05 for a solid and refused for a document, which is drawn at the tolerance it was read with.
     */
    public static final class ShowOptions {
        String view = "iso";
        Double azimuth;
        Double elevation;
        Double zoom;
        String up;
        boolean edges = true;
        int width;
        int height;
        String title;
        Double tolerance;
        float[] rgb;
        String rgbText;

        /** front, back, left, right, top, bottom or iso; null is the default, iso (Python's view=None). */
        public ShowOptions view(String value) { view = value == null ? "iso" : value; return this; }
        public ShowOptions azimuth(double value) { azimuth = value; return this; }
        public ShowOptions elevation(double value) { elevation = value; return this; }
        public ShowOptions zoom(double value) { zoom = value; return this; }
        public ShowOptions up(String value) { up = value; return this; }
        public ShowOptions edges(boolean value) { edges = value; return this; }
        public ShowOptions width(int value) { width = value; return this; }
        public ShowOptions height(int value) { height = value; return this; }
        public ShowOptions title(String value) { title = value; return this; }
        public ShowOptions tolerance(double value) { tolerance = value; return this; }
        public ShowOptions rgb(float[] value) { rgb = value; rgbText = null; return this; }
        /** The colour as text: {@code "#rgb"}, {@code "#rrggbb"} or a CSS colour name, read by the view library. */
        public ShowOptions rgb(String value) { rgbText = value; rgb = null; return this; }
    }

    /** showText's options: a white 12 px label, bottom-left on its anchor, by default. */
    public static final class TextOptions {
        /** "label" (pixels, facing the camera) or "world" (model units, in the plane of right and up). */
        public String mode = "label";
        /** The text's height: pixels for a label, model units for world text. */
        public float size = 12f;
        /** The glyphs' colour as text ("#rgb", "#rrggbb", a CSS name); it wins over {@link #colour} when both are set, as
         *  ShowOptions' text colour is read first. */
        public String colourText;
        /** The glyphs' colour, three numbers, used when {@link #colourText} is null; both null is white. */
        public float[] colour;
        /** top-left, top, top-right, left, centre (or center), right, bottom-left, bottom or bottom-right. */
        public String align = "bottom-left";
        /** A label's shift from its anchor in pixels, two numbers; null is none. */
        public float[] offset;
        /** The label's box as text (alpha 1); it wins over {@link #box} (3 or 4 numbers) when both are set; none by default. */
        public String boxText;
        public float[] box;
        /** Pixels between a label's text and the edge of its box. */
        public float padding = 4f;
        /** Drawn over the model instead of hidden by it. */
        public boolean onTop;
        /** 0 is the bundled font; else an id from {@link View#loadFont(byte[])}. */
        public int font;
        /** World text's baseline and up directions, three numbers each; null is +X and +Y. */
        public float[] right;
        public float[] up;
    }

    /** A host's window: a {@code WINDOW_*} kind, the handle, an Xlib/XCB id, the display, its size in physical pixels. */
    public record Window(int kind, long window, long windowId, long display, int width, int height) {
    }

    /**
     * One forwarded event: type is pointer_down, pointer_move, pointer_up, pointer_cancel,
     * wheel or key; pointer is mouse, touch or pen (null: mouse); timeMs 0 means now.
     */
    public record Event(String type, float x, float y, int button, boolean shift, int pointerId, String pointer,
                        float wheelY, String key, boolean keyDown, double timeMs) {
    }

    /** One viewport: rect is x, y, w, h in physical pixels, the matrices column-major, grid none, top, front or right. */
    public record Viewport(int[] rect, float[] view, float[] projection, float[] eye, String grid) {
    }

    /**
     * A pick answer: the item, node and face hit; {@code clicks} 2 for a double click, else 1;
     * {@code point} where the ray met the model (x, y, z, in the coordinates the items were shown
     * in), or null where the library read no depth (a machining stock, the terminal library).
     */
    public record Pick(int item, int node, int face, int clicks, float[] point) {
    }

    /** A CadaclysmViewPick as the answer: null for no item; the point only where has_point is set (Python's _pick_dict). */
    static Pick pickOf(MemorySegment raw) {
        return raw.get(ValueLayout.JAVA_INT, off(PICK, "item")) == 0 ? null : answerOf(raw);
    }

    /** A CadaclysmViewPick as it was answered, item 0 (nothing hit) included. */
    static Pick answerOf(MemorySegment raw) {
        float[] point = raw.get(ValueLayout.JAVA_INT, off(PICK, "has_point")) != 0
                ? raw.asSlice(off(PICK, "point"), 12).toArray(ValueLayout.JAVA_FLOAT) : null;
        return new Pick(raw.get(ValueLayout.JAVA_INT, off(PICK, "item")), raw.get(ValueLayout.JAVA_INT, off(PICK, "node")),
                raw.get(ValueLayout.JAVA_INT, off(PICK, "face")), raw.get(ValueLayout.JAVA_INT, off(PICK, "clicks")), point);
    }

    /**
     * Why the library at {@code path}, answering {@code version} from cadaclysm_view_abi_version,
     * is refused -- null when this wrapper takes it (1.11 or a later 1.x).
     */
    static String abiRefusal(String path, int version) {
        int major = version >>> 16, minor = version & 0xFFFF;
        if (major == ABI_MAJOR && minor >= ABI_MINOR) return null;
        return path + ": view ABI " + major + "." + minor + ", this wrapper needs " + ABI_MAJOR + "." + ABI_MINOR
                + " or a later " + ABI_MAJOR + ".x";
    }

    public record Camera(float[] eye, float[] target, float[] up, boolean orthographic, double azimuth,
                         double elevation, Pick pick) {
    }

    /** RGBA8, rows from the top. */
    public record Image(int width, int height, byte[] rgba) {
    }

    // ---- checks on what is handed to C ---------------------------------------------------

    static int named(Map<String, Integer> table, String value, String what) {
        Integer found = value == null ? null : table.get(value);
        if (found == null) {
            throw new ViewException(what + " " + (value == null ? "null" : "\"" + value + "\"") + ": one of "
                    + new java.util.TreeSet<>(table.keySet()));
        }
        return found;
    }

    /** Exactly {@code n} numbers, or null: C reads that many. */
    static float[] exact(float[] values, int n, String what) {
        if (values != null && values.length != n) throw new ViewException(what + ": " + n + " numbers, not " + values.length);
        return values;
    }

    static int[] exact(int[] values, int n, String what) {
        if (values != null && values.length != n) throw new ViewException(what + ": " + n + " numbers, not " + values.length);
        return values;
    }

    static double[] exact(double[] values, int n, String what) {
        if (values != null && values.length != n) throw new ViewException(what + ": " + n + " numbers, not " + values.length);
        return values;
    }

    /** Colour text as four floats, alpha 1 (text carries none); null stays null. */
    static float[] rgba(Library lib, String text) {
        float[] c = lib.colour(text);
        return c == null ? null : new float[]{c[0], c[1], c[2], 1};
    }

    /** Three or four numbers as four floats (alpha 1 where only three were given); null stays null. */
    static float[] rgba(float[] values, String what) {
        if (values == null) return null;
        if (values.length != 3 && values.length != 4) throw new ViewException(what + ": 3 or 4 numbers, not " + values.length);
        return new float[]{values[0], values[1], values[2], values.length > 3 ? values[3] : 1};
    }

    /** A whole number of {@code unit}-float records: segments, curves. */
    static float[] records(float[] values, int unit, String what, String noun) {
        if (values.length % unit != 0) throw new ViewException(what + ": " + unit + " numbers a " + noun + ", not " + values.length);
        return values;
    }

    /** width x height x 4 bytes in long arithmetic: a size nobody can allocate is the wrapper's error. */
    static long pixelBytes(long width, long height, String what) {
        if (width < 0 || height < 0) throw new ViewException(what + ": a size of " + width + " x " + height + " pixels");
        try {
            return Math.multiplyExact(Math.multiplyExact(width, height), 4L);
        } catch (ArithmeticException e) {
            throw new ViewException(what + ": " + width + " x " + height + " pixels is too large");
        }
    }

    // ---- the view -------------------------------------------------------------------

    /** The cleaner, made on first use: Cad.Scene.close() reaches release without starting its thread. */
    private static final class Cleaning {
        static final Cleaner CLEANER = Cleaner.create();
    }

    private static final List<View> OPEN_VIEWS = new ArrayList<>();
    /** Every live view, weakly: release walks it when a scene closes. */
    private static final Map<View, Boolean> LIVE = Collections.synchronizedMap(new WeakHashMap<>());

    /** The pointer and the call that frees it: what the cleaner runs, never the View itself. */
    private static final class Handle implements Runnable {
        private final MethodHandle destroy;
        long address;
        /** The arena of every scene an item shows, one per item: held here, by what the cleaner
         *  runs, so a scene dropped with its view stays open until the view is destroyed --
         *  the order cadaclysm_view.h requires. */
        final List<Object> scenes = Collections.synchronizedList(new ArrayList<>());

        Handle(MethodHandle destroy, MemorySegment raw) {
            this.destroy = destroy;
            this.address = raw.address();
        }

        @Override
        public void run() {
            long a = address;
            address = 0;
            if (a == 0) return;
            MemorySegment p = MemorySegment.ofAddress(a);
            call(() -> {
                destroy.invoke(p);
                return null;
            });
            scenes.clear();
        }
    }

    private final Library lib;
    private final Handle handle;
    private final Cleaner.Cleanable cleanable;
    private final boolean own;
    private final boolean yUp;
    private boolean windowClosed;
    private boolean drawn;
    private final Thread thread = Thread.currentThread();
    final Map<Integer, Item> items = new LinkedHashMap<>();

    /** A window of the library's own. */
    public View(Options options) {
        this(options, null, false, options.width, options.height);
    }

    public View() {
        this(new Options());
    }

    /** A view with no window and no display. */
    public static View offscreen(int width, int height, Options options) {
        return new View(options, null, true, width, height);
    }

    public static View offscreen(int width, int height) {
        return offscreen(width, height, new Options());
    }

    /** A view drawing into a host's window; the host forwards input and resizes and calls draw. */
    public static View inWindow(Window window, Options options) {
        if (window.width() <= 0 || window.height() <= 0) {
            throw new ViewException("a host's window needs width and height: its client size in physical pixels");
        }
        if (window.kind() < WINDOW_WIN32 || window.kind() > WINDOW_APPKIT) {
            throw new ViewException("kind " + window.kind() + ": one of WINDOW_WIN32 .. WINDOW_APPKIT (1 to 5)");
        }
        if (window.kind() >= WINDOW_XLIB && window.kind() <= WINDOW_WAYLAND && window.display() == 0) {
            throw new ViewException("kind " + window.kind() + " needs display (the Display*, xcb_connection_t* or wl_display*)");
        }
        return new View(options, window, false, window.width(), window.height());
    }

    private View(Options o, Window window, boolean offscreen, int w, int h) {
        String up = o.up == null ? "z" : o.up.toLowerCase();
        if (!up.equals("y") && !up.equals("z")) throw new ViewException("up \"" + o.up + "\": 'y' or 'z'");
        int surfaces = named(SURFACES, o.surfaces, "surfaces");
        if (w < 0 || h < 0) {
            throw new ViewException("width=" + w + ", height=" + h + ": a size is pixels, 0 or more (0 = the library decides)");
        }
        lib = current();
        yUp = up.equals("y");
        MemorySegment raw;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment opts = arena.allocate(OPTIONS);
            opts.set(ValueLayout.JAVA_INT, off(OPTIONS, "size"), (int) OPTIONS.byteSize());
            opts.set(ValueLayout.JAVA_INT, off(OPTIONS, "surfaces"), surfaces);
            opts.set(ValueLayout.JAVA_INT, off(OPTIONS, "backend"), o.backend);
            opts.set(ValueLayout.JAVA_INT, off(OPTIONS, "y_up"), yUp ? 1 : 0);
            opts.set(ValueLayout.ADDRESS, off(OPTIONS, "title"), o.title == null ? MemorySegment.NULL : arena.allocateFrom(o.title));
            opts.set(ValueLayout.JAVA_INT, off(OPTIONS, "width"), w);
            opts.set(ValueLayout.JAVA_INT, off(OPTIONS, "height"), h);
            opts.set(ValueLayout.JAVA_INT, off(OPTIONS, "offscreen"), offscreen ? 1 : 0);
            MemorySegment win = MemorySegment.NULL;
            if (window != null) {
                win = arena.allocate(WINDOW);
                win.set(ValueLayout.JAVA_INT, off(WINDOW, "size"), (int) WINDOW.byteSize());
                win.set(ValueLayout.JAVA_INT, off(WINDOW, "kind"), window.kind());
                win.set(ValueLayout.ADDRESS, off(WINDOW, "window"), MemorySegment.ofAddress(window.window()));
                win.set(ValueLayout.JAVA_LONG, off(WINDOW, "window_id"), window.windowId());
                win.set(ValueLayout.ADDRESS, off(WINDOW, "display"), MemorySegment.ofAddress(window.display()));
                win.set(ValueLayout.JAVA_INT, off(WINDOW, "width"), window.width());
                win.set(ValueLayout.JAVA_INT, off(WINDOW, "height"), window.height());
            }
            final MemorySegment winArg = win;
            raw = call(() -> (MemorySegment) lib.create.invoke(winArg, opts));
        }
        if (raw.address() == 0) {
            String why = lib.lastErrorText();
            if (why.isEmpty()) why = "the view library failed";
            if (why.contains("no display")) why += " -- draw without a display with View.offscreen(width, height), or the terminal (View.useTerminal())";
            throw new ViewException(why);
        }
        handle = new Handle(lib.destroy, raw);
        cleanable = Cleaning.CLEANER.register(this, handle);
        own = window == null && !offscreen;
        LIVE.put(this, Boolean.TRUE);
        if (own && "wgpu".equals(lib.kind())) {
            synchronized (View.class) {
                OPEN_VIEWS.add(this);
            }
        }
    }

    /** The live pointer for the C call {@code call}, refusing another thread's, a closed view and a closed window. */
    MemorySegment live(String call) {
        if (Thread.currentThread() != thread) throw new ViewException(call + ": a view belongs to the thread that made it");
        if (handle.address == 0) throw new ViewException(call + ": the view is closed");
        if (windowClosed) throw new ViewException(call + ": the window is closed");
        return MemorySegment.ofAddress(handle.address);
    }

    private static String c(String call) {
        return "cadaclysm_view_" + call;
    }

    private void ok(boolean done, String what) {
        if (!done) throw lib.failure(what);
    }

    /** A call with no result: a refusal is the library's last error (Python's _void). */
    private void voidCall(String call, MethodHandle target, Object... args) {
        MemorySegment p = live(c(call));
        Object[] all = new Object[args.length + 1];
        all[0] = p;
        System.arraycopy(args, 0, all, 1, args.length);
        call(() -> target.invokeWithArguments(all));
        String why = lib.lastErrorText();
        if (!why.isEmpty()) throw new ViewException(why);
    }

    private Item item(int id, Object shown, String what) {
        if (id == 0) throw lib.failure(what);
        Item item = new Item(this, id, shown);
        items.put(id, item);
        Cad.Scene scene = sceneOf(shown);
        if (scene != null) handle.scenes.add(scene.lifetime());
        return item;
    }

    public boolean closed() {
        return handle.address == 0 || windowClosed;
    }

    // -- showing

    /** A Blacksmith.Solid, a Cad.Scene or a Cad.Node, by handle. */
    public Item show(Object obj) {
        return show(obj, (float[]) null, 0.05);
    }

    /** {@link #show(Object, float[], double)} with the colour as text ({@code "#rgb"}, {@code "#rrggbb"}, a CSS name). */
    public Item show(Object obj, String rgb, double tolerance) {
        return show(obj, lib.colour(rgb), tolerance);
    }

    public Item show(Object obj, float[] rgb, double tolerance) {
        if (obj instanceof Blacksmith.Solid solid) return showSolid(solid, tolerance, rgb);
        if (obj instanceof Cad.Scene scene) return showScene(scene);
        if (obj instanceof Cad.Node node) return showNode(node);
        throw new ViewException("show: a Blacksmith.Solid, Cad.Scene or Cad.Node, not " + obj);
    }

    public Item showSolid(Blacksmith.Solid solid) {
        return showSolid(solid, 0.05, (float[]) null);
    }

    /** {@link #showSolid(Blacksmith.Solid, double, float[])} with the colour as text. */
    public Item showSolid(Blacksmith.Solid solid, double tolerance, String rgb) {
        return showSolid(solid, tolerance, lib.colour(rgb));
    }

    public Item showSolid(Blacksmith.Solid solid, double tolerance, float[] rgb) {
        exact(rgb, 3, "showSolid rgb");
        MemorySegment p = live(c("show_solid"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment colour = floats(arena, rgb);
            MemorySegment h = solid.handle();
            return item(call(() -> (int) lib.showSolid.invoke(p, h, tolerance, colour)), solid, "showSolid");
        }
    }

    public Item showScene(Cad.Scene scene) {
        return showScene(scene, scene);
    }

    private Item showScene(Cad.Scene scene, Object shown) {
        MemorySegment p = live(c("show"));
        MemorySegment h = scene.handle();
        return item(call(() -> (int) lib.show.invoke(p, h)), shown, "showScene");
    }

    /** The node's scene by handle, every node outside this one hidden. */
    public Item showNode(Cad.Node node) {
        Item item = showScene(node.scene(), node);
        List<Cad.Node> chain = new ArrayList<>();
        for (Cad.Node at = node; at != null; at = at.parent()) chain.add(0, at);
        List<Cad.Node> level = node.scene().roots();
        for (Cad.Node on : chain) {
            for (Cad.Node other : level) if (other.index() != on.index()) item.nodeVisible(other.index(), false);
            level = on.children();
        }
        return item;
    }

    /** {@link #showMesh(float[], int[], float[], float[], float[])} in the default colour. */
    public Item showMesh(float[] positions, int[] indices, float[] normals, float[] edges) {
        return showMesh(positions, indices, normals, edges, (float[]) null);
    }

    /** {@link #showMesh(float[], int[], float[], float[], float[])} with the colour as text. */
    public Item showMesh(float[] positions, int[] indices, float[] normals, float[] edges, String rgb) {
        return showMesh(positions, indices, normals, edges, lib.colour(rgb));
    }

    /** Three floats a vertex, three indices a triangle; normals (one a position) and edges (six floats a segment) may be null. */
    public Item showMesh(float[] positions, int[] indices, float[] normals, float[] edges, float[] rgb) {
        if (positions == null || indices == null) throw new ViewException("showMesh: positions and indices are required");
        if (normals != null && normals.length != positions.length) {
            throw new ViewException("showMesh: " + positions.length / 3 + " positions but " + normals.length / 3 + " normals");
        }
        if (edges != null && edges.length % 6 != 0) {
            throw new ViewException("showMesh: edges are two points a segment (6 numbers), not " + edges.length);
        }
        exact(rgb, 3, "showMesh rgb");
        MemorySegment p = live(c("show_mesh"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment m = arena.allocate(MESH);
            m.set(ValueLayout.JAVA_INT, off(MESH, "size"), (int) MESH.byteSize());
            m.set(ValueLayout.ADDRESS, off(MESH, "positions"), floats(arena, positions));
            m.set(ValueLayout.JAVA_INT, off(MESH, "vertex_count"), positions.length / 3);
            m.set(ValueLayout.ADDRESS, off(MESH, "normals"), floats(arena, normals));
            m.set(ValueLayout.ADDRESS, off(MESH, "indices"), arena.allocateFrom(ValueLayout.JAVA_INT, indices));
            m.set(ValueLayout.JAVA_INT, off(MESH, "index_count"), indices.length);
            m.set(ValueLayout.ADDRESS, off(MESH, "edges"), floats(arena, edges));
            m.set(ValueLayout.JAVA_INT, off(MESH, "edge_count"), edges == null ? 0 : edges.length / 6);
            m.set(ValueLayout.ADDRESS, off(MESH, "rgb"), floats(arena, rgb));
            return item(call(() -> (int) lib.showMesh.invoke(p, m)), null, "showMesh");
        }
    }

    /** {@link #showLines(float[], float[])} in the default colour. */
    public Item showLines(float[] segments) {
        return showLines(segments, (float[]) null);
    }

    /** {@link #showLines(float[], float[])} with the colour as text. */
    public Item showLines(float[] segments, String rgb) {
        return showLines(segments, lib.colour(rgb));
    }

    /** Six floats a segment. */
    public Item showLines(float[] segments, float[] rgb) {
        records(segments, 6, "showLines", "segment");
        exact(rgb, 3, "showLines rgb");
        MemorySegment p = live(c("show_lines"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment s = floats(arena, segments), col = floats(arena, rgb);
            return item(call(() -> (int) lib.showLines.invoke(p, s, segments.length / 6, col)), null, "showLines");
        }
    }

    /** {@link #showPoints(float[], float[], float)} in the default colour, 8 pixels across. */
    public Item showPoints(float[] positions) {
        return showPoints(positions, (float[]) null, 8f);
    }

    /** {@link #showPoints(float[], float[], float)} with the colour as text, 8 pixels across. */
    public Item showPoints(float[] positions, String rgb) {
        return showPoints(positions, rgb, 8f);
    }

    /** {@link #showPoints(float[], float[], float)} with the colour as text. */
    public Item showPoints(float[] positions, String rgb, float sizePx) {
        return showPoints(positions, lib.colour(rgb), sizePx);
    }

    /** {@link #showPoints(float[], float[], float)} 8 pixels across. */
    public Item showPoints(float[] positions, float[] rgb) {
        return showPoints(positions, rgb, 8f);
    }

    /**
     * Points as three floats each: a disc {@code sizePx} device pixels across (1 to 64) at each,
     * in {@code rgb} (null: the edge colour), as one item. A point does not pick. The library
     * refuses a number that is not finite and a size outside 1..64.
     */
    public Item showPoints(float[] positions, float[] rgb, float sizePx) {
        if (positions.length % 3 != 0) throw new ViewException("showPoints: three numbers a point, not " + positions.length);
        exact(rgb, 3, "showPoints rgb");
        MemorySegment p = live(c("show_points"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment s = floats(arena, positions), col = floats(arena, rgb);
            return item(call(() -> (int) lib.showPoints.invoke(p, s, positions.length / 3, col, sizePx)), null, "showPoints");
        }
    }

    /** {@link #showCurves(float[], float[])} in the default colour. */
    public Item showCurves(float[] beziers) {
        return showCurves(beziers, (float[]) null);
    }

    /** {@link #showCurves(float[], float[])} with the colour as text. */
    public Item showCurves(float[] beziers, String rgb) {
        return showCurves(beziers, lib.colour(rgb));
    }

    /** Sixteen floats a rational cubic: four control points as x, y, z, w. */
    public Item showCurves(float[] beziers, float[] rgb) {
        records(beziers, 16, "showCurves", "curve");
        exact(rgb, 3, "showCurves rgb");
        MemorySegment p = live(c("show_curves"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment b = floats(arena, beziers), col = floats(arena, rgb);
            return item(call(() -> (int) lib.showCurves.invoke(p, b, beziers.length / 16, col)), null, "showCurves");
        }
    }

    /** corners: twelve floats, bottom-left, bottom-right, top-right, top-left; rgba rows from the top, w * h * 4 bytes. */
    public Item showImage(float[] corners, byte[] rgba, int w, int h, float opacity) {
        if (corners == null || corners.length != 12) {
            throw new ViewException("showImage: corners are 12 numbers, not " + (corners == null ? 0 : corners.length));
        }
        long need = pixelBytes(w, h, "showImage");
        if (need != rgba.length) {
            throw new ViewException("showImage: " + w + " x " + h + " pixels need " + need + " bytes (w * h * 4), not " + rgba.length);
        }
        MemorySegment p = live(c("show_image"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment img = arena.allocate(IMAGE);
            img.set(ValueLayout.JAVA_INT, off(IMAGE, "size"), (int) IMAGE.byteSize());
            MemorySegment.copy(corners, 0, img, ValueLayout.JAVA_FLOAT, off(IMAGE, "corners"), 12);
            img.set(ValueLayout.ADDRESS, off(IMAGE, "rgba"), arena.allocateFrom(ValueLayout.JAVA_BYTE, rgba));
            img.set(ValueLayout.JAVA_INT, off(IMAGE, "width"), w);
            img.set(ValueLayout.JAVA_INT, off(IMAGE, "height"), h);
            img.set(ValueLayout.JAVA_FLOAT, off(IMAGE, "opacity"), opacity);
            return item(call(() -> (int) lib.showImage.invoke(p, img)), null, "showImage");
        }
    }

    /** The text, or a ViewException for null or for one holding a NUL (the C string would end there). */
    static String textOf(String text) {
        if (text == null) throw new ViewException("text: a string, not null");
        if (text.indexOf('\0') >= 0) {
            throw new ViewException("text \"" + text + "\": a NUL character cannot be shown (the C string ends there)");
        }
        return text;
    }

    /** {@link #showText(String, float[], TextOptions)} with the default options: a white 12 px label. */
    public Item showText(String text, float[] at) {
        return showText(text, at, new TextOptions());
    }

    /** Text shown as one item (cadaclysm_view_show_text): a label anchored to {@code at}, or world text; null options are the defaults. */
    public Item showText(String text, float[] at, TextOptions options) {
        TextOptions o = options == null ? new TextOptions() : options;
        String shown = textOf(text);
        int mode = named(TEXT_MODES, o.mode, "mode"), align = named(ALIGN, o.align, "align");
        if (at == null || at.length != 3) throw new ViewException("showText at: 3 numbers, not " + (at == null ? 0 : at.length));
        float[] rgb = exact(o.colourText != null ? lib.colour(o.colourText) : o.colour != null ? o.colour : lib.colour("white"), 3, "showText colour");
        float[] right = exact(o.right, 3, "showText right");
        float[] up = exact(o.up, 3, "showText up");
        float[] offset = exact(o.offset, 2, "showText offset");
        float[] box = o.boxText != null ? rgba(lib, o.boxText) : rgba(o.box, "showText box");
        MemorySegment p = live(c("show_text"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment t = arena.allocate(TEXT);   // zeroed: right, up, offset and box_rgba absent are all zero
            t.set(ValueLayout.JAVA_INT, off(TEXT, "size"), (int) TEXT.byteSize());
            t.set(ValueLayout.ADDRESS, off(TEXT, "text"), arena.allocateFrom(shown));
            t.set(ValueLayout.JAVA_INT, off(TEXT, "mode"), mode);
            put(t, "at", at);
            if (right != null) put(t, "right", right);
            if (up != null) put(t, "up", up);
            t.set(ValueLayout.JAVA_FLOAT, off(TEXT, "height"), o.size);
            put(t, "rgb", rgb);
            t.set(ValueLayout.JAVA_INT, off(TEXT, "align"), align);
            if (offset != null) put(t, "offset", offset);
            if (box != null) put(t, "box_rgba", box);
            t.set(ValueLayout.JAVA_FLOAT, off(TEXT, "box_padding"), o.padding);
            t.set(ValueLayout.JAVA_INT, off(TEXT, "on_top"), o.onTop ? 1 : 0);
            t.set(ValueLayout.JAVA_INT, off(TEXT, "font"), o.font);
            return item(call(() -> (int) lib.showText.invoke(p, t)), null, "showText");
        }
    }

    /** {@code values} (already length-checked) into TEXT's float array {@code field}. */
    private static void put(MemorySegment t, String field, float[] values) {
        MemorySegment.copy(values, 0, t, ValueLayout.JAVA_FLOAT, off(TEXT, field), values.length);
    }

    static MemorySegment floats(Arena arena, float[] values) {
        return values == null ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_FLOAT, values);
    }

    // -- the camera

    public void orbit(float dx, float dy) {
        voidCall("orbit", lib.orbit, dx, dy);
    }

    public void pan(float dx, float dy) {
        voidCall("pan", lib.pan, dx, dy);
    }

    public void zoom(float steps) {
        voidCall("zoom", lib.zoom, steps);
    }

    public void look(float dx, float dy) {
        voidCall("look", lib.look, dx, dy);
    }

    public void dolly(float ratio) {
        voidCall("dolly", lib.dolly, ratio);
    }

    /** top, front, right or iso. */
    public void standard(String name) {
        int which = named(STANDARD, name, "standard view");
        MemorySegment p = live(c("standard"));
        ok(call(() -> (boolean) lib.standard.invoke(p, which)), "standard");
    }

    /** Fit the camera to everything shown. */
    public void frame() {
        MemorySegment p = live(c("frame"));
        ok(call(() -> (boolean) lib.frame.invoke(p, 0)), "frame");
    }

    public void orthographic(boolean on) {
        voidCall("set_orthographic", lib.setOrthographic, on);
    }

    /**
     * Whether a double click frames what it hit (off by default: it is a pick answered with
     * {@code clicks} 2 and the camera stays). Applies where the view takes the pick itself (its own
     * window, pump, run); a host reading picks frames if it chooses.
     */
    public void setDoubleClickFrames(boolean on) {
        voidCall("set_double_click_frames", lib.setDoubleClickFrames, on);
    }

    /**
     * Moves the orbit point to {@code point} (x, y, z, as a pick's point): the eye keeps its
     * direction and distance from it, so the camera moves sideways and does not turn. Leaves fly
     * mode. Other than three numbers is refused before the call; the library refuses a point that
     * is not finite, or while viewports are set, with its own reason.
     */
    public void focus(float[] point) {
        if (point == null) throw new ViewException("focus: 3 numbers, not null");
        exact(point, 3, "focus");
        MemorySegment p = live(c("focus"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment at = arena.allocateFrom(ValueLayout.JAVA_FLOAT, point);
            ok(call(() -> (boolean) lib.focus.invoke(p, at)), "focus");
        }
    }

    /**
     * How a left drag moves the camera: "orbit" (about the target) or "fly" (the view turns about
     * the eye). A fly key (W, A, S, D, E, Q) sent through input enters fly mode and it stays after
     * the key is let go; Tab toggles it; frame, standard and focus leave it.
     */
    public String navigation() {
        MemorySegment p = live(c("navigation"));
        return View.<Integer>call(() -> (int) lib.navigation.invoke(p)) == NAVIGATION_FLY ? "fly" : "orbit";
    }

    public void viewports(List<Viewport> list) {
        List<Integer> grids = new ArrayList<>();
        for (Viewport v : list) {
            exact(v.rect(), 4, "viewport rect");
            exact(v.view(), 16, "viewport view");
            exact(v.projection(), 16, "viewport projection");
            exact(v.eye(), 3, "viewport eye");
            grids.add(named(GRIDS, v.grid() == null ? "none" : v.grid(), "grid"));
        }
        MemorySegment p = live(c("set_viewports"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment all = arena.allocate(VIEWPORT, list.size());
            for (int i = 0; i < list.size(); i++) {
                Viewport v = list.get(i);
                MemorySegment one = all.asSlice(i * VIEWPORT.byteSize(), VIEWPORT.byteSize());
                one.set(ValueLayout.JAVA_INT, off(VIEWPORT, "size"), (int) VIEWPORT.byteSize());
                MemorySegment.copy(v.rect(), 0, one, ValueLayout.JAVA_INT, off(VIEWPORT, "rect"), 4);
                MemorySegment.copy(v.view(), 0, one, ValueLayout.JAVA_FLOAT, off(VIEWPORT, "view"), 16);
                MemorySegment.copy(v.projection(), 0, one, ValueLayout.JAVA_FLOAT, off(VIEWPORT, "projection"), 16);
                MemorySegment.copy(v.eye(), 0, one, ValueLayout.JAVA_FLOAT, off(VIEWPORT, "eye"), 3);
                one.set(ValueLayout.JAVA_INT, off(VIEWPORT, "grid"), grids.get(i));
            }
            ok(call(() -> (boolean) lib.setViewports.invoke(p, all, list.size())), "viewports");
        }
    }

    /** surfaces, edges, curves, isocurves, grid or text. */
    public void layer(String name, boolean on) {
        int which = named(LAYERS, name, "layer");
        MemorySegment p = live(c("set_layer"));
        ok(call(() -> (boolean) lib.setLayer.invoke(p, which, on)), "layer");
    }

    /** The clear colour as text: {@code "#rgb"}, {@code "#rrggbb"} or a CSS colour name. */
    public void background(String rgb) {
        if (rgb == null) throw new ViewException("background: 3 numbers, not none");
        background(lib.colour(rgb));
    }

    /** Three numbers, the clear colour. */
    public void background(float[] rgb) {
        if (rgb == null) throw new ViewException("background: 3 numbers, not none");
        exact(rgb, 3, "background");
        MemorySegment p = live(c("set_background"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment colour = floats(arena, rgb);
            call(() -> lib.setBackground.invoke(p, colour));
            String why = lib.lastErrorText();
            if (!why.isEmpty()) throw new ViewException(why);
        }
    }

    public String surfaces() {
        MemorySegment p = live(c("surfaces"));
        return call(() -> (int) lib.surfaces.invoke(p)) == 1 ? "triangles" : "exact";
    }

    public void surfaces(String name) {
        int which = named(SURFACES, name, "surfaces");
        MemorySegment p = live(c("set_surfaces"));
        ok(call(() -> (boolean) lib.setSurfaces.invoke(p, which)), "surfaces");
    }

    /** How plain parts are lit, as Python's View.lighting: "headlight" (the default) or "studio". */
    public String lighting() {
        MemorySegment p = live(c("lighting"));
        return call(() -> (int) lib.lighting.invoke(p)) == 1 ? "studio" : "headlight";
    }

    /**
     * "headlight" -- whatever faces the camera is bright -- or "studio", a key light fixed above the
     * scene with an ambient and a camera fill. Another name is refused before the library is called.
     */
    public void lighting(String name) {
        int which = named(LIGHTING, name, "lighting");
        MemorySegment p = live(c("set_lighting"));
        ok(call(() -> (boolean) lib.setLighting.invoke(p, which)), "lighting");
    }

    public boolean needsDraw() {
        MemorySegment p = live(c("needs_draw"));
        return call(() -> (boolean) lib.needsDraw.invoke(p));
    }

    // -- the rest

    /**
     * What is under pixel (x, y) of {@code viewport}, or null for nothing. A view never drawn
     * is drawn first: the library answers a pick from the frame it has drawn. A failure other
     * than "no answer yet" throws at once with the library's own message.
     */
    public Pick pick(int x, int y, int viewport) {
        if (!drawn) draw();
        MemorySegment p = live(c("request_pick_in"));
        voidCall("request_pick_in", lib.requestPickIn, viewport, x, y);
        String waiting = "";
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment out = arena.allocate(PICK);
            out.set(ValueLayout.JAVA_INT, off(PICK, "size"), (int) PICK.byteSize());
            for (int i = 0; i < 200; i++) {
                draw();
                if (call(() -> (boolean) lib.pickResult.invoke(p, out))) return pickOf(out);
                waiting = lib.lastErrorText();
                if (!waiting.isEmpty() && !waiting.endsWith("no pick result")) throw new ViewException(waiting);
                sleep(10);
            }
        }
        throw new ViewException("pick: the answer never landed (" + (waiting.isEmpty() ? "no error reported" : waiting) + ")");
    }

    /**
     * The newest pick answer that has landed, without asking or waiting (Python's
     * {@code last_pick}): a click or tap in the view's own window ({@code pump} lands them as it
     * draws), a double click's ({@code clicks} 2), or one an {@code input} asked for, landed by the
     * draws after it. Empty while none has; a click on nothing is a Pick of item 0 (node and face
     * 0, no point); else the pick hit. Each answer is read once, and a newer one replaces one not
     * read yet. A failure other than "no answer yet" throws the library's own message.
     */
    public Optional<Pick> lastPick() {
        MemorySegment p = live(c("pick_result"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment out = arena.allocate(PICK);
            out.set(ValueLayout.JAVA_INT, off(PICK, "size"), (int) PICK.byteSize());
            if (call(() -> (boolean) lib.pickResult.invoke(p, out))) return Optional.of(answerOf(out));
        }
        String waiting = lib.lastErrorText();
        if (!waiting.isEmpty() && !waiting.endsWith("no pick result")) throw new ViewException(waiting);
        return Optional.empty();
    }

    private static void sleep(long ms) {
        if (ms <= 0) return;
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public Pick pick(int x, int y) {
        return pick(x, y, 0);
    }

    public void draw() {
        MemorySegment p = live(c("draw"));
        ok(call(() -> (boolean) lib.draw.invoke(p)), "draw");
        drawn = true;
    }

    /** Blocks until the window is closed; the camera it ended on and the last pick. */
    public Camera run() {
        MemorySegment p = live(c("run"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment cam = arena.allocate(CAMERA);
            cam.set(ValueLayout.JAVA_INT, 0, (int) CAMERA.byteSize());
            MemorySegment pick = arena.allocate(PICK);
            pick.set(ValueLayout.JAVA_INT, 0, (int) PICK.byteSize());
            ok(call(() -> (boolean) lib.run.invoke(p, cam, pick)), "run");
            markClosed();
            float[] eye = cam.asSlice(off(CAMERA, "eye"), 12).toArray(ValueLayout.JAVA_FLOAT);
            float[] target = cam.asSlice(off(CAMERA, "target"), 12).toArray(ValueLayout.JAVA_FLOAT);
            float[] up = cam.asSlice(off(CAMERA, "up"), 12).toArray(ValueLayout.JAVA_FLOAT);
            boolean ortho = cam.get(ValueLayout.JAVA_INT, off(CAMERA, "orthographic")) != 0;
            return camera(eye, target, up, ortho, pickOf(pick), yUp);
        }
    }

    /** One frame read back, RGBA8, rows from the top. */
    public Image image() {
        MemorySegment p = live(c("image"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment ws = arena.allocate(ValueLayout.JAVA_INT), hs = arena.allocate(ValueLayout.JAVA_INT);
            ok(call(() -> (boolean) lib.size.invoke(p, ws, hs)), "image");   // the size the next frame is drawn at
            long w = Integer.toUnsignedLong(ws.get(ValueLayout.JAVA_INT, 0));
            long h = Integer.toUnsignedLong(hs.get(ValueLayout.JAVA_INT, 0));
            long n = pixelBytes(w, h, "image");
            if (n > Integer.MAX_VALUE - 8) {
                throw new ViewException("image: " + w + " x " + h + " pixels (" + n + " bytes) is too large to read back");
            }
            MemorySegment buffer = arena.allocate(n);
            ok(call(() -> (boolean) lib.image.invoke(p, buffer, n)), "image");
            return new Image((int) w, (int) h, buffer.toArray(ValueLayout.JAVA_BYTE));
        }
    }

    /** The frame as a PNG, through java.util.zip -- no imaging library. */
    public void save(Path file) throws IOException {
        Image img = image();
        int stride = img.width() * 4;
        byte[] raw = new byte[(stride + 1) * img.height()];
        for (int y = 0; y < img.height(); y++) System.arraycopy(img.rgba(), y * stride, raw, y * (stride + 1) + 1, stride);
        Deflater deflater = new Deflater();
        deflater.setInput(raw);
        deflater.finish();
        ByteArrayOutputStream z = new ByteArrayOutputStream();
        byte[] chunk = new byte[65536];
        while (!deflater.finished()) z.write(chunk, 0, deflater.deflate(chunk));
        deflater.end();
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        png.write(new byte[]{(byte) 137, 80, 78, 71, 13, 10, 26, 10});
        byte[] ihdr = new byte[13];
        be32(ihdr, 0, img.width());
        be32(ihdr, 4, img.height());
        ihdr[8] = 8;
        ihdr[9] = 6;
        pngChunk(png, "IHDR", ihdr);
        pngChunk(png, "IDAT", z.toByteArray());
        pngChunk(png, "IEND", new byte[0]);
        Files.write(file, png.toByteArray());
    }

    private static void be32(byte[] out, int at, long v) {
        out[at] = (byte) (v >>> 24);
        out[at + 1] = (byte) (v >>> 16);
        out[at + 2] = (byte) (v >>> 8);
        out[at + 3] = (byte) v;
    }

    private static void pngChunk(ByteArrayOutputStream out, String type, byte[] data) {
        byte[] head = new byte[4];
        be32(head, 0, data.length);
        out.writeBytes(head);
        byte[] body = new byte[4 + data.length];
        System.arraycopy(type.getBytes(java.nio.charset.StandardCharsets.US_ASCII), 0, body, 0, 4);
        System.arraycopy(data, 0, body, 4, data.length);
        out.writeBytes(body);
        CRC32 crc = new CRC32();
        crc.update(body);
        byte[] tail = new byte[4];
        be32(tail, 0, crc.getValue());
        out.writeBytes(tail);
    }

    /** Hands the gesture handler one event; the INPUT_* bits it asks of the host. */
    public int input(Event event) {
        int kind = named(EVENTS, event.type(), "event type");
        int pointer = named(POINTERS, event.pointer() == null ? "mouse" : event.pointer(), "pointer");
        MemorySegment p = live(c("input"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment e = arena.allocate(EVENT);
            e.set(ValueLayout.JAVA_INT, off(EVENT, "size"), (int) EVENT.byteSize());
            e.set(ValueLayout.JAVA_INT, off(EVENT, "kind"), kind);
            e.set(ValueLayout.JAVA_INT, off(EVENT, "pointer_id"), event.pointerId());
            e.set(ValueLayout.JAVA_INT, off(EVENT, "pointer"), pointer);
            e.set(ValueLayout.JAVA_INT, off(EVENT, "button"), event.button());
            e.set(ValueLayout.JAVA_INT, off(EVENT, "shift"), event.shift() ? 1 : 0);
            e.set(ValueLayout.JAVA_FLOAT, off(EVENT, "x"), event.x());
            e.set(ValueLayout.JAVA_FLOAT, off(EVENT, "y"), event.y());
            e.set(ValueLayout.JAVA_FLOAT, off(EVENT, "wheel_y"), event.wheelY());
            e.set(ValueLayout.ADDRESS, off(EVENT, "key"), event.key() == null ? MemorySegment.NULL : arena.allocateFrom(event.key()));
            e.set(ValueLayout.JAVA_INT, off(EVENT, "key_down"), event.keyDown() ? 1 : 0);
            e.set(ValueLayout.JAVA_DOUBLE, off(EVENT, "time_ms"), event.timeMs() == 0 ? System.nanoTime() / 1e6 : event.timeMs());
            int bits = call(() -> (int) lib.input.invoke(p, e));
            if (bits == 0 && !lib.lastErrorText().isEmpty()) throw lib.failure("input");
            // Escape on a window of the view's own ends it as the user closing it does; close() still owes the destroy.
            if ((bits & INPUT_CLOSE) != 0 && own) markClosed();
            return bits;
        }
    }

    public void resize(int w, int h) {
        MemorySegment p = live(c("resize"));
        ok(call(() -> (boolean) lib.resize.invoke(p, w, h)), "resize");
    }

    /** {width, height}: what image() reads, in physical pixels. */
    public int[] size() {
        MemorySegment p = live(c("size"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment ws = arena.allocate(ValueLayout.JAVA_INT), hs = arena.allocate(ValueLayout.JAVA_INT);
            ok(call(() -> (boolean) lib.size.invoke(p, ws, hs)), "size");
            return new int[]{ws.get(ValueLayout.JAVA_INT, 0), hs.get(ValueLayout.JAVA_INT, 0)};
        }
    }

    /**
     * Levels of detail: parts of {@code minTriangles} or more (0: the library's 2,048) get
     * coarser levels, built in the background after each show; a moving frame draws as
     * {@code motion} says -- "detailed" or "smooth" (refines once the camera rests, see
     * {@link #wakeMs()}). {@code motion} null turns levels off.
     */
    public void lod(String motion, int minTriangles) {
        if (motion == null) {
            MemorySegment p = live(c("set_lod"));
            ok(call(() -> (boolean) lib.setLod.invoke(p, MemorySegment.NULL)), "lod");
            return;
        }
        int m = named(LOD_MOTION, motion, "motion");
        if (minTriangles < 0) throw new ViewException("lod: minTriangles is a count of 0 or more, not " + minTriangles);
        MemorySegment p = live(c("set_lod"));
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment lod = arena.allocate(LOD);
            lod.set(ValueLayout.JAVA_INT, off(LOD, "size"), (int) LOD.byteSize());
            lod.set(ValueLayout.JAVA_INT, off(LOD, "min_triangles"), minTriangles);
            lod.set(ValueLayout.JAVA_INT, off(LOD, "motion"), m);
            ok(call(() -> (boolean) lib.setLod.invoke(p, lod)), "lod");
        }
    }

    public void lod(String motion) {
        lod(motion, 0);
    }

    /** Milliseconds until needsDraw turns true by itself; 0 when a draw is owed now, null when none is coming. */
    public Integer wakeMs() {
        MemorySegment p = live(c("wake_ms"));
        int ms = call(() -> (int) lib.wakeMs.invoke(p));
        return ms == -1 ? null : Integer.valueOf(ms);   // UINT32_MAX: none coming
    }

    /** The window closed (its close button, Escape, the end of run): calls now throw "the window is closed". */
    private void markClosed() {
        windowClosed = true;
        synchronized (View.class) {
            OPEN_VIEWS.remove(this);
        }
    }

    /**
     * Removes every item that shows {@code obj} (a Cad.Scene, directly or through one of its
     * nodes) from every live view, before obj's handle is freed: cadaclysm_view.h requires a
     * shown scene to stay open until its item is removed or the view destroyed. Cad.Scene.close()
     * calls it first. A view of this thread whose window the user closed is destroyed instead,
     * which drops all its items. A view made on another thread cannot be called from this one:
     * when one still shows obj, this throws after this thread's views are done, and the caller
     * keeps obj open (it leaks rather than crashes) -- Python's rule.
     */
    static void release(Object obj) {
        List<View> views;
        synchronized (LIVE) {
            views = new ArrayList<>(LIVE.keySet());
        }
        int foreign = 0;
        for (View v : views) {
            if (v.handle.address == 0) continue;
            List<Item> showing = new ArrayList<>();
            for (Item i : new ArrayList<>(v.items.values())) {
                if (i.shown == obj || (i.shown instanceof Cad.Node n && n.scene() == obj)) showing.add(i);
            }
            if (showing.isEmpty()) continue;
            if (v.thread != Thread.currentThread()) {
                foreign++;
            } else if (v.windowClosed) {
                v.close();
            } else {
                for (Item i : showing) i.remove();
            }
        }
        if (foreign > 0) {
            throw new ViewException(foreign + " view(s) made on another thread still show this -- close them from their own "
                    + "thread first; it stays open until then");
        }
    }

    /** Destroy the view and its window. Idempotent. */
    @Override
    public void close() {
        if (handle.address != 0 && Thread.currentThread() != thread) {
            throw new ViewException("close: a view belongs to the thread that made it");
        }
        synchronized (View.class) {
            OPEN_VIEWS.remove(this);
        }
        LIVE.remove(this);
        cleanable.clean();   // destroy first: the library lets go of what it shows, then the items drop it
        for (Item i : items.values()) i.shown = null;
        items.clear();
    }

    /**
     * Handles every open window's events of this thread, draws what is owed, waits at most
     * {@code timeoutMs} (on the first window), and answers how many windows are still open --
     * for a program's own loop. With no window of this thread's own it just waits, so a loop
     * around it does not spin. Every window's state is taken before a refusal is thrown.
     */
    public static int pump(int timeoutMs) {
        timeoutMs = Math.max(0, timeoutMs);   // a negative wait is none, as Python's
        List<View> alive = new ArrayList<>();
        synchronized (View.class) {
            for (View v : OPEN_VIEWS) {
                if (v.handle.address != 0 && !v.windowClosed && v.thread == Thread.currentThread()) alive.add(v);
            }
        }
        if (alive.isEmpty()) {
            sleep(timeoutMs);
        } else {
            int wait = timeoutMs;
            ViewException first = null;
            for (View v : alive) {
                MemorySegment p = MemorySegment.ofAddress(v.handle.address);
                int w = wait;
                int answer = call(() -> (int) v.lib.pump.invoke(p, w));
                wait = 0;
                if (answer == CLOSED) v.markClosed();
                else if (answer != OPEN && first == null) first = v.lib.failure("pump");
            }
            if (first != null) throw first;
        }
        synchronized (View.class) {
            return (int) OPEN_VIEWS.stream().filter(v -> !v.windowClosed).count();
        }
    }

    // ---- the item ---------------------------------------------------------------------

    /** One thing a view shows. It holds the object it shows. */
    public static final class Item {
        private final View view;
        private final int id;
        Object shown;

        Item(View view, int id, Object shown) {
            this.view = view;
            this.id = id;
            this.shown = shown;
        }

        public int id() {
            return id;
        }

        public Object shown() {
            return shown;
        }

        public View view() {
            return view;
        }

        public void remove() {
            MemorySegment p = view.live(c("remove"));
            view.ok(call(() -> (boolean) view.lib.remove.invoke(p, id)), "remove");
            view.items.remove(id);
            Cad.Scene scene = sceneOf(shown);
            if (scene != null) view.handle.scenes.remove(scene.lifetime());
            shown = null;
        }

        /**
         * Poses a shown scene: one world transform per node (sixteen doubles each, column-major,
         * Pose.rawTransform's layout -- every node of the scene, in index order), drawn in place
         * of each node's rest transform. null restores the rest pose.
         */
        public void nodeTransforms(double[][] transforms) {
            if (transforms == null) {
                MemorySegment p = view.live(c("set_node_transforms"));
                view.ok(call(() -> (boolean) view.lib.setNodeTransforms.invoke(p, id, MemorySegment.NULL, 0)), "nodeTransforms");
                return;
            }
            double[] flat = new double[16 * transforms.length];
            for (int k = 0; k < transforms.length; k++) {
                exact(transforms[k], 16, "transform " + k);
                System.arraycopy(transforms[k], 0, flat, 16 * k, 16);
            }
            MemorySegment p = view.live(c("set_node_transforms"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment m = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, flat);
                int n = transforms.length;
                view.ok(call(() -> (boolean) view.lib.setNodeTransforms.invoke(p, id, m, n)), "nodeTransforms");
            }
        }

        /** Recolours the item: {@code "#rgb"}, {@code "#rrggbb"} or a CSS colour name, any case. */
        public void colour(String rgb) {
            if (rgb == null) throw new ViewException("colour: 3 numbers, not none");
            colour(view.lib.colour(rgb));
        }

        public void colour(float[] rgb) {
            if (rgb == null) throw new ViewException("colour: 3 numbers, not none");
            exact(rgb, 3, "colour");
            MemorySegment p = view.live(c("set_colour"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment colour = floats(arena, rgb);
                view.ok(call(() -> (boolean) view.lib.setColour.invoke(p, id, colour)), "colour");
            }
        }

        /** The text item's string replaced, nothing else changed (cadaclysm_view_set_text). */
        public void setText(String text) {
            String replaced = textOf(text);
            MemorySegment p = view.live(c("set_text"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment s = arena.allocateFrom(replaced);
                view.ok(call(() -> (boolean) view.lib.setText.invoke(p, id, s)), "setText");
            }
        }

        /** Sixteen doubles, column-major; null puts it back. */
        public void placement(double[] matrix) {
            exact(matrix, 16, "placement");
            MemorySegment p = view.live(c("set_placement"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment m = matrix == null ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_DOUBLE, matrix);
                view.ok(call(() -> (boolean) view.lib.setPlacement.invoke(p, id, m)), "placement");
            }
        }

        /** {@code faces} (pick numbers) coloured by {@code colours}, one text a face (alpha 1); faces null clears every one. */
        public void faceColours(int[] faces, String[] colours) {
            if (faces == null) {
                faceColours(null, (float[]) null);
                return;
            }
            float[] rgba = new float[4 * (colours == null ? 0 : colours.length)];
            for (int k = 0; colours != null && k < colours.length; k++) {
                float[] c = rgba(view.lib, colours[k]);
                if (c == null) throw new ViewException("faceColours: colour " + k + " is null");
                System.arraycopy(c, 0, rgba, 4 * k, 4);
            }
            faceColours(faces, rgba);
        }

        /** {@code faces} (pick numbers) in {@code rgba} (four floats a face); faces null clears every one. */
        public void faceColours(int[] faces, float[] rgba) {
            if (faces != null && (rgba == null || rgba.length != 4 * faces.length)) {
                throw new ViewException("faceColours: " + 4 * faces.length + " numbers (rgba, 4 a face), not "
                        + (rgba == null ? 0 : rgba.length));
            }
            MemorySegment p = view.live(c("set_face_colours"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment f = faces == null ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_INT, faces);
                MemorySegment col = faces == null ? MemorySegment.NULL : floats(arena, rgba);
                int n = faces == null ? 0 : faces.length;
                view.ok(call(() -> (boolean) view.lib.setFaceColours.invoke(p, id, f, col, n)), "faceColours");
            }
        }

        public void frame() {
            MemorySegment p = view.live(c("frame"));
            view.ok(call(() -> (boolean) view.lib.frame.invoke(p, id)), "frame");
        }

        public void xray(boolean on) {
            MemorySegment p = view.live(c("set_xray"));
            view.ok(call(() -> (boolean) view.lib.setXray.invoke(p, id, on)), "xray");
        }

        public void nodeVisible(int node, boolean on) {
            MemorySegment p = view.live(c("set_node_visible"));
            view.ok(call(() -> (boolean) view.lib.setNodeVisible.invoke(p, id, node, on)), "nodeVisible");
        }

        /** {@link #nodeColour(int, float[])} with the colour as text (alpha 1); null clears. */
        public void nodeColour(int node, String rgba) {
            nodeColour(node, rgba(view.lib, rgba));
        }

        /** Three or four numbers (alpha 1 when three); null clears. */
        public void nodeColour(int node, float[] rgba) {
            float[] four = rgba(rgba, "nodeColour");
            MemorySegment p = view.live(c("set_node_color"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment col = floats(arena, four);
                view.ok(call(() -> (boolean) view.lib.setNodeColor.invoke(p, id, node, col)), "nodeColour");
            }
        }

        /** {@link #nodeHighlight(int, float[])} with the colour as text: alpha 1, the colour itself; null clears. */
        public void nodeHighlight(int node, String rgba) {
            nodeHighlight(node, rgba(view.lib, rgba));
        }

        /** Tint {@code node} toward rgba's colour by its alpha; null clears. */
        public void nodeHighlight(int node, float[] rgba) {
            float[] four = rgba(rgba, "nodeHighlight");
            MemorySegment p = view.live(c("set_node_highlight"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment col = floats(arena, four);
                view.ok(call(() -> (boolean) view.lib.setNodeHighlight.invoke(p, id, node, col)), "nodeHighlight");
            }
        }

        public void frameNode(int node) {
            MemorySegment p = view.live(c("frame_node"));
            view.ok(call(() -> (boolean) view.lib.frameNode.invoke(p, id, node)), "frameNode");
        }
    }

    // ---- show() and view() on the objects ---------------------------------------------

    /** cadaclysm_view.py's _camera: azimuth and elevation as show() takes them. */
    static Camera camera(float[] eye, float[] target, float[] up, boolean ortho, Pick pick, boolean yUp) {
        double[] d = {eye[0] - target[0], eye[1] - target[1], eye[2] - target[2]};
        double[] u = {up[0], up[1], up[2]};
        if (yUp) {
            d = new double[]{d[0], -d[2], d[1]};
            u = new double[]{u[0], -u[2], u[1]};
        }
        double length = Math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        if (length == 0) length = 1;
        for (int i = 0; i < 3; i++) d[i] /= length;
        double azimuth;
        if (Math.hypot(d[0], d[1]) < 1e-4) {
            double sign = d[2] < 0 ? -1 : 1;
            azimuth = Math.toDegrees(Math.atan2(-sign * u[1], -sign * u[0]));
        } else {
            azimuth = Math.toDegrees(Math.atan2(d[1], d[0]));
        }
        double elevation = Math.toDegrees(Math.asin(Math.max(-1, Math.min(1, d[2]))));
        return new Camera(eye, target, up, ortho, azimuth, elevation, pick);
    }

    /**
     * The camera the options ask for, as Python's _aim and _zoom: the top view straight down,
     * any other angle an orbit from the front, then frame(0), then {@code fit} (a node's
     * frameNode), and only then the zoom, since framing resets the distance a zoom sets. The
     * camera calls are not checked, as Python's are; {@code fit}'s own refusals are.
     */
    void aim(ShowOptions o, Runnable fit) {
        double[] base = VIEWS.get(o.view);
        double az = o.azimuth != null ? o.azimuth : base[0];
        double el = o.elevation != null ? o.elevation : base[1];
        MemorySegment p = live(c("standard"));
        call(() -> {
            if (el >= 90 && az == -90) {
                lib.standard.invoke(p, STANDARD.get("top"));
            } else {
                lib.standard.invoke(p, STANDARD.get("front"));
                float dx = (float) (-Math.toRadians(az + 90) / ORBIT_PER_PIXEL);
                float dy = (float) (Math.toRadians(el) / ORBIT_PER_PIXEL);
                if (dx != 0 || dy != 0) lib.orbit.invoke(p, dx, dy);
            }
            lib.frame.invoke(p, 0);
            return null;
        });
        fit.run();
        if (o.zoom != null && o.zoom > 0) {
            float steps = (float) (Math.log(o.zoom) / -Math.log(ZOOM_PER_STEP));
            call(() -> lib.zoom.invoke(p, steps));
        }
    }

    private static Cad.Scene sceneOf(Object obj) {
        return obj instanceof Cad.Scene scene ? scene : obj instanceof Cad.Node node ? node.scene() : null;
    }

    /** The scene's file name (a node is titled by its scene, as Python's present is); "Solid" for a solid. */
    static String titleOf(Object obj) {
        Cad.Scene scene = sceneOf(obj);
        return scene != null ? Path.of(scene.path()).getFileName().toString() : "Solid";
    }

    /**
     * obj.show() ({@code orbit} false) and obj.view() (true): a fresh view; on a window library
     * it runs until the window is closed, on the terminal show() prints a still.
     */
    static Camera present(Object obj, ShowOptions o, boolean orbit) {
        return present(obj, o, orbit, null);
    }

    /** {@code transforms}, for a scene: one posed world transform per node (Pose.show), set on its item before drawing. */
    static Camera present(Object obj, ShowOptions o, boolean orbit, double[][] transforms) {
        String kind = transforms != null ? "Pose" : obj instanceof Cad.Scene ? "Scene" : obj instanceof Cad.Node ? "Node" : "Solid";
        if (o.tolerance != null && !kind.equals("Solid")) {
            throw new ViewException(kind + "." + (orbit ? "view" : "show") + " takes no tolerance: a document is drawn at the "
                    + "tolerance it was read with");
        }
        if (!VIEWS.containsKey(o.view)) throw new ViewException("view \"" + o.view + "\": one of " + new java.util.TreeSet<>(VIEWS.keySet()));
        Cad.Scene scene = sceneOf(obj);
        String up = (o.up != null ? o.up : scene != null ? scene.defaultUp() : "z").toLowerCase();
        if (!up.equals("y") && !up.equals("z")) throw new ViewException("up \"" + o.up + "\": 'y' or 'z'");
        if (o.width < 0 || o.height < 0) {
            throw new ViewException("width=" + o.width + ", height=" + o.height + ": a size is pixels, 0 or more (0 = the library decides)");
        }
        Library library = current();
        Options vo = new Options().title(o.title != null ? o.title : titleOf(obj)).width(o.width).height(o.height).up(up);
        // What the program printed goes out before the library writes a still (or a window's
        // messages) to the same output, as Python's present flushes.
        System.out.flush();
        System.err.flush();
        try (View v = new View(vo)) {
            double tolerance = o.tolerance != null ? o.tolerance : 0.05;
            Item item = o.rgbText != null ? v.show(obj, o.rgbText, tolerance) : v.show(obj, o.rgb, tolerance);
            if (transforms != null) item.nodeTransforms(transforms);
            v.layer("edges", o.edges);
            v.aim(o, obj instanceof Cad.Node node ? () -> item.frameNode(node.index()) : () -> { });
            if (!orbit && !"wgpu".equals(library.kind())) {
                v.draw();
                return null;
            }
            Camera camera = v.run();
            return orbit ? camera : null;
        }
    }
}
