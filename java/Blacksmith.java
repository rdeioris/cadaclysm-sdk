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
// bindings, no third-party interop library. It finds its library the way
// `cadaclysm_blacksmith.py` does: point `CADACLYSM_BLACKSMITH_LIBRARY` at the library or the
// directory holding it if it is not where the loader looks by default (see `library()`).
// `CADACLYSM_LIBRARY` is the reader's, as it is in Python.
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
import java.nio.DoubleBuffer;
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
    // These seven are transcribed from `cadaclysm_blacksmith.h` by hand, in the header's
    // field order, and `tests/bindings.rs` pins them against it, by field order and by
    // whether each field is a pointer, as it pins the reader's structs in `Cad.java`. A
    // field left out or reordered still compiles and reads every later field from the
    // wrong offset; the pin is what catches it. `structLayout` refuses a misaligned field
    // outright, which is why the two `paddingLayout(4)`s in EDGE are there: a 4-byte count
    // before an 8-byte pointer needs the gap the C compiler leaves (SPOT's and HIT's
    // before a double, and FACE_TRIANGLES's trailing one: the struct is as long as its
    // pointer's alignment rounds it to).

    /** {@code CadaclysmBlacksmithMesh}: a solid's triangles, borrowed from it. */
    private static final MemoryLayout MESH = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.ADDRESS.withName("normals"),
            ValueLayout.ADDRESS.withName("indices"),
            ValueLayout.JAVA_INT.withName("vertex_count"),
            ValueLayout.JAVA_INT.withName("index_count"));

    /** {@code CadaclysmBlacksmithMesh64}: the same tessellation as {@link #MESH} (the index
     *  pointer is the very one the library's f32 call gives), positions and normals
     *  unnarrowed. Pinned by {@code tests/bindings.rs}, as {@link #MESH} is. */
    private static final MemoryLayout MESH64 = MemoryLayout.structLayout(
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

    /** {@code CadaclysmBlacksmithColours}: one colour per edge polyline, three doubles each
     *  ({@code -1} where the polyline is on no coloured edge); {@code rgb} null and {@code count}
     *  0 where the solid has no edge paint. Trailing padding the same shape as {@link
     *  #FACE_TRIANGLES}'s: a pointer then one {@code u32} rounds up to 16 bytes. */
    private static final MemoryLayout COLOURS = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("rgb"),
            ValueLayout.JAVA_INT.withName("count"),
            MemoryLayout.paddingLayout(4));

    /** {@code CadaclysmBlacksmithEdge}: one edge, borrowed from its solid. */
    private static final MemoryLayout EDGE = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("kind"),
            ValueLayout.ADDRESS.withName("faces"),
            ValueLayout.JAVA_INT.withName("face_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("segments"),
            ValueLayout.JAVA_INT.withName("segment_count"),
            MemoryLayout.paddingLayout(4));

    /** {@code CadaclysmBlacksmithFaceTriangles}: triangles per face, in face order, over the
     *  solid's mesh at the same tolerance. */
    private static final MemoryLayout FACE_TRIANGLES = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("counts"),
            ValueLayout.JAVA_INT.withName("face_count"),
            MemoryLayout.paddingLayout(4));

    /** {@code CadaclysmBlacksmithPoint}. */
    private static final MemoryLayout POINT = MemoryLayout.structLayout(
            ValueLayout.JAVA_DOUBLE.withName("x"),
            ValueLayout.JAVA_DOUBLE.withName("y"),
            ValueLayout.JAVA_DOUBLE.withName("z"));

    /** {@code CadaclysmBlacksmithSpot}: four bytes of padding after {@code face}. */
    private static final MemoryLayout SPOT = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("loop_index"),
            ValueLayout.JAVA_INT.withName("segment"),
            ValueLayout.JAVA_DOUBLE.withName("t"),
            ValueLayout.JAVA_INT.withName("face"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.JAVA_DOUBLE.withName("u"),
            ValueLayout.JAVA_DOUBLE.withName("v"));

    /** {@code CadaclysmBlacksmithHit}: six bytes of padding after the two one-byte bools. */
    private static final MemoryLayout HIT = MemoryLayout.structLayout(
            ValueLayout.JAVA_BOOLEAN.withName("run"),
            ValueLayout.JAVA_BOOLEAN.withName("touch"),
            MemoryLayout.paddingLayout(6),
            POINT.withName("start"),
            POINT.withName("end"),
            SPOT.withName("a_start"),
            SPOT.withName("a_end"),
            SPOT.withName("b_start"),
            SPOT.withName("b_end"));

    /** {@code CadaclysmBlacksmithCurve}: one edge's exact curve, borrowed from its solid; four
     *  bytes of padding after {@code degree} and after each count. */
    private static final MemoryLayout CURVE = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("kind"),
            POINT.withName("origin"),
            POINT.withName("x"),
            POINT.withName("y"),
            POINT.withName("z"),
            ValueLayout.JAVA_DOUBLE.withName("radius"),
            ValueLayout.JAVA_DOUBLE.withName("radius2"),
            ValueLayout.JAVA_DOUBLE.withName("t0"),
            ValueLayout.JAVA_DOUBLE.withName("t1"),
            ValueLayout.JAVA_INT.withName("degree"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("knots"),
            ValueLayout.JAVA_INT.withName("knot_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("poles"),
            ValueLayout.JAVA_INT.withName("pole_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("weights"));

    /** {@code CadaclysmBlacksmithChain}: one branch of one face pair's crossing, borrowed from
     *  the intersection result; one byte of padding after {@code has_curve}. */
    private static final MemoryLayout CHAIN = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("points"),
            ValueLayout.JAVA_INT.withName("point_count"),
            ValueLayout.JAVA_INT.withName("face_a"),
            ValueLayout.JAVA_INT.withName("face_b"),
            ValueLayout.JAVA_BOOLEAN.withName("closed"),
            ValueLayout.JAVA_BOOLEAN.withName("tangent"),
            ValueLayout.JAVA_BOOLEAN.withName("has_curve"),
            MemoryLayout.paddingLayout(1));

    /** {@code CadaclysmBlacksmithOverlap}: a coincident face pair's shared region, borrowed
     *  from the intersection result. */
    private static final MemoryLayout OVERLAP = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("face_a"),
            ValueLayout.JAVA_INT.withName("face_b"),
            ValueLayout.ADDRESS.withName("points"),
            ValueLayout.ADDRESS.withName("loop_offsets"),
            ValueLayout.JAVA_INT.withName("point_count"),
            ValueLayout.JAVA_INT.withName("loop_count"));

    /**
     * {@code CadaclysmBlacksmithSvgOptions}. {@code cadaclysm_blacksmith_svg_options_init}
     * fills the whole struct, so this must be at least as long as the header's and may never
     * reorder. Not padded between {@code up} and {@code azimuth} -- two {@code int}s already
     * land the first {@code double} on an eight-byte boundary -- but four bytes trail {@code
     * flags} to bring the 84-byte struct up to the next multiple of eight, as alignment needs.
     * Pinned by {@code tests/bindings.rs}.
     */
    private static final MemoryLayout SVG_OPTIONS = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            ValueLayout.JAVA_INT.withName("up"),
            ValueLayout.JAVA_DOUBLE.withName("azimuth"),
            ValueLayout.JAVA_DOUBLE.withName("elevation"),
            ValueLayout.JAVA_DOUBLE.withName("fov"),
            ValueLayout.JAVA_DOUBLE.withName("width"),
            ValueLayout.JAVA_DOUBLE.withName("height"),
            ValueLayout.JAVA_DOUBLE.withName("margin"),
            ValueLayout.JAVA_DOUBLE.withName("tolerance"),
            ValueLayout.JAVA_DOUBLE.withName("stroke_width"),
            ValueLayout.JAVA_INT.withName("stroke"),
            ValueLayout.JAVA_INT.withName("background"),
            ValueLayout.JAVA_INT.withName("flags"),
            MemoryLayout.paddingLayout(4));

    /** A named field's byte offset in one of the struct layouts above. */
    private static long offset(MemoryLayout struct, String field) {
        return struct.byteOffset(MemoryLayout.PathElement.groupElement(field));
    }

    // ---- loading the library, and every entry point ----------------------------------
    //
    // The same entry points Python's `cadaclysm_blacksmith.py` declares, no more and no less;
    // `tests/bindings.rs` compares the two sets by name (every quoted
    // cadaclysm_blacksmith_ string in this file) and holds Java to Python's.

    private static final MethodHandle LAST_ERROR, LICENSE_SET, LICENSE_INFO, LICENSE_NOTICE_COUNT,
            BUILD_DATE, VERSION, SOLID_FREE, PROFILE_FREE, PROFILE_RECT, PROFILE_CIRCLE,
            PROFILE_SLOT, PROFILE_POLYGON, PROFILE_REGULAR_POLYGON, PROFILE_STAR, PROFILE_SPLINE, PROFILE_WITH_HOLE, PROFILE_HITS, HITS_FREE, HIT_COUNT, HIT_AT, SOLID_PROFILE_HITS, HITS_PIECE_COUNT, HITS_PIECE, HITS_PIECE_PROFILE, PROFILE_COMMON, PROFILE_TEXT, PROFILE_LIST_COUNT, PROFILE_LIST_GET, PROFILE_LIST_FREE, TRANSLATE_PROFILE, PROFILE_ROUND, PROFILE_CHAIN, PROFILE_FROM_LOOPS, PROFILE_CLOSE_LOOP, PROFILE_PIECE_COUNT, PROFILE_PIECE, PROFILE_TRIM_COUNT, PROFILE_TRIM_CHAIN, PROFILE_POLYLINES, PATH_BEGIN,
            PATH_LINE_TO, PATH_ARC_TO, PATH_BEZIER_TO, PATH_CONIC_TO, PATH_PARABOLA_BY_VERTEX, PATH_PARABOLA_BY_FOCUS, PATH_PARABOLA, PATH_NURBS_TO, PATH_END, PATH_END_OPEN,
            PATH_FREE, CUBOID, CYLINDER, CONE, SPHERE, TORUS, WEDGE, EXTRUDE, EXTRUDE_OPEN,
            EXTRUDE_TAPERED, EXTRUDE_OPEN_TAPERED, EXTRUDE_BETWEEN, EXTRUDE_OPEN_BETWEEN,
            SLANT_OF_PLANE, FRAME_MIDPLANE, FRAME_THROUGH, LOFT, LOFT_OPEN, LOFT_THROUGH, LOFT_THROUGH_OPEN, REVOLVE, REVOLVE_OPEN, REVOLVE_IN_PLANE, REVOLVE_OPEN_IN_PLANE, SWEEP_PATH_BEGIN,
            SWEEP_PATH_LINE_TO, SWEEP_PATH_ARC, SWEEP_PATH_ALONG, SWEEP_PATH_FREE, SWEEP, SWEEP_OPEN,
            EXTRUDE_FACES, FACE, FACE_SHEET, DROP_FACES, PLACE, TRANSLATE, ROTATE, MIRROR, JOIN, CUT,
            COMMON, SPLIT_SHEET, TRIM, FILLET, CHAMFER,
            SHELL, THICKEN, PUSH_PULL, PUSH_PULL_FACES, MERGE_FLUSH, REFILLET, UNFILLET, RECHAMFER, UNCHAMFER, COIL, PIPE, SPLIT, SPLIT_BY_PLANE, LUMP_COUNT, LUMP, FACE_COUNT, SELECT_FACE, FACE_FRAME, FACE_REF, FIND_FACE, FACE_KIND, COLOURED, COLOUR,
            PROFILE_COLOURED, PROFILE_COLOUR, EDGES_COLOURED, EDGE_COLOUR, EDGE_POLYLINE_COLOURS,
            EDGE_COUNT, EDGE_AT, EDGE_CURVE, INTERSECT, INTERSECTION_FREE, INTERSECTION_CHAIN_COUNT, INTERSECTION_CHAIN, INTERSECTION_CURVE, INTERSECTION_OVERLAP_COUNT, INTERSECTION_OVERLAP, MESH_AT, MESH_FACE_TRIANGLES,
            EDGE_POLYLINES, BOUNDS, LEAKED_EDGES, UNPAIRED_EDGES, MANIFOLD, STEP, SAT_TEXT, SAT, BREP_TEXT, BREP, STRING_FREE, FROM_BREP,
            BREP_LAYOUT_ID, SVG_OPTIONS_INIT, SVG_TEXT, SVG, DRAWING_SVG_TEXT, DRAWING_SVG,
            MESH_AT64, BOUNDS64;

    static {
        SymbolLookup lib = library();
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
        PROFILE_REGULAR_POLYGON = bind(linker, lib, "cadaclysm_blacksmith_profile_regular_polygon", FunctionDescriptor.of(A, D, D, D, I, D));
        PROFILE_STAR = bind(linker, lib, "cadaclysm_blacksmith_profile_star", FunctionDescriptor.of(A, D, D, D, D, I, D));
        PROFILE_SPLINE = bind(linker, lib, "cadaclysm_blacksmith_profile_spline", FunctionDescriptor.of(A, A, L, I, A, B));
        PROFILE_WITH_HOLE = bind(linker, lib, "cadaclysm_blacksmith_profile_with_hole", FunctionDescriptor.of(A, A, A));
        PROFILE_HITS = bind(linker, lib, "cadaclysm_blacksmith_profile_hits", FunctionDescriptor.of(A, A, A, D));
        HITS_FREE = bind(linker, lib, "cadaclysm_blacksmith_hits_free", FunctionDescriptor.ofVoid(A));
        HIT_COUNT = bind(linker, lib, "cadaclysm_blacksmith_hit_count", FunctionDescriptor.of(I, A));
        PROFILE_COMMON = bind(linker, lib, "cadaclysm_blacksmith_profile_common", FunctionDescriptor.of(A, A, A, D));
        PROFILE_TEXT = bind(linker, lib, "cadaclysm_blacksmith_profile_text", FunctionDescriptor.of(A, A, D, A, A, L, A, A, D, A));
        PROFILE_LIST_COUNT = bind(linker, lib, "cadaclysm_blacksmith_profile_list_count", FunctionDescriptor.of(I, A));
        PROFILE_LIST_GET = bind(linker, lib, "cadaclysm_blacksmith_profile_list_get", FunctionDescriptor.of(A, A, I));
        PROFILE_LIST_FREE = bind(linker, lib, "cadaclysm_blacksmith_profile_list_free", FunctionDescriptor.ofVoid(A));
        HIT_AT = bind(linker, lib, "cadaclysm_blacksmith_hit", FunctionDescriptor.of(B, A, I, A));
        SOLID_PROFILE_HITS = bind(linker, lib, "cadaclysm_blacksmith_solid_profile_hits", FunctionDescriptor.of(A, A, A, A, D, A, A));
        HITS_PIECE_COUNT = bind(linker, lib, "cadaclysm_blacksmith_hits_piece_count", FunctionDescriptor.of(I, A));
        HITS_PIECE = bind(linker, lib, "cadaclysm_blacksmith_hits_piece", FunctionDescriptor.of(B, A, I, A, A, A));
        HITS_PIECE_PROFILE = bind(linker, lib, "cadaclysm_blacksmith_hits_piece_profile", FunctionDescriptor.of(A, A, I));
        TRANSLATE_PROFILE = bind(linker, lib, "cadaclysm_blacksmith_translate_profile", FunctionDescriptor.of(A, A, D, D));
        PROFILE_ROUND = bind(linker, lib, "cadaclysm_blacksmith_profile_round", FunctionDescriptor.of(A, A, D, A, L, B));
        PROFILE_CHAIN = bind(linker, lib, "cadaclysm_blacksmith_profile_chain", FunctionDescriptor.of(A, A, L, D));
        PROFILE_FROM_LOOPS = bind(linker, lib, "cadaclysm_blacksmith_profile_from_loops", FunctionDescriptor.of(A, A, L));
        PROFILE_PIECE_COUNT = bind(linker, lib, "cadaclysm_blacksmith_profile_piece_count", FunctionDescriptor.of(I, A, A, L, D));
        PROFILE_PIECE = bind(linker, lib, "cadaclysm_blacksmith_profile_piece", FunctionDescriptor.of(A, A, A, L, I, D));
        PROFILE_TRIM_COUNT = bind(linker, lib, "cadaclysm_blacksmith_profile_trim_count", FunctionDescriptor.of(I, A, A, L, I, D));
        PROFILE_TRIM_CHAIN = bind(linker, lib, "cadaclysm_blacksmith_profile_trim_chain", FunctionDescriptor.of(A, A, A, L, I, I, D));
        PROFILE_CLOSE_LOOP = bind(linker, lib, "cadaclysm_blacksmith_profile_close_loop", FunctionDescriptor.of(A, A));
        PROFILE_POLYLINES = bind(linker, lib, "cadaclysm_blacksmith_profile_polylines", FunctionDescriptor.of(POLYLINES, A, D));
        PATH_BEGIN = bind(linker, lib, "cadaclysm_blacksmith_path_begin", FunctionDescriptor.of(A, D, D));
        PATH_LINE_TO = bind(linker, lib, "cadaclysm_blacksmith_path_line_to", FunctionDescriptor.of(B, A, D, D));
        PATH_ARC_TO = bind(linker, lib, "cadaclysm_blacksmith_path_arc_to", FunctionDescriptor.of(B, A, D, D, D, D, B));
        PATH_BEZIER_TO = bind(linker, lib, "cadaclysm_blacksmith_path_bezier_to", FunctionDescriptor.of(B, A, D, D, D, D, D, D));
        PATH_CONIC_TO = bind(linker, lib, "cadaclysm_blacksmith_path_conic_to", FunctionDescriptor.of(B, A, D, D, D, D, D));
        PATH_PARABOLA_BY_VERTEX = bind(linker, lib, "cadaclysm_blacksmith_path_parabola_by_vertex", FunctionDescriptor.of(B, A, D, D, D, D));
        PATH_PARABOLA_BY_FOCUS = bind(linker, lib, "cadaclysm_blacksmith_path_parabola_by_focus", FunctionDescriptor.of(B, A, D, D, D, D));
        PATH_PARABOLA = bind(linker, lib, "cadaclysm_blacksmith_path_parabola", FunctionDescriptor.of(A, D, D, D, D, D, D, D));
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
        FRAME_MIDPLANE = bind(linker, lib, "cadaclysm_blacksmith_frame_midplane", FunctionDescriptor.of(B, A, A, A));
        FRAME_THROUGH = bind(linker, lib, "cadaclysm_blacksmith_frame_through", FunctionDescriptor.of(B, A, A, A, A));
        LOFT = bind(linker, lib, "cadaclysm_blacksmith_loft", FunctionDescriptor.of(A, A, A, A, A));
        LOFT_OPEN = bind(linker, lib, "cadaclysm_blacksmith_loft_open", FunctionDescriptor.of(A, A, A, A, A));
        LOFT_THROUGH = bind(linker, lib, "cadaclysm_blacksmith_loft_through", FunctionDescriptor.of(A, A, A, L));
        LOFT_THROUGH_OPEN = bind(linker, lib, "cadaclysm_blacksmith_loft_through_open", FunctionDescriptor.of(A, A, A, L));
        REVOLVE = bind(linker, lib, "cadaclysm_blacksmith_revolve", FunctionDescriptor.of(A, A, A, D));
        REVOLVE_OPEN = bind(linker, lib, "cadaclysm_blacksmith_revolve_open", FunctionDescriptor.of(A, A, A, D));
        REVOLVE_IN_PLANE = bind(linker, lib, "cadaclysm_blacksmith_revolve_in_plane", FunctionDescriptor.of(A, A, A, A, D));
        REVOLVE_OPEN_IN_PLANE = bind(linker, lib, "cadaclysm_blacksmith_revolve_open_in_plane", FunctionDescriptor.of(A, A, A, A, D));
        SWEEP_PATH_BEGIN = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_begin", FunctionDescriptor.of(A, D, D, D));
        SWEEP_PATH_LINE_TO = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_line_to", FunctionDescriptor.of(B, A, D, D, D));
        SWEEP_PATH_ARC = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_arc", FunctionDescriptor.of(B, A, D, D, D, D, D, D, D));
        SWEEP_PATH_ALONG = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_along", FunctionDescriptor.of(A, A, A, D, B));
        SWEEP_PATH_FREE = bind(linker, lib, "cadaclysm_blacksmith_sweep_path_free", FunctionDescriptor.ofVoid(A));
        SWEEP = bind(linker, lib, "cadaclysm_blacksmith_sweep", FunctionDescriptor.of(A, A, A, A));
        SWEEP_OPEN = bind(linker, lib, "cadaclysm_blacksmith_sweep_open", FunctionDescriptor.of(A, A, A, A));
        EXTRUDE_FACES = bind(linker, lib, "cadaclysm_blacksmith_extrude_faces", FunctionDescriptor.of(A, A, D));
        FACE = bind(linker, lib, "cadaclysm_blacksmith_face", FunctionDescriptor.of(A, A, A));
        FACE_SHEET = bind(linker, lib, "cadaclysm_blacksmith_face_sheet", FunctionDescriptor.of(A, A, I));
        DROP_FACES = bind(linker, lib, "cadaclysm_blacksmith_drop_faces", FunctionDescriptor.of(A, A, A, L));
        PLACE = bind(linker, lib, "cadaclysm_blacksmith_place", FunctionDescriptor.of(A, A, A));
        TRANSLATE = bind(linker, lib, "cadaclysm_blacksmith_translate", FunctionDescriptor.of(A, A, D, D, D));
        ROTATE = bind(linker, lib, "cadaclysm_blacksmith_rotate", FunctionDescriptor.of(A, A, A, D));
        MIRROR = bind(linker, lib, "cadaclysm_blacksmith_mirror", FunctionDescriptor.of(A, A, A));
        JOIN = bind(linker, lib, "cadaclysm_blacksmith_join", FunctionDescriptor.of(A, A, A, D, A, A));
        CUT = bind(linker, lib, "cadaclysm_blacksmith_cut", FunctionDescriptor.of(A, A, A, D, A, A));
        COMMON = bind(linker, lib, "cadaclysm_blacksmith_common", FunctionDescriptor.of(A, A, A, D, A, A));
        SPLIT_SHEET = bind(linker, lib, "cadaclysm_blacksmith_split_sheet", FunctionDescriptor.of(A, A, A, D, A, A));
        TRIM = bind(linker, lib, "cadaclysm_blacksmith_trim", FunctionDescriptor.of(A, A, A, B, D, A, A));
        FILLET = bind(linker, lib, "cadaclysm_blacksmith_fillet", FunctionDescriptor.of(A, A, A, L, D, D, A, A));
        CHAMFER = bind(linker, lib, "cadaclysm_blacksmith_chamfer", FunctionDescriptor.of(A, A, A, L, D, D));
        SHELL = bind(linker, lib, "cadaclysm_blacksmith_shell", FunctionDescriptor.of(A, A, D, A, L, D, A, A));
        BREP_TEXT = bind(linker, lib, "cadaclysm_blacksmith_brep_text", FunctionDescriptor.of(A, A, L));
        BREP = bind(linker, lib, "cadaclysm_blacksmith_brep", FunctionDescriptor.of(B, A, L, A));
        THICKEN = bind(linker, lib, "cadaclysm_blacksmith_thicken", FunctionDescriptor.of(A, A, D, D, A, A));
        PUSH_PULL = bind(linker, lib, "cadaclysm_blacksmith_push_pull", FunctionDescriptor.of(A, A, I, D, D, A, A));
        PUSH_PULL_FACES = bind(linker, lib, "cadaclysm_blacksmith_push_pull_faces", FunctionDescriptor.of(A, A, A, L, D, D, A, A));
        MERGE_FLUSH = bind(linker, lib, "cadaclysm_blacksmith_merge_flush", FunctionDescriptor.of(A, A));
        REFILLET = bind(linker, lib, "cadaclysm_blacksmith_refillet", FunctionDescriptor.of(A, A, I, D, D));
        UNFILLET = bind(linker, lib, "cadaclysm_blacksmith_unfillet", FunctionDescriptor.of(A, A, I));
        RECHAMFER = bind(linker, lib, "cadaclysm_blacksmith_rechamfer", FunctionDescriptor.of(A, A, I, D, D));
        UNCHAMFER = bind(linker, lib, "cadaclysm_blacksmith_unchamfer", FunctionDescriptor.of(A, A, I));
        COIL = bind(linker, lib, "cadaclysm_blacksmith_coil", FunctionDescriptor.of(A, A, A, D, D));
        PIPE = bind(linker, lib, "cadaclysm_blacksmith_pipe", FunctionDescriptor.of(A, A, D, D));
        SPLIT = bind(linker, lib, "cadaclysm_blacksmith_split", FunctionDescriptor.of(A, A, A, D, A, A));
        SPLIT_BY_PLANE = bind(linker, lib, "cadaclysm_blacksmith_split_by_plane", FunctionDescriptor.of(A, A, A, D, A, A));
        LUMP_COUNT = bind(linker, lib, "cadaclysm_blacksmith_lump_count", FunctionDescriptor.of(I, A));
        LUMP = bind(linker, lib, "cadaclysm_blacksmith_lump", FunctionDescriptor.of(A, A, I));
        FACE_COUNT = bind(linker, lib, "cadaclysm_blacksmith_face_count", FunctionDescriptor.of(I, A));
        SELECT_FACE = bind(linker, lib, "cadaclysm_blacksmith_select_face", FunctionDescriptor.of(I, A, I, A, I));
        FACE_FRAME = bind(linker, lib, "cadaclysm_blacksmith_face_frame", FunctionDescriptor.of(B, A, I, A));
        FACE_REF = bind(linker, lib, "cadaclysm_blacksmith_face_ref", FunctionDescriptor.of(B, A, I, A));
        FIND_FACE = bind(linker, lib, "cadaclysm_blacksmith_find_face", FunctionDescriptor.of(I, A, A, I, D));
        FACE_KIND = bind(linker, lib, "cadaclysm_blacksmith_face_kind", FunctionDescriptor.of(A, A, I));
        COLOURED = bind(linker, lib, "cadaclysm_blacksmith_coloured", FunctionDescriptor.of(A, A, I, D, D, D));
        COLOUR = bind(linker, lib, "cadaclysm_blacksmith_colour", FunctionDescriptor.of(B, A, I, A));
        PROFILE_COLOURED = bind(linker, lib, "cadaclysm_blacksmith_profile_coloured", FunctionDescriptor.of(A, A, D, D, D));
        PROFILE_COLOUR = bind(linker, lib, "cadaclysm_blacksmith_profile_colour", FunctionDescriptor.of(B, A, A));
        EDGES_COLOURED = bind(linker, lib, "cadaclysm_blacksmith_edges_coloured", FunctionDescriptor.of(A, A, A, L, D, D, D));
        EDGE_COLOUR = bind(linker, lib, "cadaclysm_blacksmith_edge_colour", FunctionDescriptor.of(B, A, I, A));
        EDGE_POLYLINE_COLOURS = bind(linker, lib, "cadaclysm_blacksmith_edge_polyline_colours", FunctionDescriptor.of(COLOURS, A, D));
        EDGE_COUNT = bind(linker, lib, "cadaclysm_blacksmith_edge_count", FunctionDescriptor.of(I, A));
        EDGE_AT = bind(linker, lib, "cadaclysm_blacksmith_edge", FunctionDescriptor.of(B, A, I, A));
        EDGE_CURVE = bind(linker, lib, "cadaclysm_blacksmith_edge_curve", FunctionDescriptor.of(B, A, I, A));
        INTERSECT = bind(linker, lib, "cadaclysm_blacksmith_intersect", FunctionDescriptor.of(A, A, A, D, A, A));
        INTERSECTION_FREE = bind(linker, lib, "cadaclysm_blacksmith_intersection_free", FunctionDescriptor.ofVoid(A));
        INTERSECTION_CHAIN_COUNT = bind(linker, lib, "cadaclysm_blacksmith_intersection_chain_count", FunctionDescriptor.of(I, A));
        INTERSECTION_CHAIN = bind(linker, lib, "cadaclysm_blacksmith_intersection_chain", FunctionDescriptor.of(B, A, I, A));
        INTERSECTION_CURVE = bind(linker, lib, "cadaclysm_blacksmith_intersection_curve", FunctionDescriptor.of(B, A, I, A));
        INTERSECTION_OVERLAP_COUNT = bind(linker, lib, "cadaclysm_blacksmith_intersection_overlap_count", FunctionDescriptor.of(I, A));
        INTERSECTION_OVERLAP = bind(linker, lib, "cadaclysm_blacksmith_intersection_overlap", FunctionDescriptor.of(B, A, I, A));
        MESH_AT = bind(linker, lib, "cadaclysm_blacksmith_mesh", FunctionDescriptor.of(MESH, A, D));
        MESH_FACE_TRIANGLES = bind(linker, lib, "cadaclysm_blacksmith_mesh_face_triangles", FunctionDescriptor.of(FACE_TRIANGLES, A, D));
        EDGE_POLYLINES = bind(linker, lib, "cadaclysm_blacksmith_edge_polylines", FunctionDescriptor.of(POLYLINES, A, D));
        BOUNDS = bind(linker, lib, "cadaclysm_blacksmith_bounds", FunctionDescriptor.of(B, A, D, A, A));
        LEAKED_EDGES = bind(linker, lib, "cadaclysm_blacksmith_leaked_edges", FunctionDescriptor.of(I, A, D));
        UNPAIRED_EDGES = bind(linker, lib, "cadaclysm_blacksmith_unpaired_edges", FunctionDescriptor.of(I, A, D));
        MANIFOLD = bind(linker, lib, "cadaclysm_blacksmith_manifold", FunctionDescriptor.of(B, A, A));
        STEP = bind(linker, lib, "cadaclysm_blacksmith_step", FunctionDescriptor.of(A, A, L, A, I));
        SAT_TEXT = bind(linker, lib, "cadaclysm_blacksmith_sat_text", FunctionDescriptor.of(A, A, L, I));
        SAT = bind(linker, lib, "cadaclysm_blacksmith_sat", FunctionDescriptor.of(B, A, L, A, I));
        STRING_FREE = bind(linker, lib, "cadaclysm_blacksmith_string_free", FunctionDescriptor.ofVoid(A));
        FROM_BREP = bind(linker, lib, "cadaclysm_blacksmith_from_brep", FunctionDescriptor.of(A, A, A));
        BREP_LAYOUT_ID = bind(linker, lib, "cadaclysm_blacksmith_brep_layout_id", FunctionDescriptor.of(A));
        SVG_OPTIONS_INIT = bind(linker, lib, "cadaclysm_blacksmith_svg_options_init", FunctionDescriptor.ofVoid(A));
        SVG_TEXT = bind(linker, lib, "cadaclysm_blacksmith_svg_text", FunctionDescriptor.of(A, A, L, A));
        SVG = bind(linker, lib, "cadaclysm_blacksmith_svg", FunctionDescriptor.of(B, A, L, A, A));
        DRAWING_SVG_TEXT = bind(linker, lib, "cadaclysm_blacksmith_drawing_svg_text", FunctionDescriptor.of(A, A, L, A, L, A));
        DRAWING_SVG = bind(linker, lib, "cadaclysm_blacksmith_drawing_svg", FunctionDescriptor.of(B, A, L, A, L, A, A));
        MESH_AT64 = bind(linker, lib, "cadaclysm_blacksmith_mesh64", FunctionDescriptor.of(MESH64, A, D));
        BOUNDS64 = bind(linker, lib, "cadaclysm_blacksmith_bounds64", FunctionDescriptor.of(B, A, D, A, A));
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

    /** How the loaded library lays a brep out in memory: its compiler, target and source.
     *  {@code Solid.fromNode} works only where this equals the reader library's {@code
     *  Cad.Brep.layoutId()} -- the two from the same release. */
    public static String brepLayoutId() {
        return string(call(() -> (MemorySegment) BREP_LAYOUT_ID.invokeExact()));
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

    @SuppressWarnings("restricted")
    private static DoubleBuffer doubleView(long address, long count) {
        if (address == 0 || count == 0) return DoubleBuffer.allocate(0).asReadOnlyBuffer();
        return MemorySegment.ofAddress(address).reinterpret(count * Double.BYTES)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asDoubleBuffer().asReadOnlyBuffer();
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

    private static double[] toArray(DoubleBuffer view) {
        double[] out = new double[view.remaining()];
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

    /**
     * The kernel library, found by {@code cadaclysm_blacksmith.py}'s own rule, {@code
     * library_path()}: {@code CADACLYSM_BLACKSMITH_LIBRARY} (the library, or a directory
     * holding it) and nothing else if it is set; else beside this class's own jar or class
     * directory; else {@code lib/} in any ancestor (the SDK layout); else {@code
     * target/release} or {@code target/debug} in any ancestor (this repository's). Nothing
     * found is a {@link BuildException} naming every place looked, as Python's {@code
     * BuildError} does -- never the platform's own search, which would load whatever copy
     * happens to be on the path.
     */
    @SuppressWarnings("restricted") // libraryLookup: the library this file binds.
    private static SymbolLookup library() {
        String os = System.getProperty("os.name", "").toLowerCase();
        String name = os.contains("win") ? "cadaclysm_blacksmith.dll"
                : os.contains("mac") ? "libcadaclysm_blacksmith.dylib" : "libcadaclysm_blacksmith.so";
        String override = System.getenv("CADACLYSM_BLACKSMITH_LIBRARY");
        if (override != null && !override.isEmpty()) {
            // A directory or the library itself, since both are things to point at.
            java.nio.file.Path candidate = java.nio.file.Path.of(override);
            if (Files.isDirectory(candidate)) candidate = candidate.resolve(name);
            if (Files.exists(candidate)) return SymbolLookup.libraryLookup(candidate, Cad.Loader.ARENA);
            throw new BuildException("CADACLYSM_BLACKSMITH_LIBRARY=" + override + " names nothing that exists");
        }
        java.nio.file.Path start = Cad.Loader.codeLocation();
        java.nio.file.Path here = start == null || Files.isDirectory(start) ? start : start.getParent();
        List<java.nio.file.Path> ancestors = new ArrayList<>();
        for (java.nio.file.Path at = here; at != null; at = at.getParent()) ancestors.add(at);
        List<java.nio.file.Path> searched = new ArrayList<>();
        if (here != null) searched.add(here.resolve(name));
        // Walking up from this class's code: an SDK checkout keeps the library in `lib/`
        // beside the wrappers; the repository this example ships in keeps it in
        // `target/release` (or `target/debug`, a fallback for a machine that only built that).
        for (java.nio.file.Path at : ancestors) searched.add(at.resolve("lib").resolve(name));
        for (java.nio.file.Path at : ancestors) {
            searched.add(at.resolve("target").resolve("release").resolve(name));
            searched.add(at.resolve("target").resolve("debug").resolve(name));
        }
        for (java.nio.file.Path candidate : searched) {
            if (Files.exists(candidate)) return SymbolLookup.libraryLookup(candidate, Cad.Loader.ARENA);
        }
        StringBuilder message = new StringBuilder(name).append(" not found. Looked in:\n");
        for (java.nio.file.Path candidate : searched) message.append("    ").append(candidate).append('\n');
        message.append("Build it with:\n    cargo build --release -p cadaclysm-blacksmith-capi\n")
                .append("or run fetch.py in an SDK checkout, or point CADACLYSM_BLACKSMITH_LIBRARY at it.");
        throw new BuildException(message.toString());
    }

    /** How many unlicensed notices this library has printed to stderr in this process. */
    public static long licenseNoticeCount() {
        return call(() -> (long) LICENSE_NOTICE_COUNT.invokeExact());
    }

    /**
     * {@code schemas/ap203.exp}: {@code CADACLYSM_SCHEMAS/ap203.exp} if set, else the
     * repository's, found by walking up from this class's own code the way the loader finds
     * the library.
     *
     * <p>The {@code ap203.exp} file this finds is no longer needed: the kernel writes
     * against its built-in AP203 when no schema is given. This method stays for
     * compatibility and the parity gates; nothing here calls it to write STEP any more.
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
        throw new BuildException("ap203.exp not found (none is needed to write STEP: leave schema out for the "
                + "built-in AP203, or pass a schema name, a .exp path or EXPRESS text)");
    }

    // ---- SVG --------------------------------------------------------------------------

    /**
     * One of the seven camera angles {@link SvgOptions#view()} understands -- the same table
     * the reader's {@code Cad.SvgView} gives, kept separate because this file is the whole
     * kernel binding on its own. Each constant carries its own (azimuth, elevation) in degrees.
     */
    public enum SvgView {
        /** Azimuth -90, elevation 0 -- looks from -Y. */
        FRONT(-90.0, 0.0),
        /** Azimuth 90, elevation 0 -- looks from +Y. */
        BACK(90.0, 0.0),
        /** Azimuth 180, elevation 0 -- looks from -X. */
        LEFT(180.0, 0.0),
        /** Azimuth 0, elevation 0 -- looks from +X. */
        RIGHT(0.0, 0.0),
        /** Azimuth -90, elevation 90 -- looks from +Z, straight down. */
        TOP(-90.0, 90.0),
        /** Azimuth -90, elevation -90 -- looks from -Z, straight up. */
        BOTTOM(-90.0, -90.0),
        /** Azimuth -50, elevation 28 -- the viewer's own default. */
        ISO(-50.0, 28.0);

        /** Degrees about the up axis from +X: -90 looks from -Y, the front. */
        public final double azimuth;
        /** Degrees above the horizon. */
        public final double elevation;

        SvgView(double azimuth, double elevation) {
            this.azimuth = azimuth;
            this.elevation = elevation;
        }
    }

    /**
     * How an SVG drawing is made -- the camera in the viewer's words, the page, the pen and
     * which line sets. Mirrors {@code CadaclysmBlacksmithSvgOptions}, {@link #defaults()} the
     * way {@code cadaclysm_blacksmith_svg_options_init} defaults the struct, with {@link
     * #view()} supplying {@link #azimuth()}/{@link #elevation()} unless they are given directly
     * (non-null). No scene convention to default {@link #up()} from here -- a solid's own
     * frame is Z up unless {@link #up()} says otherwise.
     *
     * <p>Passed to {@link #writeSvgText}, {@link #writeSvg} and {@link Solid#svgText}/{@link
     * Solid#svg}. A refused option (an out-of-range {@link #fov()}, say) throws {@link
     * BuildException} naming the field, worded by the library itself.
     */
    public record SvgOptions(SvgView view, Double azimuth, Double elevation, String up, double fov,
                              double width, double height, double margin, double tolerance,
                              String stroke, double strokeWidth, Integer background,
                              boolean edges, boolean curves, boolean isocurves, boolean polylines) {
        /**
         * {@code view = ISO}, {@code azimuth}/{@code elevation}/{@code up}/{@code background}
         * null (fall through to {@link #view()}, "z", and transparent), {@code fov = 0}
         * (orthographic), a 1000-square page, {@code margin = 0.05}, {@code tolerance = 0.1}, a
         * black one-unit stroke, edges alone.
         */
        public static SvgOptions defaults() {
            return defaults(SvgView.ISO);
        }

        /** {@link #defaults()}, but with {@code view} in place of {@link SvgView#ISO} --
         *  {@link Profile#svgText} and {@link Profile#svg} use this to default to {@link
         *  SvgView#TOP} without repeating the other eleven fields. */
        private static SvgOptions defaults(SvgView view) {
            return new SvgOptions(view, null, null, null, 0.0, 1000.0, 1000.0, 0.05, 0.1,
                    "#000000", 1.0, null, true, false, false, false);
        }
    }

    /** A colour as the ABI's packed {@code 0xRRGGBB}: {@code "#rrggbb"}, the leading {@code #}
     *  optional. */
    private static int parseColour(String colour) {
        String hex = colour.startsWith("#") ? colour.substring(1) : colour;
        if (hex.length() != 6) throw new BuildException("colour " + colour + ": expected '#rrggbb'");
        try {
            return (int) Long.parseLong(hex, 16);
        } catch (NumberFormatException e) {
            throw new BuildException("colour " + colour + ": expected '#rrggbb'");
        }
    }

    /**
     * {@link SvgOptions}, packed into the {@link #SVG_OPTIONS} layout: {@code view} fills
     * {@code azimuth}/{@code elevation} unless they are given directly, {@code up} defaults to
     * "z" (a solid carries no convention of its own), colours are {@code "#rrggbb"} -- as the
     * reader's own {@code Cad.buildSvgOptions}, but with no scene to default {@code up} from.
     */
    private static MemorySegment buildSvgOptions(Arena arena, SvgOptions options) {
        SvgOptions o = options == null ? SvgOptions.defaults() : options;
        MemorySegment out = arena.allocate(SVG_OPTIONS);
        call(() -> {
            SVG_OPTIONS_INIT.invokeExact(out);
            return null;
        });
        SvgView view = o.view() == null ? SvgView.ISO : o.view();
        String up = o.up() == null ? "z" : o.up();
        out.set(ValueLayout.JAVA_INT, offset(SVG_OPTIONS, "up"), up.equalsIgnoreCase("y") ? 1 : 0);
        out.set(ValueLayout.JAVA_DOUBLE, offset(SVG_OPTIONS, "azimuth"), o.azimuth() == null ? view.azimuth : o.azimuth());
        out.set(ValueLayout.JAVA_DOUBLE, offset(SVG_OPTIONS, "elevation"), o.elevation() == null ? view.elevation : o.elevation());
        out.set(ValueLayout.JAVA_DOUBLE, offset(SVG_OPTIONS, "fov"), o.fov());
        out.set(ValueLayout.JAVA_DOUBLE, offset(SVG_OPTIONS, "width"), o.width());
        out.set(ValueLayout.JAVA_DOUBLE, offset(SVG_OPTIONS, "height"), o.height());
        out.set(ValueLayout.JAVA_DOUBLE, offset(SVG_OPTIONS, "margin"), o.margin());
        out.set(ValueLayout.JAVA_DOUBLE, offset(SVG_OPTIONS, "tolerance"), o.tolerance());
        out.set(ValueLayout.JAVA_DOUBLE, offset(SVG_OPTIONS, "stroke_width"), o.strokeWidth());
        out.set(ValueLayout.JAVA_INT, offset(SVG_OPTIONS, "stroke"), parseColour(o.stroke()));
        out.set(ValueLayout.JAVA_INT, offset(SVG_OPTIONS, "background"),
                o.background() == null ? 0xFFFFFFFF : o.background()); // CADACLYSM_BLACKSMITH_SVG_TRANSPARENT
        int flags = (o.edges() ? 1 : 0) | (o.curves() ? 2 : 0) | (o.isocurves() ? 4 : 0) | (o.polylines() ? 8 : 0);
        out.set(ValueLayout.JAVA_INT, offset(SVG_OPTIONS, "flags"), flags);
        return out;
    }

    /** {@link #writeSvgText(Collection, SvgOptions)} with every default. */
    public static String writeSvgText(Collection<Solid> solids) {
        return writeSvgText(solids, null);
    }

    /**
     * Several solids' wireframe as one SVG's text, each its own {@code <g>} -- see {@link
     * SvgOptions}. Owned by this call, decoded and released before it returns. Delegates to
     * {@link #writeSvgText(Collection, Collection, SvgOptions)} with no profiles -- the
     * drawing pair refuses in exactly the words the solids-only pair always has, so there is
     * nothing to gain from keeping two routes to the same drawing.
     */
    public static String writeSvgText(Collection<Solid> solids, SvgOptions options) {
        return writeSvgText(solids, List.of(), options);
    }

    /** {@link #writeSvg(String, Collection, SvgOptions)} with every default. */
    public static void writeSvg(String path, Collection<Solid> solids) {
        writeSvg(path, solids, null);
    }

    /** {@link #writeSvgText(Collection, SvgOptions)} written to {@code path} by the library
     *  itself. Delegates to {@link #writeSvg(String, Collection, Collection, SvgOptions)} with
     *  no profiles -- see that overload's comment on {@link #writeSvgText(Collection, SvgOptions)}
     *  for why. */
    public static void writeSvg(String path, Collection<Solid> solids, SvgOptions options) {
        writeSvg(path, solids, List.of(), options);
    }

    // No two-argument "every default" overload of writeSvgText(solids, profiles) -- with the
    // solids-only writeSvgText(Collection, SvgOptions) already occupying that arity, a call
    // passing a bare `null` for the third slot would be ambiguous between "no options" and
    // "no profiles" (neither Collection<Profile> nor SvgOptions is more specific than the
    // other). Pass `null` for `options` explicitly instead: writeSvgText(solids, profiles,
    // null).

    /**
     * Several solids' and profiles' wireframe as one SVG's text: a {@code <g id="solid-N">}
     * per solid then a {@code <g id="profile-N">} per profile, on one page, each its own
     * colour where it carries one and the options' {@link SvgOptions#stroke()} otherwise.
     * Either collection may be empty; both empty is refused. See {@link SvgOptions}. Owned by
     * this call, decoded and released before it returns.
     */
    public static String writeSvgText(Collection<Solid> solids, Collection<Profile> profiles, SvgOptions options) {
        Solid[] allSolids = solids.toArray(new Solid[0]);
        Profile[] allProfiles = profiles.toArray(new Profile[0]);
        MemorySegment raw;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment solidHandles = arena.allocate(ValueLayout.ADDRESS, Math.max(allSolids.length, 1));
            for (int i = 0; i < allSolids.length; i++) {
                solidHandles.setAtIndex(ValueLayout.ADDRESS, i, allSolids[i].handle());
            }
            MemorySegment profileHandles = arena.allocate(ValueLayout.ADDRESS, Math.max(allProfiles.length, 1));
            for (int i = 0; i < allProfiles.length; i++) {
                profileHandles.setAtIndex(ValueLayout.ADDRESS, i, allProfiles[i].handle());
            }
            MemorySegment o = buildSvgOptions(arena, options);
            long solidCount = allSolids.length;
            long profileCount = allProfiles.length;
            raw = call(() -> (MemorySegment) DRAWING_SVG_TEXT.invokeExact(solidHandles, solidCount, profileHandles, profileCount, o));
        } finally {
            keep((Object[]) allSolids);
            keep((Object[]) allProfiles);
        }
        if (raw.address() == 0) throw failure("svg_text");
        try {
            return string(raw);
        } finally {
            call(() -> {
                STRING_FREE.invokeExact(raw);
                return null;
            });
        }
    }

    // No three-argument "every default" overload of writeSvg(path, solids, profiles) either,
    // for the same reason writeSvgText(Collection, Collection) has none -- see its comment.
    // Pass `null` for `options` explicitly: writeSvg(path, solids, profiles, null).

    /** {@link #writeSvgText(Collection, Collection, SvgOptions)} written to {@code path} by
     *  the library itself. */
    public static void writeSvg(String path, Collection<Solid> solids, Collection<Profile> profiles, SvgOptions options) {
        Solid[] allSolids = solids.toArray(new Solid[0]);
        Profile[] allProfiles = profiles.toArray(new Profile[0]);
        boolean ok;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment solidHandles = arena.allocate(ValueLayout.ADDRESS, Math.max(allSolids.length, 1));
            for (int i = 0; i < allSolids.length; i++) {
                solidHandles.setAtIndex(ValueLayout.ADDRESS, i, allSolids[i].handle());
            }
            MemorySegment profileHandles = arena.allocate(ValueLayout.ADDRESS, Math.max(allProfiles.length, 1));
            for (int i = 0; i < allProfiles.length; i++) {
                profileHandles.setAtIndex(ValueLayout.ADDRESS, i, allProfiles[i].handle());
            }
            MemorySegment o = buildSvgOptions(arena, options);
            MemorySegment cPath = arena.allocateFrom(path);
            long solidCount = allSolids.length;
            long profileCount = allProfiles.length;
            ok = call(() -> (boolean) DRAWING_SVG.invokeExact(solidHandles, solidCount, profileHandles, profileCount, cPath, o));
        } finally {
            keep((Object[]) allSolids);
            keep((Object[]) allProfiles);
        }
        if (!ok) throw failure("svg");
    }

    /** {@link #writeStepText(Collection, String, String)} writing one STEP file (AP203 unless a schema is named), in millimetres. */
    public static String writeStepText(Collection<Solid> solids) {
        return writeStepText(solids, null, "mm");
    }

    /**
     * Several solids as one part file's text, each its own body.
     *
     * @param schema one of four things: null (the kernel's built-in AP203); the path of a
     *               schema file (no newline in it, naming an existing file), read and sent
     *               as EXPRESS text; the bare name of a built-in schema (case-insensitive,
     *               e.g. {@code "AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"} -- an
     *               unknown name throws {@link BuildException}); or a custom schema's own
     *               EXPRESS text
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
            String text = schemaText(schema);
            MemorySegment schemaSeg = text == null ? MemorySegment.NULL : arena.allocateFrom(text);
            long count = all.length;
            int code = unitCode;
            raw = call(() -> (MemorySegment) STEP.invokeExact(handles, count, schemaSeg, code));
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

    /** {@link #writeStep(String, Collection, String, String)} with no schema (the built-in AP203), in millimetres. */
    public static void writeStep(String path, Collection<Solid> solids) {
        writeStep(path, solids, null, "mm");
    }

    /** Several solids as one STEP file (AP203 unless {@code schema} names another), each its own body. */
    public static void writeStep(String path, Collection<Solid> solids, String schema, String unit) {
        writeText(path, writeStepText(solids, schema, unit));
    }

    private static int unitCode(String unit) {
        Integer unitCode = UNITS.get(unit);
        if (unitCode == null) {
            throw new BuildException("unit must be one of " + String.join(", ", UNITS.keySet().stream().sorted().toList()));
        }
        return unitCode;
    }

    /** {@link #writeSatText(Collection, String)} in millimetres. */
    public static String writeSatText(Collection<Solid> solids) {
        return writeSatText(solids, "mm");
    }

    /**
     * Several solids as one ACIS SAT file's text, each its own body: analytic surfaces
     * as their own records, splines and swept surfaces as exact NURBS.
     *
     * @param unit what the solids' lengths are: {@code "m"}, {@code "mm"} or {@code "in"}
     */
    public static String writeSatText(Collection<Solid> solids, String unit) {
        int code = unitCode(unit);
        Solid[] all = solids.toArray(new Solid[0]);
        MemorySegment raw;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
            for (int i = 0; i < all.length; i++) {
                handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
            }
            long count = all.length;
            raw = call(() -> (MemorySegment) SAT_TEXT.invokeExact(handles, count, code));
        } finally {
            keep((Object[]) all);
        }
        if (raw.address() == 0) throw failure("sat_text");
        try {
            return string(raw);
        } finally {
            call(() -> {
                STRING_FREE.invokeExact(raw);
                return null;
            });
        }
    }

    /** {@link #writeSat(String, Collection, String)} in millimetres. */
    public static void writeSat(String path, Collection<Solid> solids) {
        writeSat(path, solids, "mm");
    }

    /**
     * {@link #writeSatText(Collection, String)} written to {@code path} by the library
     * itself, which names the file in its refusal when it cannot.
     */
    public static void writeSat(String path, Collection<Solid> solids, String unit) {
        int code = unitCode(unit);
        Solid[] all = solids.toArray(new Solid[0]);
        boolean ok;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
            for (int i = 0; i < all.length; i++) {
                handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
            }
            MemorySegment cPath = arena.allocateFrom(path);
            long count = all.length;
            ok = call(() -> (boolean) SAT.invokeExact(handles, count, cPath, code));
        } finally {
            keep((Object[]) all);
        }
        if (!ok) throw failure("sat");
    }

    /**
     * Several solids as one OCCT {@code .brep}, each its own solid under one compound
     * (one solid is the file's root): the exact surfaces and curves, with a curve in each
     * face's own parameters for every edge, so OCCT's {@code BRepTools::Read} gives a shape
     * {@code BRepCheck_Analyzer} finds valid. No unit is declared -- a {@code .brep} carries
     * none -- so the numbers are the numbers.
     */
    public static String writeBrepText(Collection<Solid> solids) {
        Solid[] all = solids.toArray(new Solid[0]);
        MemorySegment raw;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment handles = handlesOf(arena, all);
            long count = all.length;
            raw = call(() -> (MemorySegment) BREP_TEXT.invokeExact(handles, count));
        } finally {
            keep((Object[]) all);
        }
        if (raw.address() == 0) throw failure("brep_text");
        try {
            return string(raw);
        } finally {
            call(() -> {
                STRING_FREE.invokeExact(raw);
                return null;
            });
        }
    }

    /** {@link #writeBrepText(Collection)} written to {@code path} by the library itself. */
    public static void writeBrep(String path, Collection<Solid> solids) {
        Solid[] all = solids.toArray(new Solid[0]);
        boolean ok;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment handles = handlesOf(arena, all);
            MemorySegment where = arena.allocateFrom(path);
            long count = all.length;
            ok = call(() -> (boolean) BREP.invokeExact(handles, count, where));
        } finally {
            keep((Object[]) all);
        }
        if (!ok) throw failure("brep");
    }

    /** The solids' handles laid out as the one array the ABI takes. */
    private static MemorySegment handlesOf(Arena arena, Solid[] all) {
        MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
        for (int i = 0; i < all.length; i++) {
            handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
        }
        return handles;
    }

    private static void writeText(String path, String text) {
        try {
            Files.writeString(java.nio.file.Path.of(path), text, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new BuildException(path + ": " + e.getMessage());
        }
    }

    /**
     * {@code schema} is null (the built-in AP203), the path of a schema file, a built-in
     * schema's name, or a custom schema's own EXPRESS text -- see {@link #writeStepText}.
     */
    private static String schemaText(String schema) {
        if (schema == null) return null;
        if (schema.indexOf('\n') < 0) {
            java.nio.file.Path at = schemaFilePath(schema);
            if (at != null && Files.isRegularFile(at)) {
                try {
                    return Files.readString(at, StandardCharsets.UTF_8);
                } catch (IOException e) {
                    throw new BuildException(schema + ": " + e.getMessage());
                }
            }
        }
        return schema;
    }

    /**
     * {@code schema} as a filesystem path, or null if it is not one -- not every legal
     * single-line schema is a legal path: a schema name always is, but custom EXPRESS
     * text ("SCHEMA x; ... : STRING ...") carries characters like {@code :} and {@code ;}
     * a Windows path refuses ({@link java.nio.file.InvalidPathException}). Not a path,
     * then: it falls through to the ABI as text.
     */
    private static java.nio.file.Path schemaFilePath(String schema) {
        try {
            return java.nio.file.Path.of(schema);
        } catch (java.nio.file.InvalidPathException e) {
            return null;
        }
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

        /** A closed polygon through {@code points} (two numbers each), in order, its side back
         *  to the first point a segment of its own. */
        public static Profile polygon(double[][] points) {
            double[] flat = flatten2(points, "point");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment xy = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, flat);
                long n = flat.length / 2;
                return new Profile(call(() -> (MemorySegment) PROFILE_POLYGON.invokeExact(xy, n)));
            }
        }

        /** {@link #regularPolygon(double[], double, int, double)} with its first corner on the x axis. */
        public static Profile regularPolygon(double[] centre, double radius, int sides) {
            return regularPolygon(centre, radius, sides, 0);
        }

        /** A regular polygon of {@code sides} sides (at least 3) on the circle of {@code radius}
         *  about {@code centre}, its first corner at {@code angle} radians from the sketch's x
         *  axis, the rest counter-clockwise. */
        public static Profile regularPolygon(double[] centre, double radius, int sides, double angle) {
            double[] c = point2(centre, "centre");
            int n = Math.max(0, sides);
            return new Profile(call(() -> (MemorySegment) PROFILE_REGULAR_POLYGON.invokeExact(c[0], c[1], radius, n, angle)));
        }

        /** {@link #star(double[], double, double, int, double)} with its first tip on the x axis. */
        public static Profile star(double[] centre, double outer, double inner, int points) {
            return star(centre, outer, inner, points, 0);
        }

        /** A star of {@code points} tips (at least 3) on the circle of {@code outer} about
         *  {@code centre}, its inner corners on the circle of {@code inner} (positive, under
         *  {@code outer}), alternating: the first tip at {@code angle} radians from the sketch's
         *  x axis, the rest counter-clockwise. */
        public static Profile star(double[] centre, double outer, double inner, int points, double angle) {
            double[] c = point2(centre, "centre");
            int n = Math.max(0, points);
            return new Profile(call(() -> (MemorySegment) PROFILE_STAR.invokeExact(c[0], c[1], outer, inner, n, angle)));
        }

        /** {@link #spline(double[][], int, double[], boolean)} of degree 3, open, unweighted. */
        public static Profile spline(double[][] points) {
            return spline(points, 3, null, false);
        }

        /**
         * A spline of {@code degree} through the control polygon {@code points} ({@code weights}
         * one per point, or null). Open, it starts on the first point and ends on the last -- an
         * open chain; {@code closed}, it is periodic, smooth through its own start -- a closed
         * profile. The degree is lowered to fit the points.
         */
        public static Profile spline(double[][] points, int degree, double[] weights, boolean closed) {
            double[] flat = flatten2(points, "point");
            // The library reads exactly one weight per point, whatever the array holds.
            if (weights != null && weights.length != flat.length / 2) {
                throw new BuildException("spline: " + weights.length + " weights for " + flat.length / 2
                        + " points; give one per point");
            }
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment xy = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, flat);
                MemorySegment w = weights == null ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_DOUBLE, weights.length == 0 ? new double[] {0} : weights);
                long n = flat.length / 2;
                int d = Math.max(0, degree);
                return new Profile(call(() -> (MemorySegment) PROFILE_SPLINE.invokeExact(xy, n, d, w, closed)));
            }
        }

        /** Start drawing an outline at {@code start} (two numbers), a segment at a time: the
         *  {@link Path} builder. */
        public static Path path(double[] start) {
            return new Path(start);
        }

        /** Start drawing on the arc of the parabola with {@code vertex} (two numbers), axis
         *  direction {@code axis} (two numbers) and focal length {@code focal}, over the
         *  across-axis coordinates {@code from}..{@code to}: the path begins at the arc's
         *  first point and holds the arc -- a reflector from rim to rim, {@code
         *  Profile.parabola(new double[] {0, 0}, new double[] {0, 1}, 20, -50, 50)} a dish
         *  100 wide opening up. */
        public static Path parabola(double[] vertex, double[] axis, double focal, double from, double to) {
            double[] v = point2(vertex, "vertex");
            double[] a = point2(axis, "axis");
            return new Path(call(() -> (MemorySegment) PATH_PARABOLA.invokeExact(v[0], v[1], a[0], a[1], focal, from, to)),
                    "path_parabola");
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

        /** {@link #hits(Profile, double)} at a tolerance of {@code 1e-6}. */
        public List<Hit> hits(Profile other) {
            return hits(other, 1e-6);
        }

        /** Where this profile's curves cross, touch or run along {@code other}'s, both read in
         *  one plane, as {@link Hit} records ordered along this profile. Points closer than
         *  {@code tolerance} merge; two curves within {@code tolerance} of each other for
         *  longer than it are one run when they part only where one ends or the stretch is
         *  flat -- one curve following the other, offset within {@code tolerance} or tilted by
         *  under about half of it, even where it leaves mid-both; a tangency or a shallow
         *  crossing is one point. A loop that stops short of its start is an open chain. */
        public List<Hit> hits(Profile other, double tolerance) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment a = handle();
                MemorySegment b = other.handle();
                MemorySegment h = checked(
                        call(() -> (MemorySegment) PROFILE_HITS.invokeExact(a, b, tolerance)), "profile_hits");
                try {
                    int n = call(() -> (int) HIT_COUNT.invokeExact(h));
                    List<Hit> found = new ArrayList<>(n);
                    MemorySegment raw = arena.allocate(HIT);
                    for (int i = 0; i < n; i++) {
                        int at = i;
                        boolean ok = call(() -> (boolean) HIT_AT.invokeExact(h, at, raw));
                        if (!ok) throw failure("hit");
                        found.add(hitOf(raw));
                    }
                    return found;
                } finally {
                    call(() -> {
                        HITS_FREE.invokeExact(h);
                        return null;
                    });
                }
            } finally {
                keep(this, other);
            }
        }

        /** {@link #common(Profile, double)} at a tolerance of {@code 1e-6}. */
        public List<Profile> common(Profile other) {
            return common(other, 1e-6);
        }

        /** The region this profile and {@code other} share, both read in one plane, as zero
         *  or more profiles -- each boundary counter-clockwise, each hole clockwise, arcs and
         *  splines kept exact. Both must be closed and simple. No shared area is an empty
         *  list. Throws {@link BuildException} for a {@code tolerance} not positive and
         *  finite, or a profile open or crossing itself. */
        public List<Profile> common(Profile other, double tolerance) {
            try {
                MemorySegment a = handle();
                MemorySegment b = other.handle();
                return profileList(call(() -> (MemorySegment) PROFILE_COMMON.invokeExact(a, b, tolerance)), "profile_common");
            } finally {
                keep(this, other);
            }
        }

        /** {@link #text(String, double, String, String, String, double, String, byte[])} in the
         *  bundled face, left-aligned on the baseline, left to right, at the font's spacing. */
        public static List<Profile> text(String text, double size) {
            return text(text, size, "", "left", "baseline", 1.0, "ltr", null);
        }

        /** {@code text} set in a font, one profile per closed shape -- a letter with its
         *  counters as holes ({@code o} one, {@code 8} two; {@code i} is two profiles) -- on the
         *  sketch plane, the baseline along x from the origin, each outline counter-clockwise
         *  and its holes clockwise, a curved side the font's own cubic Bezier kept exactly: an
         *  extruded {@code O} has curved walls. {@code size} is roughly the height of a capital.
         *  {@code font} is a family, optionally with a style ({@code "Liberation Sans:style=Bold"}),
         *  a font file's path, or empty for the bundled Liberation Sans Regular -- which also
         *  serves when the family is not found; {@code fontBytes} a font file's bytes, used
         *  instead of {@code font} when not null. {@code halign} is "left", "center" or "right";
         *  {@code valign} "baseline", "bottom", "center" or "top"; {@code spacing} multiplies the
         *  gap between glyphs; {@code direction} "ltr" or "rtl". Empty text is an empty list.
         *  Throws {@link BuildException} for a size or spacing not positive and finite, an
         *  alignment or direction not one of those words, font bytes that are not a font. */
        public static List<Profile> text(String text, double size, String font, String halign, String valign,
                                         double spacing, String direction, byte[] fontBytes) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment t = arena.allocateFrom(text);
                MemorySegment f = arena.allocateFrom(font == null ? "" : font);
                MemorySegment h = arena.allocateFrom(halign);
                MemorySegment v = arena.allocateFrom(valign);
                MemorySegment d = arena.allocateFrom(direction);
                MemorySegment bytes = MemorySegment.NULL;
                long len = 0;
                if (fontBytes != null) {
                    bytes = arena.allocate(Math.max(fontBytes.length, 1));
                    MemorySegment.copy(fontBytes, 0, bytes, ValueLayout.JAVA_BYTE, 0, fontBytes.length);
                    len = fontBytes.length;
                }
                MemorySegment b = bytes;
                long n = len;
                return profileList(call(() -> (MemorySegment) PROFILE_TEXT.invokeExact(t, size, f, b, n, h, v, spacing, d)), "profile_text");
            }
        }

        /** The profiles of a list the library handed back (null: throw), each a handle of its
         *  own, the list freed. */
        private static List<Profile> profileList(MemorySegment raw, String what) {
            List<Profile> found = new ArrayList<>();
            try {
                MemorySegment list = checked(raw, what);
                try {
                    int n = call(() -> (int) PROFILE_LIST_COUNT.invokeExact(list));
                    for (int i = 0; i < n; i++) {
                        int at = i;
                        found.add(new Profile(call(() -> (MemorySegment) PROFILE_LIST_GET.invokeExact(list, at))));
                    }
                    return found;
                } finally {
                    call(() -> {
                        PROFILE_LIST_FREE.invokeExact(list);
                        return null;
                    });
                }
            } catch (RuntimeException e) {
                for (Profile p : found) p.close();
                throw e;
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

        /** This outline coloured ({@code r}, {@code g}, {@code b}), each in 0..1: how it is drawn.
         *  The verbs that make a profile from one carry it; a solid made from it takes nothing. */
        public Profile coloured(double r, double g, double b) {
            try {
                MemorySegment h = handle();
                return new Profile(call(() -> (MemorySegment) PROFILE_COLOURED.invokeExact(h, r, g, b)));
            } finally {
                keep(this);
            }
        }

        /** The outline's colour as {r, g, b} in 0..1, or null. */
        public double[] colour() {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                MemorySegment h = handle();
                boolean ok = call(() -> (boolean) PROFILE_COLOUR.invokeExact(h, out));
                if (ok) return out.toArray(ValueLayout.JAVA_DOUBLE);
                if (!lastError().isEmpty()) throw failure("profile_colour");
                return null;
            } finally {
                keep(this);
            }
        }

        /** This profile closed -- Python's {@code close_loop}, the forge's sketch "close": where
         *  its last segment stops short of its start (a path ended open), a straight segment back
         *  to it; where it already comes back within 1e-9 of its extent, its last segment made to
         *  land on the start exactly. A closed profile comes back as it is; holes are closed the
         *  same way. (Not {@code close}: that releases the handle.) */
        public Profile closeLoop() {
            try {
                MemorySegment h = handle();
                return new Profile(call(() -> (MemorySegment) PROFILE_CLOSE_LOOP.invokeExact(h)));
            } finally {
                keep(this);
            }
        }

        /**
         * This curve cut where the cutters cross, touch or run along it -- Python's
         * {@code pieces}, the sketch trim's pieces: in order along the curve from its start,
         * each an open profile of portions of this one's own segments (a line's stretch a
         * line, an arc's an arc, a spline's the same spline over part of its domain). One
         * piece, this curve, where nothing cuts it; a closed curve's piece round its start is
         * one piece. Cuts closer than {@code tolerance} to each other fold onto one.
         */
        public List<Profile> pieces(Collection<Profile> cutters, double tolerance) {
            Profile[] all = cutters.toArray(new Profile[0]);
            List<Profile> found = new ArrayList<>();
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment h = handle();
                MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
                for (int i = 0; i < all.length; i++) {
                    handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
                }
                long count = all.length;
                int n = call(() -> (int) PROFILE_PIECE_COUNT.invokeExact(h, handles, count, tolerance));
                if (n == 0) throw failure("profile_piece_count");
                for (int i = 0; i < n; i++) {
                    int which = i;
                    found.add(new Profile(call(() -> (MemorySegment) PROFILE_PIECE.invokeExact(h, handles, count, which, tolerance))));
                }
                return found;
            } catch (RuntimeException e) {
                for (Profile q : found) q.close();
                throw e;
            } finally {
                keep(this);
                keep((Object[]) all);
            }
        }

        /**
         * This curve with piece {@code piece} of {@link #pieces} taken away -- Python's
         * {@code trim}, the sketch trim: what is left, as open profiles. One for a closed curve
         * (its other pieces run together from where the removed one ended), the stretches
         * before and after for an open one, none where the piece was the whole curve. Throws
         * {@link BuildException} for a piece the curve does not have.
         */
        public List<Profile> trim(Collection<Profile> cutters, int piece, double tolerance) {
            Profile[] all = cutters.toArray(new Profile[0]);
            List<Profile> found = new ArrayList<>();
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment h = handle();
                MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
                for (int i = 0; i < all.length; i++) {
                    handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
                }
                long count = all.length;
                int n = call(() -> (int) PROFILE_TRIM_COUNT.invokeExact(h, handles, count, piece, tolerance));
                if (n == 0 && !lastError().isEmpty()) throw failure("profile_trim_count");
                for (int i = 0; i < n; i++) {
                    int which = i;
                    found.add(new Profile(call(() -> (MemorySegment) PROFILE_TRIM_CHAIN.invokeExact(h, handles, count, piece, which, tolerance))));
                }
                return found;
            } catch (RuntimeException e) {
                for (Profile q : found) q.close();
                throw e;
            } finally {
                keep(this);
                keep((Object[]) all);
            }
        }

        /** {@link #chain(Collection, double)} at a tolerance of {@code 1e-6}. */
        public static Profile chain(Collection<Profile> pieces) {
            return chain(pieces, 1e-6);
        }

        /**
         * Open profiles joined end to end into one -- the forge's merge. The pieces may come
         * in any order and either way round: each next one is the first of the rest with an end
         * within {@code tolerance} of either end of the chain so far, reversed where that makes
         * it meet. Every segment is kept exactly. Closed where the chain's two ends meet,
         * otherwise an open chain. Throws {@link BuildException} for no pieces, a piece empty,
         * with holes or closed on its own, or one that meets none of the others.
         */
        public static Profile chain(Collection<Profile> pieces, double tolerance) {
            Profile[] all = pieces.toArray(new Profile[0]);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
                for (int i = 0; i < all.length; i++) {
                    handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
                }
                long count = all.length;
                return new Profile(call(() -> (MemorySegment) PROFILE_CHAIN.invokeExact(handles, count, tolerance)));
            } finally {
                keep((Object[]) all);
            }
        }

        /**
         * Closed loops, in any order, as one profile: the loop enclosing the most area is the
         * boundary and every other a hole in it, in the order given -- a sketch's rectangle and
         * the circles drawn inside it. Each loop is closed, with no holes of its own, wound
         * either way. Throws {@link BuildException}, naming loops by their index, for a loop
         * that is open, empty or of no area, loops that cross or touch, a hole outside the
         * boundary or inside another hole.
         */
        public static Profile fromLoops(Collection<Profile> loops) {
            Profile[] all = loops.toArray(new Profile[0]);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
                for (int i = 0; i < all.length; i++) {
                    handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
                }
                long count = all.length;
                return new Profile(call(() -> (MemorySegment) PROFILE_FROM_LOOPS.invokeExact(handles, count)));
            } finally {
                keep((Object[]) all);
            }
        }

        /** {@link #round(double, int[], boolean)} of every corner, closed. */
        public Profile round(double radius) {
            return round(radius, null, false);
        }

        /**
         * This profile with its corners rounded by {@code radius}: where two straight segments
         * meet, both are cut back and an exact arc tangent to both put between them. {@code
         * corners} null rounds every such corner, the holes' too; otherwise it picks corners of
         * the boundary -- corner {@code k} is where segment {@code k} ends. {@code open} reads
         * the profile as an open chain whose two ends stay square; closed, the corner at the
         * start is rounded too. Throws {@link BuildException} naming the corner the radius does
         * not fit.
         */
        public Profile round(double radius, int[] corners, boolean open) {
            int[] which = corners == null ? null : indices(corners);
            try (Arena arena = Arena.ofConfined()) {
                // A picked list, even an empty one, is a non-null array: null means every corner.
                MemorySegment list = which == null ? MemorySegment.NULL : arena.allocate(ValueLayout.JAVA_INT, Math.max(1, which.length));
                if (which != null) MemorySegment.copy(which, 0, list, ValueLayout.JAVA_INT, 0, which.length);
                long count = which == null ? 0 : which.length;
                MemorySegment h = handle();
                return new Profile(call(() -> (MemorySegment) PROFILE_ROUND.invokeExact(h, radius, list, count, open)));
            } finally {
                keep(this);
            }
        }

        /** {@link #svgText(SvgOptions)} with every default. */
        public String svgText() {
            return svgText(null);
        }

        /**
         * This profile's own loops as SVG text, from directly above by default -- a sketch
         * lies in z = 0, so its own plane already is the page, unlike a solid's {@link
         * Solid#svgText} ({@link SvgView#ISO}), which has no plane of its own to prefer.
         * Passing {@code options} at all -- even one left at its own defaults -- opts out of
         * the top default and uses its {@link SvgOptions#view()} as given, the same way a
         * caller of {@link SvgOptions} controls a solid's. See {@link
         * Blacksmith#writeSvgText(Collection, Collection, SvgOptions)}.
         */
        public String svgText(SvgOptions options) {
            return writeSvgText(List.of(), List.of(this), options == null ? SvgOptions.defaults(SvgView.TOP) : options);
        }

        /** {@link #svg(String, SvgOptions)} with every default. */
        public void svg(String path) {
            svg(path, null);
        }

        /** {@link #svgText(SvgOptions)} written to {@code path} by the library itself; see
         *  {@link #svgText(SvgOptions)} for the top default. */
        public void svg(String path, SvgOptions options) {
            writeSvg(path, List.of(), List.of(this), options == null ? SvgOptions.defaults(SvgView.TOP) : options);
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

        private Path(MemorySegment raw, String what) {
            handle = new Handle(PATH_FREE, "path: already ended", checked(raw, what));
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

        /** A conic arc to ({@code x}, {@code y}) through the control point {@code control}
         *  (two numbers) with middle weight {@code weight}: under 1 an elliptical arc, 1 a
         *  parabola, over 1 a hyperbola -- the rational quadratic Bezier, kept exact. */
        public Path conicTo(double x, double y, double[] control, double weight) {
            double[] c = point2(control, "control");
            try {
                MemorySegment h = handle.live();
                return step(call(() -> (boolean) PATH_CONIC_TO.invokeExact(h, x, y, c[0], c[1], weight)), "path_conic_to");
            } finally {
                keep(this);
            }
        }

        /** A parabolic arc to ({@code x}, {@code y}) whose end tangents meet at {@code
         *  control} (two numbers): {@link #conicTo} with weight 1. */
        public Path parabolaTo(double x, double y, double[] control) {
            return conicTo(x, y, control, 1.0);
        }

        /** A hyperbolic arc to ({@code x}, {@code y}) through {@code control} (two numbers)
         *  with middle {@code weight} over 1. */
        public Path hyperbolaTo(double x, double y, double[] control, double weight) {
            if (!(weight > 1.0)) {
                throw new BuildException("hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)");
            }
            return conicTo(x, y, control, weight);
        }

        /** The parabolic arc to ({@code x}, {@code y}) with {@code vertex} (two numbers):
         *  its axis and focal length solved from the two ends. Throws when no parabola with
         *  that vertex passes through both. */
        public Path parabolaByVertex(double x, double y, double[] vertex) {
            double[] v = point2(vertex, "vertex");
            try {
                MemorySegment h = handle.live();
                return step(call(() -> (boolean) PATH_PARABOLA_BY_VERTEX.invokeExact(h, x, y, v[0], v[1])), "path_parabola_by_vertex");
            } finally {
                keep(this);
            }
        }

        /** The parabolic arc to ({@code x}, {@code y}) with {@code focus} (two numbers): of
         *  the two through the ends, the one whose vertex lies between the ends' projections,
         *  then the one whose arc cups the focus (the focus between the arc and its chord),
         *  then the more symmetric; with the focus beyond the chord that is the arch over
         *  the ends, not the shallow dish -- draw that one with {@link Profile#parabola}. */
        public Path parabolaByFocus(double x, double y, double[] focus) {
            double[] f = point2(focus, "focus");
            try {
                MemorySegment h = handle.live();
                return step(call(() -> (boolean) PATH_PARABOLA_BY_FOCUS.invokeExact(h, x, y, f[0], f[1])), "path_parabola_by_focus");
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
            // The library reads one weight per control point plus the current point's.
            int n = flat.length / 2;
            if (weights != null && weights.length != n + 1) {
                throw new BuildException("nurbs_to: " + weights.length + " weights for " + (n + 1) + " control points "
                        + "(the current point and " + n + " given); give one per point");
            }
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

        private SweepPath(MemorySegment raw, String what) {
            handle = new Handle(SWEEP_PATH_FREE, "sweep_path: closed", checked(raw, what));
            cleanable = CLEANER.register(this, handle);
        }

        /** Start a sweep path at {@code point} (three numbers). */
        public static SweepPath at(double[] point) {
            return new SweepPath(point);
        }

        /** {@link #along(Profile, double[], double, boolean)} at 0.05, open. */
        public static SweepPath along(Profile curve, double[] frame) {
            return along(curve, frame, 0.05, true);
        }

        /**
         * The path the 2D chain {@code curve} (usually from {@link Path#endOpen()}) draws on
         * {@code frame}: a line a straight piece, an arc a circular one, a Bezier or spline
         * fitted with biarcs -- arcs tangent to each other and to the curve -- within {@code
         * tolerance}. {@code open} false closes the path back to its start along the side a
         * profile leaves implicit.
         */
        public static SweepPath along(Profile curve, double[] frame, double tolerance, boolean open) {
            double[] f = frame(frame);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment c = curve.handle();
                return new SweepPath(call(() -> (MemorySegment) SWEEP_PATH_ALONG.invokeExact(c, fs, tolerance, open)), "sweep_path_along");
            } finally {
                keep(curve);
            }
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

    /** A {@link Mesh64} in memory of your own. */
    public record MeshData64(double[] positions, double[] normals, int[] indices) {
    }

    /**
     * {@code cadaclysm_blacksmith_mesh64}: the same tessellation as {@link Mesh}, from the
     * same cache -- meshing at another tolerance (through {@link Solid#mesh}, {@link
     * Solid#mesh64}, {@link Solid#edgePolylines}, {@link Solid#boundsAt} or {@link
     * Solid#boundsAt64}) invalidates this the same way it invalidates {@link Mesh}.
     *
     * <p>{@link #positions()} and {@link #normals()} are {@code vertexCount * 3} doubles,
     * {@link #indices()} is {@code indexCount}, the very pointer {@link Mesh} gives.
     */
    public static final class Mesh64 {
        private final Solid solid;
        private final double tolerance;
        /** Which filling of the solid's cache this reads -- see {@link Solid#checkCache}. */
        private final int generation;
        private final long positions, normals, indices;
        private final int vertexCount, indexCount;

        private Mesh64(Solid solid, double tolerance, int generation, MemorySegment raw) {
            this.solid = solid;
            this.tolerance = tolerance;
            this.generation = generation;
            positions = raw.get(ValueLayout.ADDRESS, offset(MESH64, "positions")).address();
            normals = raw.get(ValueLayout.ADDRESS, offset(MESH64, "normals")).address();
            indices = raw.get(ValueLayout.ADDRESS, offset(MESH64, "indices")).address();
            vertexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH64, "vertex_count"));
            indexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH64, "index_count"));
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

        public DoubleBuffer positions() {
            solid.checkCache(generation);
            return doubleView(positions, vertexCount * 3L);
        }

        public DoubleBuffer normals() {
            solid.checkCache(generation);
            return doubleView(normals, vertexCount * 3L);
        }

        public IntBuffer indices() {
            solid.checkCache(generation);
            return intView(indices, indexCount);
        }

        /** The same triangles in memory of our own, safe to outlive the solid. */
        public MeshData64 copy() {
            return new MeshData64(toArray(positions()), toArray(normals()), toArray(indices()));
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

        /** The solid smooth through every profile, each on its frame ({@code frames.get(i)}
         *  for {@code profiles.get(i)}, in order): each wall interpolates its side across all
         *  the profiles (cubic through four or more, quadratic through three, {@link #loft}
         *  through two), capped by the first and the last. */
        public static Solid loftThrough(List<Profile> profiles, List<double[]> frames) {
            return loftedThrough(LOFT_THROUGH, profiles, frames);
        }

        /** {@link #loftThrough} without the caps: the sheet through the curves. */
        public static Solid loftThroughOpen(List<Profile> profiles, List<double[]> frames) {
            return loftedThrough(LOFT_THROUGH_OPEN, profiles, frames);
        }

        private static Solid loftedThrough(MethodHandle op, List<Profile> profiles, List<double[]> frames) {
            if (profiles.size() != frames.size()) {
                throw new BuildException("loft_through: " + frames.size() + " frames for " + profiles.size() + " profiles");
            }
            Profile[] all = profiles.toArray(new Profile[0]);
            double[] numbers = new double[12 * all.length];
            for (int i = 0; i < all.length; i++) {
                System.arraycopy(frame(frames.get(i)), 0, numbers, 12 * i, 12);
            }
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment handles = arena.allocate(ValueLayout.ADDRESS, Math.max(all.length, 1));
                for (int i = 0; i < all.length; i++) {
                    handles.setAtIndex(ValueLayout.ADDRESS, i, all[i].handle());
                }
                MemorySegment frameSegment = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, numbers.length == 0 ? new double[1] : numbers);
                long count = all.length;
                return new Solid(call(() -> (MemorySegment) op.invokeExact(handles, frameSegment, count)));
            } finally {
                keep((Object[]) all);
            }
        }

        /** {@code profile} swung {@code angle} radians about {@code axis} (six numbers: a
         *  point and a direction). */
        public static Solid revolve(Profile profile, double[] axis, double angle) {
            return revolved(REVOLVE, profile, axis, angle);
        }

        public static Solid revolveOpen(Profile profile, double[] axis, double angle) {
            return revolved(REVOLVE_OPEN, profile, axis, angle);
        }

        /** {@code profile} coiled about {@code axis} (six numbers: a point and a direction):
         *  read as {@link #revolve} reads it -- x the distance from the axis, y along it --
         *  and turned {@code turns} times while climbing {@code pitch} along the axis each
         *  turn: a spring, a thread. The two ends are the profile itself, flat; from a full
         *  turn up the pitch must be taller than the profile. */
        public static Solid coil(Profile profile, double[] axis, double pitch, double turns) {
            double[] ax = axisOf(axis);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment as = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, ax);
                MemorySegment p = profile.handle();
                return new Solid(call(() -> (MemorySegment) COIL.invokeExact(p, as, pitch, turns)));
            } finally {
                keep(profile);
            }
        }

        /** {@link #pipe(SweepPath, double, double)} as a solid rod. */
        public static Solid pipe(SweepPath path, double radius) {
            return pipe(path, radius, 0.0);
        }

        /** A circle of {@code radius} swept along {@code path}, square to its start: a rod, or with a positive {@code thickness} a tube whose walls are
         *  that thick. {@code path} is only borrowed, as by {@link #sweep}. */
        public static Solid pipe(SweepPath path, double radius, double thickness) {
            try {
                MemorySegment sp = path.handle();
                return new Solid(call(() -> (MemorySegment) PIPE.invokeExact(sp, radius, thickness)));
            } finally {
                keep(path);
            }
        }

        /**
         * {@code profile}, drawn on {@code frame}, swung {@code angle} radians about the axis
         * through the sketch points {@code a} and {@code b} (two numbers each, on the frame) --
         * the profile and its axis drawn together, where {@link #revolve} reads the profile as
         * (radius, height). The profile may lie on either side of the axis and touch it, not
         * cross it; the sweep starts where it is drawn and turns right-handed about b - a.
         */
        public static Solid revolveInPlane(Profile profile, double[] frame, double[] a, double[] b, double angle) {
            return inPlane(REVOLVE_IN_PLANE, profile, frame, a, b, angle);
        }

        /** {@link #revolveInPlane} for a curve: its segments swung into a sheet. */
        public static Solid revolveOpenInPlane(Profile profile, double[] frame, double[] a, double[] b, double angle) {
            return inPlane(REVOLVE_OPEN_IN_PLANE, profile, frame, a, b, angle);
        }

        private static Solid inPlane(MethodHandle op, Profile profile, double[] frame, double[] a, double[] b, double angle) {
            double[] f = frame(frame);
            double[] p0 = point2(a, "a");
            double[] p1 = point2(b, "b");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment as = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, p0[0], p0[1], p1[0], p1[1]);
                MemorySegment p = profile.handle();
                return new Solid(call(() -> (MemorySegment) op.invokeExact(p, fs, as, angle)));
            } finally {
                keep(profile);
            }
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

        /** The flat sheet {@code profile} bounds on {@code frame}: one planar face, each hole
         *  a hole through it, its normal the frame's z, every edge the exact line, arc or
         *  spline its segment is. An open sheet -- raise it with {@link #extrudeFaces}, cut it
         *  with {@link #trim}. */
        public static Solid face(Profile profile, double[] frame) {
            double[] f = frame(frame);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment p = profile.handle();
                return new Solid(call(() -> (MemorySegment) FACE.invokeExact(p, fs)));
            } finally {
                keep(profile);
            }
        }

        /** Face {@code face} alone, as an open sheet: its surface, loops and exact edge
         *  curves, the rest of the solid left behind. */
        public Solid faceSheet(int face) {
            int which = indices(new int[] {face})[0];
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) FACE_SHEET.invokeExact(h, which)));
            } finally {
                keep(this);
            }
        }

        /** This solid without the faces at {@code faces}: the rest keep their order, so an
         *  index into the result is this one's with the dropped ones closed up. */
        public Solid dropFaces(int[] faces) {
            int[] which = indices(faces);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment list = arena.allocateFrom(ValueLayout.JAVA_INT, which);
                long count = which.length;
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) DROP_FACES.invokeExact(h, list, count)));
            } finally {
                keep(this);
            }
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

        /** {@link #join(Solid, double)}, its flush faces merged when {@code merge} ({@link #mergeFlush});
         *  the unmerged result is closed. */
        public Solid join(Solid other, double tolerance, boolean merge) {
            Solid out = join(other, tolerance);
            if (!merge) return out;
            try (out) {
                return out.mergeFlush();
            }
        }

        /** {@link #cut(Solid, double)} at 0.05. */
        public Solid cut(Solid other) {
            return cut(other, 0.05);
        }

        /** This solid with {@code other} removed; both inputs stay valid. */
        public Solid cut(Solid other, double tolerance) {
            return combine(CUT, other, tolerance);
        }

        /** {@link #cut(Solid, double)}, its flush faces merged when {@code merge} ({@link #mergeFlush});
         *  the unmerged result is closed. */
        public Solid cut(Solid other, double tolerance, boolean merge) {
            Solid out = cut(other, tolerance);
            if (!merge) return out;
            try (out) {
                return out.mergeFlush();
            }
        }

        /** {@link #common(Solid, double)} at 0.05. */
        public Solid common(Solid other) {
            return common(other, 0.05);
        }

        /** What this solid and {@code other} share; both inputs stay valid. */
        public Solid common(Solid other, double tolerance) {
            return combine(COMMON, other, tolerance);
        }

        /** {@link #common(Solid, double)}, its flush faces merged when {@code merge} ({@link #mergeFlush});
         *  the unmerged result is closed. */
        public Solid common(Solid other, double tolerance, boolean merge) {
            Solid out = common(other, tolerance);
            if (!merge) return out;
            try (out) {
                return out.mergeFlush();
            }
        }

        /** {@link #splitSheet(Solid, double)} at 0.05. */
        public Solid splitSheet(Solid tool) {
            return splitSheet(tool, 0.05);
        }

        /**
         * This solid (a sheet or a solid) cut along {@code tool}'s boundary, nothing
         * removed: every face comes back in its pieces outside {@code tool} and its pieces
         * inside, each piece a face, in this solid's own face order with each face's outside
         * pieces before its inside pieces. {@code tool} must be a closed solid. Keep or
         * discard pieces with {@link #dropFaces}; {@link #trim} is the split with one side
         * dropped.
         */
        public Solid splitSheet(Solid tool, double tolerance) {
            return combine(SPLIT_SHEET, tool, tolerance);
        }

        /** {@link #trim(Solid, String, double)} keeping what lies outside, at 0.05. */
        public Solid trim(Solid tool) {
            return trim(tool, "outside", 0.05);
        }

        /** {@link #trim(Solid, String, double)} at 0.05. */
        public Solid trim(Solid tool, String keep) {
            return trim(tool, keep, 0.05);
        }

        /** This sheet (or solid) cut along the closed {@code tool}'s boundary and the pieces
         *  on one side thrown away: {@code keep} "outside" keeps what lies outside the tool (a
         *  hole punched through), "inside" what lies within it. */
        public Solid trim(Solid tool, String keep, double tolerance) {
            if (!keep.equals("outside") && !keep.equals("inside"))
                throw new BuildException("trim: keep must be 'outside' or 'inside', not '" + keep + "'");
            boolean inside = keep.equals("inside");
            try {
                MemorySegment a = handle();
                MemorySegment b = tool.handle();
                return new Solid(call(() -> (MemorySegment) TRIM.invokeExact(a, b, inside, tolerance, MemorySegment.NULL, MemorySegment.NULL)));
            } finally {
                keep(this, tool);
            }
        }

        /** {@link #intersect(Solid, double)} at 0.05. */
        public Intersection intersect(Solid other) {
            return intersect(other, 0.05);
        }

        /** Where this solid's faces cross or coincide with {@code other}'s, at {@code tolerance},
         *  as an {@link Intersection}: {@code chains} along the curves the faces meet on and
         *  {@code overlaps} where a face pair coincides. Neither solid is changed; either may be
         *  an open sheet. No crossing is an empty result, never an error.
         *
         *  <p>Each {@link Chain}'s points are within {@code tolerance} of both faces' exact
         *  surfaces; there is one chain per face pair per branch -- chains are not joined across
         *  a face boundary or a closed curve's seam, so join them by matching ends. A chain's
         *  {@code curve} is its exact curve where the kernel found one every point lies within
         *  {@code tolerance} of, else null; {@code tangent} is set where the surfaces are
         *  near-tangent along the chain or the snap did not settle (the points are then the best
         *  estimate) -- a closed chain that does not go once round its own curve (a sliver where
         *  two surfaces barely cross) has no curve, {@code tangent} still true. An
         *  {@link Overlap} is a coincident face pair with the shared region's rings (outer
         *  first, holes after), which may be empty for a partial overlap whose outlines cross.
         *  Known limit: a crossing narrower than {@code tolerance} -- two surfaces passing within
         *  it without their meshes crossing -- can be missed; near-tangent contact is where this
         *  bites.
         *
         *  <p>Throws {@link BuildException} for a {@code tolerance} not positive and finite, a
         *  solid with no faces, or one that meshes to nothing. */
        public Intersection intersect(Solid other, double tolerance) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment a = handle();
                MemorySegment b = other.handle();
                MemorySegment h = checked(
                        call(() -> (MemorySegment) INTERSECT.invokeExact(a, b, tolerance, MemorySegment.NULL, MemorySegment.NULL)),
                        "intersect");
                try {
                    int n = call(() -> (int) INTERSECTION_CHAIN_COUNT.invokeExact(h));
                    List<Chain> chains = new ArrayList<>(n);
                    MemorySegment raw = arena.allocate(CHAIN);
                    MemorySegment rawCurve = arena.allocate(CURVE);
                    for (int i = 0; i < n; i++) {
                        int at = i;
                        boolean ok = call(() -> (boolean) INTERSECTION_CHAIN.invokeExact(h, at, raw));
                        if (!ok) throw failure("intersection_chain");
                        Curve curve = null;
                        if (raw.get(ValueLayout.JAVA_BOOLEAN, offset(CHAIN, "has_curve"))) {
                            boolean okCurve = call(() -> (boolean) INTERSECTION_CURVE.invokeExact(h, at, rawCurve));
                            if (!okCurve) throw failure("intersection_curve");
                            curve = curveOf(rawCurve);
                        }
                        int pointCount = raw.get(ValueLayout.JAVA_INT, offset(CHAIN, "point_count"));
                        chains.add(new Chain(
                                pointsOf(doublesOf(raw.get(ValueLayout.ADDRESS, offset(CHAIN, "points")), 3 * pointCount)),
                                raw.get(ValueLayout.JAVA_BOOLEAN, offset(CHAIN, "closed")),
                                raw.get(ValueLayout.JAVA_INT, offset(CHAIN, "face_a")),
                                raw.get(ValueLayout.JAVA_INT, offset(CHAIN, "face_b")),
                                raw.get(ValueLayout.JAVA_BOOLEAN, offset(CHAIN, "tangent")),
                                curve));
                    }
                    n = call(() -> (int) INTERSECTION_OVERLAP_COUNT.invokeExact(h));
                    List<Overlap> overlaps = new ArrayList<>(n);
                    MemorySegment rawOverlap = arena.allocate(OVERLAP);
                    for (int i = 0; i < n; i++) {
                        int at = i;
                        boolean ok = call(() -> (boolean) INTERSECTION_OVERLAP.invokeExact(h, at, rawOverlap));
                        if (!ok) throw failure("intersection_overlap");
                        int pointCount = rawOverlap.get(ValueLayout.JAVA_INT, offset(OVERLAP, "point_count"));
                        int loopCount = rawOverlap.get(ValueLayout.JAVA_INT, offset(OVERLAP, "loop_count"));
                        double[][] points = pointsOf(doublesOf(rawOverlap.get(ValueLayout.ADDRESS, offset(OVERLAP, "points")), 3 * pointCount));
                        int[] starts = intsOf(rawOverlap.get(ValueLayout.ADDRESS, offset(OVERLAP, "loop_offsets")), loopCount);
                        double[][][] loops = new double[loopCount][][];
                        for (int r = 0; r < loopCount; r++) {
                            int end = r + 1 < loopCount ? starts[r + 1] : pointCount;
                            loops[r] = Arrays.copyOfRange(points, starts[r], end);
                        }
                        overlaps.add(new Overlap(
                                rawOverlap.get(ValueLayout.JAVA_INT, offset(OVERLAP, "face_a")),
                                rawOverlap.get(ValueLayout.JAVA_INT, offset(OVERLAP, "face_b")),
                                loops));
                    }
                    return new Intersection(chains, overlaps);
                } finally {
                    call(() -> {
                        INTERSECTION_FREE.invokeExact(h);
                        return null;
                    });
                }
            } finally {
                keep(this, other);
            }
        }

        /** {@link #hits(Profile, double[], double)} at 0.05. */
        public SolidHits hits(Profile profile, double[] frame) {
            return hits(profile, frame, 0.05);
        }

        /** Where {@code profile}, placed on {@code frame}, pierces this solid's faces, and the
         *  pieces its loops cut into, as a {@link SolidHits}. Neither is changed.
         *
         *  <p>A point hit lies within {@code tolerance} of the segment's exact curve and of the
         *  face's exact surface, inside the face's trim; its profile spot ({@code aStart}: loop,
         *  segment, t) and face spot ({@code bStart}: face, u, v) evaluate to the point within
         *  {@code tolerance}; {@code touch} where the curve's tangent lies within 1e-3 (sine) of
         *  the surface's tangent plane there (a graze), false at a crossing. A run is a stretch
         *  of one segment lying within {@code tolerance} of one face and inside it, longer than
         *  {@code tolerance}. Hits within {@code tolerance} of each other merge (a hit at a
         *  segment join reported once, as {@code (k, t = 1)}; a closed loop's closing join
         *  reads {@code (0, 0)}). Every point is in world space
         *  (the frame applied).
         *
         *  <p>Pieces only for a closed body -- an open body has none -- in loop order, covering
         *  every loop exactly; a piece's spots read a segment join as the next segment's start
         *  {@code (k + 1, 0)}, and an open chain runs from {@code (0, 0)} to {@code (n - 1, 1)};
         *  a loop no hit cuts is one closed piece. {@code inside} by the piece middle's winding
         *  number over the body's mesh; a piece lying on the surface is inside. Known limit: a
         *  segment passing within {@code tolerance} of a face without crossing its mesh can be
         *  missed (near-tangent grazes).
         *
         *  <p>Throws {@link BuildException} for a {@code tolerance} not positive and finite, a
         *  solid with no faces or that meshes to nothing, a profile with no segments, or a
         *  free-form segment that is not an evaluable NURBS curve. */
        public SolidHits hits(Profile profile, double[] frame, double tolerance) {
            double[] f = frame(frame);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment s = handle();
                MemorySegment p = profile.handle();
                MemorySegment h = checked(
                        call(() -> (MemorySegment) SOLID_PROFILE_HITS.invokeExact(s, p, fs, tolerance, MemorySegment.NULL, MemorySegment.NULL)),
                        "solid_profile_hits");
                try {
                    int n = call(() -> (int) HIT_COUNT.invokeExact(h));
                    List<Hit> hits = new ArrayList<>(n);
                    MemorySegment raw = arena.allocate(HIT);
                    for (int i = 0; i < n; i++) {
                        int at = i;
                        boolean ok = call(() -> (boolean) HIT_AT.invokeExact(h, at, raw));
                        if (!ok) throw failure("hit");
                        hits.add(hitOf(raw));
                    }
                    n = call(() -> (int) HITS_PIECE_COUNT.invokeExact(h));
                    List<Piece> pieces = new ArrayList<>(n);
                    MemorySegment inside = arena.allocate(ValueLayout.JAVA_BOOLEAN);
                    MemorySegment start = arena.allocate(SPOT);
                    MemorySegment end = arena.allocate(SPOT);
                    for (int i = 0; i < n; i++) {
                        int at = i;
                        boolean ok = call(() -> (boolean) HITS_PIECE.invokeExact(h, at, inside, start, end));
                        if (!ok) throw failure("hits_piece");
                        Profile own = new Profile(checked(
                                call(() -> (MemorySegment) HITS_PIECE_PROFILE.invokeExact(h, at)), "hits_piece_profile"));
                        pieces.add(new Piece(inside.get(ValueLayout.JAVA_BOOLEAN, 0), spotOf(start, 0), spotOf(end, 0), own));
                    }
                    return new SolidHits(hits, pieces);
                } finally {
                    call(() -> {
                        HITS_FREE.invokeExact(h);
                        return null;
                    });
                }
            } finally {
                keep(this, profile);
            }
        }

        /** {@code flat} xyz triples as one array a point. */
        private static double[][] pointsOf(double[] flat) {
            double[][] points = new double[flat.length / 3][];
            for (int k = 0; k < points.length; k++) points[k] = Arrays.copyOfRange(flat, 3 * k, 3 * k + 3);
            return points;
        }

        @SuppressWarnings("restricted") // reinterpret: the count beside the pointer says how far it reaches.
        private static int[] intsOf(MemorySegment at, int count) {
            return count == 0 || at.address() == 0
                    ? new int[0]
                    : at.reinterpret(count * (long) Integer.BYTES).toArray(ValueLayout.JAVA_INT);
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

        /** {@link #boundsAt64(double)} at 0.05. */
        public Bounds bounds64() {
            return boundsAt64(0.05);
        }

        /** {@link #boundsAt(double)}, from the same tessellation's unnarrowed positions --
         *  exact far from the origin, where {@link #boundsAt(double)}'s bounds, widened back
         *  from `float`, are not. */
        public Bounds boundsAt64(double tolerance) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment lo = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                MemorySegment hi = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                MemorySegment h = handle();
                boolean ok = call(() -> (boolean) BOUNDS64.invokeExact(h, tolerance, lo, hi));
                if (!ok) throw failure("bounds64");
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

        /** Whether the faces make a manifold -- every edge bordered by one face or two, the
         *  faces round every vertex one fan -- and whether it is closed. Read off the solid's
         *  topology, not a mesh, so it takes no tolerance; whether the faces all face out is
         *  {@link #unpairedEdges}'s question. */
        public Cad.Manifold manifold() {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_INT, 8);
                MemorySegment h = handle();
                boolean ok = call(() -> (boolean) MANIFOLD.invokeExact(h, out));
                if (!ok) throw failure("manifold");
                return Cad.Manifold.of(out.toArray(ValueLayout.JAVA_INT));
            } finally {
                keep(this);
            }
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

        /** {@link #mesh64(double)} at 0.05. */
        public Mesh64 mesh64() {
            return mesh64(0.05);
        }

        /** {@link #mesh(double)} in {@code double}, from the same cache: valid until the
         *  solid is closed or meshed again at a different tolerance -- through {@link
         *  #mesh(double)} as much as through this. */
        public Mesh64 mesh64(double tolerance) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = arena;
                MemorySegment h = handle();
                MemorySegment raw = call(() -> (MemorySegment) MESH_AT64.invokeExact(allocator, h, tolerance));
                if (raw.get(ValueLayout.ADDRESS, offset(MESH64, "positions")).address() == 0) throw failure("mesh64");
                return new Mesh64(this, tolerance, filled(tolerance), raw);
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

        /** {@link #stepText(String, String)} with no schema (the built-in AP203), in millimetres. */
        public String stepText() {
            return stepText(null, "mm");
        }

        /** This solid as STEP text (AP203 unless {@code schema} names another); see {@link Blacksmith#writeStepText}. */
        public String stepText(String schema, String unit) {
            return writeStepText(List.of(this), schema, unit);
        }

        /** {@link #step(String, String, String)} with no schema (the built-in AP203), in millimetres. */
        public void step(String path) {
            step(path, null, "mm");
        }

        /** This solid written as a STEP file (AP203 unless {@code schema} names another). */
        public void step(String path, String schema, String unit) {
            writeText(path, stepText(schema, unit));
        }

        /** {@link #satText(String)} in millimetres. */
        public String satText() {
            return satText("mm");
        }

        /** This solid as ACIS SAT text; see {@link Blacksmith#writeSatText}. */
        public String satText(String unit) {
            return writeSatText(List.of(this), unit);
        }

        /** {@link #sat(String, String)} in millimetres. */
        public void sat(String path) {
            sat(path, "mm");
        }

        /** This solid written as an ACIS SAT file by the library itself. */
        public void sat(String path, String unit) {
            writeSat(path, List.of(this), unit);
        }

        /** This solid as OCCT {@code .brep} text; see {@link Blacksmith#writeBrepText}. */
        public String brepText() {
            return writeBrepText(List.of(this));
        }

        /** This solid written as a {@code .brep} file, by the library itself. */
        public void brep(String path) {
            writeBrep(path, List.of(this));
        }

        /** {@link #svgText(SvgOptions)} with every default. */
        public String svgText() {
            return svgText(null);
        }

        /** This solid's wireframe as SVG text, from the camera {@code options} describes --
         *  the library's own camera, not a viewer. See {@link Blacksmith#writeSvgText}. */
        public String svgText(SvgOptions options) {
            return writeSvgText(List.of(this), options);
        }

        /** {@link #svg(String, SvgOptions)} with every default. */
        public void svg(String path) {
            svg(path, null);
        }

        /** This solid written as an SVG file by the library itself. */
        public void svg(String path, SvgOptions options) {
            writeSvg(path, List.of(this), options);
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

        /** Face {@code face} by what it is, eight doubles: the surface's kind (plane 0,
         * cylinder 1, cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8), a
         * point on the surface at the face's middle (x y z), the outward normal there (x y z),
         * and the face's extent -- what a feature made on the face keeps, to find the face again
         * with {@link #findFace} when the solid has been rebuilt with its faces moved, split or
         * renumbered. Take it before any move you apply to the solid, and look it up on the
         * unmoved one. */
        public double[] faceRef(int face) {
            int i = index(face);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 8);
                MemorySegment h = handle();
                boolean ok = call(() -> (boolean) FACE_REF.invokeExact(h, i, out));
                if (!ok) throw failure("face_ref");
                return out.toArray(ValueLayout.JAVA_DOUBLE);
            } finally {
                keep(this);
            }
        }

        /** The face {@code faceRef} (from {@link #faceRef}) refers to: among the faces of that
         * kind whose surface passes through the point, facing the same way, the one the point
         * lies in -- or, where it lies in none, the one whose boundary comes nearest.
         * {@code hint} is the index the face had, preferred among faces that fit equally well
         * (negative for none); {@code tolerance} how far the point may sit off a surface to
         * still be on it. -1 where the face is gone. */
        public int findFace(double[] faceRef, int hint, double tolerance) {
            if (faceRef.length != 8) throw new BuildException("find_face: a face reference is eight numbers");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment ref = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, faceRef);
                MemorySegment h = handle();
                int h2 = hint < 0 ? -1 : hint;
                int found = call(() -> (int) FIND_FACE.invokeExact(h, ref, h2, tolerance));
                if (found == -2) throw failure("find_face");
                return found < 0 ? -1 : found;
            } finally {
                keep(this);
            }
        }

        /** {@code findFace(faceRef, hint, 1e-3)}. */
        public int findFace(double[] faceRef, int hint) { return findFace(faceRef, hint, 1e-3); }

        // -- colour

        /** This solid coloured ({@code r}, {@code g}, {@code b}), each in 0..1. What is made from
         *  a coloured solid inherits: a move keeps every colour; a boolean, fillet, chamfer or
         *  shell gives each face the colour of the face it lies on (a cut's bore the tool's), and
         *  a new face the solid's. */
        public Solid coloured(double r, double g, double b) {
            return colouredAt(NONE, r, g, b);
        }

        /** This solid with {@code face} coloured, a colour that wins over the solid's. */
        public Solid coloured(int face, double r, double g, double b) {
            return colouredAt(index(face), r, g, b);
        }

        private Solid colouredAt(int face, double r, double g, double b) {
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) COLOURED.invokeExact(h, face, r, g, b)));
            } finally {
                keep(this);
            }
        }

        /** The solid's colour as {r, g, b} in 0..1, or null. */
        public double[] colour() {
            return colourAt(NONE);
        }

        /** {@code face}'s colour as drawn -- its own, else the solid's -- or null. */
        public double[] faceColour(int face) {
            return colourAt(index(face));
        }

        private double[] colourAt(int face) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                MemorySegment h = handle();
                boolean ok = call(() -> (boolean) COLOUR.invokeExact(h, face, out));
                if (ok) return out.toArray(ValueLayout.JAVA_DOUBLE);
                if (!lastError().isEmpty()) throw failure("colour");
                return null;
            } finally {
                keep(this);
            }
        }

        /** This solid with every edge coloured ({@code r}, {@code g}, {@code b}). Inherited as face
         *  colours are: a move keeps every one, a boolean or a fillet gives each edge the colour of
         *  the input edge it lies on, a new edge the all-edges one. */
        public Solid edgesColoured(double r, double g, double b) {
            return edgesColouredAt(MemorySegment.NULL, 0, r, g, b);
        }

        /** This solid with {@code edges} (by index, as {@link #fillet(int[], double, double)} takes
         *  them) coloured, a colour that wins over the all-edges one; an empty list colours none. */
        public Solid edgesColoured(int[] edges, double r, double g, double b) {
            int[] which = indices(edges);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment list = arena.allocateFrom(ValueLayout.JAVA_INT, which);
                return edgesColouredAt(list, which.length, r, g, b);
            }
        }

        /** {@link #edgesColoured(int[], double, double, double)} by {@link Edge}. */
        public Solid edgesColoured(Collection<Edge> edges, double r, double g, double b) {
            return edgesColoured(indicesOf(edges), r, g, b);
        }

        private Solid edgesColouredAt(MemorySegment list, long count, double r, double g, double b) {
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) EDGES_COLOURED.invokeExact(h, list, count, r, g, b)));
            } finally {
                keep(this);
            }
        }

        /** Edge {@code edge}'s colour as drawn -- its own, else the solid's edge colour -- or null. */
        public double[] edgeColour(int edge) {
            int at = index(edge);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                MemorySegment h = handle();
                boolean ok = call(() -> (boolean) EDGE_COLOUR.invokeExact(h, at, out));
                if (ok) return out.toArray(ValueLayout.JAVA_DOUBLE);
                if (!lastError().isEmpty()) throw failure("edge_colour");
                return null;
            } finally {
                keep(this);
            }
        }

        /** {@link #edgePolylineColours(double)} at 0.05. */
        public double[][] edgePolylineColours() {
            return edgePolylineColours(0.05);
        }

        /** A colour per polyline of {@link #edgePolylines(double)} at the same tolerance, as drawn:
         *  {r, g, b}, or null for a polyline on no coloured edge; an empty array where the solid has
         *  no edge paint at all. Copied out. */
        @SuppressWarnings("restricted") // reinterpret: `count` says how far `rgb` reaches.
        public double[][] edgePolylineColours(double tolerance) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = arena;
                MemorySegment h = handle();
                MemorySegment raw = call(() -> (MemorySegment) EDGE_POLYLINE_COLOURS.invokeExact(allocator, h, tolerance));
                MemorySegment rgb = raw.get(ValueLayout.ADDRESS, offset(COLOURS, "rgb"));
                int count = raw.get(ValueLayout.JAVA_INT, offset(COLOURS, "count"));
                if (rgb.address() == 0 && !lastError().isEmpty()) throw failure("edge_polyline_colours");
                // This call tessellates like every other cache reader, even to report "no
                // paint": it can replace the cache a view taken earlier is still borrowing, so
                // it must bump the generation those views check, even though this method
                // copies its own result out and keeps nothing borrowed itself.
                filled(tolerance);
                if (rgb.address() == 0) return new double[0][];
                double[] values = rgb.reinterpret(3L * count * Double.BYTES).toArray(ValueLayout.JAVA_DOUBLE);
                double[][] out = new double[count][];
                for (int i = 0; i < count; i++) {
                    out[i] = values[3 * i] < 0 ? null : new double[] { values[3 * i], values[3 * i + 1], values[3 * i + 2] };
                }
                return out;
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
                MemorySegment rawCurve = arena.allocate(CURVE);
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
                    found.add(new Edge(i, kind, faces, segments, edgeCurve(h, i, rawCurve)));
                }
                return found;
            } finally {
                keep(this);
            }
        }

        /** Edge {@code i}'s exact curve copied out of {@code raw}, or null for an edge with
         *  none (the library's "has no exact curve"); any other refusal throws. */
        private static Curve edgeCurve(MemorySegment h, int i, MemorySegment raw) {
            boolean ok = call(() -> (boolean) EDGE_CURVE.invokeExact(h, i, raw));
            if (!ok) {
                if (lastError().contains("has no exact curve")) return null;
                throw failure("edge_curve");
            }
            return curveOf(raw);
        }

        /** The {@code CadaclysmBlacksmithCurve} in {@code raw} copied out (an edge's or an
         *  intersection chain's). */
        private static Curve curveOf(MemorySegment raw) {
            int degree = raw.get(ValueLayout.JAVA_INT, offset(CURVE, "degree"));
            int knotCount = raw.get(ValueLayout.JAVA_INT, offset(CURVE, "knot_count"));
            int poleCount = raw.get(ValueLayout.JAVA_INT, offset(CURVE, "pole_count"));
            MemorySegment weightsAt = raw.get(ValueLayout.ADDRESS, offset(CURVE, "weights"));
            return new Curve(
                    string(raw.get(ValueLayout.ADDRESS, offset(CURVE, "kind"))),
                    pointOf(raw, offset(CURVE, "origin")),
                    pointOf(raw, offset(CURVE, "x")),
                    pointOf(raw, offset(CURVE, "y")),
                    pointOf(raw, offset(CURVE, "z")),
                    raw.get(ValueLayout.JAVA_DOUBLE, offset(CURVE, "radius")),
                    raw.get(ValueLayout.JAVA_DOUBLE, offset(CURVE, "radius2")),
                    raw.get(ValueLayout.JAVA_DOUBLE, offset(CURVE, "t0")),
                    raw.get(ValueLayout.JAVA_DOUBLE, offset(CURVE, "t1")),
                    degree,
                    doublesOf(raw.get(ValueLayout.ADDRESS, offset(CURVE, "knots")), knotCount),
                    doublesOf(raw.get(ValueLayout.ADDRESS, offset(CURVE, "poles")), 3 * poleCount),
                    weightsAt.address() == 0 ? null : doublesOf(weightsAt, poleCount));
        }

        @SuppressWarnings("restricted") // reinterpret: the count beside the pointer says how far it reaches.
        private static double[] doublesOf(MemorySegment at, int count) {
            return count == 0 || at.address() == 0
                    ? new double[0]
                    : at.reinterpret(count * (long) Double.BYTES).toArray(ValueLayout.JAVA_DOUBLE);
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

        /** {@link #pushPull(int, double, double)} at tolerance 0.05. */
        public Solid pushPull(int face, double distance) {
            return pushPull(face, distance, 0.05);
        }

        /** Face {@code face} pushed out by {@code distance} along its outward normal (pulled
         *  in, negative) as a face extrude does it: the prism over it joined on
         *  (cut out), and the flush faces merged -- a box's top raised is one taller box of
         *  six faces. A face on a cylinder, a cone, a sphere or a torus moves out along its
         *  normal instead, the surface a step out (a boss fatter, a bore or a countersink
         *  narrower, a dome fuller), the flat faces beside it carried along; any other
         *  curved face is refused. */
        public Solid pushPull(int face, double distance, double tolerance) {
            int which = index(face);
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) PUSH_PULL.invokeExact(h, which, distance, tolerance, MemorySegment.NULL, MemorySegment.NULL)));
            } finally {
                keep(this);
            }
        }

        /** {@link #pushPull(int[], double, double)} at tolerance 0.05. */
        public Solid pushPull(int[] faces, double distance) {
            return pushPull(faces, distance, 0.05);
        }

        /** Faces {@code faces} pushed out by {@code distance} together -- a press-pull on a selection: each by {@link #pushPull(int, double, double)}'s rule
         *  for it, one after another, each found again after the pushes before it
         *  renumbered the faces. A box's top and a side pushed 5 is the box 5 taller and 5
         *  wider; a face on the same curved surface as one before it, and joined to it,
         *  moved with that one and is not pushed twice. */
        public Solid pushPull(int[] faces, double distance, double tolerance) {
            int[] which = indices(faces);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment list = arena.allocateFrom(ValueLayout.JAVA_INT, which);
                long count = which.length;
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) PUSH_PULL_FACES.invokeExact(
                        h, list, count, distance, tolerance, MemorySegment.NULL, MemorySegment.NULL)));
            } finally {
                keep(this);
            }
        }

        /** {@link #split(Solid, double)} at 0.05. */
        public List<Solid> split(Solid tool) {
            return split(tool, 0.05);
        }

        /** This solid split by {@code tool} into bodies: a closed
         *  {@code tool} gives the parts outside it, then the parts inside; a flat sheet splits
         *  by the whole plane it lies on. Each connected part is a body of its own. */
        public List<Solid> split(Solid tool, double tolerance) {
            try (Solid all = combine(SPLIT, tool, tolerance)) {
                return all.lumps();
            }
        }

        /** {@link #splitByPlane(double[], double)} at 0.05. */
        public List<Solid> splitByPlane(double[] plane) {
            return splitByPlane(plane, 0.05);
        }

        /** This solid split by the plane through {@code plane}'s origin, square to its z (a
         *  frame, twelve numbers): the bodies in front of it first, then those behind. */
        public List<Solid> splitByPlane(double[] plane, double tolerance) {
            double[] f = frame(plane);
            Solid all;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment fs = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, f);
                MemorySegment h = handle();
                all = new Solid(call(() -> (MemorySegment) SPLIT_BY_PLANE.invokeExact(h, fs, tolerance, MemorySegment.NULL, MemorySegment.NULL)));
            } finally {
                keep(this);
            }
            try (all) {
                return all.lumps();
            }
        }

        /** This solid's connected bodies, each a solid of its own -- faces sharing an edge are
         *  one body -- in the order of their first faces. */
        public List<Solid> lumps() {
            List<Solid> bodies = new ArrayList<>();
            try {
                MemorySegment h = handle();
                int n = call(() -> (int) LUMP_COUNT.invokeExact(h));
                if (n == 0) throw failure("lump_count");
                for (int i = 0; i < n; i++) {
                    int which = i;
                    bodies.add(new Solid(call(() -> (MemorySegment) LUMP.invokeExact(h, which))));
                }
                return bodies;
            } catch (RuntimeException e) {
                for (Solid b : bodies) b.close();
                throw e;
            } finally {
                keep(this);
            }
        }

        /** This solid with its flush faces merged: flat faces on one plane, facing one way and
         *  meeting, made one face, and the vertices left mid-way along a straight edge taken
         *  out -- the seams a {@link #join} leaves where two parts are flush. */
        public Solid mergeFlush() {
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) MERGE_FLUSH.invokeExact(h)));
            } finally {
                keep(this);
            }
        }

        /** {@link #refillet(int, double, double)} at tolerance 1e-6. */
        public Solid refillet(int face, double radius) {
            return refillet(face, radius, 1e-6);
        }

        /** The round {@code face} belongs to -- a fillet's bands, balls and rim bands joined to
         *  that face -- made again at {@code radius}, as a press-pull on a fillet face:
         *  taken back to the sharp edges it replaced, and those rounded again. */
        public Solid refillet(int face, double radius, double tolerance) {
            int which = index(face);
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) REFILLET.invokeExact(h, which, radius, tolerance)));
            } finally {
                keep(this);
            }
        }

        /** The round {@code face} belongs to taken off, the faces beside it sharp again --
         *  the delete of a fillet face. */
        public Solid unfillet(int face) {
            int which = index(face);
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) UNFILLET.invokeExact(h, which)));
            } finally {
                keep(this);
            }
        }

        /** {@link #rechamfer(int, double, double)} at tolerance 1e-6. */
        public Solid rechamfer(int face, double distance) {
            return rechamfer(face, distance, 1e-6);
        }

        /** The chamfer {@code face} belongs to -- its bevels, flat or round a rim, and the corner
         *  triangles joined to that face -- cut again at {@code distance}, as a press-pull
         *  on a chamfer face: taken back to the sharp edges it cut, and those bevelled again. */
        public Solid rechamfer(int face, double distance, double tolerance) {
            int which = index(face);
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) RECHAMFER.invokeExact(h, which, distance, tolerance)));
            } finally {
                keep(this);
            }
        }

        /** The chamfer {@code face} belongs to taken off, the faces beside it sharp again --
         *  the delete of a chamfer face. */
        public Solid unchamfer(int face) {
            int which = index(face);
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) UNCHAMFER.invokeExact(h, which)));
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

        /** {@link #thicken(double, double)} at tolerance 1e-6. */
        public Solid thicken(double thickness) {
            return thicken(thickness, 1e-6);
        }

        /** This sheet made a solid {@code thickness} thick: its faces, their
         *  twins moved {@code thickness} along the faces' normals (against them for a negative
         *  thickness), and a wall round every open edge. A closed sheet thickens to a hollow. */
        public Solid thicken(double thickness, double tolerance) {
            try {
                MemorySegment h = handle();
                return new Solid(call(() -> (MemorySegment) THICKEN.invokeExact(
                        h, thickness, tolerance, MemorySegment.NULL, MemorySegment.NULL)));
            } finally {
                keep(this);
            }
        }

        // -- from files

        /** {@link #fromNode(Cad.Scene, Cad.Node, boolean)}, placed. */
        public static Solid fromNode(Cad.Scene scene, Cad.Node node) {
            return fromNode(scene, node, true);
        }

        /** {@link #fromNode(Cad.Scene, Cad.Node, boolean)} by node index. */
        public static Solid fromNode(Cad.Scene scene, int node, boolean placed) {
            return fromNode(scene, scene.nodes().get(node), placed);
        }

        /**
         * The body {@code node} of a reader {@link Cad.Scene} draws, as a solid -- sharing the
         * reader's brep, not copying it. The scene can be closed before the solid is.
         * {@code placed} puts it where the node's {@code transform()} does, which is where its
         * mesh draws; a node at the identity stays shared, a moved one is a moved copy. In the
         * file's own units and axes. Needs the reader's library from the same release as this
         * one's: the brep is handed across by pointer and the two layouts are compared first.
         * What a solid from a file can then do: see {@link #open(String)}.
         */
        public static Solid fromNode(Cad.Scene scene, Cad.Node node, boolean placed) {
            String label = "from_node: node " + node.index() + " (" + label(node) + ")";
            Solid solid = fromBrep(node, label);
            if (solid == null) {
                throw new BuildException(label + " has no brep: only a B-rep body has one (STEP, ACIS, Rhino, "
                        + "OCCT .brep, IGES, IFC), not a mesh, a curve or a CSG body");
            }
            if (!placed) return solid;
            double[][] m = node.transform();
            if (scene.convention() != Cad.Convention.NATIVE && !isIdentity(m)) {
                solid.close();
                throw new BuildException("from_node: placed=True needs the scene opened with Convention.NATIVE -- the "
                        + "brep is in the file's own axes and the node's transform is not; open NATIVE, or pass placed false");
            }
            return solid.placed(m, "from_node");
        }

        /**
         * The body a CAD file holds, as a solid: a STEP (AP203/214/242), ACIS {@code .sat},
         * Rhino {@code .3dm}, OCCT {@code .brep}, IGES or IFC file, read where it draws, in the
         * file's own units and axes. A file drawing several bodies needs {@link #open(String,
         * int)} or {@link #openAll}. Fillet and chamfer want line and circle edges; booleans
         * take any surface, but the new edges they trace on a free-form (NURBS) face are not
         * always writable back to STEP; and every verb meshes its operands first, so its cost
         * grows with the body's face count.
         */
        public static Solid open(String path) {
            return openOne(path, -1);
        }

        /** {@link #open(String)} for one body of several, 0-based in drawing order. */
        public static Solid open(String path, int body) {
            if (body < 0) throw new BuildException("open: " + java.nio.file.Path.of(path).getFileName() + " has no body " + body);
            return openOne(path, body);
        }

        private static Solid openOne(String path, int body) {
            List<Solid> solids = openAll(path);
            String name = String.valueOf(java.nio.file.Path.of(path).getFileName());
            if (body < 0 && solids.size() == 1) return solids.get(0);
            if (body < 0 || body >= solids.size()) {
                for (Solid s : solids) s.close();
                throw new BuildException(body < 0
                        ? "open: " + name + " holds " + solids.size() + " bodies: pass body= (0 to "
                                + (solids.size() - 1) + "), or use Solid.open_all"
                        : "open: " + name + " has no body " + body + ": it holds " + solids.size());
            }
            for (int i = 0; i < solids.size(); i++) if (i != body) solids.get(i).close();
            return solids.get(body);
        }

        /** Every body a CAD file draws, as solids placed where it draws them: one per
         *  placement, so a part placed twice is two solids. See {@link #open(String)}. */
        public static List<Solid> openAll(String path) {
            Cad.Scene scene;
            try {
                scene = Cad.open(path);
            } catch (Cad.CadaclysmException e) {
                throw new BuildException("open: " + e.getMessage());
            }
            List<Solid> solids = new ArrayList<>();
            try (scene) {
                for (Cad.Placement placement : scene.placements()) {
                    Cad.Node node = placement.geometry();
                    String what = "open: " + label(node);
                    Solid solid = fromBrep(node, what);
                    if (solid != null) solids.add(solid.placed(placement.transform(), what));
                }
            } catch (RuntimeException e) {
                for (Solid s : solids) s.close();
                throw e;
            }
            if (solids.isEmpty()) {
                String name = String.valueOf(java.nio.file.Path.of(path).getFileName());
                int dot = name.lastIndexOf('.');
                String extension = dot < 0 ? "" : name.substring(dot + 1).toLowerCase();
                throw new BuildException("open: the ." + extension + " file draws no B-rep body -- only a STEP, ACIS, "
                        + "Rhino, OCCT .brep, IGES or IFC body can be a solid, not a mesh, a curve or a CSG body");
            }
            return solids;
        }

        private static String label(Cad.Node node) {
            if (!node.name().isEmpty()) return node.name();
            if (!node.kind().isEmpty()) return node.kind();
            return String.valueOf(node.index());
        }

        /** The node's brep as a solid, shared, or null where it has none. */
        private static Solid fromBrep(Cad.Node node, String what) {
            try (Cad.Brep brep = node.brep()) {
                if (brep == null) return null;
                try (Arena arena = Arena.ofConfined()) {
                    MemorySegment layout = arena.allocateFrom(Cad.Brep.layoutId());
                    MemorySegment pointer = brep.pointer();
                    MemorySegment raw = call(() -> (MemorySegment) FROM_BREP.invokeExact(pointer, layout));
                    if (raw.address() == 0) throw failure(what);
                    return new Solid(raw);
                }
            }
        }

        private static boolean isIdentity(double[][] m) {
            for (int i = 0; i < 4; i++)
                for (int j = 0; j < 4; j++)
                    if (m[i][j] != (i == j ? 1.0 : 0.0)) return false;
            return true;
        }

        /** This solid moved by a row-major 4x4 placement: itself at the identity, a moved copy
         *  for a rigid move (a mirror included; this one is closed), refused for a scale or
         *  shear, which a brep cannot follow exactly (a cylinder's radius is a number, not a
         *  point). */
        private Solid placed(double[][] m, String what) {
            if (isIdentity(m)) return this;
            try (this) {
                for (int a = 0; a < 3; a++)
                    for (int b = 0; b < 3; b++) {
                        double dot = m[0][a] * m[0][b] + m[1][a] * m[1][b] + m[2][a] * m[2][b];
                        if (Math.abs(dot - (a == b ? 1.0 : 0.0)) > 1e-9)
                            throw new BuildException(what + ": the placement scales or shears, which a brep cannot follow");
                    }
                return place(new double[] {m[0][3], m[1][3], m[2][3], m[0][0], m[1][0], m[2][0],
                        m[0][1], m[1][1], m[2][1], m[0][2], m[1][2], m[2][2]});
            }
        }

        /** {@link #toScene(String)} with the built-in AP203. */
        public Cad.Scene toScene() {
            return toScene(null);
        }

        /**
         * This solid as a reader {@link Cad.Scene}, through STEP text and {@link
         * Cad#openMemory} -- the door to the viewer and the tree walk. Needs the reader's
         * library built beside this one.
         *
         * @param schema as {@link #stepText(String, String)} takes it; the reader is given
         *               the schema's path only when it names an existing file, since it
         *               carries every built-in schema itself and there is no file here to
         *               read a {@code FILE_SCHEMA} line out of.
         */
        public Cad.Scene toScene(String schema) {
            byte[] bytes = stepText(schema, "mm").getBytes(StandardCharsets.UTF_8);
            java.nio.file.Path at = schema != null && schema.indexOf('\n') < 0 ? schemaFilePath(schema) : null;
            String schemaPath = at != null && Files.isRegularFile(at) ? schema : null;
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
     * One edge's, or one intersection chain's, exact curve as plain data copied out
     * ({@link Edge#curve}, {@link Chain#curve}): {@code kind} is "line", "circle", "ellipse", "parabola", "hyperbola"
     * or "nurbs".
     *
     * <p>{@code t0..t1} is the edge's parameter range on its own curve: a line's fraction (0..1
     * over {@code origin -> origin + x}, where {@code x} is the full {@code to - from}, NOT unit
     * -- so {@code point(t) = origin + x*t}); a circle's or ellipse's angle in radians about
     * {@code origin} in the {@code x, y} plane ({@code point(t) = origin + x*radius*cos(t) +
     * y*radius2*sin(t)}, {@code radius2 = radius} for a circle); a NURBS's knot parameter
     * ({@code knots[degree] <= t0 < t1 <= knots[n]}). Frame vectors {@code x, y, z} are unit for
     * conics; for a line {@code x} is the direction with length = the line's length and
     * {@code y, z} are zero.
     *
     * <p>For a NURBS the frame is zero and so are the radii; for a conic or a line {@code degree}
     * is 0 and {@code knots}, {@code poles} are empty.
     *
     * @param origin  three doubles
     * @param x       three doubles
     * @param y       three doubles
     * @param z       three doubles
     * @param knots   the knot vector ({@code knots.length == poles.length / 3 + degree + 1})
     * @param poles   three doubles per control point
     * @param weights one per pole, or null for a non-rational (plain B-spline) curve, a conic
     *                or a line
     */
    public record Curve(String kind, double[] origin, double[] x, double[] y, double[] z,
                        double radius, double radius2, double t0, double t1, int degree,
                        double[] knots, double[] poles, double[] weights) {
        @Override
        public String toString() {
            return kind.equals("nurbs")
                    ? "Curve(\"nurbs\", degree=" + degree + ", poles=" + poles.length / 3
                    + ", rational=" + (weights != null) + ", t0=" + t0 + ", t1=" + t1 + ")"
                    : "Curve(\"" + kind + "\", origin=" + Arrays.toString(origin) + ", radius=" + radius
                    + ", t0=" + t0 + ", t1=" + t1 + ")";
        }
    }

    /**
     * One edge of a solid, as plain data: its index (what {@link Solid#fillet} takes), the
     * curve kind, the faces meeting on it, its segments' ends, and its exact {@link Curve}.
     *
     * @param index    the edge's index in the solid's own order
     * @param kind     "line", "circle", "ellipse", "parabola", "hyperbola", "nurbs" or "other"
     * @param faces    the faces that meet on it, in the solid's face order
     * @param segments the two ends of each trim piece of the edge
     * @param curve    the edge's exact curve, or null for an edge with none (kind "other")
     */
    public record Edge(int index, String kind, int[] faces, Segment[] segments, Curve curve) {
        /** The two ends of one trim piece, three doubles each. */
        public record Segment(double[] a, double[] b) {
        }

        public Edge(int index, String kind, int[] faces, Segment[] segments) {
            this(index, kind, faces, segments, null);
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

    /**
     * Where a hit lands on one side: a profile's {@code loopIndex} (0 the boundary or the open
     * chain, then the holes in the order they were added), {@code segment}, and {@code t} from 0
     * to 1 along it, with {@code face} NONE -- or a solid's {@code face} at ({@code u}, {@code
     * v}), with {@code loopIndex} and {@code segment} NONE. NONE is {@code 0xFFFFFFFF}, read
     * into a Java {@code int} as -1.
     */
    public record Spot(int loopIndex, int segment, double t, int face, double u, double v) {
    }

    /**
     * What {@link Solid#hits} found, copied out: {@code hits} (ordered along the profile;
     * {@code aStart}/{@code aEnd} on the profile, {@code bStart}/{@code bEnd} on the solid's
     * faces: a face at (u, v)) and {@code pieces} (empty for an open body).
     */
    public record SolidHits(List<Hit> hits, List<Piece> pieces) {
        @Override
        public String toString() {
            return "SolidHits(hits=" + hits.size() + ", pieces=" + pieces.size() + ")";
        }
    }

    /**
     * One stretch of a profile loop between two cuts ({@link SolidHits#pieces}): {@code inside}
     * (by its middle's winding number over the body; a piece lying on the surface is inside),
     * {@code start}/{@code end} (profile spots -- a segment join reads as the next segment's
     * start {@code (k + 1, 0)}, an open chain runs from {@code (0, 0)} to {@code (n - 1, 1)}; a
     * loop no hit cuts is one closed piece) and {@code profile}, the piece's own open chain
     * (what {@link SweepPath#along} with {@code open} sweeps).
     */
    public record Piece(boolean inside, Spot start, Spot end, Profile profile) {
        @Override
        public String toString() {
            return "Piece(inside=" + inside + ", start=" + start + ", end=" + end + ")";
        }
    }

    /**
     * What {@link Solid#intersect} found, copied out: {@code chains} (one per face pair per
     * branch) and {@code overlaps} (one per coincident face pair). Both empty where the solids
     * do not meet.
     */
    public record Intersection(List<Chain> chains, List<Overlap> overlaps) {
        @Override
        public String toString() {
            return "Intersection(chains=" + chains.size() + ", overlaps=" + overlaps.size() + ")";
        }
    }

    /**
     * One branch of one face pair's crossing ({@link Intersection#chains}): {@code points}
     * (three doubles each, in walk order; a closed chain does not repeat its first point),
     * {@code closed}, the faces ({@code faceA} in the first solid, {@code faceB} in the second),
     * {@code tangent} (the surfaces near-tangent along it, or the snap unsettled -- the points
     * their best estimate) and {@code curve}, its exact curve over the chain's own
     * {@code t0..t1}, or null where the kernel found none. A chain may stop at a face boundary
     * or a closed curve's seam and continue as another: join chains by matching ends.
     *
     * @param points three doubles each
     */
    public record Chain(double[][] points, boolean closed, int faceA, int faceB, boolean tangent, Curve curve) {
        @Override
        public String toString() {
            return "Chain(points=" + points.length + ", closed=" + closed + ", faces=(" + faceA + ", " + faceB
                    + "), tangent=" + tangent + ", curve=" + curve + ")";
        }
    }

    /**
     * A face of the first solid and a face of the second that coincide
     * ({@link Intersection#overlaps}): the faces ({@code faceA}, {@code faceB}) and
     * {@code loops}, the shared region's rings as arrays of points (outer first, holes after;
     * each ring closed without repeating its first point) -- empty for a partial overlap whose
     * outlines cross.
     *
     * @param loops each ring an array of points, three doubles each
     */
    public record Overlap(int faceA, int faceB, double[][][] loops) {
        @Override
        public String toString() {
            return "Overlap(faces=(" + faceA + ", " + faceB + "), loops=" + loops.length + ")";
        }
    }

    /**
     * One place two curves meet, copied out. A point ({@code run} false): {@code start} equals
     * {@code end}, and {@code touch} is true where the curves are tangent rather than crossing.
     * A run ({@code run} true): they coincide from {@code start} to {@code end}. {@code
     * aStart}/{@code aEnd} are where on the first curve, {@code bStart}/{@code bEnd} where on
     * the second.
     *
     * @param start three doubles
     * @param end   three doubles
     */
    public record Hit(boolean run, boolean touch, double[] start, double[] end,
                      Spot aStart, Spot aEnd, Spot bStart, Spot bEnd) {
        @Override
        public String toString() {
            return "Hit(run=" + run + ", touch=" + touch + ", start=" + Arrays.toString(start)
                    + ", end=" + Arrays.toString(end) + ")";
        }
    }

    private static Spot spotOf(MemorySegment raw, long base) {
        return new Spot(
                raw.get(ValueLayout.JAVA_INT, base + offset(SPOT, "loop_index")),
                raw.get(ValueLayout.JAVA_INT, base + offset(SPOT, "segment")),
                raw.get(ValueLayout.JAVA_DOUBLE, base + offset(SPOT, "t")),
                raw.get(ValueLayout.JAVA_INT, base + offset(SPOT, "face")),
                raw.get(ValueLayout.JAVA_DOUBLE, base + offset(SPOT, "u")),
                raw.get(ValueLayout.JAVA_DOUBLE, base + offset(SPOT, "v")));
    }

    private static double[] pointOf(MemorySegment raw, long base) {
        return new double[]{
                raw.get(ValueLayout.JAVA_DOUBLE, base + offset(POINT, "x")),
                raw.get(ValueLayout.JAVA_DOUBLE, base + offset(POINT, "y")),
                raw.get(ValueLayout.JAVA_DOUBLE, base + offset(POINT, "z"))};
    }

    private static Hit hitOf(MemorySegment raw) {
        return new Hit(
                raw.get(ValueLayout.JAVA_BOOLEAN, offset(HIT, "run")),
                raw.get(ValueLayout.JAVA_BOOLEAN, offset(HIT, "touch")),
                pointOf(raw, offset(HIT, "start")),
                pointOf(raw, offset(HIT, "end")),
                spotOf(raw, offset(HIT, "a_start")),
                spotOf(raw, offset(HIT, "a_end")),
                spotOf(raw, offset(HIT, "b_start")),
                spotOf(raw, offset(HIT, "b_end")));
    }

    // ---- frames ---------------------------------------------------------------------------

    /**
     * An origin and three unit axes, square to each other and right-handed (z = x × y): the
     * plane a profile is drawn on (its x/y) and the direction it is built along (its z).
     * {@link #toArray()} is the twelve numbers every call taking a {@code frame} reads.
     * Immutable. The constructor normalises the axes and throws {@link BuildException} when
     * they are not square or not right-handed.
     */
    public static final class Frame {
        /** How far from square the axes may be (the cosine between two of them). */
        private static final double SQUARE = 1e-6;

        private final double[] v;

        public Frame(double[] origin, double[] x, double[] y, double[] z) {
            double[] o = point3(origin, "Frame: origin");
            for (double c : o) {
                if (!Double.isFinite(c)) throw new BuildException("Frame: origin must be three finite numbers");
            }
            double[] ux = unit(x, "Frame: x"), uy = unit(y, "Frame: y"), uz = unit(z, "Frame: z");
            if (Math.max(Math.abs(dot(ux, uy)), Math.max(Math.abs(dot(uy, uz)), Math.abs(dot(uz, ux)))) > SQUARE) {
                throw new BuildException("Frame: the axes are not square to each other");
            }
            if (dot(cross(ux, uy), uz) < 0) {
                throw new BuildException("Frame: the axes are left-handed (z must be x × y)");
            }
            v = new double[]{o[0], o[1], o[2], ux[0], ux[1], ux[2], uy[0], uy[1], uy[2], uz[0], uz[1], uz[2]};
            for (int i = 0; i < v.length; i++) v[i] += 0.0; // no -0.0 to print or compare
        }

        /** Twelve numbers -- what {@link Solid#faceFrame} and {@link Workplane#frame()} hand
         *  back -- checked as the constructor checks. */
        public static Frame of(double[] frame) {
            double[] f = frame(frame);
            return new Frame(Arrays.copyOfRange(f, 0, 3), Arrays.copyOfRange(f, 3, 6),
                Arrays.copyOfRange(f, 6, 9), Arrays.copyOfRange(f, 9, 12));
        }

        /** The world XY plane through the origin: z up, as {@link Workplane#xy()}. */
        public static Frame xy() {
            return xy(new double[3]);
        }

        /** The world XY plane through {@code origin}. */
        public static Frame xy(double[] origin) {
            return new Frame(origin, new double[]{1, 0, 0}, new double[]{0, 1, 0}, new double[]{0, 0, 1});
        }

        /** The world XZ plane through the origin: x along X, y along Z, so z is -Y, as
         *  {@link Workplane#xz()}. */
        public static Frame xz() {
            return xz(new double[3]);
        }

        /** The world XZ plane through {@code origin}. */
        public static Frame xz(double[] origin) {
            return new Frame(origin, new double[]{1, 0, 0}, new double[]{0, 0, 1}, new double[]{0, -1, 0});
        }

        /** The world YZ plane through the origin: x along Y, y along Z, so z is +X, as
         *  {@link Workplane#yz()}. */
        public static Frame yz() {
            return yz(new double[3]);
        }

        /** The world YZ plane through {@code origin}. */
        public static Frame yz(double[] origin) {
            return new Frame(origin, new double[]{0, 1, 0}, new double[]{0, 0, 1}, new double[]{1, 0, 0});
        }

        /**
         * The plane through {@code origin} square to {@code normal} (the frame's z). Its x
         * axis is world X laid onto that plane, or world Y when the normal is within about
         * 25° of X, the axes {@link Solid#faceFrame} gives a face facing {@code normal} -- so a
         * normal along +Z, -Y or +X gives exactly {@link #xy}, {@link #xz} or
         * {@link #yz}.
         */
        /** The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line. */
        public static Frame midplane(Frame a, Frame b) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment sa = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, a.toArray());
                MemorySegment sb = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, b.toArray());
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 12);
                boolean ok = call(() -> (boolean) FRAME_MIDPLANE.invokeExact(sa, sb, out));
                if (!ok) throw failure("frame_midplane");
                return of(out.toArray(ValueLayout.JAVA_DOUBLE));
            }
        }

        /** The plane through three points: its origin p, its x towards q, its z the normal they turn about counter-clockwise. Throws for three points on one line. */
        public static Frame through(double[] p, double[] q, double[] r) {
            double[] a = point3(p, "p"), b = point3(q, "q"), c = point3(r, "r");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment sp = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, a);
                MemorySegment sq = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, b);
                MemorySegment sr = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, c);
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 12);
                boolean ok = call(() -> (boolean) FRAME_THROUGH.invokeExact(sp, sq, sr, out));
                if (!ok) throw failure("frame_through");
                return of(out.toArray(ValueLayout.JAVA_DOUBLE));
            }
        }

        public static Frame at(double[] origin, double[] normal) {
            double[] z = unit(normal, "Frame.at: normal");
            return at(origin, z, Math.abs(z[0]) <= 0.9 ? new double[]{1, 0, 0} : new double[]{0, 1, 0});
        }

        /** As {@link #at(double[], double[])}, with its x axis {@code x} laid onto the plane. */
        public static Frame at(double[] origin, double[] normal, double[] x) {
            double[] z = unit(normal, "Frame.at: normal");
            double[] hint = unit(x, "Frame.at: x");
            double d = dot(hint, z);
            if (Math.abs(d) > 1 - SQUARE) throw new BuildException("Frame.at: x lies along the normal");
            double[] ax = unit(new double[]{hint[0] - d * z[0], hint[1] - d * z[1], hint[2] - d * z[2]}, "Frame.at: x");
            return new Frame(origin, ax, cross(z, ax), z);
        }

        public double[] origin() {
            return Arrays.copyOfRange(v, 0, 3);
        }

        public double[] x() {
            return Arrays.copyOfRange(v, 3, 6);
        }

        public double[] y() {
            return Arrays.copyOfRange(v, 6, 9);
        }

        public double[] z() {
            return Arrays.copyOfRange(v, 9, 12);
        }

        /** This frame moved by ({@code dx}, {@code dy}, {@code dz}) in world coordinates. */
        public Frame translate(double dx, double dy, double dz) {
            return new Frame(new double[]{v[0] + dx, v[1] + dy, v[2] + dz}, x(), y(), z());
        }

        /** This frame moved {@code distance} along its own z. */
        public Frame offset(double distance) {
            return translate(distance * v[9], distance * v[10], distance * v[11]);
        }

        /** The twelve numbers: origin, x, y, z -- a copy, to pass wherever a frame goes. */
        public double[] toArray() {
            return v.clone();
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof Frame f && Arrays.equals(v, f.v);
        }

        @Override
        public int hashCode() {
            return Arrays.hashCode(v);
        }

        @Override
        public String toString() {
            return "Frame(origin=" + Arrays.toString(origin()) + ", x=" + Arrays.toString(x()) + ", y="
                + Arrays.toString(y()) + ", z=" + Arrays.toString(z()) + ")";
        }

        private static double dot(double[] a, double[] b) {
            return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        }

        private static double[] cross(double[] a, double[] b) {
            return new double[]{a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
        }

        private static double[] unit(double[] v, String what) {
            double[] p = point3(v, what);
            double n = Math.sqrt(dot(p, p));
            if (!(n > 1e-12 && Double.isFinite(n))) throw new BuildException(what + " has no direction");
            return new double[]{p[0] / n, p[1] / n, p[2] / n};
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

        /** The flat sheet {@code profile} bounds on this workplane's frame. */
        public Workplane face(Profile profile) {
            return set(Solid.face(profile, frame));
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
