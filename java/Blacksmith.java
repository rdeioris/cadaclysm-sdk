// The cadaclysm_blacksmith C ABI, as Java objects: this file is the whole kernel binding.
//
//     try (Blacksmith.Profile hole = Blacksmith.Profile.circle(4);
//          Blacksmith.Profile outline = Blacksmith.Profile.rect(80, 40).withHole(hole);
//          Blacksmith.Solid plate = Blacksmith.Workplane.xy().extrude(outline, 6).solid();
//          Blacksmith.Solid pin = Blacksmith.Workplane.fromSolid(plate)
//                  .faces(Blacksmith.Selector.max(Blacksmith.Axis.Z)).onFace()   // Python's .workplane()
//                  .cylinder(5, 10).solid();                                     // seated over the hole
//          Blacksmith.Solid part = plate.join(pin)) {
//         List<Blacksmith.Edge> corners = part.edges().stream()
//                 .filter(e -> e.isLine() && Math.abs(e.direction()[2]) > 0.99)
//                 .filter(e -> Arrays.stream(e.faces()).allMatch(f -> part.faceKind(f).equals("plane")))
//                 .toList();
//         try (Blacksmith.Solid rounded = part.fillet(corners, 1.0)) {
//             rounded.step("plate.stp");
//             Blacksmith.Mesh mesh = rounded.mesh(0.05);
//         }
//     }
//
// Through the Foreign Function and Memory API, declared by hand from the published header
// `include/cadaclysm_blacksmith.h`, on the object model of `cadaclysm_blacksmith.py` -- the
// same names (camelCase here), the same arguments and defaults (Java overloads standing in
// for Python's keyword arguments), the same C calls, member for member. No JNI, no generated
// bindings, no third-party interop library. It shares `Cad.java`'s loader: point
// `CADACLYSM_LIBRARY` at the directory holding both libraries (or
// `CADACLYSM_BLACKSMITH_LIBRARY` at this one, as Python's kernel module reads it) if they
// are not where the loader looks by default.
//
// ## Every array borrows from its solid
//
// `Solid.mesh` and `Solid.edgePolylines` hand back read-only `FloatBuffer`/`IntBuffer`
// *views* over the library's own cache rather than copies, as the reader's `Cad.Mesh` does.
// Two things invalidate a view: closing the solid, which frees the handle; and meshing the
// same solid again (through `mesh`, `edgePolylines` or `boundsAt`) at a *different*
// tolerance, which replaces the cache the earlier views point into -- and going back to the
// first tolerance does not bring the old memory back. Python reads freed memory in either
// case; here the view remembers which filling of the cache it was cut from and throws
// `IllegalStateException` instead. Call `copy()` on any view that must outlive either.
// Strings are copied on the way out and are always safe.
//
// ## The chain mirrors the Rust `Workplane`
//
// A build call (`cuboid`, `cylinder`, `extrude`, `extrudeTapered`, `revolve`, `sweep`,
// `loft`) makes a fresh `Solid`; combining two solids is explicit -- build the pin as its own
// solid, then `plate.join(pin)`. Every step throws `BuildException` at once with the
// library's own text, rather than latching the first error until some final call.
//
// `join`/`cut`/`common` default their `tolerance` to `0.05`, not the tighter `1e-6`
// `fillet`, `chamfer` and `shell` use, for cost: a boolean meshes both solids at its
// tolerance, and a curved solid at `1e-6` is hundreds of thousands of triangles. `0.05` is
// what the crate's own boolean tests run at; a tighter one is as correct, only slower.
//
// ## Ownership
//
// `Profile`, `Path`, `SweepPath` and `Solid` own a C handle: close them (a
// try-with-resources), or let the `Cleaner` free them when the garbage collector finds them
// unreachable, as Python's `__del__` does. `Workplane`, `Selector`, `Slant`, `Edge` and
// `Axis` are plain values. `close()` is idempotent; a call on a closed object throws
// `IllegalStateException`. The progress callbacks Python's `join`/`cut`/`common`/
// `split_sheet`/`fillet`/`shell` accept are not offered: an upcall stub over the C callback
// is out of this binding's scope, and every call runs silent.
//
// FFM is final since JDK 22 (JEP 454), which is what this file is written against: it needs
// JDK 22 or later. Run with --enable-native-access=ALL-UNNAMED to silence the
// restricted-method warning.
import java.io.IOException;
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SegmentAllocator;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.lang.ref.Cleaner;
import java.lang.ref.Reference;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.List;
import java.util.Map;

/**
 * The kernel's module-level entry points -- the library's version and licensing, the default
 * schema, and writing several solids as one STEP file -- plus the nested types they build:
 * {@link Profile}, {@link Path}, {@link SweepPath}, {@link Solid}, {@link Workplane},
 * {@link Selector}, {@link Edge}, {@link Slant}, {@link Axis}.
 *
 * <p>See the file header for the whole story: what borrows from a solid, what the chain
 * does, and who owns which handle. {@code java.nio.file.Path} is spelled out in full inside
 * this class because the nested {@link Path} (the outline builder, named as Python names it)
 * shadows it.
 */
public final class Blacksmith {

    private Blacksmith() {
    }

    /** {@code CADACLYSM_BLACKSMITH_NONE}: what a lookup that found nothing returns. */
    static final int NONE = 0xFFFFFFFF;

    private static final Map<String, Integer> UNITS = Map.of("m", 0, "mm", 1, "in", 2);

    // ---- the structs the ABI returns by value ----------------------------------------
    //
    // These three are transcribed from `cadaclysm_blacksmith.h` by hand, in the header's
    // field order, and nothing pins them against it: `tests/bindings.rs` pins the reader's
    // structs in `Cad.java` only. A field left out or reordered still compiles and reads
    // every later field from the wrong offset, so a change to the header's structs must be
    // brought here by hand. `structLayout` refuses a misaligned field outright, which is
    // why the two `paddingLayout(4)`s in EDGE are there: a 4-byte count before an 8-byte
    // pointer needs the gap the C compiler leaves.

    /** {@code CadaclysmBlacksmithMesh}: a solid's triangles, borrowed from it. */
    private static final MemoryLayout MESH = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.ADDRESS.withName("normals"),
            ValueLayout.ADDRESS.withName("indices"),
            ValueLayout.JAVA_INT.withName("vertex_count"),
            ValueLayout.JAVA_INT.withName("index_count"));

    /** {@code CadaclysmBlacksmithPolylines}: polyline {@code i} is {@code points[offsets[i]
     *  .. offsets[i + 1]]}, three floats a point; {@code offsets} has {@code polyline_count
     *  + 1} entries. */
    private static final MemoryLayout POLYLINES = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("points"),
            ValueLayout.ADDRESS.withName("offsets"),
            ValueLayout.JAVA_INT.withName("point_count"),
            ValueLayout.JAVA_INT.withName("polyline_count"));

    /** {@code CadaclysmBlacksmithEdge}: one edge, borrowed from its solid. */
    private static final MemoryLayout EDGE = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("kind"),
            ValueLayout.ADDRESS.withName("faces"),
            ValueLayout.JAVA_INT.withName("face_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("segments"),
            ValueLayout.JAVA_INT.withName("segment_count"),
            MemoryLayout.paddingLayout(4));

    /** A named field's byte offset in one of the struct layouts above. */
    private static long offset(MemoryLayout struct, String field) {
        return struct.byteOffset(MemoryLayout.PathElement.groupElement(field));
    }

    // ---- loading the library, and every entry point ----------------------------------
    //
    // The same 70 Python's `cadaclysm_blacksmith.py` declares, no more and no less;
    // `tests/bindings.rs` compares the two sets by name (every quoted
    // cadaclysm_blacksmith_ string in this file) and holds Java to Python's.

    private static final MethodHandle LAST_ERROR, LICENSE_SET, LICENSE_INFO, LICENSE_NOTICE_COUNT,
            BUILD_DATE, VERSION, SOLID_FREE, PROFILE_FREE, PROFILE_RECT, PROFILE_CIRCLE,
            PROFILE_SLOT, PROFILE_POLYGON, PROFILE_WITH_HOLE, TRANSLATE_PROFILE, PATH_BEGIN,
            PATH_LINE_TO, PATH_ARC_TO, PATH_BEZIER_TO, PATH_NURBS_TO, PATH_END, PATH_END_OPEN,
            PATH_FREE, CUBOID, CYLINDER, CONE, SPHERE, TORUS, WEDGE, EXTRUDE, EXTRUDE_OPEN,
            EXTRUDE_TAPERED, EXTRUDE_OPEN_TAPERED, EXTRUDE_BETWEEN, EXTRUDE_OPEN_BETWEEN,
            SLANT_OF_PLANE, LOFT, LOFT_OPEN, REVOLVE, REVOLVE_OPEN, SWEEP_PATH_BEGIN,
            SWEEP_PATH_LINE_TO, SWEEP_PATH_ARC, SWEEP_PATH_FREE, SWEEP, SWEEP_OPEN, EXTRUDE_FACES,
            PLACE, TRANSLATE, ROTATE, MIRROR, JOIN, CUT, COMMON, SPLIT_SHEET, FILLET, CHAMFER,
            SHELL, FACE_COUNT, SELECT_FACE, FACE_FRAME, FACE_KIND, EDGE_COUNT, EDGE_AT, MESH_AT,
            EDGE_POLYLINES, BOUNDS, LEAKED_EDGES, UNPAIRED_EDGES, STEP, STRING_FREE;

    static {
        SymbolLookup lib = Cad.Loader.resolve(Cad.Loader.BLACKSMITH_LIBRARY);
        Linker linker = Linker.nativeLinker();
        ValueLayout.OfInt I = ValueLayout.JAVA_INT;
        ValueLayout.OfLong L = ValueLayout.JAVA_LONG;
        ValueLayout.OfDouble D = ValueLayout.JAVA_DOUBLE;
        ValueLayout.OfBoolean B = ValueLayout.JAVA_BOOLEAN;
        var A = ValueLayout.ADDRESS;

        LAST_ERROR = bind(linker, lib, "cadaclysm_blacksmith_last_error", FunctionDescriptor.of(A));
        LICENSE_SET = bind(linker, lib, "cadaclysm_blacksmith_license_set", FunctionDescriptor.of(B, A));
        LICENSE_INFO = bind(linker, lib, "cadaclysm_blacksmith_license_info", FunctionDescriptor.of(A));
        LICENSE_NOTICE_COUNT = bind(linker, lib, "cadaclysm_blacksmith_license_notice_count", FunctionDescriptor.of(L));
        BUILD_DATE = bind(linker, lib, "cadaclysm_blacksmith_build_date", FunctionDescriptor.of(A));
        VERSION = bind(linker, lib, "cadaclysm_blacksmith_version", FunctionDescriptor.of(A));
        SOLID_FREE = bind(linker, lib, "cadaclysm_blacksmith_solid_free", FunctionDescriptor.ofVoid(A));
        PROFILE_FREE = bind(linker, lib, "cadaclysm_blacksmith_profile_free", FunctionDescriptor.ofVoid(A));
        PROFILE_RECT = bind(linker, lib, "cadaclysm_blacksmith_profile_rect", FunctionDescriptor.of(A, D, D));
        PROFILE_CIRCLE = bind(linker, lib, "cadaclysm_blacksmith_profile_circle", FunctionDescriptor.of(A, D));
        PROFILE_SLOT = bind(linker, lib, "cadaclysm_blacksmith_profile_slot", FunctionDescriptor.of(A, D, D, D, D));
        PROFILE_POLYGON = bind(linker, lib, "cadaclysm_blacksmith_profile_polygon", FunctionDescriptor.of(A, A, L));
        PROFILE_WITH_HOLE = bind(linker, lib, "cadaclysm_blacksmith_profile_with_hole", FunctionDescriptor.of(A, A, A));
        TRANSLATE_PROFILE = bind(linker, lib, "cadaclysm_blacksmith_translate_profile", FunctionDescriptor.of(A, A, D, D));
        PATH_BEGIN = bind(linker, lib, "cadaclysm_blacksmith_path_begin", FunctionDescriptor.of(A, D, D));
        PATH_LINE_TO = bind(linker, lib, "cadaclysm_blacksmith_path_line_to", FunctionDescriptor.of(B, A, D, D));
        PATH_ARC_TO = bind(linker, lib, "cadaclysm_blacksmith_path_arc_to", FunctionDescriptor.of(B, A, D, D, D, D, B));
        PATH_BEZIER_TO = bind(linker, lib, "cadaclysm_blacksmith_path_bezier_to", FunctionDescriptor.of(B, A, D, D, D, D, D, D));
        PATH_NURBS_TO = bind(linker, lib, "cadaclysm_blacksmith_path_nurbs_to", FunctionDescriptor.of(B, A, A, L, A, A, L, I));
        PATH_END = bind(linker, lib, "cadaclysm_blacksmith_path_end", FunctionDescriptor.of(A, A));
        PATH_END_OPEN = bind(linker, lib, "cadaclysm_blacksmith_path_end_open", FunctionDescriptor.of(A, A));
        PATH_FREE = bind(linker, lib, "cadaclysm_blacksmith_path_free", FunctionDescriptor.ofVoid(A));
        CUBOID = bind(linker, lib, "cadaclysm_blacksmith_cuboid", FunctionDescriptor.of(A, D, D, D));
        CYLINDER = bind(linker, lib, "cadaclysm_blacksmith_cylinder", FunctionDescriptor.of(A, D, D));
        CONE = bind(linker, lib, "cadaclysm_blacksmith_cone", FunctionDescriptor.of(A, D, D));
        SPHERE = bind(linker, lib, "cadaclysm_blacksmith_sphere", FunctionDescriptor.of(A, D));
        TORUS = bind(linker, lib, "cadaclysm_blacksmith_torus", FunctionDescriptor.of(A, D, D));
        WEDGE = bind(linker, lib, "cadaclysm_blacksmith_wedge", FunctionDescriptor.of(A, D, D, D, D));
        EXTRUDE = bind(linker, lib, "cadaclysm_blacksmith_extrude", FunctionDescriptor.of(A, A, A, D));
        EXTRUDE_OPEN = bind(linker, lib, "cadaclysm_blacksmith_extrude_open", FunctionDescriptor.of(A, A, A, D));
        EXTRUDE_TAPERED = bind(linker, lib, "cadaclysm_blacksmith_extrude_tapered", FunctionDescriptor.of(A, A, A, D, D));
        EXTRUDE_OPEN_TAPERED = bind(linker, lib, "cadaclysm_blacksmith_extrude_open_tapered", FunctionDescriptor.of(A, A, A, D, D));
        EXTRUDE_BETWEEN = bind(linker, lib, "cadaclysm_blacksmith_extrude_between", FunctionDescriptor.of(A, A, A, A, A));
        EXTRUDE_OPEN_BETWEEN = bind(linker, lib, "cadaclysm_blacksmith_extrude_open_between", FunctionDescriptor.of(A, A, A, A, A));
        SLANT_OF_PLANE = bind(linker, lib, "cadaclysm_blacksmith_slant_of_plane", FunctionDescriptor.of(B, A, A, A, A));
        LOFT = bind(linker, lib, "cadaclysm_blacksmith_loft", FunctionDescriptor.of(A, A, A, A, A));
        LOFT_OPEN = bind(linker, lib, "cadaclysm_blacksmith_loft_open", FunctionDescriptor.of(A, A, A, A, A));
        REVOLVE = bind(linker, lib, "cadaclysm_blacksmith_revolve", FunctionDescriptor.of(A, A, A, D));
        REVOLVE_OPEN = bind(linker, lib, "cadaclysm_blacksmith_revolve_open", FunctionDescriptor.of(A, A, A, D));
        SWEEP_PATH_BEGIN = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_begin", FunctionDescriptor.of(A, D, D, D));
        SWEEP_PATH_LINE_TO = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_line_to", FunctionDescriptor.of(B, A, D, D, D));
        SWEEP_PATH_ARC = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_arc", FunctionDescriptor.of(B, A, D, D, D, D, D, D, D));
        SWEEP_PATH_FREE = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_free", FunctionDescriptor.ofVoid(A));
        SWEEP = bind(linker, lib, "cadaclysm_blacksmith_sweep", FunctionDescriptor.of(A, A, A, A));
        SWEEP_OPEN = bind(linker, lib, "cadaclysm_blacksmith_sweep_open", FunctionDescriptor.of(A, A, A, A));
        EXTRUDE_FACES = bind(linker, lib, "cadaclysm_blacksmith_extrude_faces", FunctionDescriptor.of(A, A, D));
        PLACE = bind(linker, lib, "cadaclysm_blacksmith_place", FunctionDescriptor.of(A, A, A));
        TRANSLATE = bind(linker, lib, "cadaclysm_blacksmith_translate", FunctionDescriptor.of(A, A, D, D, D));
        ROTATE = bind(linker, lib, "cadaclysm_blacksmith_rotate", FunctionDescriptor.of(A, A, A, D));
        MIRROR = bind(linker, lib, "cadaclysm_blacksmith_mirror", FunctionDescriptor.of(A, A, A));
        JOIN = bind(linker, lib, "cadaclysm_blacksmith_join", FunctionDescriptor.of(A, A, A, D, A, A));
        CUT = bind(linker, lib, "cadaclysm_blacksmith_cut", FunctionDescriptor.of(A, A, A, D, A, A));
        COMMON = bind(linker, lib, "cadaclysm_blacksmith_common", FunctionDescriptor.of(A, A, A, D, A, A));
        SPLIT_SHEET = bind(linker, lib, "cadaclysm_blacksmith_split_sheet", FunctionDescriptor.of(A, A, A, D, A, A));
        FILLET = bind(linker, lib, "cadaclysm_blacksmith_fillet", FunctionDescriptor.of(A, A, A, L, D, D, A, A));
        CHAMFER = bind(linker, lib, "cadaclysm_blacksmith_chamfer", FunctionDescriptor.of(A, A, A, L, D, D));
        SHELL = bind(linker, lib, "cadaclysm_blacksmith_shell", FunctionDescriptor.of(A, A, D, A, L, D, A, A));
        FACE_COUNT = bind(linker, lib, "cadaclysm_blacksmith_face_count", FunctionDescriptor.of(I, A));
        SELECT_FACE = bind(linker, lib, "cadaclysm_blacksmith_select_face", FunctionDescriptor.of(I, A, I, A, I));
        FACE_FRAME = bind(linker, lib, "cadaclysm_blacksmith_face_frame", FunctionDescriptor.of(B, A, I, A));
        FACE_KIND = bind(linker, lib, "cadaclysm_blacksmith_face_kind", FunctionDescriptor.of(A, A, I));
        EDGE_COUNT = bind(linker, lib, "cadaclysm_blacksmith_edge_count", FunctionDescriptor.of(I, A));
        EDGE_AT = bind(linker, lib, "cadaclysm_blacksmith_edge", FunctionDescriptor.of(B, A, I, A));
        MESH_AT = bind(linker, lib, "cadaclysm_blacksmith_mesh", FunctionDescriptor.of(MESH, A, D));
        EDGE_POLYLINES = bind(linker, lib, "cadaclysm_blacksmith_edge_polylines", FunctionDescriptor.of(POLYLINES, A, D));
        BOUNDS = bind(linker, lib, "cadaclysm_blacksmith_bounds", FunctionDescriptor.of(B, A, D, A, A));
        LEAKED_EDGES = bind(linker, lib, "cadaclysm_blacksmith_leaked_edges", FunctionDescriptor.of(I, A, D));
        UNPAIRED_EDGES = bind(linker, lib, "cadaclysm_blacksmith_unpaired_edges", FunctionDescriptor.of(I, A, D));
        STEP = bind(linker, lib, "cadaclysm_blacksmith_step", FunctionDescriptor.of(A, A, L, A, I));
        STRING_FREE = bind(linker, lib, "cadaclysm_blacksmith_string_free", FunctionDescriptor.ofVoid(A));
    }

    @SuppressWarnings("restricted") // downcallHandle: every entry point here is the published ABI.
    private static MethodHandle bind(Linker linker, SymbolLookup lib, String name, FunctionDescriptor fd) {
        return linker.downcallHandle(
                lib.find(name).orElseThrow(() -> new UnsatisfiedLinkError(name)), fd);
    }

    // ---- small native-call helpers -------------------------------------------------------

    /** One downcall, written as a lambda around {@code invokeExact} so the {@code Throwable}
     *  it declares is handled in one place ({@link #call}). */
    @FunctionalInterface
    private interface Native<T> {
        T call() throws Throwable;
    }

    /** Runs a downcall. A {@code Throwable} out of {@code invokeExact} is a linkage mistake
     *  in this file, not a library failure, so it comes out as a {@code RuntimeException};
     *  an unchecked exception thrown by our own code inside the lambda (a {@link
     *  BuildException} from a nested check) passes through untouched. */
    private static <T> T call(Native<T> body) {
        try {
            return body.call();
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** Keeps {@code owners} reachable until here: a handle read off an owner before a
     *  downcall says nothing to the collector about the owner itself, and a temporary
     *  (`Profile.rect(80, 40).withHole(Profile.circle(4))`) whose last use was that read
     *  could otherwise be found unreachable, and its handle freed by the {@link Cleaner},
     *  while the library is still working on it. */
    private static void keep(Object... owners) {
        for (Object owner : owners) Reference.reachabilityFence(owner);
    }

    /** A C string at an address the library owns; null becomes "", matching Python's `_text`. */
    @SuppressWarnings("restricted") // reinterpret: the library terminates every string it hands back.
    private static String string(MemorySegment address) {
        if (address.address() == 0) return "";
        return address.reinterpret(Long.MAX_VALUE).getString(0);
    }

    /** The library's own reason for the last failure, or "" if it left none. */
    private static String lastError() {
        return string(call(() -> (MemorySegment) LAST_ERROR.invokeExact()));
    }

    /** The library's own reason, or {@code what} if it left none. */
    private static BuildException failure(String what) {
        String reason = lastError();
        return new BuildException(reason.isEmpty() ? what : reason);
    }

    private static MemorySegment checked(MemorySegment handle, String what) {
        if (handle.address() == 0) throw failure(what);
        return handle;
    }

    private static double[] doubles(double[] values, int count, String what) {
        int got = values == null ? 0 : values.length;
        if (values == null || got != count) {
            throw new BuildException(what + ": expected " + count + " numbers, got " + got);
        }
        return values;
    }

    /** Twelve numbers: origin, x, y, z. */
    private static double[] frame(double[] frame) {
        return doubles(frame, 12, "frame");
    }

    /** Six numbers: a point and a direction. */
    private static double[] axisOf(double[] axis) {
        return doubles(axis, 6, "axis");
    }

    private static double[] point2(double[] p, String what) {
        return doubles(p, 2, what);
    }

    private static double[] point3(double[] p, String what) {
        return doubles(p, 3, what);
    }

    /** {@code points} flattened to x, y pairs. */
    private static double[] flatten2(double[][] points, String what) {
        double[] flat = new double[points.length * 2];
        for (int i = 0; i < points.length; i++) {
            double[] p = point2(points[i], what);
            flat[2 * i] = p[0];
            flat[2 * i + 1] = p[1];
        }
        return flat;
    }

    /** Face and edge indices are {@code int} on this surface, as Python's are, and the C
     *  ABI's {@code uint32_t} at the boundary; a negative one is refused rather than wrapped. */
    static int index(int index) {
        if (index < 0) throw new BuildException("index " + index + " is negative");
        return index;
    }

    private static int[] indices(int[] list) {
        int[] out = list.clone();
        for (int i : out) index(i);
        return out;
    }

    @SuppressWarnings("restricted")
    private static FloatBuffer floatView(long address, long count) {
        if (address == 0 || count == 0) return FloatBuffer.allocate(0).asReadOnlyBuffer();
        return MemorySegment.ofAddress(address).reinterpret(count * Float.BYTES)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asFloatBuffer().asReadOnlyBuffer();
    }

    @SuppressWarnings("restricted")
    private static IntBuffer intView(long address, long count) {
        if (address == 0 || count == 0) return IntBuffer.allocate(0).asReadOnlyBuffer();
        return MemorySegment.ofAddress(address).reinterpret(count * Integer.BYTES)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asIntBuffer().asReadOnlyBuffer();
    }

    private static float[] toArray(FloatBuffer view) {
        float[] out = new float[view.remaining()];
        view.duplicate().get(out);
        return out;
    }

    private static int[] toArray(IntBuffer view) {
        int[] out = new int[view.remaining()];
        view.duplicate().get(out);
        return out;
    }

    // ---- owning a C handle ----------------------------------------------------------------

    private static final Cleaner CLEANER = Cleaner.create();

    /**
     * One C handle and the entry point that frees it. This is what the {@link Cleaner} runs
     * when the owner is collected, so it must not reference the owner: it holds the address
     * as a bare {@code long} and nothing else. Freeing once is guaranteed twice over -- the
     * cleaner runs an action at most once, and the address is zeroed before the free -- so
     * {@code close()} on an owner, then the cleaner finding it, frees nothing twice.
     */
    private static final class Handle implements Runnable {
        private final MethodHandle free;
        /** What a call on the freed handle says -- Python's own text for it. */
        private final String closedMessage;
        private long address;

        Handle(MethodHandle free, String closedMessage, MemorySegment raw) {
            this.free = free;
            this.closedMessage = closedMessage;
            this.address = raw.address();
        }

        /** The handle for a call, refusing a freed one so a use-after-close throws at the
         *  call site instead of passing a dangling pointer into the library. */
        MemorySegment live() {
            if (address == 0) throw new IllegalStateException(closedMessage);
            return MemorySegment.ofAddress(address);
        }

        boolean closed() {
            return address == 0;
        }

        /** Give the handle up to a call that consumes it: the library owns it from here, so
         *  nothing frees it on this side, whether or not that call succeeds. */
        MemorySegment consume() {
            MemorySegment h = live();
            address = 0;
            return h;
        }

        @Override
        public void run() {
            long a = address;
            address = 0;
            if (a == 0) return;
            MemorySegment h = MemorySegment.ofAddress(a);
            call(() -> {
                free.invokeExact(h);
                return null;
            });
        }
    }

    // ---- BuildException -------------------------------------------------------------------

    /** What the library refused, in its own words ({@code cadaclysm_blacksmith_last_error}). */
    public static final class BuildException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public BuildException(String message) {
            super(message);
        }
    }

    // ---- the module-level entry points ---------------------------------------------------

    /** The version of the library actually loaded, which is the one worth reporting. */
    public static String version() {
        return string(call(() -> (MemorySegment) VERSION.invokeExact()));
    }

    /** When the loaded library was built, {@code YYYY-MM-DD}. */
    public static String buildDate() {
        return string(call(() -> (MemorySegment) BUILD_DATE.invokeExact()));
    }

    /**
     * Load a license: the certificate text, or the path of a file holding it (see {@link
     * Cad#license}). Throws with the library's reason when the text does not verify; the
     * previous license, if any, stays in use.
     */
    public static void license(String textOrPath) {
        boolean ok;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment text = arena.allocateFrom(textOrPath);
            ok = call(() -> (boolean) LICENSE_SET.invokeExact(text));
        }
        if (!ok) throw failure("license refused");
    }

    /**
     * One line about the license the library is running under. Never null: the license
     * line, or, without one, {@code "unlicensed"} ({@code "unlicensed -- <reason>"} when a
     * license was found but did not verify).
     */
    public static String licenseInfo() {
        String info = string(call(() -> (MemorySegment) LICENSE_INFO.invokeExact()));
        return info.isEmpty() ? "unlicensed" : info;
    }

    /** How many unlicensed notices this library has printed to stderr in this process. */
    public static long licenseNoticeCount() {
        return call(() -> (long) LICENSE_NOTICE_COUNT.invokeExact());
    }

    /**
     * {@code schemas/ap203.exp}: {@code CADACLYSM_SCHEMAS/ap203.exp} if set, else the
     * repository's, found by walking up from this class's own code the way the loader finds
     * the library.
     */
    public static String defaultSchema() {
        List<java.nio.file.Path> candidates = new ArrayList<>();
        String env = System.getenv("CADACLYSM_SCHEMAS");
        if (env != null && !env.isEmpty()) candidates.add(java.nio.file.Path.of(env, "ap203.exp"));
        // Python takes the repository root as a fixed number of parents above its own file;
        // this class sits under a classes/ directory or a jar of varying depth, so every
        // ancestor is tried -- the SDK layout and this repository's both keep `schemas/` at
        // the top.
        for (java.nio.file.Path at = Cad.Loader.codeLocation(); at != null; at = at.getParent()) {
            candidates.add(at.resolve("schemas").resolve("ap203.exp"));
        }
        for (java.nio.file.Path candidate : candidates) {
            if (Files.isRegularFile(candidate)) return candidate.toString();
        }
        throw new BuildException("ap203.exp not found; pass schema (a path or the schema's text)");
    }

    /** {@link #writeStepText(Collection, String, String)} with the default schema, in millimetres. */
    public static String writeStepText(Collection<Solid> solids) {
        return writeStepText(solids, null, "mm");
    }

    /**
     * Several solids as one AP203 part file's text, each its own body.
     *
     * @param schema null for the default lookup, the path of an {@code .exp}, or the
     *               schema's own text
     * @param unit   what the solids' lengths are: {@code "m"}, {@code "mm"} or {@code "in"}
     */
    public static String writeStepText(Collection<Solid> solids, String schema, String unit) {
        Integer unitCode = UNITS.get(unit);
        if (unitCode == null) {
            throw new BuildException("unit must be one of " + String.join(", ", UNITS.keySet().stream().sorted().toList()));
        }
        Solid[] all = solids.toArray(new Solid[0]);
        MemorySegment raw;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
            for (int i = 0; i < all.length; i++) {
                handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
            }
            MemorySegment schemaText = arena.allocateFrom(schemaText(schema));
            long count = all.length;
            int code = unitCode;
            raw = call(() -> (MemorySegment) STEP.invokeExact(handles, count, schemaText, code));
        } finally {
            keep((Object[]) all);
        }
        if (raw.address() == 0) throw failure("step");
        try {
            return string(raw);
        } finally {
            call(() -> {
                STRING_FREE.invokeExact(raw);
                return null;
            });
        }
    }

    /** {@link #writeStep(String, Collection, String, String)} with the default schema, in millimetres. */
    public static void writeStep(String path, Collection<Solid> solids) {
        writeStep(path, solids, null, "mm");
    }

    /** Several solids as one AP203 file, each its own body. */
    public static void writeStep(String path, Collection<Solid> solids, String schema, String unit) {
        writeText(path, writeStepText(solids, schema, unit));
    }

    private static void writeText(String path, String text) {
        try {
            Files.writeString(java.nio.file.Path.of(path), text, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new BuildException(path + ": " + e.getMessage());
        }
    }

    /** {@code schema} is null (the default lookup), a path, or the schema's text. */
    private static String schemaText(String schema) {
        if (schema == null) schema = defaultSchema();
        if (schema.indexOf('\n') < 0) {
            java.nio.file.Path at = java.nio.file.Path.of(schema);
            if (Files.isRegularFile(at)) {
                try {
                    return Files.readString(at, StandardCharsets.UTF_8);
                } catch (IOException e) {
                    throw new BuildException(schema + ": " + e.getMessage());
                }
            }
        }
        return schema;
    }

    // ---- profiles -------------------------------------------------------------------------

    /**
     * A closed outline with holes, in its own x/y. Immutable; every method returns a new
     * one. Owns a handle: close it once done, or the cleaner will.
     */
    public static final class Profile implements AutoCloseable {
        private final Handle handle;
        private final Cleaner.Cleanable cleanable;

        private Profile(MemorySegment raw) {
            handle = new Handle(PROFILE_FREE, "profile: closed", checked(raw, "profile"));
            cleanable = CLEANER.register(this, handle);
        }

        MemorySegment handle() {
            return handle.live();
        }

        public boolean closed() {
            return handle.closed();
        }

        /** Give the profile back. Idempotent. */
        @Override
        public void close() {
            cleanable.clean();
        }

        /** A rectangle {@code w} by {@code h} centred on the origin. */
        public static Profile rect(double w, double h) {
            return new Profile(call(() -> (MemorySegment) PROFILE_RECT.invokeExact(w, h)));
        }

        /** A circle of radius {@code r} about the origin: two semicircular arcs. */
        public static Profile circle(double r) {
            return new Profile(call(() -> (MemorySegment) PROFILE_CIRCLE.invokeExact(r)));
        }

        /** A stadium: a {@code length}-long slot of end radius {@code r}, centred at {@code
         *  centre} (two numbers), running along x. */
        public static Profile slot(double[] centre, double length, double r) {
            double[] c = point2(centre, "centre");
            return new Profile(call(() -> (MemorySegment) PROFILE_SLOT.invokeExact(c[0], c[1], length, r)));
        }

        /** A closed polygon through {@code points} (two numbers each), in order; the closing
         *  side is implied. */
        public static Profile polygon(double[][] points) {
            double[] flat = flatten2(points, "point");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment xy = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, flat);
                long n = flat.length / 2;
                return new Profile(call(() -> (MemorySegment) PROFILE_POLYGON.invokeExact(xy, n)));
            }
        }

        /** Start drawing an outline at {@code start} (two numbers), a segment at a time: the
         *  {@link Path} builder. */
        public static Path path(double[] start) {
            return new Path(start);
        }

        /** This outline with {@code hole} cut from it, as a new profile; both inputs are
         *  untouched. */
        public Profile withHole(Profile hole) {
            try {
                MemorySegment outer = handle();
                MemorySegment inner = hole.handle();
                return new Profile(call(() -> (MemorySegment) PROFILE_WITH_HOLE.invokeExact(outer, inner)));
            } finally {
                keep(this, hole);
            }
        }

        /** This outline shifted by ({@code dx}, {@code dy}) in its own plane. */
        public Profile translate(double dx, double dy) {
            try {
                MemorySegment h = handle();
                return new Profile(call(() -> (MemorySegment) TRANSLATE_PROFILE.invokeExact(h, dx, dy)));
            } finally {
                keep(this);
            }
        }
    }

    /**
     * An outline drawn a segment at a time; {@link #end()} closes it into a {@link Profile}
     * and consumes the builder. Named as Python names it, which is why {@code
     * java.nio.file.Path} is spelled out in full throughout this file.
     */
    public static final class Path implements AutoCloseable {
        private final Handle handle;
        private final Cleaner.Cleanable cleanable;

        private Path(double[] start) {
            double[] s = point2(start, "start");
            MemorySegment raw = call(() -> (MemorySegment) PATH_BEGIN.invokeExact(s[0], s[1]));
            handle = new Handle(PATH_FREE, "path: already ended", checked(raw, "path_begin"));
            cleanable = CLEANER.register(this, handle);
        }

        public boolean closed() {
            return handle.closed();
        }

        /** Release a path that was never ended; a no-op after {@link #end()} or {@link
         *  #endOpen()}, which consume the builder. Idempotent. */
        @Override
        public void close() {
            cleanable.clean();
        }

        private Path step(boolean ok, String what) {
            if (!ok) throw failure(what);
            return this;
        }

        /** A straight segment to ({@code x}, {@code y}). */
        public Path lineTo(double x, double y) {
            try {
                MemorySegment h = handle.live();
                return step(call(() -> (boolean) PATH_LINE_TO.invokeExact(h, x, y)), "path_line_to");
            } finally {
                keep(this);
            }
        }

        /** {@link #arcTo(double, double, double[], boolean)} counter-clockwise. */
        public Path arcTo(double x, double y, double[] centre) {
            return arcTo(x, y, centre, true);
        }

        /** A circular arc to ({@code x}, {@code y}) about {@code centre} (two numbers),
         *  counter-clockwise if {@code ccw}. */
        public Path arcTo(double x, double y, double[] centre, boolean ccw) {
            double[] c = point2(centre, "centre");
            try {
                MemorySegment h = handle.live();
                return step(call(() -> (boolean) PATH_ARC_TO.invokeExact(h, x, y, c[0], c[1], ccw)), "path_arc_to");
            } finally {
                keep(this);
            }
        }

        /** A cubic Bezier to {@code to} with interior control points {@code c1} and {@code
         *  c2} (two numbers each); the first control point is the current point. */
        public Path bezierTo(double[] c1, double[] c2, double[] to) {
            double[] a = point2(c1, "c1");
            double[] b = point2(c2, "c2");
            double[] t = point2(to, "to");
            try {
                MemorySegment h = handle.live();
                return step(call(() -> (boolean) PATH_BEZIER_TO.invokeExact(h, a[0], a[1], b[0], b[1], t[0], t[1])),
                        "path_bezier_to");
            } finally {
                keep(this);
            }
        }

        /** {@link #nurbsTo(double[][], double[], int, double[])} without weights. */
        public Path nurbsTo(double[][] control, double[] knots, int degree) {
            return nurbsTo(control, knots, degree, null);
        }

        /**
         * A NURBS segment. {@code control}: every control point after the current one, the
         * endpoint last; {@code weights}: one per control point <em>including</em> the
         * current one, or null; {@code knots}: the full repeated knot vector.
         */
        public Path nurbsTo(double[][] control, double[] knots, int degree, double[] weights) {
            double[] flat = flatten2(control, "control");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment c = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, flat);
                MemorySegment w = weights == null ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_DOUBLE, weights);
                MemorySegment k = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, knots);
                long controlCount = flat.length / 2;
                long knotCount = knots.length;
                MemorySegment h = handle.live();
                return step(call(() -> (boolean) PATH_NURBS_TO.invokeExact(h, c, controlCount, w, k, knotCount, degree)),
                        "path_nurbs_to");
            } finally {
                keep(this);
            }
        }

        /**
         * The path as it stands, without closing it: an open chain for {@link
         * Solid#extrudeOpen}, {@link Solid#sweepOpen} or {@link Solid#loftOpen} (a closed
         * sweep closes it with a straight side). Consumes the builder as {@link #end()} does.
         */
        public Profile endOpen() {
            MemorySegment h = handle.consume();
            cleanable.clean();
            return new Profile(call(() -> (MemorySegment) PATH_END_OPEN.invokeExact(h)));
        }

        /** Close the path into a profile. The builder is consumed whether or not this
         *  succeeds. */
        public Profile end() {
            MemorySegment h = handle.consume();
            cleanable.clean();
            return new Profile(call(() -> (MemorySegment) PATH_END.invokeExact(h)));
        }
    }

    /**
     * A 3D path a profile is carried along -- lines and arcs, a point at a time -- for
     * {@link Solid#sweep}/{@link Solid#sweepOpen}. Named apart from {@link Path} (the 2D
     * outline builder) because it plays a different role: a sweep path has no closing rule
     * of its own, so a sweep only <em>borrows</em> it rather than consuming it -- the same
     * path can be swept more than once, open or closed. Close it once done.
     */
    public static final class SweepPath implements AutoCloseable {
        private final Handle handle;
        private final Cleaner.Cleanable cleanable;

        private SweepPath(double[] at) {
            double[] p = point3(at, "at");
            MemorySegment raw = call(() -> (MemorySegment) SWEEP_PATH_BEGIN.invokeExact(p[0], p[1], p[2]));
            handle = new Handle(SWEEP_PATH_FREE, "sweep_path: closed", checked(raw, "sweep_path_begin"));
            cleanable = CLEANER.register(this, handle);
        }

        /** Start a sweep path at {@code point} (three numbers). */
        public static SweepPath at(double[] point) {
            return new SweepPath(point);
        }

        MemorySegment handle() {
            return handle.live();
        }

        public boolean closed() {
            return handle.closed();
        }

        /** Give the path back. Idempotent. */
        @Override
        public void close() {
            cleanable.clean();
        }

        private SweepPath step(boolean ok, String what) {
            if (!ok) throw failure(what);
            return this;
        }

        /** A straight piece to {@code point} (three numbers). */
        public SweepPath lineTo(double[] point) {
            double[] p = point3(point, "point");
            try {
                MemorySegment h = handle();
                return step(call(() -> (boolean) SWEEP_PATH_LINE_TO.invokeExact(h, p[0], p[1], p[2])), "sweep_path_line_to");
            } finally {
                keep(this);
            }
        }

        /** Turn {@code angle} radians about the axis through {@code centre} with direction
         *  {@code axis} (three numbers each; the direction need not be unit); {@code angle}
         *  must be in {@code (0, 2*pi]}. */
        public SweepPath arc(double[] centre, double[] axis, double angle) {
            double[] c = point3(centre, "centre");
            double[] a = point3(axis, "axis");
            try {
                MemorySegment h = handle();
                return step(call(() -> (boolean) SWEEP_PATH_ARC.invokeExact(h, c[0], c[1], c[2], a[0], a[1], a[2], angle)),
                        "sweep_path_arc");
            } finally {
                keep(this);
            }
        }
    }

    /**
     * A plane a sweep starts or ends on, read as a height over the sketch plane at each
     * point: {@code at + grad.p} (a dot product). Flat ({@code grad} zero) for {@link
     * Solid#extrude}'s own caps; sloped for a mitre -- the mitred end of a sweep's straight
     * piece, where it meets the plane bisecting its corner with the next.
     *
     * @param at   the height at the sketch plane's origin
     * @param grad the slope along the sketch plane's x and y, two numbers
     */
    public record Slant(double at, double[] grad) {
        public Slant {
            grad = point2(grad, "grad").clone();
        }

        /** A flat plane at height {@code at}. */
        public Slant(double at) {
            this(at, new double[]{0.0, 0.0});
        }

        public static Slant flat(double at) {
            return new Slant(at);
        }

        /**
         * The plane through {@code point} square to {@code normal}, read as heights over
         * {@code frame}. Throws {@link BuildException} when the plane holds the sweep
         * direction itself ({@code normal} square to {@code frame}'s z), so no height is on
         * it.
         */
        public static Slant ofPlane(double[] frame, double[] point, double[] normal) {
            double[] f = frame(frame);
            double[] p = point3(point, "point");
            double[] n = point3(normal, "normal");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment ps = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, p);
                MemorySegment ns = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, n);
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                boolean ok = call(() -> (boolean) SLANT_OF_PLANE.invokeExact(fs, ps, ns, out));
                if (!ok) throw failure("slant_of_plane");
                double[] raw = out.toArray(ValueLayout.JAVA_DOUBLE);
                return new Slant(raw[0], new double[]{raw[1], raw[2]});
            }
        }

        /** What the C ABI takes: {@code at, grad_x, grad_y}. */
        double[] raw() {
            return new double[]{at, grad[0], grad[1]};
        }

        @Override
        public String toString() {
            return "Slant(" + at + ", (" + grad[0] + ", " + grad[1] + "))";
        }
    }

    // ---- solids ---------------------------------------------------------------------------

    /** The same triangles in memory of our own, safe to outlive the solid -- what {@link
     *  Mesh#copy()} returns. */
    public record MeshData(float[] positions, float[] normals, int[] indices) {
    }

    /**
     * A solid's triangles -- views over the library's own cache at one tolerance, valid
     * until the solid is closed or meshed again at another tolerance (see the file header).
     *
     * <p>{@link #positions()} and {@link #normals()} are {@code vertexCount * 3} floats,
     * {@link #indices()} is {@code indexCount}, three to a triangle. Every view is read-only
     * and never null: an empty mesh reads as empty buffers, as Python's reads as empty
     * arrays.
     */
    public static final class Mesh {
        private final Solid solid;
        private final double tolerance;
        /** Which filling of the solid's cache this reads -- see {@link Solid#checkCache}. */
        private final int generation;
        private final long positions, normals, indices;
        private final int vertexCount, indexCount;

        private Mesh(Solid solid, double tolerance, int generation, MemorySegment raw) {
            this.solid = solid;
            this.tolerance = tolerance;
            this.generation = generation;
            positions = raw.get(ValueLayout.ADDRESS, offset(MESH, "positions")).address();
            normals = raw.get(ValueLayout.ADDRESS, offset(MESH, "normals")).address();
            indices = raw.get(ValueLayout.ADDRESS, offset(MESH, "indices")).address();
            vertexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH, "vertex_count"));
            indexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH, "index_count"));
        }

        /** The solid this borrows from. */
        public Solid solid() {
            return solid;
        }

        /** The tolerance this was meshed at. */
        public double tolerance() {
            return tolerance;
        }

        public int vertexCount() {
            return vertexCount;
        }

        public int indexCount() {
            return indexCount;
        }

        public int triangleCount() {
            return indexCount / 3;
        }

        public FloatBuffer positions() {
            solid.checkCache(generation);
            return floatView(positions, vertexCount * 3L);
        }

        public FloatBuffer normals() {
            solid.checkCache(generation);
            return floatView(normals, vertexCount * 3L);
        }

        public IntBuffer indices() {
            solid.checkCache(generation);
            return intView(indices, indexCount);
        }

        /** The same triangles in memory of our own, safe to outlive the solid. */
        public MeshData copy() {
            return new MeshData(toArray(positions()), toArray(normals()), toArray(indices()));
        }
    }

    /**
     * A solid's feature edges as polylines -- views over the library's own cache at one
     * tolerance, under the same lifetime rule as {@link Mesh}. Polyline {@code i} is {@code
     * points[offsets[i] * 3 .. offsets[i + 1] * 3]}, three floats a point.
     */
    public static final class Polylines {
        private final Solid solid;
        private final double tolerance;
        private final int generation;
        private final long points, offsets;
        private final int pointCount, polylineCount;

        private Polylines(Solid solid, double tolerance, int generation, MemorySegment raw) {
            this.solid = solid;
            this.tolerance = tolerance;
            this.generation = generation;
            points = raw.get(ValueLayout.ADDRESS, offset(POLYLINES, "points")).address();
            offsets = raw.get(ValueLayout.ADDRESS, offset(POLYLINES, "offsets")).address();
            pointCount = raw.get(ValueLayout.JAVA_INT, offset(POLYLINES, "point_count"));
            polylineCount = raw.get(ValueLayout.JAVA_INT, offset(POLYLINES, "polyline_count"));
        }

        public Solid solid() {
            return solid;
        }

        public double tolerance() {
            return tolerance;
        }

        public int pointCount() {
            return pointCount;
        }

        public int polylineCount() {
            return polylineCount;
        }

        /** {@code pointCount * 3} floats, the polylines end to end. */
        public FloatBuffer points() {
            solid.checkCache(generation);
            return floatView(points, pointCount * 3L);
        }

        /** {@code polylineCount + 1} point offsets; the last equals {@link #pointCount()}. */
        public IntBuffer offsets() {
            solid.checkCache(generation);
            return intView(offsets, polylineCount + 1L);
        }

        /** Polyline {@code i}'s points, three floats each -- what Python's list holds at
         *  {@code i}. */
        public FloatBuffer polyline(int i) {
            IntBuffer o = offsets();
            int from = o.get(i) * 3;
            int to = o.get(i + 1) * 3;
            return points().slice(from, to - from).asReadOnlyBuffer();
        }

        /** Every polyline in memory of our own, one {@code k * 3} array each, safe to
         *  outlive the solid. */
        public float[][] copy() {
            float[][] out = new float[polylineCount][];
            for (int i = 0; i < out.length; i++) out[i] = toArray(polyline(i));
            return out;
        }
    }

    /** An axis-aligned box, in the solid's own units and at double precision -- what
     *  {@link Solid#bounds()} hands back. */
    public record Bounds(double[] min, double[] max) {
    }

    /**
     * An exact B-rep solid (or open sheet). Immutable; every operation returns a new one.
     * Close it to free it; the cleaner does so otherwise.
     */
    public static final class Solid implements AutoCloseable {
        private final Handle handle;
        private final Cleaner.Cleanable cleanable;

        /**
         * The tolerance the library's tessellation cache was last filled at (NaN before any
         * of {@link #mesh}, {@link #edgePolylines} and {@link #boundsAt} ran), and how many
         * times it has been filled. The library replaces the cache whole whenever it is
         * asked for a tolerance other than the one it holds, so a view is tied to a
         * <em>filling</em>, not a tolerance: after 0.05, 0.5, 0.05 the first view's memory
         * is gone even though the cache is back at its tolerance. A view checks the
         * generation it was cut from, never the tolerance.
         */
        private double cacheTolerance = Double.NaN;
        private int cacheGeneration;

        private Solid(MemorySegment raw) {
            handle = new Handle(SOLID_FREE, "solid: closed", checked(raw, "solid"));
            cleanable = CLEANER.register(this, handle);
        }

        /** Record that a call just tessellated at {@code tolerance}: a new filling if it
         *  differs from the one the cache held. Returns the generation a view made now
         *  belongs to. */
        private int filled(double tolerance) {
            if (Double.isNaN(cacheTolerance) || cacheTolerance != tolerance) {
                cacheTolerance = tolerance;
                cacheGeneration++;
            }
            return cacheGeneration;
        }

        /** A view cut from filling {@code generation} may read only while that filling is
         *  the one the solid holds; a closed solid has none. */
        void checkCache(int generation) {
            handle();
            if (cacheGeneration != generation) {
                throw new IllegalStateException(
                        "the view is stale: the solid's tessellation has been replaced since (now at tolerance "
                                + cacheTolerance + ")");
            }
        }

        MemorySegment handle() {
            return handle.live();
        }

        public boolean closed() {
            return handle.closed();
        }

        /** Give the solid back. Idempotent. Every {@link Mesh} and {@link Polylines} still
         *  held throws on its next read. */
        @Override
        public void close() {
            cleanable.clean();
        }

        // -- building

        /** A box {@code x} by {@code y} by {@code z}, centred on the origin. */
        public static Solid cuboid(double x, double y, double z) {
            return new Solid(call(() -> (MemorySegment) CUBOID.invokeExact(x, y, z)));
        }

        /** A cylinder of radius {@code r}, height {@code h}, based on z=0 and rising along +z. */
        public static Solid cylinder(double r, double h) {
            return new Solid(call(() -> (MemorySegment) CYLINDER.invokeExact(r, h)));
        }

        /** A cone of base radius {@code r} and height {@code h}, apex up. */
        public static Solid cone(double r, double h) {
            return new Solid(call(() -> (MemorySegment) CONE.invokeExact(r, h)));
        }

        /** A sphere of radius {@code r} about the origin. */
        public static Solid sphere(double r) {
            return new Solid(call(() -> (MemorySegment) SPHERE.invokeExact(r)));
        }

        /** A torus of ring radius {@code major} and tube radius {@code minor}, about z. */
        public static Solid torus(double major, double minor) {
            return new Solid(call(() -> (MemorySegment) TORUS.invokeExact(major, minor)));
        }

        /** A box {@code x} by {@code y} by {@code z} whose top face is narrowed to {@code
         *  topX} along x. */
        public static Solid wedge(double x, double y, double z, double topX) {
            return new Solid(call(() -> (MemorySegment) WEDGE.invokeExact(x, y, z, topX)));
        }

        /** One of the four `(profile, frame, double)` builders. */
        private static Solid onFrame(MethodHandle op, Profile profile, double[] frame, double height) {
            double[] f = frame(frame);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment p = profile.handle();
                return new Solid(call(() -> (MemorySegment) op.invokeExact(p, fs, height)));
            } finally {
                keep(profile);
            }
        }

        /** One of the two tapered builders. */
        private static Solid onFrameTapered(MethodHandle op, Profile profile, double[] frame, double height, double taper) {
            double[] f = frame(frame);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment p = profile.handle();
                return new Solid(call(() -> (MemorySegment) op.invokeExact(p, fs, height, taper)));
            } finally {
                keep(profile);
            }
        }

        /** One of the two between-planes builders. */
        private static Solid between(MethodHandle op, Profile profile, double[] frame, Slant bottom, Slant top) {
            double[] f = frame(frame);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment lo = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, bottom.raw());
                MemorySegment hi = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, top.raw());
                MemorySegment p = profile.handle();
                return new Solid(call(() -> (MemorySegment) op.invokeExact(p, fs, lo, hi)));
            } finally {
                keep(profile);
            }
        }

        /** One of the two loft builders. */
        private static Solid lofted(MethodHandle op, Profile a, double[] frameA, Profile b, double[] frameB) {
            double[] fa = frame(frameA);
            double[] fb = frame(frameB);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment sa = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, fa);
                MemorySegment sb = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, fb);
                MemorySegment pa = a.handle();
                MemorySegment pb = b.handle();
                return new Solid(call(() -> (MemorySegment) op.invokeExact(pa, sa, pb, sb)));
            } finally {
                keep(a, b);
            }
        }

        /** One of the two revolve builders. */
        private static Solid revolved(MethodHandle op, Profile profile, double[] axis, double angle) {
            double[] ax = axisOf(axis);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment as = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, ax);
                MemorySegment p = profile.handle();
                return new Solid(call(() -> (MemorySegment) op.invokeExact(p, as, angle)));
            } finally {
                keep(profile);
            }
        }

        /** One of the two sweep builders. */
        private static Solid swept(MethodHandle op, Profile profile, double[] frame, SweepPath path) {
            double[] f = frame(frame);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment p = profile.handle();
                MemorySegment sp = path.handle();
                return new Solid(call(() -> (MemorySegment) op.invokeExact(p, fs, sp)));
            } finally {
                keep(profile, path);
            }
        }

        /** {@code profile} swept {@code height} along the frame's z, closed with two caps.
         *  {@code frame} is twelve numbers: origin, x, y, z. */
        public static Solid extrude(Profile profile, double[] frame, double height) {
            return onFrame(EXTRUDE, profile, frame, height);
        }

        /** {@link #extrude} without the caps: an open sheet of walls. */
        public static Solid extrudeOpen(Profile profile, double[] frame, double height) {
            return onFrame(EXTRUDE_OPEN, profile, frame, height);
        }

        /** {@link #extrude} with a draft: the walls lean out by {@code taper} radians as
         *  they rise (in, when negative), every wall exact -- a plane off a line, a cone off
         *  an arc. A taper of zero is {@link #extrude}. */
        public static Solid extrudeTapered(Profile profile, double[] frame, double height, double taper) {
            return onFrameTapered(EXTRUDE_TAPERED, profile, frame, height, taper);
        }

        public static Solid extrudeOpenTapered(Profile profile, double[] frame, double height, double taper) {
            return onFrameTapered(EXTRUDE_OPEN_TAPERED, profile, frame, height, taper);
        }

        /**
         * {@link #extrude} between two planes instead of two heights: {@code bottom} and
         * {@code top} are each a {@link Slant}. The profile's walls run from where {@code
         * bottom} cuts them to where {@code top} does, the caps lying on those planes. With
         * both flat this <em>is</em> {@link #extrude} (bit for bit); with a slope it is the
         * mitred end of a sweep's straight piece. Throws {@link BuildException} where the
         * top plane comes down to or through the bottom across the profile.
         */
        public static Solid extrudeBetween(Profile profile, double[] frame, Slant bottom, Slant top) {
            return between(EXTRUDE_BETWEEN, profile, frame, bottom, top);
        }

        /** {@link #extrudeBetween(Profile, double[], Slant, Slant)} with two flat planes --
         *  a bare number is {@code Slant.flat(number)}, as Python reads one. */
        public static Solid extrudeBetween(Profile profile, double[] frame, double bottom, double top) {
            return extrudeBetween(profile, frame, Slant.flat(bottom), Slant.flat(top));
        }

        /** {@link #extrudeBetween(Profile, double[], Slant, Slant)} without the caps: an
         *  open sheet of walls running from {@code bottom} to {@code top}, as {@link
         *  #extrudeOpen} is to {@link #extrude}. */
        public static Solid extrudeOpenBetween(Profile profile, double[] frame, Slant bottom, Slant top) {
            return between(EXTRUDE_OPEN_BETWEEN, profile, frame, bottom, top);
        }

        public static Solid extrudeOpenBetween(Profile profile, double[] frame, double bottom, double top) {
            return extrudeOpenBetween(profile, frame, Slant.flat(bottom), Slant.flat(top));
        }

        /** The solid between {@code a} on {@code frameA} and {@code b} on {@code frameB}:
         *  ruled walls between matching sides (the profiles must have the same number of
         *  sides, and no holes), capped by the two profiles. */
        public static Solid loft(Profile a, double[] frameA, Profile b, double[] frameB) {
            return lofted(LOFT, a, frameA, b, frameB);
        }

        /** {@link #loft} without the caps: the sheet ruled between the two curves. */
        public static Solid loftOpen(Profile a, double[] frameA, Profile b, double[] frameB) {
            return lofted(LOFT_OPEN, a, frameA, b, frameB);
        }

        /** {@code profile} swung {@code angle} radians about {@code axis} (six numbers: a
         *  point and a direction). */
        public static Solid revolve(Profile profile, double[] axis, double angle) {
            return revolved(REVOLVE, profile, axis, angle);
        }

        public static Solid revolveOpen(Profile profile, double[] axis, double angle) {
            return revolved(REVOLVE_OPEN, profile, axis, angle);
        }

        /**
         * {@code profile}, drawn on {@code frame}, carried along {@code path} into a closed
         * solid: a straight piece of the path is an extrusion, a circular piece a revolution
         * about the arc's axis, so nothing is approximated -- a circle along an arc is an
         * exact torus wall. {@code path} is only borrowed, not consumed; sweep it again, open
         * or closed, as often as needed.
         */
        public static Solid sweep(Profile profile, double[] frame, SweepPath path) {
            return swept(SWEEP, profile, frame, path);
        }

        /** {@link #sweep} for a curve rather than a face: one wall per segment per piece, no
         *  caps -- an open sheet, the way {@link #extrudeOpen} is to {@link #extrude}. */
        public static Solid sweepOpen(Profile profile, double[] frame, SweepPath path) {
            return swept(SWEEP_OPEN, profile, frame, path);
        }

        /** Every face of this sheet pushed {@code height} along its own normal, walled and
         *  closed: the sheet as a solid of that thickness. */
        public Solid extrudeFaces(double height) {
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) EXTRUDE_FACES.invokeExact(h, height)));
            } finally {
                keep(this);
            }
        }

        /** This solid, built about the origin, moved onto {@code frame}. */
        public Solid place(double[] frame) {
            double[] f = frame(frame);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) PLACE.invokeExact(h, fs)));
            } finally {
                keep(this);
            }
        }

        public Solid translate(double dx, double dy, double dz) {
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) TRANSLATE.invokeExact(h, dx, dy, dz)));
            } finally {
                keep(this);
            }
        }

        /** This solid turned {@code radians} about {@code axis} (six numbers: a point and a
         *  direction). */
        public Solid rotate(double[] axis, double radians) {
            double[] ax = axisOf(axis);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment as = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, ax);
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) ROTATE.invokeExact(h, as, radians)));
            } finally {
                keep(this);
            }
        }

        /** This solid reflected across {@code plane} (a frame; its z is the plane's normal). */
        public Solid mirror(double[] plane) {
            double[] f = frame(plane);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) MIRROR.invokeExact(h, fs)));
            } finally {
                keep(this);
            }
        }

        // -- combining

        /** One of the four booleans; the progress callback and its user pointer are null. */
        private Solid combine(MethodHandle op, Solid other, double tolerance) {
            try {
                MemorySegment a = handle();
                MemorySegment b = other.handle();
                return new Solid(call(() -> (MemorySegment) op.invokeExact(a, b, tolerance, MemorySegment.NULL, MemorySegment.NULL)));
            } finally {
                keep(this, other);
            }
        }

        /** {@link #join(Solid, double)} at 0.05. */
        public Solid join(Solid other) {
            return join(other, 0.05);
        }

        /** This solid and {@code other} as one; both inputs stay valid. */
        public Solid join(Solid other, double tolerance) {
            return combine(JOIN, other, tolerance);
        }

        /** {@link #cut(Solid, double)} at 0.05. */
        public Solid cut(Solid other) {
            return cut(other, 0.05);
        }

        /** This solid with {@code other} removed; both inputs stay valid. */
        public Solid cut(Solid other, double tolerance) {
            return combine(CUT, other, tolerance);
        }

        /** {@link #common(Solid, double)} at 0.05. */
        public Solid common(Solid other) {
            return common(other, 0.05);
        }

        /** What this solid and {@code other} share; both inputs stay valid. */
        public Solid common(Solid other, double tolerance) {
            return combine(COMMON, other, tolerance);
        }

        /** {@link #splitSheet(Solid, double)} at 0.05. */
        public Solid splitSheet(Solid tool) {
            return splitSheet(tool, 0.05);
        }

        /**
         * This solid (a sheet or a solid) cut along {@code tool}'s boundary, nothing
         * removed: every face comes back in its pieces outside {@code tool} and its pieces
         * inside, each piece a face, in this solid's own face order with each face's outside
         * pieces before its inside pieces. {@code tool} must be a closed solid. There is no
         * way yet, from here or the C ABI, to build a new solid from a chosen subset of a
         * result's faces: this only cuts.
         */
        public Solid splitSheet(Solid tool, double tolerance) {
            return combine(SPLIT_SHEET, tool, tolerance);
        }

        // -- asking

        /** How many faces, in the solid's own order; a face index runs to this. */
        public int faces() {
            try {
                MemorySegment h = handle();
                int n = call(() -> (int) FACE_COUNT.invokeExact(h));
                if (n == 0 && !lastError().isEmpty()) throw failure("face_count");
                return n;
            } finally {
                keep(this);
            }
        }

        /** The face's surface kind: "plane", "cylinder", "cone", "sphere", "torus", "nurbs",
         *  "revolution", "extrusion", "other", or "none" for a face without a surface. */
        public String faceKind(int face) {
            int i = index(face);
            try {
                MemorySegment h = handle();
                MemorySegment raw = call(() -> (MemorySegment) FACE_KIND.invokeExact(h, i));
                if (raw.address() == 0) throw failure("face_kind");
                return string(raw);
            } finally {
                keep(this);
            }
        }

        /** {@link #boundsAt} at tolerance 0.05. */
        public Bounds bounds() {
            return boundsAt(0.05);
        }

        /** The solid's axis-aligned bounds, over the positions of its cached tessellation
         *  at {@code tolerance} (the same cache {@link #mesh} fills and reuses, so a second
         *  call at the same tolerance is free). */
        public Bounds boundsAt(double tolerance) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment lo = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                MemorySegment hi = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                MemorySegment h = handle();
                boolean ok = call(() -> (boolean) BOUNDS.invokeExact(h, tolerance, lo, hi));
                if (!ok) throw failure("bounds");
                filled(tolerance);
                return new Bounds(lo.toArray(ValueLayout.JAVA_DOUBLE), hi.toArray(ValueLayout.JAVA_DOUBLE));
            } finally {
                keep(this);
            }
        }

        /** {@link #leakedEdges(double)} at 0.05. */
        public int leakedEdges() {
            return leakedEdges(0.05);
        }

        /** How many edges of the mesh at {@code tolerance} are bound by anything other than
         *  exactly two triangles -- zero for a closed solid. A seam two solids share along a
         *  line (four triangles, two pairs) does <em>not</em> count here; a genuine hole or
         *  a fold does. */
        public int leakedEdges(double tolerance) {
            try {
                MemorySegment h = handle();
                int n = call(() -> (int) LEAKED_EDGES.invokeExact(h, tolerance));
                if (n == NONE) throw failure("leaked_edges");
                return n;
            } finally {
                keep(this);
            }
        }

        /** {@link #unpairedEdges(double)} at 0.05. */
        public int unpairedEdges() {
            return unpairedEdges(0.05);
        }

        /** How many edges of the mesh at {@code tolerance} have directed triangle uses that
         *  do not cancel out -- zero for a closed, consistently oriented solid. Where {@link
         *  #leakedEdges} asks for exactly two triangles on an edge, this asks that they run
         *  opposite ways: a shared seam pairs off and is <em>not</em> counted, a fold -- two
         *  triangles running the same way -- is. */
        public int unpairedEdges(double tolerance) {
            try {
                MemorySegment h = handle();
                int n = call(() -> (int) UNPAIRED_EDGES.invokeExact(h, tolerance));
                if (n == NONE) throw failure("unpaired_edges");
                return n;
            } finally {
                keep(this);
            }
        }

        /** {@link #isWatertight(double)} at 0.05. */
        public boolean isWatertight() {
            return isWatertight(0.05);
        }

        /** {@code leakedEdges(tolerance) == 0}. */
        public boolean isWatertight(double tolerance) {
            return leakedEdges(tolerance) == 0;
        }

        // -- out

        /** {@link #mesh(double)} at 0.05. */
        public Mesh mesh() {
            return mesh(0.05);
        }

        /** The triangles at {@code tolerance}, as views into the solid's cache. See the file
         *  header for what invalidates them. */
        public Mesh mesh(double tolerance) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = arena;
                MemorySegment h = handle();
                MemorySegment raw = call(() -> (MemorySegment) MESH_AT.invokeExact(allocator, h, tolerance));
                if (raw.get(ValueLayout.ADDRESS, offset(MESH, "positions")).address() == 0) throw failure("mesh");
                return new Mesh(this, tolerance, filled(tolerance), raw);
            } finally {
                keep(this);
            }
        }

        /** {@link #edgePolylines(double)} at 0.05. */
        public Polylines edgePolylines() {
            return edgePolylines(0.05);
        }

        /** The feature edges as polylines, views into the same cache as {@link #mesh}. */
        public Polylines edgePolylines(double tolerance) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = arena;
                MemorySegment h = handle();
                MemorySegment raw = call(() -> (MemorySegment) EDGE_POLYLINES.invokeExact(allocator, h, tolerance));
                if (raw.get(ValueLayout.ADDRESS, offset(POLYLINES, "offsets")).address() == 0) throw failure("edge_polylines");
                return new Polylines(this, tolerance, filled(tolerance), raw);
            } finally {
                keep(this);
            }
        }

        /** {@link #stepText(String, String)} with the default schema, in millimetres. */
        public String stepText() {
            return stepText(null, "mm");
        }

        /** This solid as AP203 STEP text; see {@link Blacksmith#writeStepText}. */
        public String stepText(String schema, String unit) {
            return writeStepText(List.of(this), schema, unit);
        }

        /** {@link #step(String, String, String)} with the default schema, in millimetres. */
        public void step(String path) {
            step(path, null, "mm");
        }

        /** This solid written as an AP203 STEP file. */
        public void step(String path, String schema, String unit) {
            writeText(path, stepText(schema, unit));
        }

        // -- selecting and edges

        /** The face {@code selector} picks; throws when none does. */
        public int selectFace(Selector selector) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment v = selector.direction() == null
                        ? MemorySegment.NULL
                        : arena.allocateFrom(ValueLayout.JAVA_DOUBLE, selector.direction());
                int kind = selector.kind();
                int at = selector.at();
                MemorySegment h = handle();
                int i = call(() -> (int) SELECT_FACE.invokeExact(h, kind, v, at));
                if (i == NONE) throw failure("select_face");
                return i;
            } finally {
                keep(this);
            }
        }

        /** Twelve doubles: origin, x, y, z of the workplane on {@code face}. */
        public double[] faceFrame(int face) {
            int i = index(face);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 12);
                MemorySegment h = handle();
                boolean ok = call(() -> (boolean) FACE_FRAME.invokeExact(h, i, out));
                if (!ok) throw failure("face_frame");
                return out.toArray(ValueLayout.JAVA_DOUBLE);
            } finally {
                keep(this);
            }
        }

        /** The edges a fillet indexes, as {@link Edge} records (copied; safe to keep). */
        @SuppressWarnings("restricted") // reinterpret: the counts beside each pointer say how far it reaches.
        public List<Edge> edges() {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment h = handle();
                int n = call(() -> (int) EDGE_COUNT.invokeExact(h));
                if (n == 0 && !lastError().isEmpty()) throw failure("edge_count");
                List<Edge> found = new ArrayList<>(n);
                MemorySegment raw = arena.allocate(EDGE);
                for (int i = 0; i < n; i++) {
                    int at = i;
                    boolean ok = call(() -> (boolean) EDGE_AT.invokeExact(h, at, raw));
                    if (!ok) throw failure("edge");
                    String kind = string(raw.get(ValueLayout.ADDRESS, offset(EDGE, "kind")));
                    int faceCount = raw.get(ValueLayout.JAVA_INT, offset(EDGE, "face_count"));
                    MemorySegment facesAt = raw.get(ValueLayout.ADDRESS, offset(EDGE, "faces"));
                    int[] faces = faceCount == 0 || facesAt.address() == 0
                            ? new int[0]
                            : facesAt.reinterpret(faceCount * (long) Integer.BYTES).toArray(ValueLayout.JAVA_INT);
                    int segmentCount = raw.get(ValueLayout.JAVA_INT, offset(EDGE, "segment_count"));
                    MemorySegment segmentsAt = raw.get(ValueLayout.ADDRESS, offset(EDGE, "segments"));
                    Edge.Segment[] segments = new Edge.Segment[segmentCount];
                    if (segmentCount > 0 && segmentsAt.address() != 0) {
                        double[] flat = segmentsAt.reinterpret(6L * segmentCount * Double.BYTES).toArray(ValueLayout.JAVA_DOUBLE);
                        for (int s = 0; s < segmentCount; s++) {
                            segments[s] = new Edge.Segment(
                                    Arrays.copyOfRange(flat, 6 * s, 6 * s + 3),
                                    Arrays.copyOfRange(flat, 6 * s + 3, 6 * s + 6));
                        }
                    } else {
                        Arrays.fill(segments, new Edge.Segment(new double[3], new double[3]));
                    }
                    found.add(new Edge(i, kind, faces, segments));
                }
                return found;
            } finally {
                keep(this);
            }
        }

        private static int[] indicesOf(Collection<Edge> edges) {
            int[] out = new int[edges.size()];
            int i = 0;
            for (Edge e : edges) out[i++] = e.index();
            return out;
        }

        /** {@link #fillet(Collection, double, double)} at tolerance 1e-6. */
        public Solid fillet(Collection<Edge> edges, double radius) {
            return fillet(edges, radius, 1e-6);
        }

        /** This solid with {@code edges} rounded to {@code radius}. */
        public Solid fillet(Collection<Edge> edges, double radius, double tolerance) {
            return fillet(indicesOf(edges), radius, tolerance);
        }

        /** {@link #fillet(int[], double, double)} at tolerance 1e-6. */
        public Solid fillet(int[] edges, double radius) {
            return fillet(edges, radius, 1e-6);
        }

        /** {@link #fillet(Collection, double, double)} by edge index. */
        public Solid fillet(int[] edges, double radius, double tolerance) {
            int[] which = indices(edges);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment list = arena.allocateFrom(ValueLayout.JAVA_INT, which);
                long count = which.length;
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) FILLET.invokeExact(
                        h, list, count, radius, tolerance, MemorySegment.NULL, MemorySegment.NULL)));
            } finally {
                keep(this);
            }
        }

        /** {@link #chamfer(Collection, double, double)} at tolerance 1e-6. */
        public Solid chamfer(Collection<Edge> edges, double distance) {
            return chamfer(edges, distance, 1e-6);
        }

        /** {@link #fillet(Collection, double, double)} with a flat bevel: each edge cut back
         *  {@code distance} along both its faces. */
        public Solid chamfer(Collection<Edge> edges, double distance, double tolerance) {
            return chamfer(indicesOf(edges), distance, tolerance);
        }

        /** {@link #chamfer(int[], double, double)} at tolerance 1e-6. */
        public Solid chamfer(int[] edges, double distance) {
            return chamfer(edges, distance, 1e-6);
        }

        /** {@link #chamfer(Collection, double, double)} by edge index. */
        public Solid chamfer(int[] edges, double distance, double tolerance) {
            int[] which = indices(edges);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment list = arena.allocateFrom(ValueLayout.JAVA_INT, which);
                long count = which.length;
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) CHAMFER.invokeExact(h, list, count, distance, tolerance)));
            } finally {
                keep(this);
            }
        }

        /** {@link #shell(double, int[], double)} with no face opened, at tolerance 1e-6. */
        public Solid shell(double thickness) {
            return shell(thickness, new int[0], 1e-6);
        }

        /** {@link #shell(double, int[], double)} at tolerance 1e-6. */
        public Solid shell(double thickness, int[] open) {
            return shell(thickness, open, 1e-6);
        }

        /** This solid hollowed to a wall {@code thickness} thick (inward for a positive
         *  thickness, outward for a negative one), with the faces at {@code open} removed so
         *  the hollow is reachable. */
        public Solid shell(double thickness, int[] open, double tolerance) {
            int[] which = indices(open);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment list = arena.allocateFrom(ValueLayout.JAVA_INT, which);
                long count = which.length;
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) SHELL.invokeExact(
                        h, thickness, list, count, tolerance, MemorySegment.NULL, MemorySegment.NULL)));
            } finally {
                keep(this);
            }
        }

        /** {@link #toScene(String)} with {@link Blacksmith#defaultSchema()}. */
        public Cad.Scene toScene() {
            return toScene(null);
        }

        /**
         * This solid as a reader {@link Cad.Scene}, through STEP text and {@link
         * Cad#openMemory} -- the door to the viewer and the tree walk. Needs the reader's
         * library built beside this one.
         *
         * @param schema the path of the {@code .exp} to write and read with; null for
         *               {@link Blacksmith#defaultSchema()}. A path, not text: the reader's
         *               open takes one.
         */
        public Cad.Scene toScene(String schema) {
            String schemaPath = schema == null ? defaultSchema() : schema;
            byte[] bytes = stepText(schemaPath, "mm").getBytes(StandardCharsets.UTF_8);
            Cad.OpenOptions options = new Cad.OpenOptions(Cad.Convention.NATIVE, false, false, schemaPath, false, 0.0);
            return Cad.openMemory(bytes, "solid.stp", options);
        }
    }

    // ---- selecting ------------------------------------------------------------------------

    public enum Axis {
        X(0), Y(1), Z(2);

        private final int code;

        Axis(int code) {
            this.code = code;
        }

        /** The ABI's own number for this axis. */
        public int code() {
            return code;
        }
    }

    /**
     * Which face: furthest along an axis, furthest against it, by outward normal, or by
     * index -- {@code Selector::Max/Min/Normal/Index} in the crate. Built through the four
     * factories; the components are what {@code cadaclysm_blacksmith_select_face} takes.
     *
     * @param kind      0 max, 1 min, 2 normal, 3 index
     * @param direction the direction, read only for a normal; null otherwise
     * @param at        the axis or the face index, read only for an axis or an index
     */
    public record Selector(int kind, double[] direction, int at) {
        /** The face furthest along {@code axis}. */
        public static Selector max(Axis axis) {
            return new Selector(0, null, axis.code());
        }

        /** The face furthest against {@code axis}. */
        public static Selector min(Axis axis) {
            return new Selector(1, null, axis.code());
        }

        /** The face whose outward normal is nearest {@code direction} (three numbers, need
         *  not be unit). */
        public static Selector normal(double[] direction) {
            return new Selector(2, point3(direction, "direction").clone(), 0);
        }

        /** The face at {@code i} in the solid's own order. */
        public static Selector index(int i) {
            return new Selector(3, null, Blacksmith.index(i));
        }
    }

    /**
     * One edge of a solid, as plain data: its index (what {@link Solid#fillet} takes), the
     * curve kind, the faces meeting on it, and its segments' ends.
     *
     * @param index    the edge's index in the solid's own order
     * @param kind     "line", "circle", "ellipse", "nurbs" or "other"
     * @param faces    the faces that meet on it, in the solid's face order
     * @param segments the two ends of each trim piece of the edge
     */
    public record Edge(int index, String kind, int[] faces, Segment[] segments) {
        /** The two ends of one trim piece, three doubles each. */
        public record Segment(double[] a, double[] b) {
        }

        public boolean isLine() {
            return kind.equals("line");
        }

        /** Unit direction of a line edge (from its first segment), else null. */
        public double[] direction() {
            if (!isLine() || segments.length == 0) return null;
            double[] a = segments[0].a();
            double[] b = segments[0].b();
            double[] d = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
            double n = Math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
            return n > 0 ? new double[]{d[0] / n, d[1] / n, d[2] / n} : null;
        }

        @Override
        public String toString() {
            return "Edge(" + index + ", \"" + kind + "\", faces=" + Arrays.toString(faces) + ")";
        }
    }

    // ---- Workplane ------------------------------------------------------------------------

    /**
     * The fluent chain, mirroring the Rust {@code Workplane}: a frame, the solid built so
     * far, and the face last picked. A build call <em>replaces</em> the solid (as {@code
     * Workplane::set_brep} does); combine solids explicitly with {@link Solid#join}. Every
     * step throws {@link BuildException} at once rather than latching it. Owns no handle:
     * the solids it makes are the caller's to close, through {@link #solid()}.
     *
     * <p>Python's {@code workplane()} -- adopt the picked face's frame -- is {@link
     * #onFace()} here, the name the C# and Go bindings settled on (C# cannot name a member
     * after its own type, and the three keep one spelling).
     */
    public static final class Workplane {
        private static final double[] XY = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        private static final double[] XZ = {0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0};
        private static final double[] YZ = {0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0};

        private double[] frame;
        private Solid solid;
        private int selected = -1;

        /** A chain on {@code frame} (twelve numbers), holding {@code solid} if not null --
         *  what {@link #on} and {@link #fromSolid} build. */
        public Workplane(double[] frame, Solid solid) {
            this.frame = Blacksmith.frame(frame).clone();
            this.solid = solid;
        }

        /** Twelve numbers: origin, x, y, z -- the plane the next build call sketches on. A
         *  copy, so the chain's own array cannot be edited underneath it. */
        public double[] frame() {
            return frame.clone();
        }

        /** Set the frame, as Python's {@code frame} attribute can be. Leaves the solid and
         *  the picked face alone, as {@link #onFace()} does. */
        public void frame(double[] frame) {
            this.frame = Blacksmith.frame(frame).clone();
        }

        public static Workplane xy() {
            return new Workplane(XY, null);
        }

        public static Workplane xz() {
            return new Workplane(XZ, null);
        }

        public static Workplane yz() {
            return new Workplane(YZ, null);
        }

        public static Workplane on(double[] frame) {
            return new Workplane(frame, null);
        }

        public static Workplane fromSolid(Solid solid) {
            return new Workplane(XY, solid);
        }

        private Workplane set(Solid built) {
            solid = built;
            selected = -1;
            return this;
        }

        public Workplane cuboid(double x, double y, double z) {
            // The primitive is built about the origin and then placed; the unplaced one is
            // nobody's, so it is freed here rather than left to the cleaner.
            try (Solid raw = Solid.cuboid(x, y, z)) {
                return set(raw.place(frame));
            }
        }

        public Workplane cylinder(double r, double h) {
            try (Solid raw = Solid.cylinder(r, h)) {
                return set(raw.place(frame));
            }
        }

        public Workplane extrude(Profile profile, double height) {
            return set(Solid.extrude(profile, frame, height));
        }

        /** About this workplane's own y axis through its origin, as the Rust chain. */
        public Workplane revolve(Profile profile, double angle) {
            double[] axis = {frame[0], frame[1], frame[2], frame[6], frame[7], frame[8]};
            return set(Solid.revolve(profile, axis, angle));
        }

        /**
         * Slide the current solid. Unlike a build call, this keeps {@link #faces}'s
         * selection: a rigid translation carries every face along at the same index, exactly
         * as Rust's {@code Workplane::translate} writes the moved solid back without touching
         * {@code selected}. Rust's is a silent no-op on an empty workplane; this throws at
         * once, like every other step in the chain.
         */
        public Workplane translate(double dx, double dy, double dz) {
            if (solid == null) throw new BuildException("translate: the workplane holds no solid (BuildError::Empty)");
            solid = solid.translate(dx, dy, dz);
            return this;
        }

        public Workplane faces(Selector selector) {
            if (solid == null) throw new BuildException("faces: the workplane holds no solid (BuildError::Empty)");
            selected = solid.selectFace(selector);
            return this;
        }

        /** Adopt the frame on the face last picked; a no-op if none is. Python's {@code
         *  workplane()}, under the name the other bindings share (see the class notes). */
        public Workplane onFace() {
            if (solid != null && selected >= 0) frame = solid.faceFrame(selected);
            return this;
        }

        /** The solid built so far -- the caller's to close. */
        public Solid solid() {
            if (solid == null) throw new BuildException("solid: nothing was built (BuildError::Empty)");
            return solid;
        }
    }
}
