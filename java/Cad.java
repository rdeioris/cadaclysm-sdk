// The cadaclysm C ABI, as Java objects: this file is the whole binding.
//
//     try (Cad.Scene scene = Cad.open("part.stp")) {
//         System.out.println(scene.version() + " " + scene.schema() + " " + scene.metresPerUnit());
//         for (Cad.Node root : scene.roots()) walk(root, 0);
//     }
//
// Through the Foreign Function and Memory API, declared by hand from the published header.
// No JNI, no generated bindings, no third-party interop library -- if this draws your part,
// so will your engine. Point CADACLYSM_LIBRARY at the shared library if it is not in the
// place the loader looks by default.
//
// This is a transcription of examples/cadaclysm.py onto the same object model the C# and Go
// bindings already carry -- same names (camelCase here), same arguments and defaults (Java
// overloads standing in for Python's keyword arguments), same C calls. See Cad.java's own
// nested types for the shape: Scene, Node, Placement, Mesh, Polylines, Surfaces.
//
// ## Everything borrows from the scene
//
// Every pointer this ABI hands back -- names, ids, attribute text, vertex and index arrays --
// points into the open document and dies with it. A scene dropped without `close()` is closed
// once nothing reaches it -- and a buffer cut from one of its meshes reaches it, so reading a
// buffer you still hold is safe until you close the scene yourself. `Mesh` and `Polylines` hand back read-only
// `FloatBuffer`/`IntBuffer` *views* straight over the library's own memory rather than copies:
// an assembly with tens of millions of triangles makes a defensive copy of every mesh a cost
// most callers never asked for, most meshes being uploaded to a GPU and dropped. Call
// `Mesh.copy()` for arrays that must outlive the scene, or read the buffers before
// `Scene.close()` runs.
//
// Strings are the easy half: every `char *` this ABI returns is copied into a `String` on the
// way out, so `Node.name()` and friends outlive anything.
//
// ## One exception: FemMesh owns its own memory
//
// `FemMesh` (`Node.femMesh(..)`) is the one borrowed view here whose owner is **not** the
// scene. It is a handle of your own -- close it (a try-with-resources), or drop it and it is
// freed once nothing reaches it -- and its buffers belong to that handle: `Scene.close()` neither frees one nor
// stales one, and meshing the body again does not either. Only `FemMesh.free()`, or nothing
// reaching the mesh or any buffer cut from it, does.
//
// Every accessor on it asks the handle first, so a buffer **asked for** after `free()` throws
// `CadaclysmException`. A buffer **already in hand** is not protected and cannot be: a
// read-only NIO buffer over a reinterpreted address is a window with no owner left to ask, so
// it reads the freed block instead -- measured: 1.29e-311 where the mesh had 4.0, no throw.
// Copy anything that must outlive an explicit free (`nodes().get(new double[..])`); a buffer of
// a FemMesh merely dropped keeps it alive.
//
// FFM is final since JDK 22 (JEP 454), which is what this file is written against: it needs
// JDK 22 or later. No compiler flags; run with --enable-native-access=ALL-UNNAMED to silence
// the restricted-method warning.
import java.io.IOException;
import java.io.InputStream;
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
import java.math.BigDecimal;
import java.nio.ByteOrder;
import java.nio.DoubleBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.CodeSource;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * An open document's reader, as a class of statics plus the nested types they hand back.
 *
 * <p>See the file header for the whole story: everything a {@link Scene}, {@link Node} or
 * {@link Placement} hands back that is not a copied {@link String} borrows from that scene
 * and dies with it.
 */
public final class Cad {

    private Cad() {
    }

    // ---- the structs the ABI returns by value ----------------------------------------

    private static final MemoryLayout BOUNDS = MemoryLayout.structLayout(
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("min"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("max"));

    // Field order must match the header's CadaclysmMesh exactly; every accessor below reads
    // the struct by these names, so a field missing or misplaced here reads the wrong word.
    // `uvs` and `colors` sit between `normals` and `indices`, which is where the header puts
    // them -- cadaclysm-capi/tests/bindings.rs pins this against the header, by field order
    // and by whether each field is a pointer (ADDRESS against JAVA_INT). It does not pin the
    // exact width, so JAVA_INT becoming JAVA_LONG is still yours to get right.
    private static final MemoryLayout MESH = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.ADDRESS.withName("normals"),
            ValueLayout.ADDRESS.withName("uvs"),
            ValueLayout.ADDRESS.withName("colors"),
            ValueLayout.ADDRESS.withName("indices"),
            ValueLayout.JAVA_INT.withName("vertex_count"),
            ValueLayout.JAVA_INT.withName("index_count"));

    // CadaclysmMesh64: the same five pointers and two counts as MESH, positions/normals/uvs
    // in double rather than float, colors still float (RGBA in 0..1 needs no more) -- pinned
    // by tests/bindings.rs the same way MESH is.
    private static final MemoryLayout MESH64 = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.ADDRESS.withName("normals"),
            ValueLayout.ADDRESS.withName("uvs"),
            ValueLayout.ADDRESS.withName("colors"),
            ValueLayout.ADDRESS.withName("indices"),
            ValueLayout.JAVA_INT.withName("vertex_count"),
            ValueLayout.JAVA_INT.withName("index_count"));

    // CadaclysmBounds64: the same box as BOUNDS, in double. Pinned by bindings.rs against the
    // header's `double min[3]; double max[3];`, field for field, though neither has a pointer
    // to misalign the way BOUNDS's own C# twin (flattened MinX..MaxZ) cannot be pinned this way.
    private static final MemoryLayout BOUNDS64 = MemoryLayout.structLayout(
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_DOUBLE).withName("min"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_DOUBLE).withName("max"));

    /**
     * {@code CadaclysmOpenOptions}. {@code cadaclysm_open_options_init} fills the whole
     * struct the library was built with, so this layout must be at least as long as the
     * header's or init corrupts the heap past it -- intermittently, which is how a missing
     * {@code pick}/{@code pick_user} pair once showed up as heap corruption on one open in
     * three. It may never reorder; pinned by {@code tests/bindings.rs}.
     */
    private static final MemoryLayout OPEN_OPTIONS = MemoryLayout.structLayout(
            ValueLayout.JAVA_LONG.withName("size"),
            ValueLayout.JAVA_INT.withName("convention"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("spec"),
            ValueLayout.JAVA_BOOLEAN.withName("file_units"),
            MemoryLayout.paddingLayout(3),
            ValueLayout.JAVA_INT.withName("uvs"),
            ValueLayout.JAVA_INT.withName("colors"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.JAVA_DOUBLE.withName("source_meters_per_unit"),
            ValueLayout.ADDRESS.withName("schemas"),
            ValueLayout.JAVA_LONG.withName("schema_count"),
            ValueLayout.ADDRESS.withName("schema_text"),
            ValueLayout.JAVA_LONG.withName("schema_length"),
            // The pick hook is not exposed here; init leaves both null, which takes the
            // library's own choice among a zip's candidates.
            ValueLayout.ADDRESS.withName("pick"),
            ValueLayout.ADDRESS.withName("pick_user"));

    /**
     * {@code CadaclysmSvgOptions}. {@code cadaclysm_svg_options_init} fills the whole struct,
     * as {@link #OPEN_OPTIONS}'s init does, so this must be at least as long as the header's
     * and may never reorder. Not padded between {@code up} and {@code azimuth} -- two
     * {@code int}s already land the first {@code double} on an eight-byte boundary -- but four
     * bytes trail {@code flags} to bring the 84-byte struct up to the next multiple of eight,
     * as alignment needs. Pinned by {@code tests/bindings.rs} against the header, as the
     * kernel's {@code CadaclysmBlacksmithSvgOptions} in {@code Blacksmith.java} is.
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

    private static final MemoryLayout POLYLINES = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.ADDRESS.withName("counts"),
            ValueLayout.JAVA_INT.withName("polyline_count"),
            ValueLayout.JAVA_INT.withName("vertex_count"));

    // CadaclysmEdgeColors: a pointer then a count, padded to 8, as BEZIERS is; pinned by
    // bindings.rs.
    private static final MemoryLayout EDGE_COLORS = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("rgba"),
            ValueLayout.JAVA_INT.withName("count"),
            MemoryLayout.paddingLayout(4));

    // CadaclysmBeziers: two pointers then a count, padded to 8; pinned by bindings.rs.
    private static final MemoryLayout BEZIERS = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("points"),
            ValueLayout.ADDRESS.withName("weights"),
            ValueLayout.JAVA_INT.withName("count"),
            MemoryLayout.paddingLayout(4));

    // CadaclysmBeziers64: two pointers then a count, padded to 8, as BEZIERS is; pinned by
    // bindings.rs.
    private static final MemoryLayout BEZIERS64 = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("points"),
            ValueLayout.ADDRESS.withName("weights"),
            ValueLayout.JAVA_INT.withName("count"),
            MemoryLayout.paddingLayout(4));

    // CadaclysmCollision: four ints, then doubles, then two ints -- 200 bytes, naturally
    // 8-aligned at every field, so no padding. Pinned by bindings.rs.
    private static final MemoryLayout COLLISION = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("size"),
            ValueLayout.JAVA_INT.withName("shape"),
            ValueLayout.JAVA_INT.withName("confidence"),
            ValueLayout.JAVA_INT.withName("axis"),
            MemoryLayout.sequenceLayout(16, ValueLayout.JAVA_DOUBLE).withName("frame"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_DOUBLE).withName("half_extent"),
            ValueLayout.JAVA_DOUBLE.withName("radius"),
            ValueLayout.JAVA_DOUBLE.withName("height"),
            ValueLayout.JAVA_DOUBLE.withName("error"),
            ValueLayout.JAVA_INT.withName("hull_vertex_count"),
            ValueLayout.JAVA_INT.withName("hull_index_count"));

    private static final MemoryLayout COLLISION_HULL = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.ADDRESS.withName("indices"),
            ValueLayout.JAVA_INT.withName("vertex_count"),
            ValueLayout.JAVA_INT.withName("index_count"));

    // {const char* name; enum kind; const char* text; int64_t integer; double real; bool
    // boolean;}. An enum is a C int (4 bytes); the compiler pads 4 bytes before the 8-byte
    // aligned int64_t that follows, and 7 bytes after the trailing bool to bring the whole
    // struct back up to 8-byte alignment.
    private static final MemoryLayout ATTRIBUTE = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("name"),
            ValueLayout.JAVA_INT.withName("kind"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("text"),
            ValueLayout.JAVA_LONG.withName("integer"),
            ValueLayout.JAVA_DOUBLE.withName("real"),
            ValueLayout.JAVA_BOOLEAN.withName("boolean"),
            MemoryLayout.paddingLayout(7));

    // CadaclysmTaskTime: nine (bool, double) pairs; each bool is followed by seven bytes of
    // padding to the double's 8-byte alignment -- 144 bytes. Pinned by bindings.rs.
    private static final MemoryLayout TASK_TIME = MemoryLayout.structLayout(
            ValueLayout.JAVA_BOOLEAN.withName("has_schedule_start"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("schedule_start"),
            ValueLayout.JAVA_BOOLEAN.withName("has_schedule_finish"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("schedule_finish"),
            ValueLayout.JAVA_BOOLEAN.withName("has_early_start"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("early_start"),
            ValueLayout.JAVA_BOOLEAN.withName("has_early_finish"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("early_finish"),
            ValueLayout.JAVA_BOOLEAN.withName("has_late_start"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("late_start"),
            ValueLayout.JAVA_BOOLEAN.withName("has_late_finish"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("late_finish"),
            ValueLayout.JAVA_BOOLEAN.withName("has_actual_start"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("actual_start"),
            ValueLayout.JAVA_BOOLEAN.withName("has_actual_finish"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("actual_finish"),
            ValueLayout.JAVA_BOOLEAN.withName("has_duration"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("duration"));

    // CadaclysmElementState: two ints, a double, a bool padded to the next double -- 32
    // bytes. Pinned by bindings.rs.
    private static final MemoryLayout ELEMENT_STATE = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("node"),
            ValueLayout.JAVA_INT.withName("phase"),
            ValueLayout.JAVA_DOUBLE.withName("progress"),
            ValueLayout.JAVA_BOOLEAN.withName("has_variance"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("variance"));

    // CadaclysmFace: no pointers at all, so every field is naturally 4-byte aligned and the
    // struct needs no padding of its own -- unlike SURFACES below, whose pointers force a gap
    // after each interleaved count.
    private static final MemoryLayout FACE = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("kind"),
            ValueLayout.JAVA_INT.withName("reversed"),
            ValueLayout.JAVA_INT.withName("transposed"),
            ValueLayout.JAVA_INT.withName("reserved"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_FLOAT).withName("origin"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_FLOAT).withName("ax"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_FLOAT).withName("ay"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_FLOAT).withName("az"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_FLOAT).withName("domain"),
            MemoryLayout.sequenceLayout(4, ValueLayout.JAVA_FLOAT).withName("scalars"),
            ValueLayout.JAVA_INT.withName("loop_start"),
            ValueLayout.JAVA_INT.withName("loop_count"),
            ValueLayout.JAVA_INT.withName("profile_start"),
            ValueLayout.JAVA_INT.withName("profile_count"),
            ValueLayout.JAVA_INT.withName("profile2_start"),
            ValueLayout.JAVA_INT.withName("profile2_count"),
            ValueLayout.JAVA_INT.withName("nurbs_start"),
            ValueLayout.JAVA_INT.withName("nurbs_count"));

    // CadaclysmSurfaces: a pointer then a count, six times over. Each count needs four bytes
    // of padding to bring the next pointer back onto an eight-byte boundary. This is the
    // return layout of cadaclysm_node_surfaces, so a copy that stops short is a buffer the
    // callee writes past: every field is here whether Node.surfaces reads it or not. Pinned,
    // offsets and size included, by bindings.rs.
    private static final MemoryLayout SURFACES = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("faces"),
            ValueLayout.JAVA_INT.withName("face_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("loops"),
            ValueLayout.JAVA_INT.withName("loop_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("points"),
            ValueLayout.JAVA_INT.withName("point_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("profiles"),
            ValueLayout.JAVA_INT.withName("profile_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("nurbs"),
            ValueLayout.JAVA_INT.withName("nurbs_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("shared"),
            ValueLayout.JAVA_INT.withName("shared_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("duplicate"),
            ValueLayout.JAVA_INT.withName("duplicate_count"),
            MemoryLayout.paddingLayout(4));

    /**
     * {@code CadaclysmFemOptions}. Field order and {@code size} are the whole contract, as
     * {@link #OPEN_OPTIONS} above: {@code cadaclysm_fem_options_init} fills the library's
     * <em>whole</em> struct, so a field the library has and this layout does not is written
     * past what {@link Node#femMesh(double, double, double[])} allocated. It may never
     * reorder; pinned field for field, and width for width, by {@code tests/bindings.rs}.
     */
    private static final MemoryLayout FEM_OPTIONS = MemoryLayout.structLayout(
            ValueLayout.JAVA_LONG.withName("size"),
            ValueLayout.JAVA_DOUBLE.withName("tolerance"),
            ValueLayout.JAVA_DOUBLE.withName("max_size"));

    // CadaclysmFemMeshView: every pointer here is borrowed from the FEM handle rather than
    // from the scene, and dies with `cadaclysm_fem_mesh_free`. The paddings are the ones a C
    // compiler inserts: four bytes after each count that a pointer follows, two after the two
    // bools to bring `min_angle` onto eight, and four after `worst_triangle` before
    // `longest_edge`. `structLayout` refuses a misaligned field, so a missing padding is a
    // build failure here rather than a silent misread -- but a padding in the *wrong place*
    // still aligns, which is what bindings.rs pins.
    private static final MemoryLayout FEM_MESH_VIEW = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("nodes"),
            ValueLayout.JAVA_INT.withName("node_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("triangles"),
            ValueLayout.JAVA_INT.withName("triangle_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("triangle_face"),
            ValueLayout.ADDRESS.withName("node_kind"),
            ValueLayout.ADDRESS.withName("node_entity"),
            ValueLayout.JAVA_INT.withName("face_count"),
            ValueLayout.JAVA_INT.withName("edge_count"),
            ValueLayout.JAVA_INT.withName("vertex_count"),
            ValueLayout.JAVA_INT.withName("open_edge_count"),
            ValueLayout.JAVA_INT.withName("folded_edge_count"),
            ValueLayout.JAVA_BOOLEAN.withName("watertight"),
            ValueLayout.JAVA_BOOLEAN.withName("from_mesh"),
            MemoryLayout.paddingLayout(2),
            ValueLayout.JAVA_DOUBLE.withName("min_angle"),
            ValueLayout.JAVA_INT.withName("worst_triangle"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.JAVA_DOUBLE.withName("longest_edge"));

    // CadaclysmFemEdge: one B-rep edge's node chain, filled in by
    // `cadaclysm_fem_mesh_edge`. `nodes` and `runs` are pointers into the handle, read out
    // as arrays of our own (see FemEdge).
    private static final MemoryLayout FEM_EDGE = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("id"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("nodes"),
            ValueLayout.JAVA_INT.withName("node_count"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("runs"),
            ValueLayout.JAVA_INT.withName("run_count"),
            ValueLayout.JAVA_INT.withName("face_a"),
            ValueLayout.JAVA_INT.withName("face_b"),
            ValueLayout.JAVA_INT.withName("end_a"),
            ValueLayout.JAVA_INT.withName("end_b"),
            ValueLayout.JAVA_BOOLEAN.withName("closed"),
            ValueLayout.JAVA_BOOLEAN.withName("seam"),
            MemoryLayout.paddingLayout(2));

    // CadaclysmFemVertex: `point` is three doubles held in the struct itself, not a pointer,
    // so it is one sequenceLayout -- the shape BOUNDS64's own min/max have.
    private static final MemoryLayout FEM_VERTEX = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("node"),
            MemoryLayout.paddingLayout(4),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_DOUBLE).withName("point"),
            ValueLayout.JAVA_BOOLEAN.withName("has_position"),
            MemoryLayout.paddingLayout(7));

    // CadaclysmFreedom: each 1-byte bool is followed by 7 padding bytes to bring the next
    // double back onto an eight-byte boundary, the same rule ATTRIBUTE and FEM_VERTEX follow.
    private static final MemoryLayout FREEDOM = MemoryLayout.structLayout(
            ValueLayout.JAVA_INT.withName("motion"),
            ValueLayout.JAVA_INT.withName("axis"),
            ValueLayout.JAVA_BOOLEAN.withName("has_lower"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("lower"),
            ValueLayout.JAVA_BOOLEAN.withName("has_upper"),
            MemoryLayout.paddingLayout(7),
            ValueLayout.JAVA_DOUBLE.withName("upper"));

    // ---- loading the library, and every entry point ----------------------------------

    private static final MethodHandle LAST_ERROR, VERSION, LICENSE_SET, LICENSE_INFO,
            LICENSE_NOTICE_COUNT, BUILD_DATE, OPEN, OPEN_MEMORY, OPEN_OPTIONS_INIT, CLOSE,
            SOURCE_NAME, NODE_COUNT, ROOT_COUNT, ROOT, SCHEMA, SCHEMA_READ, METRES_PER_UNIT, TOLERANCES,
            BOUNDS_OF, NODE_PARENT, NODE_CHILD_COUNT, NODE_CHILD, NODE_DEPTH, NODE_NAME,
            NODE_KIND, NODE_VISIBLE, NODE_SAVE_MESH, SCENE_SAVE, MESH_FORMAT_COUNT,
            MESH_FORMAT, MESH_FORMAT_EXTENSION, QUERY, PICK_FILE, NODE_ID, NODE_COLOR,
            NODE_TRANSFORM, NODE_ATTRIBUTE_COUNT, NODE_ATTRIBUTE, PLACEMENT_COUNT,
            PLACEMENT_GEOMETRY, PLACEMENT_SELECT, PLACEMENT_TRANSFORM, NODE_CAN_MESH,
            NODE_MESH, NODE_SURFACES, SURFACE_MATRIX, NODE_BOUNDS, NODE_INSTANCE_OF,
            NODE_SELECT_AS, NODE_GENERATOR, DIAGNOSTIC_COUNT, DIAGNOSTIC, NODE_EDGES,
            NODE_CURVES, NODE_ISOCURVES, REALIZE_ALL, REALIZED, REALIZE_TOTAL, CANCEL,
            NODE_BREP, BREP_RELEASE, BREP_LAYOUT_ID, BREP_MANIFOLD, BREP_SEW, MESH_FORMAT_LABEL,
            BREP_HEALTH, BREP_HEALTH_FREE, BREP_HEALTH_SUMMARY, BREP_HEALTH_FREE_EDGES, BREP_HEALTH_WIRES,
            BREP_HEALTH_SMALL, BREP_HEALTH_CRACK_EDGES, BREP_HEALED, BREP_HEAL_BODY, BREP_HEAL_FREE,
            BREP_HEAL_SUMMARY, BREP_HEAL_FIXES, BREP_HEAL_REFUSED, BREP_EDGE_TOLERANCE,
            FORMAT_COUNT, FORMAT_NAME, FORMAT_EXTENSIONS, PICK_SAVE, GEOMETRY_DIAGNOSTIC_COUNT,
            GEOMETRY_DIAGNOSTIC, FORGET_MESHES, LOD_LEVELS, NODE_MESH_LOD, NODE_LOD_ERROR,
            NODE_EDGE_BEZIERS, NODE_CURVE_BEZIERS, NODE_ISOCURVE_BEZIERS,
            NODE_COLLISION, NODE_COLLISION_HULL,
            MESHLETS_BUILD, MESHLETS_COUNT, MESHLETS_FREE, MESHLET_TRIANGLE_COUNT, MESHLET_VERTEX_COUNT,
            MESHLET_LEVEL, MESHLET_GROUP, MESHLET_ERROR, MESHLET_CHILD_COUNT, MESHLET_POSITIONS,
            MESHLET_NORMALS, MESHLET_INDICES, MESHLET_CHILDREN,
            NODE_BOUNDS_PLACED, NODE_IS_MESHED, NODE_SURFACE_EDGES, NODE_SURFACE_EDGE_BEZIERS, NODE_SURFACE_ISOCURVES,
            NODE_SURFACE_PICK, NODE_SURFACE_PROXY_MESH, NODE_TRIANGLE_ESTIMATE, REALIZE_MESHES,
            SVG_OPTIONS_INIT, SCENE_SVG_TEXT, SCENE_SVG, NODE_SVG_TEXT, NODE_SVG, NODE_SILHOUETTE_BEZIERS,
            NODE_MESH64, NODE_EDGE_BEZIERS64, NODE_CURVE_BEZIERS64, NODE_ISOCURVE_BEZIERS64,
            NODE_BOUNDS64, NODE_BOUNDS_PLACED64, BOUNDS64_ALL,
            LINK_COUNT, LINK_NAME, LINK_NODE_COUNT, LINK_NODE,
            JOINT_COUNT, JOINT_NAME, JOINT_START, JOINT_END,
            JOINT_PAIR_KIND, JOINT_PAIR_TYPE, JOINT_PAIR_KIND_NAME, JOINT_PAIR_PARAMETERS, JOINT_PAIR_PITCH, JOINT_PAIR_FRAMES,
            JOINT_FREEDOM_COUNT, JOINT_FREEDOM, STATE_COUNT, STATE_NAME, STATE_VALUE_COUNT, STATE_VALUE,
            SEQUENCE_COUNT, SEQUENCE_NAME, SEQUENCE_CLOSED, SEQUENCE_SECONDS_PER_UNIT, SEQUENCE_SEGMENT_COUNT, SEQUENCE_SEGMENT, POSE_SEQUENCE,
            SCHEDULE_COUNT, SCHEDULE_NAME, SCHEDULE_IDENTIFICATION, SCHEDULE_KIND, SCHEDULE_KIND_NAME, SCHEDULE_START, SCHEDULE_FINISH,
            TASK_COUNT, TASK_NAME, TASK_IDENTIFICATION, TASK_KIND, TASK_KIND_NAME, TASK_STATUS, TASK_MILESTONE, TASK_PARENT,
            TASK_TIME_OF, TASK_NODE_COUNT, TASK_NODES, TASK_LINK_COUNT, TASK_LINK, TASK_LINK_KIND_NAME, SCHEDULE_AT,
            POSE, POSE_STATE, POSE_FREE, POSE_GROUND, POSE_NODE_COUNT, POSE_NODE_TRANSFORM,
            POSE_UNSOLVED_COUNT, POSE_UNSOLVED, POSE_DIAGNOSTIC_COUNT, POSE_DIAGNOSTIC, POSE_OUT_OF_RANGE_COUNT, POSE_OUT_OF_RANGE, KINEMATICS_BASE,
            FEM_OPTIONS_INIT, NODE_FEM_MESH, FEM_VIEW, FEM_EDGE_AT, FEM_VERTEX_AT,
            FEM_OPEN_EDGE, FEM_FOLDED_EDGE, FEM_CROSSING_COUNT, FEM_CROSSING, FEM_MSH_TEXT, FEM_SAVE_MSH, FEM_FREE,
            NODE_EDGE_COLORS, NODE_SURFACE_EDGE_COLORS, PARSE_COLOUR;

    static {
        SymbolLookup lib = Loader.resolve(Loader.CAPI_LIBRARY);
        Linker linker = Linker.nativeLinker();
        ValueLayout.OfInt I = ValueLayout.JAVA_INT;
        ValueLayout.OfLong L = ValueLayout.JAVA_LONG;
        ValueLayout.OfDouble D = ValueLayout.JAVA_DOUBLE;
        ValueLayout.OfFloat F = ValueLayout.JAVA_FLOAT;
        ValueLayout.OfBoolean B = ValueLayout.JAVA_BOOLEAN;
        var A = ValueLayout.ADDRESS;

        LAST_ERROR = bind(linker, lib, "cadaclysm_last_error", FunctionDescriptor.of(A));
        VERSION = bind(linker, lib, "cadaclysm_version", FunctionDescriptor.of(A));
        LICENSE_SET = bind(linker, lib, "cadaclysm_license_set", FunctionDescriptor.of(B, A));
        LICENSE_INFO = bind(linker, lib, "cadaclysm_license_info", FunctionDescriptor.of(A));
        LICENSE_NOTICE_COUNT = bind(linker, lib, "cadaclysm_license_notice_count", FunctionDescriptor.of(L));
        BUILD_DATE = bind(linker, lib, "cadaclysm_build_date", FunctionDescriptor.of(A));
        OPEN = bind(linker, lib, "cadaclysm_open", FunctionDescriptor.of(A, A, A));
        OPEN_MEMORY = bind(linker, lib, "cadaclysm_open_memory", FunctionDescriptor.of(A, A, L, A, A));
        OPEN_OPTIONS_INIT = bind(linker, lib, "cadaclysm_open_options_init", FunctionDescriptor.ofVoid(A));
        CLOSE = bind(linker, lib, "cadaclysm_close", FunctionDescriptor.ofVoid(A));
        SOURCE_NAME = bind(linker, lib, "cadaclysm_source_name", FunctionDescriptor.of(A, A));
        NODE_COUNT = bind(linker, lib, "cadaclysm_node_count", FunctionDescriptor.of(I, A));
        ROOT_COUNT = bind(linker, lib, "cadaclysm_root_count", FunctionDescriptor.of(I, A));
        ROOT = bind(linker, lib, "cadaclysm_root", FunctionDescriptor.of(I, A, I));
        SCHEMA = bind(linker, lib, "cadaclysm_schema", FunctionDescriptor.of(A, A));
        SCHEMA_READ = bind(linker, lib, "cadaclysm_schema_read", FunctionDescriptor.of(A, A));
        METRES_PER_UNIT = bind(linker, lib, "cadaclysm_metres_per_unit", FunctionDescriptor.of(D, A));
        TOLERANCES = bind(linker, lib, "cadaclysm_tolerances", FunctionDescriptor.of(B, A, A, A));
        BOUNDS_OF = bind(linker, lib, "cadaclysm_bounds", FunctionDescriptor.of(BOUNDS, A));
        NODE_PARENT = bind(linker, lib, "cadaclysm_node_parent", FunctionDescriptor.of(I, A, I));
        NODE_CHILD_COUNT = bind(linker, lib, "cadaclysm_node_child_count", FunctionDescriptor.of(I, A, I));
        NODE_CHILD = bind(linker, lib, "cadaclysm_node_child", FunctionDescriptor.of(I, A, I, I));
        NODE_DEPTH = bind(linker, lib, "cadaclysm_node_depth", FunctionDescriptor.of(I, A, I));
        NODE_NAME = bind(linker, lib, "cadaclysm_node_name", FunctionDescriptor.of(A, A, I));
        NODE_KIND = bind(linker, lib, "cadaclysm_node_kind", FunctionDescriptor.of(A, A, I));
        NODE_VISIBLE = bind(linker, lib, "cadaclysm_node_visible", FunctionDescriptor.of(B, A, I));
        NODE_SAVE_MESH = bind(linker, lib, "cadaclysm_node_save_mesh", FunctionDescriptor.of(B, A, I, A, A));
        SCENE_SAVE = bind(linker, lib, "cadaclysm_scene_save", FunctionDescriptor.of(B, A, A, A));
        MESH_FORMAT_COUNT = bind(linker, lib, "cadaclysm_mesh_format_count", FunctionDescriptor.of(I));
        MESH_FORMAT = bind(linker, lib, "cadaclysm_mesh_format", FunctionDescriptor.of(A, I));
        MESH_FORMAT_EXTENSION = bind(linker, lib, "cadaclysm_mesh_format_extension", FunctionDescriptor.of(A, I));
        QUERY = bind(linker, lib, "cadaclysm_query", FunctionDescriptor.of(I, A, A, A, I));
        PICK_FILE = bind(linker, lib, "cadaclysm_pick_file", FunctionDescriptor.of(A, A));
        NODE_ID = bind(linker, lib, "cadaclysm_node_id", FunctionDescriptor.of(A, A, I));
        NODE_COLOR = bind(linker, lib, "cadaclysm_node_color", FunctionDescriptor.of(B, A, I, A));
        NODE_TRANSFORM = bind(linker, lib, "cadaclysm_node_transform", FunctionDescriptor.ofVoid(A, I, A));
        NODE_ATTRIBUTE_COUNT = bind(linker, lib, "cadaclysm_node_attribute_count", FunctionDescriptor.of(I, A, I));
        NODE_ATTRIBUTE = bind(linker, lib, "cadaclysm_node_attribute", FunctionDescriptor.of(ATTRIBUTE, A, I, I));
        PLACEMENT_COUNT = bind(linker, lib, "cadaclysm_placement_count", FunctionDescriptor.of(I, A));
        PLACEMENT_GEOMETRY = bind(linker, lib, "cadaclysm_placement_geometry", FunctionDescriptor.of(I, A, I));
        PLACEMENT_SELECT = bind(linker, lib, "cadaclysm_placement_select", FunctionDescriptor.of(I, A, I));
        PLACEMENT_TRANSFORM = bind(linker, lib, "cadaclysm_placement_transform", FunctionDescriptor.ofVoid(A, I, A));
        NODE_CAN_MESH = bind(linker, lib, "cadaclysm_node_can_mesh", FunctionDescriptor.of(B, A, I));
        NODE_MESH = bind(linker, lib, "cadaclysm_node_mesh", FunctionDescriptor.of(MESH, A, I));
        NODE_SURFACES = bind(linker, lib, "cadaclysm_node_surfaces", FunctionDescriptor.of(SURFACES, A, I));
        SURFACE_MATRIX = bind(linker, lib, "cadaclysm_surface_matrix", FunctionDescriptor.ofVoid(A, A));
        NODE_BOUNDS = bind(linker, lib, "cadaclysm_node_bounds", FunctionDescriptor.of(BOUNDS, A, I));
        NODE_INSTANCE_OF = bind(linker, lib, "cadaclysm_node_instance_of", FunctionDescriptor.of(I, A, I));
        NODE_SELECT_AS = bind(linker, lib, "cadaclysm_node_select_as", FunctionDescriptor.of(I, A, I));
        NODE_GENERATOR = bind(linker, lib, "cadaclysm_node_generator", FunctionDescriptor.of(A, A, I));
        DIAGNOSTIC_COUNT = bind(linker, lib, "cadaclysm_diagnostic_count", FunctionDescriptor.of(I, A));
        DIAGNOSTIC = bind(linker, lib, "cadaclysm_diagnostic", FunctionDescriptor.of(A, A, I));
        NODE_EDGES = bind(linker, lib, "cadaclysm_node_edges", FunctionDescriptor.of(POLYLINES, A, I));
        NODE_EDGE_COLORS = bind(linker, lib, "cadaclysm_node_edge_colors", FunctionDescriptor.of(EDGE_COLORS, A, I));
        NODE_CURVES = bind(linker, lib, "cadaclysm_node_curves", FunctionDescriptor.of(POLYLINES, A, I));
        NODE_ISOCURVES = bind(linker, lib, "cadaclysm_node_isocurves", FunctionDescriptor.of(POLYLINES, A, I));
        REALIZE_ALL = bind(linker, lib, "cadaclysm_realize_all", FunctionDescriptor.of(I, A));
        REALIZED = bind(linker, lib, "cadaclysm_realized", FunctionDescriptor.of(I, A));
        REALIZE_TOTAL = bind(linker, lib, "cadaclysm_realize_total", FunctionDescriptor.of(I, A));
        CANCEL = bind(linker, lib, "cadaclysm_cancel", FunctionDescriptor.ofVoid(A));
        NODE_BREP = bind(linker, lib, "cadaclysm_node_brep", FunctionDescriptor.of(A, A, I));
        BREP_RELEASE = bind(linker, lib, "cadaclysm_brep_release", FunctionDescriptor.ofVoid(A));
        BREP_LAYOUT_ID = bind(linker, lib, "cadaclysm_brep_layout_id", FunctionDescriptor.of(A));
        BREP_MANIFOLD = bind(linker, lib, "cadaclysm_brep_manifold", FunctionDescriptor.of(B, A, A));
        BREP_SEW = bind(linker, lib, "cadaclysm_brep_sew", FunctionDescriptor.of(A, A, D, D, A, A));
        BREP_HEALTH = bind(linker, lib, "cadaclysm_brep_health", FunctionDescriptor.of(A, A, D, B));
        BREP_HEALTH_FREE = bind(linker, lib, "cadaclysm_brep_health_free", FunctionDescriptor.ofVoid(A));
        BREP_HEALTH_SUMMARY = bind(linker, lib, "cadaclysm_brep_health_summary", FunctionDescriptor.of(B, A, A, A));
        BREP_HEALTH_FREE_EDGES = bind(linker, lib, "cadaclysm_brep_health_free_edges", FunctionDescriptor.of(I, A, A, A));
        BREP_HEALTH_WIRES = bind(linker, lib, "cadaclysm_brep_health_wires", FunctionDescriptor.of(I, A, A, A));
        BREP_HEALTH_SMALL = bind(linker, lib, "cadaclysm_brep_health_small", FunctionDescriptor.of(I, A, A, A));
        BREP_HEALTH_CRACK_EDGES = bind(linker, lib, "cadaclysm_brep_health_crack_edges", FunctionDescriptor.of(I, A, A));
        BREP_HEALED = bind(linker, lib, "cadaclysm_brep_healed", FunctionDescriptor.of(A, A, D, I));
        BREP_HEAL_BODY = bind(linker, lib, "cadaclysm_brep_heal_body", FunctionDescriptor.of(A, A));
        BREP_HEAL_FREE = bind(linker, lib, "cadaclysm_brep_heal_free", FunctionDescriptor.ofVoid(A));
        BREP_HEAL_SUMMARY = bind(linker, lib, "cadaclysm_brep_heal_summary", FunctionDescriptor.of(B, A, A, A));
        BREP_HEAL_FIXES = bind(linker, lib, "cadaclysm_brep_heal_fixes", FunctionDescriptor.of(I, A, A, A));
        BREP_HEAL_REFUSED = bind(linker, lib, "cadaclysm_brep_heal_refused", FunctionDescriptor.of(I, A, A, A));
        BREP_EDGE_TOLERANCE = bind(linker, lib, "cadaclysm_brep_edge_tolerance", FunctionDescriptor.of(D, A, I));
        MESH_FORMAT_LABEL = bind(linker, lib, "cadaclysm_mesh_format_label", FunctionDescriptor.of(A, I));
        FORMAT_COUNT = bind(linker, lib, "cadaclysm_format_count", FunctionDescriptor.of(I));
        FORMAT_NAME = bind(linker, lib, "cadaclysm_format_name", FunctionDescriptor.of(A, I));
        FORMAT_EXTENSIONS = bind(linker, lib, "cadaclysm_format_extensions", FunctionDescriptor.of(A, I));
        PICK_SAVE = bind(linker, lib, "cadaclysm_pick_save", FunctionDescriptor.of(A, A, A));
        GEOMETRY_DIAGNOSTIC_COUNT = bind(linker, lib, "cadaclysm_geometry_diagnostic_count", FunctionDescriptor.of(I, A));
        GEOMETRY_DIAGNOSTIC = bind(linker, lib, "cadaclysm_geometry_diagnostic", FunctionDescriptor.of(A, A, I));
        FORGET_MESHES = bind(linker, lib, "cadaclysm_forget_meshes", FunctionDescriptor.ofVoid(A));
        LOD_LEVELS = bind(linker, lib, "cadaclysm_lod_levels", FunctionDescriptor.of(I));
        NODE_MESH_LOD = bind(linker, lib, "cadaclysm_node_mesh_lod", FunctionDescriptor.of(MESH, A, I, I));
        NODE_LOD_ERROR = bind(linker, lib, "cadaclysm_node_lod_error", FunctionDescriptor.of(F, A, I, I));
        NODE_EDGE_BEZIERS = bind(linker, lib, "cadaclysm_node_edge_beziers", FunctionDescriptor.of(BEZIERS, A, I));
        NODE_CURVE_BEZIERS = bind(linker, lib, "cadaclysm_node_curve_beziers", FunctionDescriptor.of(BEZIERS, A, I));
        NODE_ISOCURVE_BEZIERS = bind(linker, lib, "cadaclysm_node_isocurve_beziers", FunctionDescriptor.of(BEZIERS, A, I));
        NODE_COLLISION = bind(linker, lib, "cadaclysm_node_collision", FunctionDescriptor.of(B, A, I, I, A));
        NODE_COLLISION_HULL = bind(linker, lib, "cadaclysm_node_collision_hull", FunctionDescriptor.of(COLLISION_HULL, A, I, I));
        MESHLETS_BUILD = bind(linker, lib, "cadaclysm_meshlets_build", FunctionDescriptor.of(A, A, A, L, A, L, I, I, I));
        MESHLETS_COUNT = bind(linker, lib, "cadaclysm_meshlets_count", FunctionDescriptor.of(I, A));
        MESHLETS_FREE = bind(linker, lib, "cadaclysm_meshlets_free", FunctionDescriptor.ofVoid(A));
        MESHLET_TRIANGLE_COUNT = bind(linker, lib, "cadaclysm_meshlet_triangle_count", FunctionDescriptor.of(I, A, I));
        MESHLET_VERTEX_COUNT = bind(linker, lib, "cadaclysm_meshlet_vertex_count", FunctionDescriptor.of(I, A, I));
        MESHLET_LEVEL = bind(linker, lib, "cadaclysm_meshlet_level", FunctionDescriptor.of(I, A, I));
        MESHLET_GROUP = bind(linker, lib, "cadaclysm_meshlet_group", FunctionDescriptor.of(I, A, I));
        MESHLET_ERROR = bind(linker, lib, "cadaclysm_meshlet_error", FunctionDescriptor.of(F, A, I));
        MESHLET_CHILD_COUNT = bind(linker, lib, "cadaclysm_meshlet_child_count", FunctionDescriptor.of(I, A, I));
        MESHLET_POSITIONS = bind(linker, lib, "cadaclysm_meshlet_positions", FunctionDescriptor.ofVoid(A, I, A));
        MESHLET_NORMALS = bind(linker, lib, "cadaclysm_meshlet_normals", FunctionDescriptor.ofVoid(A, I, A));
        MESHLET_INDICES = bind(linker, lib, "cadaclysm_meshlet_indices", FunctionDescriptor.ofVoid(A, I, A));
        MESHLET_CHILDREN = bind(linker, lib, "cadaclysm_meshlet_children", FunctionDescriptor.ofVoid(A, I, A));
        NODE_BOUNDS_PLACED = bind(linker, lib, "cadaclysm_node_bounds_placed", FunctionDescriptor.of(BOUNDS, A, I, A));
        NODE_IS_MESHED = bind(linker, lib, "cadaclysm_node_is_meshed", FunctionDescriptor.of(B, A, I));
        NODE_SURFACE_EDGES = bind(linker, lib, "cadaclysm_node_surface_edges", FunctionDescriptor.of(POLYLINES, A, I));
        NODE_SURFACE_EDGE_BEZIERS = bind(linker, lib, "cadaclysm_node_surface_edge_beziers", FunctionDescriptor.of(BEZIERS, A, I));
        NODE_SURFACE_EDGE_COLORS = bind(linker, lib, "cadaclysm_node_surface_edge_colors", FunctionDescriptor.of(EDGE_COLORS, A, I));
        NODE_SURFACE_ISOCURVES = bind(linker, lib, "cadaclysm_node_surface_isocurves", FunctionDescriptor.of(POLYLINES, A, I));
        NODE_SURFACE_PICK = bind(linker, lib, "cadaclysm_node_surface_pick", FunctionDescriptor.of(B, A, I, A, A, A));
        NODE_SURFACE_PROXY_MESH = bind(linker, lib, "cadaclysm_node_surface_proxy_mesh", FunctionDescriptor.of(MESH, A, I, I));
        NODE_TRIANGLE_ESTIMATE = bind(linker, lib, "cadaclysm_node_triangle_estimate", FunctionDescriptor.of(L, A, I));
        REALIZE_MESHES = bind(linker, lib, "cadaclysm_realize_meshes", FunctionDescriptor.of(I, A, I));
        // The FEM surface mesh. `cadaclysm_fem_mesh_msh_text` hands back a pointer into a slot
        // on the handle, not an owned string, so nothing here frees it -- the kernel library's
        // twin is the other way round. See FemMesh.mshText.
        FEM_OPTIONS_INIT = bind(linker, lib, "cadaclysm_fem_options_init", FunctionDescriptor.ofVoid(A));
        NODE_FEM_MESH = bind(linker, lib, "cadaclysm_node_fem_mesh", FunctionDescriptor.of(A, A, I, A, A));
        FEM_VIEW = bind(linker, lib, "cadaclysm_fem_mesh_view", FunctionDescriptor.of(B, A, A));
        FEM_EDGE_AT = bind(linker, lib, "cadaclysm_fem_mesh_edge", FunctionDescriptor.of(B, A, I, A));
        FEM_VERTEX_AT = bind(linker, lib, "cadaclysm_fem_mesh_vertex", FunctionDescriptor.of(B, A, I, A));
        FEM_OPEN_EDGE = bind(linker, lib, "cadaclysm_fem_mesh_open_edge", FunctionDescriptor.of(B, A, I, A, A, A));
        FEM_FOLDED_EDGE = bind(linker, lib, "cadaclysm_fem_mesh_folded_edge", FunctionDescriptor.of(B, A, I, A, A, A));
        FEM_CROSSING_COUNT = bind(linker, lib, "cadaclysm_fem_mesh_crossing_count", FunctionDescriptor.of(I, A));
        FEM_CROSSING = bind(linker, lib, "cadaclysm_fem_mesh_crossing", FunctionDescriptor.of(B, A, I, A, A));
        FEM_MSH_TEXT = bind(linker, lib, "cadaclysm_fem_mesh_msh_text", FunctionDescriptor.of(A, A));
        FEM_SAVE_MSH = bind(linker, lib, "cadaclysm_fem_mesh_save_msh", FunctionDescriptor.of(B, A, A));
        FEM_FREE = bind(linker, lib, "cadaclysm_fem_mesh_free", FunctionDescriptor.ofVoid(A));
        PARSE_COLOUR = bind(linker, lib, "cadaclysm_parse_colour", FunctionDescriptor.of(B, A, A));
        SVG_OPTIONS_INIT = bind(linker, lib, "cadaclysm_svg_options_init", FunctionDescriptor.ofVoid(A));
        SCENE_SVG_TEXT = bind(linker, lib, "cadaclysm_scene_svg_text", FunctionDescriptor.of(A, A, A));
        SCENE_SVG = bind(linker, lib, "cadaclysm_scene_svg", FunctionDescriptor.of(B, A, A, A));
        NODE_SVG_TEXT = bind(linker, lib, "cadaclysm_node_svg_text", FunctionDescriptor.of(A, A, I, A));
        NODE_SVG = bind(linker, lib, "cadaclysm_node_svg", FunctionDescriptor.of(B, A, I, A, A));
        // BORROWED into a per-scene slot that the next silhouette call on that scene replaces.
        NODE_SILHOUETTE_BEZIERS = bind(linker, lib, "cadaclysm_node_silhouette_beziers", FunctionDescriptor.of(BEZIERS64, A, I, A));
        NODE_MESH64 = bind(linker, lib, "cadaclysm_node_mesh64", FunctionDescriptor.of(MESH64, A, I));
        NODE_EDGE_BEZIERS64 = bind(linker, lib, "cadaclysm_node_edge_beziers64", FunctionDescriptor.of(BEZIERS64, A, I));
        NODE_CURVE_BEZIERS64 = bind(linker, lib, "cadaclysm_node_curve_beziers64", FunctionDescriptor.of(BEZIERS64, A, I));
        NODE_ISOCURVE_BEZIERS64 = bind(linker, lib, "cadaclysm_node_isocurve_beziers64", FunctionDescriptor.of(BEZIERS64, A, I));
        NODE_BOUNDS64 = bind(linker, lib, "cadaclysm_node_bounds64", FunctionDescriptor.of(BOUNDS64, A, I));
        NODE_BOUNDS_PLACED64 = bind(linker, lib, "cadaclysm_node_bounds_placed64", FunctionDescriptor.of(BOUNDS64, A, I, A));
        BOUNDS64_ALL = bind(linker, lib, "cadaclysm_bounds64", FunctionDescriptor.of(BOUNDS64, A));
        LINK_COUNT = bind(linker, lib, "cadaclysm_link_count", FunctionDescriptor.of(I, A));
        LINK_NAME = bind(linker, lib, "cadaclysm_link_name", FunctionDescriptor.of(A, A, I));
        LINK_NODE_COUNT = bind(linker, lib, "cadaclysm_link_node_count", FunctionDescriptor.of(I, A, I));
        LINK_NODE = bind(linker, lib, "cadaclysm_link_node", FunctionDescriptor.of(I, A, I, I));
        JOINT_COUNT = bind(linker, lib, "cadaclysm_joint_count", FunctionDescriptor.of(I, A));
        JOINT_NAME = bind(linker, lib, "cadaclysm_joint_name", FunctionDescriptor.of(A, A, I));
        JOINT_START = bind(linker, lib, "cadaclysm_joint_start", FunctionDescriptor.of(I, A, I));
        JOINT_END = bind(linker, lib, "cadaclysm_joint_end", FunctionDescriptor.of(I, A, I));
        JOINT_PAIR_KIND = bind(linker, lib, "cadaclysm_joint_pair_kind", FunctionDescriptor.of(I, A, I));
        JOINT_PAIR_TYPE = bind(linker, lib, "cadaclysm_joint_pair_type", FunctionDescriptor.of(A, A, I));
        JOINT_PAIR_KIND_NAME = bind(linker, lib, "cadaclysm_joint_pair_kind_name", FunctionDescriptor.of(A, A, I));
        JOINT_PAIR_PARAMETERS = bind(linker, lib, "cadaclysm_joint_pair_parameters", FunctionDescriptor.of(L, A, I, A, L));
        JOINT_PAIR_PITCH = bind(linker, lib, "cadaclysm_joint_pair_pitch", FunctionDescriptor.of(D, A, I));
        JOINT_PAIR_FRAMES = bind(linker, lib, "cadaclysm_joint_pair_frames", FunctionDescriptor.of(B, A, I, A, A));
        JOINT_FREEDOM_COUNT = bind(linker, lib, "cadaclysm_joint_freedom_count", FunctionDescriptor.of(I, A, I));
        JOINT_FREEDOM = bind(linker, lib, "cadaclysm_joint_freedom", FunctionDescriptor.of(B, A, I, I, A));
        STATE_COUNT = bind(linker, lib, "cadaclysm_state_count", FunctionDescriptor.of(I, A));
        STATE_NAME = bind(linker, lib, "cadaclysm_state_name", FunctionDescriptor.of(A, A, I));
        STATE_VALUE_COUNT = bind(linker, lib, "cadaclysm_state_value_count", FunctionDescriptor.of(I, A, I));
        STATE_VALUE = bind(linker, lib, "cadaclysm_state_value", FunctionDescriptor.of(I, A, I, I, A, A, I));
        // Motion sequences (plan 2026-10-05-motion-sequences-2): a sequence's name, closedness,
        // seconds per unit (0 for none), and its segments (state index, parameter, interpolation
        // code); pose_sequence poses the mechanism at a parameter.
        SEQUENCE_COUNT = bind(linker, lib, "cadaclysm_sequence_count", FunctionDescriptor.of(I, A));
        SEQUENCE_NAME = bind(linker, lib, "cadaclysm_sequence_name", FunctionDescriptor.of(A, A, I));
        SEQUENCE_CLOSED = bind(linker, lib, "cadaclysm_sequence_closed", FunctionDescriptor.of(B, A, I));
        SEQUENCE_SECONDS_PER_UNIT = bind(linker, lib, "cadaclysm_sequence_seconds_per_unit", FunctionDescriptor.of(D, A, I));
        SEQUENCE_SEGMENT_COUNT = bind(linker, lib, "cadaclysm_sequence_segment_count", FunctionDescriptor.of(I, A, I));
        SEQUENCE_SEGMENT = bind(linker, lib, "cadaclysm_sequence_segment", FunctionDescriptor.of(B, A, I, I, A, A, A));
        POSE_SEQUENCE = bind(linker, lib, "cadaclysm_pose_sequence", FunctionDescriptor.of(A, A, I, D, I));
        // IFC work schedules (plan 2026-10-06-ifc-4d-2): a schedule's words and dates, its tasks
        // and the links between them, and the state of every element on a date.
        SCHEDULE_COUNT = bind(linker, lib, "cadaclysm_schedule_count", FunctionDescriptor.of(I, A));
        SCHEDULE_NAME = bind(linker, lib, "cadaclysm_schedule_name", FunctionDescriptor.of(A, A, I));
        SCHEDULE_IDENTIFICATION = bind(linker, lib, "cadaclysm_schedule_identification", FunctionDescriptor.of(A, A, I));
        SCHEDULE_KIND = bind(linker, lib, "cadaclysm_schedule_kind", FunctionDescriptor.of(I, A, I));
        SCHEDULE_KIND_NAME = bind(linker, lib, "cadaclysm_schedule_kind_name", FunctionDescriptor.of(A, A, I));
        SCHEDULE_START = bind(linker, lib, "cadaclysm_schedule_start", FunctionDescriptor.of(B, A, I, A));
        SCHEDULE_FINISH = bind(linker, lib, "cadaclysm_schedule_finish", FunctionDescriptor.of(B, A, I, A));
        TASK_COUNT = bind(linker, lib, "cadaclysm_task_count", FunctionDescriptor.of(I, A, I));
        TASK_NAME = bind(linker, lib, "cadaclysm_task_name", FunctionDescriptor.of(A, A, I, I));
        TASK_IDENTIFICATION = bind(linker, lib, "cadaclysm_task_identification", FunctionDescriptor.of(A, A, I, I));
        TASK_KIND = bind(linker, lib, "cadaclysm_task_kind", FunctionDescriptor.of(I, A, I, I));
        TASK_KIND_NAME = bind(linker, lib, "cadaclysm_task_kind_name", FunctionDescriptor.of(A, A, I, I));
        TASK_STATUS = bind(linker, lib, "cadaclysm_task_status", FunctionDescriptor.of(A, A, I, I));
        TASK_MILESTONE = bind(linker, lib, "cadaclysm_task_milestone", FunctionDescriptor.of(B, A, I, I));
        TASK_PARENT = bind(linker, lib, "cadaclysm_task_parent", FunctionDescriptor.of(B, A, I, I, A));
        TASK_TIME_OF = bind(linker, lib, "cadaclysm_task_time", FunctionDescriptor.of(B, A, I, I, A));
        TASK_NODE_COUNT = bind(linker, lib, "cadaclysm_task_node_count", FunctionDescriptor.of(I, A, I, I));
        TASK_NODES = bind(linker, lib, "cadaclysm_task_nodes", FunctionDescriptor.of(I, A, I, I, A, I));
        TASK_LINK_COUNT = bind(linker, lib, "cadaclysm_task_link_count", FunctionDescriptor.of(I, A, I));
        TASK_LINK = bind(linker, lib, "cadaclysm_task_link", FunctionDescriptor.of(B, A, I, I, A, A, A, A, A));
        TASK_LINK_KIND_NAME = bind(linker, lib, "cadaclysm_task_link_kind_name", FunctionDescriptor.of(A, A, I, I));
        SCHEDULE_AT = bind(linker, lib, "cadaclysm_schedule_at", FunctionDescriptor.of(L, A, I, D, I, A, I));
        // Posing: the mechanism posed by
        // explicit values or a named state, copied eagerly into a Pose and freed (POSE_FREE) before
        // the C handle escapes anywhere -- see Scene.copyPose.
        POSE = bind(linker, lib, "cadaclysm_pose", FunctionDescriptor.of(A, A, A, A, A, I, I));
        POSE_STATE = bind(linker, lib, "cadaclysm_pose_state", FunctionDescriptor.of(A, A, I, I));
        POSE_FREE = bind(linker, lib, "cadaclysm_pose_free", FunctionDescriptor.ofVoid(A));
        POSE_GROUND = bind(linker, lib, "cadaclysm_pose_ground", FunctionDescriptor.of(I, A));
        POSE_NODE_COUNT = bind(linker, lib, "cadaclysm_pose_node_count", FunctionDescriptor.of(I, A));
        POSE_NODE_TRANSFORM = bind(linker, lib, "cadaclysm_pose_node_transform", FunctionDescriptor.ofVoid(A, I, A));
        POSE_UNSOLVED_COUNT = bind(linker, lib, "cadaclysm_pose_unsolved_count", FunctionDescriptor.of(I, A));
        POSE_UNSOLVED = bind(linker, lib, "cadaclysm_pose_unsolved", FunctionDescriptor.of(I, A, I));
        POSE_DIAGNOSTIC_COUNT = bind(linker, lib, "cadaclysm_pose_diagnostic_count", FunctionDescriptor.of(I, A));
        POSE_DIAGNOSTIC = bind(linker, lib, "cadaclysm_pose_diagnostic", FunctionDescriptor.of(A, A, I));
        POSE_OUT_OF_RANGE_COUNT = bind(linker, lib, "cadaclysm_pose_out_of_range_count", FunctionDescriptor.of(I, A));
        POSE_OUT_OF_RANGE = bind(linker, lib, "cadaclysm_pose_out_of_range", FunctionDescriptor.of(B, A, I, A, A, A));
        KINEMATICS_BASE = bind(linker, lib, "cadaclysm_kinematics_base", FunctionDescriptor.of(I, A));
    }

    @SuppressWarnings("restricted") // downcallHandle: every entry point here is the published ABI.
    private static MethodHandle bind(Linker linker, SymbolLookup lib, String name, FunctionDescriptor fd) {
        return linker.downcallHandle(
                lib.find(name).orElseThrow(() -> new UnsatisfiedLinkError(name)), fd);
    }

    /** A named field's byte offset in one of the struct layouts above. */
    private static long offset(MemoryLayout struct, String field) {
        return struct.byteOffset(MemoryLayout.PathElement.groupElement(field));
    }

    // ---- small native-call helpers, kept tiny so a `CadaclysmException` thrown by the
    // caller around one of these is never itself caught by the `Throwable` handler below.

    /** A C string at an address the library owns; null becomes "", matching Python's `_text`. */
    @SuppressWarnings("restricted") // reinterpret: the library terminates every string it hands back.
    private static String string(MemorySegment address) {
        if (address.address() == 0) return "";
        return address.reinterpret(Long.MAX_VALUE).getString(0);
    }

    private static String stringOrNull(MemorySegment address) {
        return address.address() == 0 ? null : string(address);
    }

    private static String lastError() {
        try {
            return string((MemorySegment) LAST_ERROR.invokeExact());
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static String lastErrorOr(String fallback) {
        String e = lastError();
        return e.isEmpty() ? fallback : e;
    }

    /** The version of the library actually loaded, which is the one worth reporting. */
    public static String version() {
        try {
            return string((MemorySegment) VERSION.invokeExact());
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** When the loaded library was built, {@code YYYY-MM-DD}. */
    public static String buildDate() {
        try {
            return string((MemorySegment) BUILD_DATE.invokeExact());
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * Load a license: the certificate text, or the path of a file holding it.
     *
     * <p>Without this the library looks in {@code CADACLYSM_LICENSE}, then for {@code
     * cadaclysm.lic} beside the running executable and in the working directory. Throws with
     * the library's reason when the text does not verify; the previous license, if any, stays
     * in use.
     */
    public static void license(String textOrPath) {
        boolean ok;
        try (Arena arena = Arena.ofConfined()) {
            ok = invokeLicenseSet(arena.allocateFrom(textOrPath));
        }
        if (!ok) throw new CadaclysmException(lastErrorOr("license refused"));
    }

    private static boolean invokeLicenseSet(MemorySegment textOrPath) {
        try {
            return (boolean) LICENSE_SET.invokeExact(textOrPath);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * One line about the license the library is running under. Never null: the license line,
     * or, without one, {@code "unlicensed"}.
     */
    public static String licenseInfo() {
        try {
            MemorySegment p = (MemorySegment) LICENSE_INFO.invokeExact();
            return p.address() == 0 ? "unlicensed" : string(p);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** How many unlicensed notices this library has printed to stderr in this process. */
    public static long licenseNoticeCount() {
        try {
            return (long) LICENSE_NOTICE_COUNT.invokeExact();
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** How many coarser levels {@link Node#meshLod(int)} offers above the mesh itself. */
    public static int lodLevels() {
        try {
            return (int) LOD_LEVELS.invokeExact();
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** What a file declares about its own precision ({@link Scene#tolerances}): {@code absolute},
     *  a length in the file's own unit, and {@code angular}, in radians -- each null where the
     *  file said nothing. */
    public record Tolerances(Double absolute, Double angular) {
    }

    /** One format {@link Node#saveMesh} writes: its bare name, its file extension, and a
     *  label for a menu ({@code "STL (binary)"}). */
    public record MeshFormat(String name, String extension, String label) {
    }

    public static List<MeshFormat> meshFormats() {
        int count = invokeMeshFormatCount();
        List<MeshFormat> out = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            out.add(new MeshFormat(invokeMeshFormatName(i), invokeMeshFormatExtension(i), invokeStringAtIndex(MESH_FORMAT_LABEL, i)));
        }
        return out;
    }

    /** One format this build reads: its name and the extensions its files take. */
    public record Format(String name, List<String> extensions) {
    }

    /** Every format this build reads, for an open dialog's filter. The library hands the
     *  extensions over semicolon-separated; they are split here. */
    public static List<Format> formats() {
        int count;
        try {
            count = (int) FORMAT_COUNT.invokeExact();
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        List<Format> out = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            List<String> extensions = new ArrayList<>();
            for (String e : invokeStringAtIndex(FORMAT_EXTENSIONS, i).split(";")) if (!e.isEmpty()) extensions.add(e);
            out.add(new Format(invokeStringAtIndex(FORMAT_NAME, i), List.copyOf(extensions)));
        }
        return out;
    }

    /** A borrowed string from a {@code (uint32_t index)} entry point. */
    private static String invokeStringAtIndex(MethodHandle function, int index) {
        try {
            return string((MemorySegment) function.invokeExact(index));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** Ask the user where to save, through the library's own dialog, with
     *  {@code suggestedName} prefilled (null for none). Null if they cancelled or no dialog
     *  was available. Blocks; on macOS must be called from the main thread. */
    public static String pickSave(String suggestedName) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment name = suggestedName == null ? MemorySegment.NULL : arena.allocateFrom(suggestedName);
            MemorySegment raw = (MemorySegment) PICK_SAVE.invokeExact(MemorySegment.NULL, name);
            return stringOrNull(raw);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static int invokeMeshFormatCount() {
        try {
            return (int) MESH_FORMAT_COUNT.invokeExact();
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static String invokeMeshFormatName(int index) {
        try {
            return string((MemorySegment) MESH_FORMAT.invokeExact(index));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static String invokeMeshFormatExtension(int index) {
        try {
            return string((MemorySegment) MESH_FORMAT_EXTENSION.invokeExact(index));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * Ask the user for a file to open, through the library's own dialog. Null if they
     * cancelled, or if no dialog was available. Blocks until the user acts; on macOS must be
     * called from the main thread.
     */
    public static String pickFile() {
        try {
            MemorySegment raw = (MemorySegment) PICK_FILE.invokeExact(MemorySegment.NULL);
            return stringOrNull(raw);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * The schema a STEP or IFC file says it speaks, from its own header --
     * {@code FILE_SCHEMA(('IFC2X3'))} sits near the top of the file, so a few kilobytes is
     * plenty and a 300&nbsp;MB IFC costs nothing to ask.
     */
    public static String declaredSchema(String modelPath) {
        byte[] head;
        try (InputStream in = Files.newInputStream(Path.of(modelPath))) {
            head = in.readNBytes(8192);
        } catch (IOException e) {
            throw new CadaclysmException(modelPath + ": " + e.getMessage());
        }
        String text = new String(head, StandardCharsets.ISO_8859_1);
        Matcher m = Pattern.compile("FILE_SCHEMA\\s*\\(\\s*\\(\\s*'([^']+)'", Pattern.CASE_INSENSITIVE)
                .matcher(text);
        return m.find() ? m.group(1) : "";
    }

    private static String plain(String name) {
        StringBuilder out = new StringBuilder();
        for (char c : name.toUpperCase().toCharArray()) {
            if (Character.isLetterOrDigit(c)) out.append(c);
        }
        return out.toString();
    }

    private static String stemOf(Path p) {
        String name = p.getFileName().toString();
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    /** {@code schema} resolved to one {@code .exp}, or a list of them to try in turn. */
    public record SchemaResolution(String chosen, List<String> fallbacks) {
    }

    /**
     * {@code schema} resolved against what the model declares -- one {@code .exp}, or a list
     * to try.
     *
     * <p>A file is taken as given. A directory is matched against what the model says it
     * speaks: the ABI registers exactly one schema per open, so something has to choose, and
     * the file itself is the one that knows. Where the declared name resembles no filename the
     * whole directory comes back as fallbacks to try in turn -- AP203 calls itself
     * CONFIG_CONTROL_DESIGN, and there will be others.
     */
    public static SchemaResolution resolveSchema(String modelPath, String schema) {
        if (schema == null) return new SchemaResolution(null, List.of());
        Path at = Path.of(schema);
        if (Files.isRegularFile(at)) return new SchemaResolution(schema, List.of());
        if (!Files.isDirectory(at)) {
            throw new CadaclysmException("schema " + schema + " is neither a file nor a directory");
        }
        List<Path> available;
        try (var stream = Files.list(at)) {
            available = stream.filter(p -> p.toString().toLowerCase().endsWith(".exp"))
                    .sorted().collect(Collectors.toList());
        } catch (IOException e) {
            throw new CadaclysmException(schema + ": " + e.getMessage());
        }
        if (available.isEmpty()) throw new CadaclysmException("no .exp schemas in " + schema);

        String declared = plain(declaredSchema(modelPath));
        List<Path> matches = new ArrayList<>();
        for (Path exp : available) {
            String stem = plain(stemOf(exp));
            if (!declared.isEmpty() && (declared.startsWith(stem) || stem.startsWith(declared))) matches.add(exp);
        }
        if (!matches.isEmpty()) {
            // The longest name that still matches is the most specific one.
            Path best = matches.get(0);
            for (Path candidate : matches) {
                if (plain(stemOf(candidate)).length() > plain(stemOf(best)).length()) best = candidate;
            }
            return new SchemaResolution(best.toString(), List.of());
        }
        List<String> fallback = new ArrayList<>();
        for (Path p : available) fallback.add(p.toString());
        return new SchemaResolution(null, fallback);
    }

    // ---- opening ------------------------------------------------------------------------

    private static MemorySegment buildOptions(Arena arena, OpenOptions options) {
        MemorySegment out = arena.allocate(OPEN_OPTIONS);
        invokeOpenOptionsInit(out);
        out.set(ValueLayout.JAVA_INT, offset(OPEN_OPTIONS, "convention"), options.convention().code());
        out.set(ValueLayout.JAVA_BOOLEAN, offset(OPEN_OPTIONS, "file_units"), options.fileUnits());
        out.set(ValueLayout.JAVA_INT, offset(OPEN_OPTIONS, "uvs"), options.uvWorld() ? 1 : 0);
        out.set(ValueLayout.JAVA_INT, offset(OPEN_OPTIONS, "colors"), options.colours() ? 1 : 0);
        out.set(ValueLayout.JAVA_DOUBLE, offset(OPEN_OPTIONS, "source_meters_per_unit"),
                options.sourceMetresPerUnit());
        return out;
    }

    private static void invokeOpenOptionsInit(MemorySegment options) {
        try {
            OPEN_OPTIONS_INIT.invokeExact(options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** Attaches one schema path to an already-built options struct, in the same arena. */
    private static void attachSchema(Arena arena, MemorySegment options, String schema) {
        MemorySegment text = arena.allocateFrom(schema);
        MemorySegment list = arena.allocate(ValueLayout.ADDRESS);
        list.set(ValueLayout.ADDRESS, 0, text);
        options.set(ValueLayout.ADDRESS, offset(OPEN_OPTIONS, "schemas"), list);
        options.set(ValueLayout.JAVA_LONG, offset(OPEN_OPTIONS, "schema_count"), 1L);
    }

    private static MemorySegment invokeOpen(MemorySegment path, MemorySegment options) {
        try {
            return (MemorySegment) OPEN.invokeExact(path, options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static MemorySegment invokeOpenMemory(MemorySegment bytes, long length, MemorySegment format,
                                                   MemorySegment options) {
        try {
            return (MemorySegment) OPEN_MEMORY.invokeExact(bytes, length, format, options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** {@link #open(String, OpenOptions)} with every default: the file's own axes and units. */
    public static Scene open(String path) {
        return open(path, OpenOptions.defaults());
    }

    /**
     * Open a CAD file, or a {@code .zip}, {@code .stpZ} or {@code .gz} holding one.
     *
     * <p>{@code options.schema()} names an EXPRESS schema ({@code .exp}) beyond the ones built
     * into the library -- every schema the project ships is compiled in, so a STEP or IFC file
     * opens with none. A directory is allowed and is matched against what the file says it
     * speaks. {@code options.convention()} is the space to read the file into; the library
     * does the converting, so every array a caller reads out is already in it.
     *
     * <p>A {@code .zip} (or {@code .stpZ}, STEP's zip) opens its first readable member;
     * {@link Scene#sourceName()} says which. A {@code .gz} is read as the format named before
     * it: {@code part.step.gz} as {@code .step}. Throws {@link CadaclysmException} on failure, carrying what the library said.
     */
    public static Scene open(String path, OpenOptions options) {
        if (!Files.exists(Path.of(path))) {
            throw new CadaclysmException(path + ": no such file");
        }
        String label = Path.of(path).getFileName().toString();

        // A directory schema goes over whole rather than being narrowed to one file here: the
        // library walks it and keys each schema under the name that schema itself *declares*.
        if (options.schema() != null && Files.isDirectory(Path.of(options.schema()))) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment p = arena.allocateFrom(path);
                MemorySegment opt = buildOptions(arena, options);
                attachSchema(arena, opt, options.schema());
                MemorySegment handle = invokeOpen(p, opt);
                if (handle.address() != 0) {
                    return new Scene(handle, label, path, options.schema(), options.convention());
                }
            }
            throw new CadaclysmException(label + ": " + lastErrorOr("open failed"));
        }

        SchemaResolution resolved = resolveSchema(path, options.schema());
        List<String> candidates;
        if (resolved.chosen() != null || resolved.fallbacks().isEmpty()) {
            candidates = new ArrayList<>();
            candidates.add(resolved.chosen());
        } else {
            candidates = resolved.fallbacks();
        }
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment p = arena.allocateFrom(path);
            for (String candidate : candidates) {
                MemorySegment opt = buildOptions(arena, options);
                if (candidate != null) attachSchema(arena, opt, candidate);
                MemorySegment handle = invokeOpen(p, opt);
                if (handle.address() != 0) {
                    return new Scene(handle, label, path, candidate, options.convention());
                }
            }
        }
        throw new CadaclysmException(label + ": " + lastErrorOr("open failed"));
    }

    private static String extensionOf(String name) {
        int dot = name.lastIndexOf('.');
        return dot >= 0 && dot < name.length() - 1 ? name.substring(dot + 1) : "";
    }

    /** {@link #openMemory(byte[], String, OpenOptions)} with every default. */
    public static Scene openMemory(byte[] bytes, String name) {
        return openMemory(bytes, name, OpenOptions.defaults());
    }

    /**
     * {@link #openMemory(byte[], String, String, OpenOptions)} with the format taken from
     * {@code name}'s own extension.
     */
    public static Scene openMemory(byte[] bytes, String name, OpenOptions options) {
        return openMemory(bytes, name, extensionOf(name), options);
    }

    /** {@link #openMemory(byte[], String, String, OpenOptions)} with every default. */
    public static Scene openMemory(byte[] bytes, String name, String format) {
        return openMemory(bytes, name, format, OpenOptions.defaults());
    }

    /**
     * Open a CAD file already in bytes. {@code format} names the kind as an extension would
     * -- {@code "step"}, {@code "ifc"}, {@code "igs"}, {@code "brep"}, {@code "3dm"},
     * {@code "scad"} -- since there is no file name to take it from: Python's own
     * {@code format} argument, given on its own here as there, where the two-argument
     * overloads read it off {@code name}. A leading dot is allowed and ignored.
     * {@code options.schema()} must be a path here: there is no file on disk to read a
     * {@code FILE_SCHEMA} line out of.
     */
    public static Scene openMemory(byte[] bytes, String name, String format, OpenOptions options) {
        if (format.startsWith(".")) format = format.substring(1);
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment buffer = arena.allocate(Math.max(bytes.length, 1));
            MemorySegment.copy(bytes, 0, buffer, ValueLayout.JAVA_BYTE, 0, bytes.length);
            MemorySegment opt = buildOptions(arena, options);
            if (options.schema() != null) attachSchema(arena, opt, options.schema());
            MemorySegment f = arena.allocateFrom(format);
            MemorySegment handle = invokeOpenMemory(buffer, bytes.length, f, opt);
            if (handle.address() == 0) throw new CadaclysmException(name + ": " + lastErrorOr("open failed"));
            // Python's own `open_memory` sets `path = Path(name)`, never None -- there being
            // no file on disk does not mean there is no name to report, and a caller printing
            // `scene.path()` for a title bar wants `name` back rather than a null to guard.
            return new Scene(handle, name, name, options.schema(), options.convention());
        }
    }

    // ---- Convention -----------------------------------------------------------------------

    /**
     * The coordinate space to open a file into -- the header's {@code CadaclysmConvention}.
     *
     * <p>The library converts on the way out, so nothing here rotates anything: a caller
     * names the space it draws in and reads geometry already in it. {@link #NATIVE} keeps the
     * file's own axes and units, which is what every caller got before the parameter existed.
     */
    public enum Convention {
        /** The file's own axes and its own units. */
        NATIVE(0),
        /** Z up, left-handed, centimetres. */
        UNREAL(1),
        /** Y up, left-handed, metres. */
        UNITY(2),
        /** Y up, right-handed, metres -- glTF, three.js, Bevy, wgpu. */
        Y_UP(3),
        /** Z up, right-handed, metres. {@link #NATIVE}'s axes at Blender's unit, which is the
         *  only difference between the two. */
        BLENDER(4);

        /**
         * ORs into the packed value {@link #parse} returns: keep the preset's axes but the
         * file's own units. A Java enum cannot itself carry an OR'd flag the way Python's
         * {@code IntEnum} or C#'s uint-backed enum can, so a caller wanting this rides it as
         * {@link OpenOptions#fileUnits()} beside {@link OpenOptions#convention()} instead.
         */
        public static final int FILE_UNITS = 0x100;

        /** ORs into the packed value {@link #parse} returns: ask for {@link Mesh#uvs()} at
         *  one world unit per unit of u -- see {@link OpenOptions#uvWorld()}. */
        public static final int UV_WORLD = 0x200;

        private final int code;

        Convention(int code) {
            this.code = code;
        }

        /** The ABI's own number for this preset. */
        public int code() {
            return code;
        }

        /** The preset half of a value {@link #parse} returned, with {@link #FILE_UNITS} and
         *  {@link #UV_WORLD} masked away. */
        public static Convention of(int packed) {
            int code = packed & ~(FILE_UNITS | UV_WORLD);
            for (Convention convention : values()) {
                if (convention.code == code) return convention;
            }
            throw new IllegalArgumentException("no convention numbered " + code);
        }

        /**
         * A packed convention from a name a user typed, as the viewers take it: {@code
         * "unreal"}, or {@code "unreal+file-units"} to keep the file's own units under the
         * preset's axes. An {@code int}, exactly as Python's own classmethod returns, since
         * the packed value is what a caller unpacks into {@link #of} and the {@link
         * #FILE_UNITS} bit.
         *
         * <p>Throws rather than falling back to {@link #NATIVE}: an unrecognised name
         * silently read as the file's own space is the one outcome that looks like success
         * and draws the wrong thing.
         */
        public static int parse(String text) {
            String[] parts = text.trim().toLowerCase().split("\\+");
            int packed = switch (parts[0]) {
                case "native" -> NATIVE.code;
                case "unreal" -> UNREAL.code;
                case "unity" -> UNITY.code;
                case "y-up" -> Y_UP.code;
                case "blender" -> BLENDER.code;
                default -> throw new IllegalArgumentException(
                        "no convention called '" + parts[0] + "': native, unreal, unity, y-up or blender");
            };
            for (int i = 1; i < parts.length; i++) {
                if (!parts[i].equals("file-units")) {
                    throw new IllegalArgumentException(
                            "no convention flag called '" + parts[i] + "': file-units");
                }
                packed |= FILE_UNITS;
            }
            return packed;
        }
    }

    /**
     * Everything {@link #open} takes beyond the path -- Java's stand-in for Python's keyword
     * arguments to {@code open()}.
     *
     * <p>{@link #fileUnits()} and {@link #uvWorld()} are what Python and C# pack as bits OR'd
     * into their {@code convention} argument (see {@link Convention#FILE_UNITS} and {@link
     * Convention#UV_WORLD}): a Java enum cannot carry an arbitrary OR'd bit the way an {@code
     * IntEnum} or a uint-backed enum can, so here they ride as their own named fields instead
     * of inside {@link #convention()}.
     */
    public record OpenOptions(Convention convention, boolean fileUnits, boolean uvWorld,
                               String schema, boolean colours, double sourceMetresPerUnit) {
        /** The file's own axes and units, no extra schema, no colours. */
        public static OpenOptions defaults() {
            return new OpenOptions(Convention.NATIVE, false, false, null, false, 0.0);
        }
    }

    // ---- SVG --------------------------------------------------------------------------

    /**
     * One of the seven camera angles {@link SvgOptions#view()} understands -- the same table
     * {@code cadaclysm_view.VIEWS} gives Python's {@code show()} and {@code svg()} both. Each
     * constant carries its own (azimuth, elevation) in degrees, which is the "View helper"
     * every language's SVG binding offers.
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
     * which line sets. Mirrors {@code CadaclysmSvgOptions}, {@link #defaults()} the way {@code
     * cadaclysm_svg_options_init} defaults the struct, with {@link #view()} supplying {@link
     * #azimuth()}/{@link #elevation()} unless they are given directly (non-null).
     *
     * <p>Passed to {@link Scene#svgText(SvgOptions)}, {@link Scene#svg(String, SvgOptions)},
     * {@link Node#svgText(SvgOptions)} and {@link Node#svg(String, SvgOptions)}. A refused
     * option (an out-of-range {@link #fov()}, say) throws {@link CadaclysmException} naming the
     * field, worded by the library itself.
     *
     * <p>{@code stroke} is the pen colour: {@code "#rgb"}, {@code "#rrggbb"} or a CSS colour
     * name. {@code background} is the packed {@code 0xRRGGBB} number, or null for no {@code
     * <rect>} behind the drawing. Both take either form through {@link #withStroke(String)}/{@link
     * #withStroke(int)} and {@link #withBackground(String)}/{@link #withBackground(int)}, e.g.
     * {@code SvgOptions.defaults().withBackground("navy")}.
     */
    public record SvgOptions(SvgView view, Double azimuth, Double elevation, String up, double fov,
                              double width, double height, double margin, double tolerance,
                              String stroke, double strokeWidth, Integer background,
                              boolean edges, boolean curves, boolean isocurves, boolean polylines,
                              boolean silhouettes) {
        /**
         * {@code view = ISO}, {@code azimuth}/{@code elevation}/{@code up}/{@code background}
         * null (fall through to {@link #view()}, the scene's convention, and transparent),
         * {@code fov = 0} (orthographic), a 1000-square page, {@code margin = 0.05}, {@code
         * tolerance = 0.1}, a black one-unit stroke, and edges with each body's outline
         * beside them.
         *
         * <p>{@code silhouettes} is on because a line set alone cannot draw every body: a
         * sphere's and a torus's only curves are the seams where their one face meets itself,
         * which are not edges of the body and are never drawn, so without it those two draw a
         * blank page.
         */
        public static SvgOptions defaults() {
            return new SvgOptions(SvgView.ISO, null, null, null, 0.0, 1000.0, 1000.0, 0.05, 0.1,
                    "#000000", 1.0, null, true, false, false, false, true);
        }

        /** These options with {@code stroke} as colour text: {@code "#rgb"}, {@code "#rrggbb"}
         *  or a CSS colour name, read when the drawing is made. */
        public SvgOptions withStroke(String colour) {
            return new SvgOptions(view, azimuth, elevation, up, fov, width, height, margin, tolerance,
                    colour, strokeWidth, background, edges, curves, isocurves, polylines, silhouettes);
        }

        /** These options with {@code stroke} a packed {@code 0xRRGGBB}. */
        public SvgOptions withStroke(int packed) {
            return withStroke(hexColour(packed, "svg: stroke"));
        }

        /** These options with {@code background} from colour text -- {@code "#rgb"}, {@code
         *  "#rrggbb"} or a CSS colour name, read by the library's own parser now -- or null for
         *  no {@code <rect>} behind the drawing. Text it refuses throws {@link
         *  CadaclysmException}. */
        public SvgOptions withBackground(String colour) {
            return new SvgOptions(view, azimuth, elevation, up, fov, width, height, margin, tolerance,
                    stroke, strokeWidth, colour == null ? null : packedField(colour, "svg: background"), edges,
                    curves, isocurves, polylines, silhouettes);
        }

        /** These options with {@code background} a packed {@code 0xRRGGBB}. */
        public SvgOptions withBackground(int packed) {
            hexColour(packed, "svg: background");
            return new SvgOptions(view, azimuth, elevation, up, fov, width, height, margin, tolerance,
                    stroke, strokeWidth, packed, edges, curves, isocurves, polylines, silhouettes);
        }
    }

    /** {@code packed} as {@code "#rrggbb"}, refused past {@code 0xFFFFFF}; {@code what} names
     *  the field. */
    private static String hexColour(int packed, String what) {
        if (packed < 0 || packed > 0xFFFFFF)
            throw new CadaclysmException(what + ": a packed colour is 0x000000..0xFFFFFF, not 0x" + Integer.toHexString(packed));
        return String.format("#%06x", packed);
    }

    /** {@link #packed(String)}, its refusal naming {@code what}. */
    private static int packedField(String colour, String what) {
        try {
            return parseColour(colour);
        } catch (CadaclysmException e) {
            throw new CadaclysmException(what + ": a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or 0xRRGGBB, not '" + colour + "'");
        }
    }

    /** A colour as the ABI's packed {@code 0xRRGGBB}, from {@code "#rgb"}, {@code "#rrggbb"} or a
     *  CSS colour name -- read by the library's own parser, so every wrapper takes the same
     *  forms. */
    private static int parseColour(String colour) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
            if ((boolean) PARSE_COLOUR.invokeExact(arena.allocateFrom(colour), out)) {
                double[] c = out.toArray(ValueLayout.JAVA_DOUBLE);
                return ((int) Math.round(c[0] * 255) << 16) | ((int) Math.round(c[1] * 255) << 8) | (int) Math.round(c[2] * 255);
            }
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        throw new CadaclysmException("colour: a colour is \"#rgb\", \"#rrggbb\" or a CSS colour name, not '" + colour + "'");
    }

    /** A colour as the ABI's packed {@code 0xRRGGBB}, from {@code "#rgb"}, {@code "#rrggbb"} or a
     *  CSS colour name -- for a host that wants the number itself ({@link
     *  SvgOptions#withBackground(String)} takes the text directly). */
    public static int packed(String colour) {
        return parseColour(colour);
    }

    /**
     * {@link SvgOptions}, packed into the {@link #SVG_OPTIONS} layout: {@code view} fills
     * {@code azimuth}/{@code elevation} unless they are given directly, {@code up} defaults to
     * {@code defaultUp}, colours are {@code "#rrggbb"}. Shared by {@link
     * Scene#svgText(SvgOptions)}/{@link Scene#svg(String, SvgOptions)} and {@link
     * Node#svgText(SvgOptions)}/{@link Node#svg(String, SvgOptions)}, as Python's {@code
     * _svg_options} is shared by {@code Scene.svg} and {@code Node.svg}.
     */
    private static MemorySegment buildSvgOptions(Arena arena, SvgOptions options, String defaultUp) {
        SvgOptions o = options == null ? SvgOptions.defaults() : options;
        MemorySegment out = arena.allocate(SVG_OPTIONS);
        invokeSvgOptionsInit(out);
        SvgView view = o.view() == null ? SvgView.ISO : o.view();
        String up = o.up() == null ? defaultUp : o.up();
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
                o.background() == null ? 0xFFFFFFFF : o.background()); // CADACLYSM_SVG_TRANSPARENT
        int flags = (o.edges() ? 1 : 0) | (o.curves() ? 2 : 0) | (o.isocurves() ? 4 : 0) | (o.polylines() ? 8 : 0)
                | (o.silhouettes() ? 16 : 0);
        out.set(ValueLayout.JAVA_INT, offset(SVG_OPTIONS, "flags"), flags);
        return out;
    }

    private static void invokeSvgOptionsInit(MemorySegment options) {
        try {
            SVG_OPTIONS_INIT.invokeExact(options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    // ---- ValueKind ------------------------------------------------------------------------

    /**
     * Which field of an {@link Attribute} holds its value.
     *
     * <p>One-based, with zero meaning the attribute was not there -- see {@code
     * include/cadaclysm.h}. A zero-based reading of this enum is off by one for every kind.
     */
    public enum ValueKind {
        NONE, TEXT, INTEGER, REAL, BOOLEAN,
        /** The flat C struct cannot hold a list's elements, so {@link Attribute#value()}
         *  carries a {@code [a, b, c]} rendering of them. */
        LIST,
        /** Another entity, with the id the file gave ({@code #4}) as the value. Its own kind
         *  rather than {@link #TEXT} so a consumer can follow it instead of showing it as
         *  prose. */
        REFERENCE;

        static ValueKind of(int raw) {
            ValueKind[] values = values();
            return raw >= 0 && raw < values.length ? values[raw] : NONE;
        }
    }

    // ---- CadaclysmException -----------------------------------------------------------

    /** A call into the library failed, carrying what it said about it. */
    public static final class CadaclysmException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public CadaclysmException(String message) {
            super(message);
        }
    }

    // ---- Bounds -------------------------------------------------------------------------

    /** An axis-aligned box, or all zeros where there was nothing to bound. */
    public record Bounds(float[] min, float[] max) {
        /** Whether this is the all-zero box the ABI uses for "nothing here". */
        public boolean isEmpty() {
            for (float v : min) if (v != 0) return false;
            for (float v : max) if (v != 0) return false;
            return true;
        }

        public float[] size() {
            return new float[]{max[0] - min[0], max[1] - min[1], max[2] - min[2]};
        }

        public float[] centre() {
            return new float[]{(min[0] + max[0]) / 2f, (min[1] + max[1]) / 2f, (min[2] + max[2]) / 2f};
        }
    }

    private static Bounds readBounds(MemorySegment allocatorTarget) {
        float[] b = allocatorTarget.toArray(ValueLayout.JAVA_FLOAT);
        return new Bounds(new float[]{b[0], b[1], b[2]}, new float[]{b[3], b[4], b[5]});
    }

    /** {@code CadaclysmBounds64}: the same axis-aligned box as {@link Bounds}, unnarrowed --
     *  exact far from the origin, where {@link Bounds}'s widened {@code float} positions are
     *  not. */
    public record Bounds64(double[] min, double[] max) {
        /** Whether this is the all-zero box the ABI uses for "nothing here". */
        public boolean isEmpty() {
            for (double v : min) if (v != 0) return false;
            for (double v : max) if (v != 0) return false;
            return true;
        }

        public double[] size() {
            return new double[]{max[0] - min[0], max[1] - min[1], max[2] - min[2]};
        }

        public double[] centre() {
            return new double[]{(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2};
        }
    }

    private static Bounds64 readBounds64(MemorySegment allocatorTarget) {
        double[] b = allocatorTarget.toArray(ValueLayout.JAVA_DOUBLE);
        return new Bounds64(new double[]{b[0], b[1], b[2]}, new double[]{b[3], b[4], b[5]});
    }

    // ---- Attribute ------------------------------------------------------------------------

    /**
     * A real the way cadaclysm's own {@code Display for Value} renders it in Rust: the
     * shortest decimal that round-trips, never forcing a trailing {@code .0}, and never in
     * exponent notation for any magnitude a CAD property plausibly holds.
     *
     * <p>{@code Double.toString} already picks the shortest round-tripping digits, but always
     * carries a decimal point and switches to scientific notation outside {@code
     * 1e-3..1e7} -- an IFC precision like {@code 1e-5} would print as {@code "1.0E-5"} where
     * Rust prints {@code "0.00001"}. Routing the same digits through {@link
     * BigDecimal#toPlainString()} expands any exponent back to fixed notation, and {@link
     * BigDecimal#stripTrailingZeros()} is what removes the forced {@code .0}.
     */
    private static String formatReal(double value) {
        if (Double.isNaN(value)) return "NaN";
        if (Double.isInfinite(value)) return value > 0 ? "inf" : "-inf";
        if (value == 0.0) {
            return (1 / value < 0) ? "-0" : "0";
        }
        return new BigDecimal(Double.toString(value)).stripTrailingZeros().toPlainString();
    }

    /** One thing the file said about a node. */
    public record Attribute(String name, ValueKind kind, String value) {
        /**
         * The value rendered for display, as cadaclysm's own Rust {@code Display} does --
         * agrees exactly with what the Python, Go and C# clients print for every finite
         * value.
         */
        public String text() {
            if (value == null) return "";
            if (kind == ValueKind.REAL) return formatReal(Double.parseDouble(value));
            return value;
        }
    }

    private static Attribute buildAttribute(MemorySegment raw) {
        MemorySegment nameSeg = raw.get(ValueLayout.ADDRESS, offset(ATTRIBUTE, "name"));
        if (nameSeg.address() == 0) return null;
        ValueKind kind = ValueKind.of(raw.get(ValueLayout.JAVA_INT, offset(ATTRIBUTE, "kind")));
        String value = switch (kind) {
            case TEXT, LIST, REFERENCE -> string(raw.get(ValueLayout.ADDRESS, offset(ATTRIBUTE, "text")));
            case INTEGER -> Long.toString(raw.get(ValueLayout.JAVA_LONG, offset(ATTRIBUTE, "integer")));
            case REAL -> Double.toString(raw.get(ValueLayout.JAVA_DOUBLE, offset(ATTRIBUTE, "real")));
            case BOOLEAN -> Boolean.toString(raw.get(ValueLayout.JAVA_BOOLEAN, offset(ATTRIBUTE, "boolean")));
            default -> null;
        };
        return new Attribute(string(nameSeg), kind, value);
    }

    // ---- borrowed arrays --------------------------------------------------------------

    // Every method below reinterprets a pointer the library itself handed back, to the exact
    // size the struct beside it said: the trust the whole "everything borrows from the scene"
    // design rests on, and why this file is the one place that trust is spent.

    // A scene's views are cut from the scene's own arena: a buffer keeps that arena, and with
    // it the scene, reachable, so the scene is not closed under a buffer still being read.
    @SuppressWarnings("restricted")
    private static FloatBuffer floatView(Arena owner, long address, long count) {
        if (address == 0 || count == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Float.BYTES, owner, null)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asFloatBuffer().asReadOnlyBuffer();
    }

    @SuppressWarnings("restricted")
    private static IntBuffer intView(Arena owner, long address, long count) {
        if (address == 0 || count == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Integer.BYTES, owner, null)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asIntBuffer().asReadOnlyBuffer();
    }

    @SuppressWarnings("restricted")
    private static DoubleBuffer doubleView(Arena owner, long address, long count) {
        if (address == 0 || count == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Double.BYTES, owner, null)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asDoubleBuffer().asReadOnlyBuffer();
    }

    @SuppressWarnings("restricted")
    private static FloatBuffer floatView(long address, long count) {
        if (address == 0 || count == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Float.BYTES)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asFloatBuffer().asReadOnlyBuffer();
    }

    @SuppressWarnings("restricted")
    private static IntBuffer intView(long address, long count) {
        if (address == 0 || count == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Integer.BYTES)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asIntBuffer().asReadOnlyBuffer();
    }

    @SuppressWarnings("restricted")
    private static float[] floatArray(long address, long count) {
        if (address == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Float.BYTES).toArray(ValueLayout.JAVA_FLOAT);
    }

    @SuppressWarnings("restricted")
    private static int[] intArray(long address, long count) {
        if (address == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Integer.BYTES).toArray(ValueLayout.JAVA_INT);
    }

    @SuppressWarnings("restricted")
    private static DoubleBuffer doubleView(long address, long count) {
        if (address == 0 || count == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Double.BYTES)
                .asByteBuffer().order(ByteOrder.nativeOrder()).asDoubleBuffer().asReadOnlyBuffer();
    }

    @SuppressWarnings("restricted")
    private static double[] doubleArray(long address, long count) {
        if (address == 0) return null;
        return MemorySegment.ofAddress(address).reinterpret(count * Double.BYTES).toArray(ValueLayout.JAVA_DOUBLE);
    }

    // ---- MeshData / Mesh --------------------------------------------------------------

    /** A node's triangles, copied out as plain arrays -- what {@link Mesh#copy()} returns. */
    public record MeshData(float[] positions, float[] normals, float[] uvs, float[] colours, int[] indices) {
    }

    /**
     * A node's triangles, in the node's own frame -- views over the scene's own memory, valid
     * until {@link Scene#close()}.
     *
     * <p>{@link #positions()} and {@link #normals()} are {@code vertexCount * 3} floats,
     * {@link #uvs()} is {@code vertexCount * 2}, {@link #colours()} is {@code vertexCount * 4}
     * RGBA, and {@link #indices()} is {@code indexCount}, three to a triangle. Null stands in
     * for Python's {@code None}: {@link #normals()}, {@link #uvs()} and {@link #colours()} are
     * null for a mesh that carries none, which is the common case for the last two.
     */
    public static final class Mesh {
        private final Scene scene;
        private final long positions, normals, uvs, colours, indices;
        private final int vertexCount, indexCount;

        private Mesh(Scene scene, long positions, long normals, long uvs, long colours, long indices,
                     int vertexCount, int indexCount) {
            this.scene = scene;
            this.positions = positions;
            this.normals = normals;
            this.uvs = uvs;
            this.colours = colours;
            this.indices = indices;
            this.vertexCount = vertexCount;
            this.indexCount = indexCount;
        }

        /** The scene this borrows from -- kept so a caller can see what must stay open. */
        public Scene scene() {
            return scene;
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

        /** A view over a closed scene is over freed memory: every buffer below asks the scene
         *  first, and a closed one throws its own {@link CadaclysmException} rather than hand
         *  out a buffer into it. */
        private void open() {
            scene.handle();
        }

        public FloatBuffer positions() {
            open();
            return floatView(scene.lifetime(), positions, vertexCount * 3L);
        }

        public FloatBuffer normals() {
            open();
            return floatView(scene.lifetime(), normals, vertexCount * 3L);
        }

        /** Two floats a vertex, not three. Null for a node whose reader produced none. */
        public FloatBuffer uvs() {
            open();
            return floatView(scene.lifetime(), uvs, vertexCount * 2L);
        }

        /** Four floats a vertex, RGBA -- present only for a body opened asking for per-vertex
         *  colour whose faces carry more than one between them. */
        public FloatBuffer colours() {
            open();
            return floatView(scene.lifetime(), colours, vertexCount * 4L);
        }

        public IntBuffer indices() {
            open();
            return intView(scene.lifetime(), indices, indexCount);
        }

        /**
         * The same triangles in memory of our own, safe to outlive the scene. Expensive on
         * purpose to be visible: this is where the gigabytes go on a large assembly.
         */
        public MeshData copy() {
            open();
            return new MeshData(
                    floatArray(positions, vertexCount * 3L),
                    floatArray(normals, vertexCount * 3L),
                    floatArray(uvs, vertexCount * 2L),
                    floatArray(colours, vertexCount * 4L),
                    intArray(indices, indexCount));
        }
    }

    /** A node's triangles in {@code double}, copied out -- what {@link Mesh64#copy()} returns. */
    public record MeshData64(double[] positions, double[] normals, double[] uvs, float[] colours, int[] indices) {
    }

    /**
     * {@code CadaclysmMesh64}: this node's own mesh, in {@code double}, lent as it is rather
     * than narrowed the way {@link Mesh} is -- the same triangles and indices, {@link Mesh}'s
     * {@code float} positions being exactly these narrowed. For a caller that uses the mesh as
     * geometry (an exporter, a measurement, a solver) and wants the file's own coordinates,
     * which {@code float} cannot hold far from the origin.
     *
     * <p>Colours stay {@code float} (RGBA in 0..1 needs no more). <b>A forget drops it</b>:
     * {@link Scene#forgetMeshes()} frees the document's own mesh these pointers borrow -- read
     * none of them after a forget, ask again and the mesh is built again. {@link Mesh}'s
     * pointers survive a forget, its {@code float} copy being kept separately.
     */
    public static final class Mesh64 {
        private final Scene scene;
        private final long positions, normals, uvs, colours, indices;
        private final int vertexCount, indexCount;
        // The scene's forget count when this was made; see Scene.forgets.
        private final long forgets;

        private Mesh64(Scene scene, long positions, long normals, long uvs, long colours, long indices,
                       int vertexCount, int indexCount) {
            this.scene = scene;
            this.positions = positions;
            this.normals = normals;
            this.uvs = uvs;
            this.colours = colours;
            this.indices = indices;
            this.vertexCount = vertexCount;
            this.indexCount = indexCount;
            this.forgets = scene.forgets;
        }

        /** The scene this borrows from. */
        public Scene scene() {
            return scene;
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

        /** As {@link Mesh}'s: a closed scene throws rather than hand out a view over freed
         *  memory -- and so does a scene that has forgotten its meshes since this was made,
         *  the forget having freed the mesh this lends. */
        private void open() {
            scene.handle();
            if (scene.forgets != forgets) {
                throw new CadaclysmException("mesh64: stale view: the scene has forgotten its meshes since, "
                        + "freeing the document's own mesh this lends (ask the node again)");
            }
        }

        public DoubleBuffer positions() {
            open();
            return doubleView(scene.lifetime(), positions, vertexCount * 3L);
        }

        public DoubleBuffer normals() {
            open();
            return doubleView(scene.lifetime(), normals, vertexCount * 3L);
        }

        /** Two doubles a vertex, not three. Null for a node whose reader produced none. */
        public DoubleBuffer uvs() {
            open();
            return doubleView(scene.lifetime(), uvs, vertexCount * 2L);
        }

        /** Four floats a vertex, RGBA -- still {@code float}, as {@code CadaclysmMesh64::colors}'s
         *  own note says: RGBA in 0..1 needs no more precision. */
        public FloatBuffer colours() {
            open();
            return floatView(scene.lifetime(), colours, vertexCount * 4L);
        }

        public IntBuffer indices() {
            open();
            return intView(scene.lifetime(), indices, indexCount);
        }

        /** The same triangles in memory of our own, safe to outlive the scene. */
        public MeshData64 copy() {
            open();
            return new MeshData64(
                    doubleArray(positions, vertexCount * 3L),
                    doubleArray(normals, vertexCount * 3L),
                    doubleArray(uvs, vertexCount * 2L),
                    floatArray(colours, vertexCount * 4L),
                    intArray(indices, indexCount));
        }
    }

    // ---- Polylines ----------------------------------------------------------------------

    /**
     * A node's feature edges or free curves, already flattened to points -- a view over the
     * scene's own memory, valid until the scene closes.
     */
    public static final class Polylines {
        private final Scene scene;
        private final long positions, counts;
        private final int polylineCount, vertexCount;

        private Polylines(Scene scene, long positions, long counts, int polylineCount, int vertexCount) {
            this.scene = scene;
            this.positions = positions;
            this.counts = counts;
            this.polylineCount = polylineCount;
            this.vertexCount = vertexCount;
        }

        public Scene scene() {
            return scene;
        }

        public int polylineCount() {
            return polylineCount;
        }

        public int vertexCount() {
            return vertexCount;
        }

        /** {@code vertexCount * 3} floats, the runs end to end. A closed scene throws its own
         *  {@link CadaclysmException} here, as {@link Mesh}'s views do. */
        public FloatBuffer positions() {
            scene.handle();
            return floatView(scene.lifetime(), positions, vertexCount * 3L);
        }

        /** {@code polylineCount} vertex counts: how many points each run has, not where it
         * ends, so twelve two-point edges read {@code 2, 2, 2, ...}. */
        public IntBuffer counts() {
            scene.handle();
            return intView(scene.lifetime(), counts, polylineCount);
        }

        /**
         * Indices into {@link #positions()} making line-segment endpoint pairs: a polyline of
         * n points is n - 1 segments, so each interior point is named twice.
         */
        public int[] segmentIndices() {
            IntBuffer countsBuf = counts();
            if (countsBuf == null) return new int[0];
            List<Integer> pairs = new ArrayList<>();
            int at = 0;
            for (int i = 0; i < polylineCount; i++) {
                int count = countsBuf.get(i);
                for (int k = 0; k + 1 < count; k++) {
                    pairs.add(at + k);
                    pairs.add(at + k + 1);
                }
                at += count;
            }
            int[] out = new int[pairs.size()];
            for (int i = 0; i < out.length; i++) out[i] = pairs.get(i);
            return out;
        }

        /** The endpoint pairs themselves, {@code 2 * segmentCount} points, in the node's own
         *  frame. */
        public float[] segments() {
            int[] indices = segmentIndices();
            FloatBuffer pos = positions();
            float[] out = new float[indices.length * 3];
            for (int i = 0; i < indices.length; i++) {
                int p = indices[i] * 3;
                out[i * 3] = pos.get(p);
                out[i * 3 + 1] = pos.get(p + 1);
                out[i * 3 + 2] = pos.get(p + 2);
            }
            return out;
        }
    }

    private static Polylines buildPolylines(Scene scene, MemorySegment raw) {
        long positions = raw.get(ValueLayout.ADDRESS, offset(POLYLINES, "positions")).address();
        long counts = raw.get(ValueLayout.ADDRESS, offset(POLYLINES, "counts")).address();
        int polylineCount = raw.get(ValueLayout.JAVA_INT, offset(POLYLINES, "polyline_count"));
        int vertexCount = raw.get(ValueLayout.JAVA_INT, offset(POLYLINES, "vertex_count"));
        return new Polylines(scene, positions, counts, polylineCount, vertexCount);
    }

    /** A node's edges, curves or isocurves as cubic Bézier curves -- exact where the file's
     *  curves were, where {@link Polylines} are their chords. A view over the scene's
     *  memory, valid until the scene closes. */
    public static final class Beziers {
        private final Scene scene;
        private final long points, weights;
        private final int count;

        private Beziers(Scene scene, long points, long weights, int count) {
            this.scene = scene;
            this.points = points;
            this.weights = weights;
            this.count = count;
        }

        public Scene scene() {
            return scene;
        }

        /** How many curves. */
        public int count() {
            return count;
        }

        /** {@code count * 12} floats: four control points a curve, three floats each. */
        public FloatBuffer points() {
            scene.handle();
            return floatView(scene.lifetime(), points, count * 12L);
        }

        /** {@code count * 4} floats: a weight per control point, all ones for a polynomial
         *  curve, and the weights that make a circular arc exact for a rational one. */
        public FloatBuffer weights() {
            scene.handle();
            return floatView(scene.lifetime(), weights, count * 4L);
        }

        /** The same curves in memory of your own, safe to keep after the scene closes. */
        public BeziersData copy() {
            scene.handle();
            return new BeziersData(floatArray(points, count * 12L), floatArray(weights, count * 4L));
        }
    }

    /** A {@link Beziers} copied out as plain arrays. */
    public record BeziersData(float[] points, float[] weights) {
    }

    private static Beziers buildBeziers(Scene scene, MemorySegment raw) {
        long points = raw.get(ValueLayout.ADDRESS, offset(BEZIERS, "points")).address();
        long weights = raw.get(ValueLayout.ADDRESS, offset(BEZIERS, "weights")).address();
        int count = raw.get(ValueLayout.JAVA_INT, offset(BEZIERS, "count"));
        return new Beziers(scene, points, weights, count);
    }

    /** {@code CadaclysmBeziers64}: the same segments as a {@link Beziers}, unnarrowed -- a view
     *  over the scene's memory, valid until the scene closes. */
    public static final class Beziers64 {
        private final Scene scene;
        private final long points, weights;
        private final int count;

        private Beziers64(Scene scene, long points, long weights, int count) {
            this.scene = scene;
            this.points = points;
            this.weights = weights;
            this.count = count;
        }

        public Scene scene() {
            return scene;
        }

        /** How many curves. */
        public int count() {
            return count;
        }

        /** {@code count * 12} doubles: four control points a curve, three doubles each. */
        public DoubleBuffer points() {
            scene.handle();
            return doubleView(scene.lifetime(), points, count * 12L);
        }

        /** {@code count * 4} doubles: a weight per control point. */
        public DoubleBuffer weights() {
            scene.handle();
            return doubleView(scene.lifetime(), weights, count * 4L);
        }

        /** The same curves in memory of your own, safe to keep after the scene closes. */
        public BeziersData64 copy() {
            scene.handle();
            return new BeziersData64(doubleArray(points, count * 12L), doubleArray(weights, count * 4L));
        }
    }

    /** A {@link Beziers64} copied out as plain arrays. */
    public record BeziersData64(double[] points, double[] weights) {
        /** How many curves: {@code weights} holds four a curve, {@code points} twelve. */
        public int count() {
            return weights.length / 4;
        }
    }

    private static Beziers64 buildBeziers64(Scene scene, MemorySegment raw) {
        long points = raw.get(ValueLayout.ADDRESS, offset(BEZIERS64, "points")).address();
        long weights = raw.get(ValueLayout.ADDRESS, offset(BEZIERS64, "weights")).address();
        int count = raw.get(ValueLayout.JAVA_INT, offset(BEZIERS64, "count"));
        return new Beziers64(scene, points, weights, count);
    }

    /** What a node turned out to be for a physics engine: a box, sphere, capsule or cylinder
     *  where one fits within {@code error}, else a convex hull. {@code frame} (16 doubles,
     *  column-major) and {@code halfExtent} are always the true oriented box. */
    public record Collision(int shape, int confidence, int axis, double[] frame, double[] halfExtent,
                            double radius, double height, double error, int hullVertexCount, int hullIndexCount) {
        private static final String[] NAMES = {"none", "box", "sphere", "capsule", "cylinder", "hull"};

        /** {@code none}, {@code box}, {@code sphere}, {@code capsule}, {@code cylinder} or {@code hull}. */
        public String shapeName() {
            return shape >= 0 && shape < NAMES.length ? NAMES[shape] : Integer.toString(shape);
        }
    }

    /** A node's convex hull for a physics engine, as triangles -- a view over the scene's
     *  memory, valid until the scene closes. */
    public static final class CollisionHull {
        private final Scene scene;
        private final long positions, indices;
        private final int vertexCount, indexCount;

        private CollisionHull(Scene scene, long positions, long indices, int vertexCount, int indexCount) {
            this.scene = scene;
            this.positions = positions;
            this.indices = indices;
            this.vertexCount = vertexCount;
            this.indexCount = indexCount;
        }

        public int vertexCount() {
            return vertexCount;
        }

        public int indexCount() {
            return indexCount;
        }

        /** {@code vertexCount * 3} floats. */
        public FloatBuffer positions() {
            scene.handle();
            return floatView(scene.lifetime(), positions, vertexCount * 3L);
        }

        /** {@code indexCount} indices, three a triangle. */
        public IntBuffer indices() {
            scene.handle();
            return intView(scene.lifetime(), indices, indexCount);
        }
    }

    // ---- Face / Surfaces ----------------------------------------------------------------

    /**
     * One trimmed face: the surface itself, plus the loops that cut it. {@code kind} is 0
     * plane, 1 cylinder, 2 cone, 3 sphere, 4 torus, 5 revolution, 6 extrusion, 7 NURBS, 8 sum.
     * {@code origin}, {@code ax}, {@code ay}, {@code az} are the frame, each three floats --
     * the header pads them to {@code float[4]} so every field lands on a 16-byte boundary, and
     * the fourth is dropped here exactly as Python slices it to {@code [:3]}. {@code scalars}
     * is kind-dependent and kept at four; {@code domain} is {@code (u_min, v_min, u_max,
     * v_max)}, also four. {@code loops} is one array of {@code (u, v)} pairs per loop, each
     * closing implicitly, and {@code profile} and {@code nurbs} carry what a swept or NURBS
     * surface needs.
     *
     * <p>Copied out at construction, unlike {@link Mesh} and {@link Polylines}: a face's trim
     * loops and profile samples are a handful of points next to a mesh's millions of vertices.
     */
    public record Face(int kind, boolean reversed, boolean transposed, float[] origin, float[] ax, float[] ay,
                        float[] az, float[] domain, float[] scalars, float[][] loops, float[] profile,
                        float[] profile2, float[] nurbs) {
    }

    /**
     * A part's faces as surfaces and trims, and the arrays they share. Iterate it for {@link
     * Face} objects. Everything here is <b>in the file's own frame</b>, unlike every other
     * product this binding hands back -- see {@link Scene#surfaceMatrix()}.
     */
    public static final class Surfaces implements Iterable<Face> {
        private final Face[] faces;

        private Surfaces(Face[] faces) {
            this.faces = faces;
        }

        public int size() {
            return faces.length;
        }

        public boolean isEmpty() {
            return faces.length == 0;
        }

        public Face get(int index) {
            return faces[index];
        }

        @Override
        public Iterator<Face> iterator() {
            return Arrays.asList(faces).iterator();
        }
    }

    /** Reads the header's {@code float[4]} frame vectors as three floats: the fourth is pad
     *  the header carries so every field lands on a 16-byte boundary, not part of the vector
     *  -- Python slices the same field to {@code [:3]} and C# does the same. */
    private static float[] readFloat3(MemorySegment seg, long fieldOffset) {
        float[] out = new float[3];
        for (int i = 0; i < 3; i++) out[i] = seg.get(ValueLayout.JAVA_FLOAT, fieldOffset + i * 4L);
        return out;
    }

    private static float[] readFloat4(MemorySegment seg, long fieldOffset) {
        float[] out = new float[4];
        for (int i = 0; i < 4; i++) out[i] = seg.get(ValueLayout.JAVA_FLOAT, fieldOffset + i * 4L);
        return out;
    }

    @SuppressWarnings("restricted") // reinterpret: sized against the counts the same struct gives.
    private static Surfaces buildSurfaces(MemorySegment raw) {
        int faceCount = raw.get(ValueLayout.JAVA_INT, offset(SURFACES, "face_count"));
        if (faceCount == 0) return new Surfaces(new Face[0]);
        long facesPtr = raw.get(ValueLayout.ADDRESS, offset(SURFACES, "faces")).address();
        long loopsPtr = raw.get(ValueLayout.ADDRESS, offset(SURFACES, "loops")).address();
        long pointsPtr = raw.get(ValueLayout.ADDRESS, offset(SURFACES, "points")).address();
        long profilesPtr = raw.get(ValueLayout.ADDRESS, offset(SURFACES, "profiles")).address();
        long nurbsPtr = raw.get(ValueLayout.ADDRESS, offset(SURFACES, "nurbs")).address();
        int loopCount = raw.get(ValueLayout.JAVA_INT, offset(SURFACES, "loop_count"));
        int pointCount = raw.get(ValueLayout.JAVA_INT, offset(SURFACES, "point_count"));
        int profileCount = raw.get(ValueLayout.JAVA_INT, offset(SURFACES, "profile_count"));
        int nurbsCount = raw.get(ValueLayout.JAVA_INT, offset(SURFACES, "nurbs_count"));

        MemorySegment facesSeg = MemorySegment.ofAddress(facesPtr).reinterpret((long) faceCount * FACE.byteSize());
        MemorySegment loopsSeg = loopsPtr == 0 ? null
                : MemorySegment.ofAddress(loopsPtr).reinterpret(loopCount * 2L * Integer.BYTES);
        MemorySegment pointsSeg = pointsPtr == 0 ? null
                : MemorySegment.ofAddress(pointsPtr).reinterpret(pointCount * 2L * Float.BYTES);
        float[] profiles = profilesPtr == 0 ? new float[0]
                : MemorySegment.ofAddress(profilesPtr).reinterpret(profileCount * 4L * Float.BYTES)
                        .toArray(ValueLayout.JAVA_FLOAT);
        float[] nurbs = nurbsPtr == 0 ? new float[0]
                : MemorySegment.ofAddress(nurbsPtr).reinterpret((long) nurbsCount * Float.BYTES)
                        .toArray(ValueLayout.JAVA_FLOAT);

        Face[] faces = new Face[faceCount];
        for (int i = 0; i < faceCount; i++) {
            long base = (long) i * FACE.byteSize();
            int kind = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "kind"));
            boolean reversed = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "reversed")) != 0;
            boolean transposed = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "transposed")) != 0;
            float[] origin = readFloat3(facesSeg, base + offset(FACE, "origin"));
            float[] ax = readFloat3(facesSeg, base + offset(FACE, "ax"));
            float[] ay = readFloat3(facesSeg, base + offset(FACE, "ay"));
            float[] az = readFloat3(facesSeg, base + offset(FACE, "az"));
            float[] domain = readFloat4(facesSeg, base + offset(FACE, "domain"));
            float[] scalars = readFloat4(facesSeg, base + offset(FACE, "scalars"));
            int loopStart = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "loop_start"));
            int loopCountHere = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "loop_count"));
            int profileStart = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "profile_start"));
            int profileCountHere = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "profile_count"));
            int profile2Start = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "profile2_start"));
            int profile2CountHere = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "profile2_count"));
            int nurbsStart = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "nurbs_start"));
            int nurbsCountHere = facesSeg.get(ValueLayout.JAVA_INT, base + offset(FACE, "nurbs_count"));

            float[][] loops = new float[loopCountHere][];
            for (int k = 0; k < loopCountHere; k++) {
                long loopOffset = (loopStart + k) * 2L * Integer.BYTES;
                int start = loopsSeg.get(ValueLayout.JAVA_INT, loopOffset);
                int length = loopsSeg.get(ValueLayout.JAVA_INT, loopOffset + Integer.BYTES);
                float[] loop = new float[length * 2];
                for (int p = 0; p < length * 2; p++) {
                    loop[p] = pointsSeg.get(ValueLayout.JAVA_FLOAT, (start * 2L + p) * Float.BYTES);
                }
                loops[k] = loop;
            }
            faces[i] = new Face(kind, reversed, transposed, origin, ax, ay, az, domain, scalars, loops,
                    Arrays.copyOfRange(profiles, profileStart * 4, (profileStart + profileCountHere) * 4),
                    Arrays.copyOfRange(profiles, profile2Start * 4, (profile2Start + profile2CountHere) * 4),
                    Arrays.copyOfRange(nurbs, nurbsStart, nurbsStart + nurbsCountHere));
        }
        return new Surfaces(faces);
    }

    // ---- matrices -------------------------------------------------------------------------

    private static double[][] toRowMajor(double[] raw) {
        double[][] m = new double[4][4];
        for (int col = 0; col < 4; col++) {
            for (int row = 0; row < 4; row++) m[row][col] = raw[col * 4 + row];
        }
        return m;
    }

    private static float[][] toRowMajor(float[] raw) {
        float[][] m = new float[4][4];
        for (int col = 0; col < 4; col++) {
            for (int row = 0; row < 4; row++) m[row][col] = raw[col * 4 + row];
        }
        return m;
    }

    // ---- Placement --------------------------------------------------------------------

    /**
     * One drawing of one node's geometry, at one place.
     *
     * <p><b>A node is not a drawing, and the difference is a bug this library shipped.</b>
     * Most nodes are structure and draw nothing; a node that places a block draws everything
     * inside that block; and a block's members draw once per placement of it rather than once
     * on their own account. So iterate {@link Scene#placements()} to draw, and nodes to build
     * a tree.
     */
    // ---- breps ----------------------------------------------------------------------------

    private static final Cleaner CLEANER = Cleaner.create();

    /** The one reference a {@link Brep} holds, and what gives it back -- what the {@link
     *  Cleaner} runs, so it holds the bare address and never the owner. Given back once:
     *  the address is zeroed first. */
    private static final class BrepReference implements Runnable {
        private long address;

        BrepReference(long address) {
            this.address = address;
        }

        @Override
        public void run() {
            long a = address;
            address = 0;
            if (a == 0) return;
            try {
                BREP_RELEASE.invokeExact(MemorySegment.ofAddress(a));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    /** Whether a brep's or a solid's faces make a manifold, as plain data ({@link
     *  Brep#manifold()}, and {@code Blacksmith.Solid.manifold()}): its faces, edges and
     *  vertices; the edges one face borders (a sheet's rim), the edges three or more do, and
     *  the vertices whose faces make more than one fan (two solids touching at a corner).
     *  {@code isManifold} where there are none of the last two, {@code isClosed} where there
     *  is no boundary edge either -- it encloses a solid. */
    public record Manifold(int faces, int edges, int vertices, int boundaryEdges, int nonManifoldEdges,
                           int nonManifoldVertices, boolean isManifold, boolean isClosed) {
        /** From the eight counts {@code cadaclysm_brep_manifold} and {@code
         *  cadaclysm_blacksmith_manifold} write, in their order. */
        public static Manifold of(int[] row) {
            return new Manifold(row[0], row[1], row[2], row[3], row[4], row[5], row[6] == 1, row[7] == 1);
        }
    }

    /** What {@link Brep#sewed} did, as plain data: the edges it joined ({@code pairs}), the
     *  free edges before and after, how many groups of free edges between the same two
     *  vertices it left free ({@code refused}: too far apart for the tolerance, or more than
     *  two), the widest gap it sewed, and the two tolerances it used. */
    public record SewReport(int pairs, int freeBefore, int freeAfter, int refused, double worstGap,
                            double tolerance, double vertex) {
    }

    /** A sewn brep and its {@link SewReport}, from {@link Brep#sewed}. The brep is the
     *  caller's to close. */
    public record Sewn(Brep brep, SewReport report) {
    }

    /** One free edge (a side only one face bounds), from {@link HealthReport#freeEdges()}: its
     *  {@code trim} (the face's side), the {@code edge} it lies on (null for a side with no
     *  edge), the {@code face} and free {@code wire} it is on, its nearest {@code partner} --
     *  a row of {@code freeEdges}, null if there is none -- how many of its two ends it
     *  {@code sharedEnds} with that partner, its {@code length} and the {@code gap} to the
     *  partner (infinite without one). */
    public record FreeEdge(int trim, Integer edge, int face, int wire, Integer partner, int sharedEnds,
                           double length, double gap) {
    }

    /** A chain of free edges end to end: the rows {@code first .. first + count} of {@link
     *  HealthReport#freeEdges()}, whether it {@code closed} on itself, its total {@code length}
     *  and the {@code widestGap} to any partner. */
    public record FreeWire(int first, int count, boolean closed, double length, double widestGap) {
    }

    /** Something below the tolerance: {@code kind} is "short_edge", "collapsed_edge",
     *  "sliver_face", "tiny_face", "tiny_body" or "small_hole"; {@code index} its edge, face,
     *  body or loop number; {@code size} how small. */
    public record SmallFeature(String kind, int index, double size) {
    }

    /** What a mesh of the body shows ({@code health(tolerance, true)}): whether it is {@code
     *  watertight}, how many mesh edges are {@code open} or {@code folded}, how many {@code
     *  crossings}, and the brep {@code edges} it cracks along. */
    public record Cracks(boolean watertight, int open, int folded, int crossings, List<Integer> edges) {
        public Cracks {
            edges = List.copyOf(edges);
        }
    }

    /** The kinds a {@link SmallFeature}, {@link HealFix} or {@link HealRefusal} names, by the C
     *  ABI's number. */
    private static final String[] HEALTH_KINDS = {"short_edge", "collapsed_edge", "sliver_face", "tiny_face", "tiny_body", "small_hole"};

    /** The reasons a {@link HealRefusal} gives, by the C ABI's number. */
    private static final String[] HEAL_WHYS = {"would_empty_loop", "closed", "seam", "chain", "neighbours_part", "uneven",
            "non_manifold", "has_holes", "body_guard", "toggled", "unsupported"};

    /** The C ABI's "no such id" in a free-edge row. */
    private static final int HEALTH_NONE = 0xFFFFFFFF;

    /**
     * What is wrong with a body, as plain data ({@link Brep#health}): the {@code tolerance} and
     * {@code rounding} it judged at and the body's {@code extent}; the free edges, their wires,
     * the features below the tolerance; the loose edges ({@code worstLoose} the farthest from
     * any face); what sewing would do ({@code sewPairs} joined, {@code sewRefused}, {@code
     * sewWorstGap}); and, if asked for with {@code mesh}, the mesh's {@code cracks} (else
     * null). {@code worstGap} is the widest gap between a free edge and its partner.
     */
    public record HealthReport(double tolerance, double rounding, double extent, List<FreeEdge> freeEdges,
                               List<FreeWire> wires, List<SmallFeature> small, int looseEdges, double worstLoose,
                               int sewPairs, int sewRefused, double sewWorstGap, Cracks cracks, double worstGap) {
        public HealthReport {
            freeEdges = List.copyOf(freeEdges);
            wires = List.copyOf(wires);
            small = List.copyOf(small);
        }

        /** The free edges of wire number {@code wire}, in order. */
        public List<FreeEdge> wireEdges(int wire) {
            FreeWire w = wires.get(wire);
            return freeEdges.subList(w.first(), w.first() + w.count());
        }

        /** From the flat rows {@code cadaclysm_brep_health_summary} and the row readers write, in
         *  their order: counts (18) and sizes (8); free edges 6 ids and 2 sizes a row; wires 3
         *  and 2; small features 2 and 1; the crack edges. */
        public static HealthReport of(int[] counts, double[] sizes, int[] freeIds, double[] freeSizes, int[] wireRuns,
                                      double[] wireSizes, int[] smallItems, double[] smallSizes, int[] crackEdges) {
            List<FreeEdge> free = new ArrayList<>(freeIds.length / 6);
            for (int i = 0; i < freeIds.length / 6; i++) {
                int edge = freeIds[6 * i + 1], partner = freeIds[6 * i + 4];
                free.add(new FreeEdge(freeIds[6 * i], edge == HEALTH_NONE ? null : edge, freeIds[6 * i + 2], freeIds[6 * i + 3],
                        partner == HEALTH_NONE ? null : partner, freeIds[6 * i + 5], freeSizes[2 * i], freeSizes[2 * i + 1]));
            }
            List<FreeWire> wires = new ArrayList<>(wireRuns.length / 3);
            for (int i = 0; i < wireRuns.length / 3; i++)
                wires.add(new FreeWire(wireRuns[3 * i], wireRuns[3 * i + 1], wireRuns[3 * i + 2] != 0, wireSizes[2 * i], wireSizes[2 * i + 1]));
            List<SmallFeature> small = new ArrayList<>(smallSizes.length);
            for (int i = 0; i < smallSizes.length; i++)
                small.add(new SmallFeature(HEALTH_KINDS[smallItems[2 * i]], smallItems[2 * i + 1], smallSizes[i]));
            Cracks cracks = null;
            if (counts[12] == 1) {
                List<Integer> edges = new ArrayList<>(crackEdges.length);
                for (int e : crackEdges) edges.add(e);
                cracks = new Cracks(counts[13] != 0, counts[14], counts[15], counts[16], edges);
            }
            return new HealthReport(sizes[0], sizes[1], sizes[2], free, wires, small, counts[9], sizes[4], counts[10], counts[11],
                    sizes[5], cracks, sizes[3]);
        }
    }

    /** One small feature {@link Brep#healed} removed: its {@code kind} (as {@link
     *  SmallFeature#kind()}), its {@code index} in the input (the edge, face or loop number
     *  {@code health} gave it), its {@code size}, and how far the vertex it merged {@code
     *  moved}. */
    public record HealFix(String kind, int index, double size, double moved) {
    }

    /** One small feature {@link Brep#healed} left, and why: {@code kind} and {@code index} as in
     *  {@link HealFix}; {@code why} is "would_empty_loop", "closed", "seam", "chain",
     *  "neighbours_part", "uneven", "non_manifold", "has_holes", "body_guard", "toggled" or
     *  "unsupported"; {@code figure} the chain's width or the neighbours' gap, else 0. */
    public record HealRefusal(String kind, int index, String why, double figure) {
    }

    /**
     * What {@link Brep#healed} did, as plain data: the {@code tolerance} it healed at, the
     * furthest any trim {@code moved}, whether the body guard refused fixes ({@code guarded}),
     * the {@code fixes} made and the features {@code refused}; and the body's health before and
     * after at that tolerance -- its small features, free edges, whether it is closed, and its
     * non-manifold edges.
     */
    public record HealReport(double tolerance, double moved, boolean guarded, List<HealFix> fixes, List<HealRefusal> refused,
                             int smallBefore, int smallAfter, int freeBefore, int freeAfter, boolean closedBefore,
                             boolean closedAfter, int nonmanifoldBefore, int nonmanifoldAfter) {
        public HealReport {
            fixes = List.copyOf(fixes);
            refused = List.copyOf(refused);
        }

        /** From the flat rows {@code cadaclysm_brep_heal_summary} and the row readers write, in
         *  their order: counts (11) and sizes (2); fixes 2 items and 2 sizes a row; refusals 3
         *  items and 1 size. */
        public static HealReport of(int[] counts, double[] sizes, int[] fixItems, double[] fixSizes, int[] refusedItems,
                                    double[] refusedSizes) {
            List<HealFix> fixes = new ArrayList<>(fixItems.length / 2);
            for (int i = 0; i < fixItems.length / 2; i++)
                fixes.add(new HealFix(HEALTH_KINDS[fixItems[2 * i]], fixItems[2 * i + 1], fixSizes[2 * i], fixSizes[2 * i + 1]));
            List<HealRefusal> refused = new ArrayList<>(refusedSizes.length);
            for (int i = 0; i < refusedSizes.length; i++)
                refused.add(new HealRefusal(HEALTH_KINDS[refusedItems[3 * i]], refusedItems[3 * i + 1], HEAL_WHYS[refusedItems[3 * i + 2]],
                        refusedSizes[i]));
            return new HealReport(sizes[0], sizes[1], counts[2] != 0, fixes, refused, counts[3], counts[4], counts[5], counts[6],
                    counts[7] != 0, counts[8] != 0, counts[9], counts[10]);
        }
    }

    /** A healed brep and its {@link HealReport}, from {@link Brep#healed}. The brep is the
     *  caller's to close. */
    public record Healed(Brep brep, HealReport report) {
    }

    /** {@code healed}'s switches as the C ABI's flag bits: 1 edges, 2 faces, 4 holes. */
    static int healFlags(boolean edges, boolean faces, boolean holes) {
        return (edges ? 1 : 0) | (faces ? 2 : 0) | (holes ? 4 : 0);
    }

    /** One two-call row reader's rows: the count with null buffers, then the rows into buffers
     *  of {@code idsPer} {@code uint32_t} and {@code sizesPer} doubles a row. */
    private record HealthRows(int[] ids, double[] sizes) {
        static HealthRows read(MethodHandle reader, MemorySegment handle, int idsPer, int sizesPer) throws Throwable {
            int n = (int) reader.invokeExact(handle, MemorySegment.NULL, MemorySegment.NULL);
            if (n == 0) return new HealthRows(new int[0], new double[0]);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment ids = arena.allocate(ValueLayout.JAVA_INT, (long) idsPer * n);
                MemorySegment sizes = arena.allocate(ValueLayout.JAVA_DOUBLE, (long) sizesPer * n);
                int written = (int) reader.invokeExact(handle, ids, sizes);
                if (written != n) throw new CadaclysmException("health: a row reader wrote " + written + " rows, not " + n);
                return new HealthRows(ids.toArray(ValueLayout.JAVA_INT), sizes.toArray(ValueLayout.JAVA_DOUBLE));
            }
        }
    }

    /**
     * A body's exact B-rep -- the trimmed surfaces its mesh is cut from -- shared with the
     * scene rather than copied: a reference of this object's own, given back by {@link
     * #close()} (or the {@link Cleaner}). It is for the blacksmith library, which operates
     * on it without a copy ({@code Blacksmith.Solid.fromNode}), and for asking whether it is
     * a manifold ({@link #manifold()}). It outlives its scene for as long as anything holds
     * it. In the node's own frame and the
     * file's own units and axes, whatever convention the scene was opened with. The
     * blacksmith library must come from the same release; it checks {@link #layoutId()}
     * and refuses otherwise.
     */
    public static final class Brep implements AutoCloseable {
        private final BrepReference reference;
        private final Cleaner.Cleanable cleanable;

        private Brep(MemorySegment raw) {
            reference = new BrepReference(raw.address());
            cleanable = CLEANER.register(this, reference);
        }

        /** The C pointer, for the blacksmith library to take its own reference on. */
        public MemorySegment pointer() {
            if (reference.address == 0) throw new IllegalStateException("brep: released");
            return MemorySegment.ofAddress(reference.address);
        }

        /** How this library lays a brep out in memory: its compiler, target and source.
         *  The blacksmith library shares a brep only with a library whose id equals its own. */
        public static String layoutId() {
            try {
                return string((MemorySegment) BREP_LAYOUT_ID.invokeExact());
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        public boolean closed() {
            return reference.address == 0;
        }

        /** Whether its faces make a manifold -- every edge bordered by one face or two, the
         *  faces round every vertex one fan -- and whether it is closed. Read off the topology
         *  the file wrote, not a mesh: faces that name no shared edge (IGES, each surface its
         *  own sheet; an IFC face written as one polygon) read as open however well they meet
         *  in space. */
        public Manifold manifold() {
            MemorySegment p = pointer();
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_INT, 8);
                boolean ok;
                try {
                    ok = (boolean) BREP_MANIFOLD.invokeExact(p, out);
                } catch (Throwable t) {
                    throw new RuntimeException(t);
                }
                if (!ok) throw new CadaclysmException(lastErrorOr("manifold"));
                return Manifold.of(out.toArray(ValueLayout.JAVA_INT));
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
        }

        /** This brep with its free edges sewn, and what was sewn, as a new {@link Brep} and a
         *  {@link SewReport}; this one is left as it was. Two free edges become one shared
         *  edge where both their ends coincide within {@code vertex} -- by default the
         *  rounding {@link #manifold()} merges vertices at -- and their curves lie within
         *  {@code tolerance} of each other, by default {@code vertex} too, so only edges that
         *  are one curve written twice are joined. A larger {@code tolerance} also joins two
         *  curves between the same two vertices that part by up to it; {@code vertex} is what
         *  decides which edges are candidates at all, and raising it is what could close a
         *  slot. Nothing moves. Pass null for either to take its default. */
        public Sewn sewed(Double tolerance, Double vertex) {
            MemorySegment p = pointer();
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment counts = arena.allocate(ValueLayout.JAVA_INT, 4);
                MemorySegment gaps = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                MemorySegment raw;
                try {
                    raw = (MemorySegment) BREP_SEW.invokeExact(p, tolerance == null ? Double.NaN : tolerance,
                            vertex == null ? Double.NaN : vertex, counts, gaps);
                } catch (Throwable t) {
                    throw new RuntimeException(t);
                }
                if (raw.address() == 0) throw new CadaclysmException(lastErrorOr("sew"));
                int[] c = counts.toArray(ValueLayout.JAVA_INT);
                double[] g = gaps.toArray(ValueLayout.JAVA_DOUBLE);
                return new Sewn(new Brep(raw), new SewReport(c[0], c[1], c[2], c[3], g[0], g[1], g[2]));
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
        }

        /** {@link #health(Double, boolean)} at the default tolerance, without the mesh. */
        public HealthReport health() {
            return health(null, false);
        }

        /** What is wrong with this brep, as a {@link HealthReport}: the free edges (the sides one
         *  face bounds) and the wires they chain into, with each edge's nearest partner and the
         *  gap to it; the features below {@code tolerance}; the loose edges; and what {@link
         *  #sewed} would join and leave. {@code tolerance} is the length below which a feature
         *  is small and a gap closes -- null, or a value that is not finite and positive, takes
         *  the default (the report shows what was used). {@code mesh} also meshes the brep and
         *  reports where the mesh cracks ({@code cracks}); without it {@code cracks} is null.
         *  Nothing moves. */
        public HealthReport health(Double tolerance, boolean mesh) {
            MemorySegment p = pointer();
            MemorySegment h;
            try {
                h = (MemorySegment) BREP_HEALTH.invokeExact(p, tolerance == null ? Double.NaN : tolerance, mesh);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            if (h.address() == 0) throw new CadaclysmException(lastErrorOr("health"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment counts = arena.allocate(ValueLayout.JAVA_INT, 18);
                MemorySegment sizes = arena.allocate(ValueLayout.JAVA_DOUBLE, 8);
                if (!(boolean) BREP_HEALTH_SUMMARY.invokeExact(h, counts, sizes)) throw new CadaclysmException(lastErrorOr("health"));
                HealthRows free = HealthRows.read(BREP_HEALTH_FREE_EDGES, h, 6, 2);
                HealthRows wires = HealthRows.read(BREP_HEALTH_WIRES, h, 3, 2);
                HealthRows small = HealthRows.read(BREP_HEALTH_SMALL, h, 2, 1);
                int n = (int) BREP_HEALTH_CRACK_EDGES.invokeExact(h, MemorySegment.NULL);
                int[] cracks = new int[0];
                if (n > 0) {
                    MemorySegment ids = arena.allocate(ValueLayout.JAVA_INT, n);
                    int written = (int) BREP_HEALTH_CRACK_EDGES.invokeExact(h, ids);
                    if (written != n) throw new CadaclysmException("health: the crack edges wrote " + written + " ids, not " + n);
                    cracks = ids.toArray(ValueLayout.JAVA_INT);
                }
                return HealthReport.of(counts.toArray(ValueLayout.JAVA_INT), sizes.toArray(ValueLayout.JAVA_DOUBLE), free.ids(),
                        free.sizes(), wires.ids(), wires.sizes(), small.ids(), small.sizes(), cracks);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            } finally {
                try {
                    BREP_HEALTH_FREE.invokeExact(h);
                } catch (Throwable t) {
                    throw new RuntimeException(t);
                }
                java.lang.ref.Reference.reachabilityFence(this);
            }
        }

        /** {@link #healed(Double, boolean, boolean, boolean)} at the default tolerance, every
         *  kind of fix on. */
        public Healed healed() {
            return healed(null, true, true, true);
        }

        /** {@link #healed(Double, boolean, boolean, boolean)} with every kind of fix on. */
        public Healed healed(Double tolerance) {
            return healed(tolerance, true, true, true);
        }

        /** This brep with its small features removed, and what was done, as a new {@link Brep}
         *  and a {@link HealReport}; this one is left as it was. The features are the ones
         *  {@link #health} lists as small at {@code tolerance}: short and collapsed edges,
         *  sliver and tiny faces, small holes. Every fix is a vertex merge, and an edge it moves
         *  records how far as its {@link #edgeTolerance}. A guard compares the result's health
         *  with this one's and refuses fixes that made it worse ({@code guarded}). {@code
         *  edges}, {@code faces} and {@code holes} switch each kind of fix; a kind switched off
         *  is refused as "toggled". {@code tolerance} null, or a value that is not finite and
         *  positive, takes the default (the report shows what was used). The brep is the
         *  caller's to close. */
        public Healed healed(Double tolerance, boolean edges, boolean faces, boolean holes) {
            MemorySegment p = pointer();
            MemorySegment h;
            try {
                h = (MemorySegment) BREP_HEALED.invokeExact(p, tolerance == null ? Double.NaN : tolerance, healFlags(edges, faces, holes));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            if (h.address() == 0) throw new CadaclysmException(lastErrorOr("healed"));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment counts = arena.allocate(ValueLayout.JAVA_INT, 11);
                MemorySegment sizes = arena.allocate(ValueLayout.JAVA_DOUBLE, 2);
                if (!(boolean) BREP_HEAL_SUMMARY.invokeExact(h, counts, sizes)) throw new CadaclysmException(lastErrorOr("healed"));
                HealthRows fixes = HealthRows.read(BREP_HEAL_FIXES, h, 2, 2);
                HealthRows refused = HealthRows.read(BREP_HEAL_REFUSED, h, 3, 1);
                HealReport report = HealReport.of(counts.toArray(ValueLayout.JAVA_INT), sizes.toArray(ValueLayout.JAVA_DOUBLE),
                        fixes.ids(), fixes.sizes(), refused.ids(), refused.sizes());
                MemorySegment body = (MemorySegment) BREP_HEAL_BODY.invokeExact(h);
                if (body.address() == 0) throw new CadaclysmException(lastErrorOr("healed"));
                return new Healed(new Brep(body), report);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            } finally {
                try {
                    BREP_HEAL_FREE.invokeExact(h);
                } catch (Throwable t) {
                    throw new RuntimeException(t);
                }
                java.lang.ref.Reference.reachabilityFence(this);
            }
        }

        /** How far brep edge {@code edge} (as a {@link HealFix} names one) may lie off its curve:
         *  0 for an exact edge, the distance healing (or sewing) moved it where that is
         *  recorded, null when no trim names the id (an edge healing removed). */
        public Double edgeTolerance(int edge) {
            MemorySegment p = pointer();
            try {
                double t = (double) BREP_EDGE_TOLERANCE.invokeExact(p, edge);
                return Double.isNaN(t) ? null : t;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
        }

        /** Give this reference back. Idempotent. */
        @Override
        public void close() {
            cleanable.clean();
        }
    }

    /** One meshlet, copied out: the arrays are yours. */
    public record Meshlet(int index, int level, int group, float error, int vertexCount, int triangleCount,
                          float[] positions, float[] normals, int[] indices, int[] children) {
    }

    /** The one handle a {@link Meshlets} holds, freed once by the {@link Cleaner} or by
     *  {@link Meshlets#free()}; the address is zeroed first. */
    private static final class MeshletsReference implements Runnable {
        private long address;

        MeshletsReference(long address) {
            this.address = address;
        }

        @Override
        public void run() {
            long a = address;
            address = 0;
            if (a == 0) return;
            try {
                MESHLETS_FREE.invokeExact(MemorySegment.ofAddress(a));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    /**
     * A mesh split into meshlets, optionally with coarser levels above them, for a mesh-shader
     * or meshlet-based renderer. Built from any mesh and owned by you: {@link #free()} it, or
     * use it in try-with-resources.
     */
    public static final class Meshlets implements AutoCloseable {
        private final MeshletsReference reference;
        private final Cleaner.Cleanable cleanable;

        private Meshlets(MemorySegment raw) {
            reference = new MeshletsReference(raw.address());
            cleanable = CLEANER.register(this, reference);
        }

        /**
         * Split {@code positions} (three floats a vertex), {@code normals} (the same, or null)
         * and {@code indices} (three a triangle) into meshlets of at most {@code maxTriangles}
         * and {@code maxVertices} each -- the consumer's own limits, with no default: Nanite
         * takes 128/256, a mesh-shader pipeline 124/64. {@code levels} above 0 groups and
         * simplifies each level into the next until one meshlet is left.
         */
        public static Meshlets build(float[] positions, float[] normals, int[] indices, int maxTriangles, int maxVertices, int levels) {
            if (maxTriangles <= 0 || maxVertices <= 0) throw new CadaclysmException("meshlets: maxTriangles and maxVertices are required");
            if (positions.length % 3 != 0 || indices.length % 3 != 0)
                throw new CadaclysmException("meshlets: positions must hold three floats a vertex and indices three a triangle");
            if (normals != null && normals.length != positions.length)
                throw new CadaclysmException("meshlets: normals must hold one per vertex, three floats each");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment p = arena.allocateFrom(ValueLayout.JAVA_FLOAT, positions);
                MemorySegment n = normals == null ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_FLOAT, normals);
                MemorySegment i = arena.allocateFrom(ValueLayout.JAVA_INT, indices);
                MemorySegment raw = (MemorySegment) MESHLETS_BUILD.invokeExact(p, n, (long) (positions.length / 3), i, (long) indices.length,
                        maxTriangles, maxVertices, levels);
                if (raw.address() == 0) {
                    String reason = string((MemorySegment) LAST_ERROR.invokeExact());
                    throw new CadaclysmException(reason.isEmpty() ? "meshlets: build failed" : reason);
                }
                return new Meshlets(raw);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        private MemorySegment handle() {
            if (reference.address == 0) throw new CadaclysmException("meshlets: freed");
            return MemorySegment.ofAddress(reference.address);
        }

        public boolean closed() {
            return reference.address == 0;
        }

        /** Give the meshlets back. Idempotent. */
        public void free() {
            cleanable.clean();
        }

        @Override
        public void close() {
            free();
        }

        /** How many meshlets, every level counted. */
        public int count() {
            return invokeIntOf(MESHLETS_COUNT, handle());
        }

        public int triangleCount(int i) {
            return invokeIntAt(MESHLET_TRIANGLE_COUNT, handle(), i);
        }

        public int vertexCount(int i) {
            return invokeIntAt(MESHLET_VERTEX_COUNT, handle(), i);
        }

        /** 0 for a leaf over the mesh itself, higher for a simplified level above it. */
        public int level(int i) {
            return invokeIntAt(MESHLET_LEVEL, handle(), i);
        }

        public int group(int i) {
            return invokeIntAt(MESHLET_GROUP, handle(), i);
        }

        /** How far this meshlet's level moved the surface; zero at level 0. */
        public float error(int i) {
            try {
                return (float) MESHLET_ERROR.invokeExact(handle(), i);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        public int childCount(int i) {
            return invokeIntAt(MESHLET_CHILD_COUNT, handle(), i);
        }

        /** One meshlet's arrays and numbers, copied out. */
        public Meshlet meshlet(int i) {
            MemorySegment h = handle();
            int vertexCount = vertexCount(i), triangleCount = triangleCount(i), childCount = childCount(i);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment positions = arena.allocate(ValueLayout.JAVA_FLOAT, Math.max(1, vertexCount * 3L));
                MemorySegment normals = arena.allocate(ValueLayout.JAVA_FLOAT, Math.max(1, vertexCount * 3L));
                MemorySegment indices = arena.allocate(ValueLayout.JAVA_INT, Math.max(1, triangleCount * 3L));
                MemorySegment children = arena.allocate(ValueLayout.JAVA_INT, Math.max(1, (long) childCount));
                MESHLET_POSITIONS.invokeExact(h, i, positions);
                MESHLET_NORMALS.invokeExact(h, i, normals);
                MESHLET_INDICES.invokeExact(h, i, indices);
                MESHLET_CHILDREN.invokeExact(h, i, children);
                return new Meshlet(i, level(i), group(i), error(i), vertexCount, triangleCount,
                        positions.asSlice(0, vertexCount * 3L * Float.BYTES).toArray(ValueLayout.JAVA_FLOAT),
                        normals.asSlice(0, vertexCount * 3L * Float.BYTES).toArray(ValueLayout.JAVA_FLOAT),
                        indices.asSlice(0, triangleCount * 3L * Integer.BYTES).toArray(ValueLayout.JAVA_INT),
                        children.asSlice(0, (long) childCount * Integer.BYTES).toArray(ValueLayout.JAVA_INT));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    /** An int from a {@code (handle, uint32_t index)} entry point. */
    private static int invokeIntAt(MethodHandle function, MemorySegment handle, int index) {
        try {
            return (int) function.invokeExact(handle, index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** A double from a {@code (handle, uint32_t index)} entry point. */
    private static double invokeDoubleAt(MethodHandle function, MemorySegment handle, int index) {
        try {
            return (double) function.invokeExact(handle, index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** Frees a {@code CadaclysmPose *}; null is fine, as the ABI documents. */
    private static void invokePoseFree(MemorySegment pose) {
        try {
            POSE_FREE.invokeExact(pose);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    // ---- the FEM surface mesh ---------------------------------------------------------

    /**
     * One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain breaks.
     * Plain data, copied out of the handle -- {@code nodes} and {@code runs} are arrays of
     * your own where {@link FemMesh#nodes()} and its siblings are views, because the ABI hands
     * these over one edge at a time and a record cannot hold a buffer whose owner may be freed
     * under it. Python copies them into tuples for the same reason.
     *
     * <p>{@code nodes} are this mesh's node indices in order along the edge, its end vertices
     * included; a closed edge repeats no node. <b>{@code runs} says where the chain breaks</b>:
     * read {@code nodes[runs[i] .. runs[i + 1]]} (the last run to the end) as one polyline and
     * join nothing across a run boundary. The two ends either side of one are two points of the
     * edge with no mesh edge between them -- a crack along the edge, or a stretch of it the
     * mesher sampled on one face only. {@code [0]} is the ordinary answer, and a caller reading
     * {@code nodes} as one polyline without looking here jumps the gap silently.
     *
     * <p>{@code faces} is {@code (face_a, face_b)} and {@code ends} is {@code (end_a, end_b)},
     * two ints each, as {@code Blacksmith.Edge.faces} is: the second of each is the
     * {@code CADACLYSM_NONE} sentinel where there is none -- an open body's rim, or both ends
     * at one vertex (a closed edge, a circle's rim, a full-turn seam). NONE is
     * {@code 0xFFFFFFFF}, read into a Java {@code int} as <b>-1</b>, the way
     * {@code Blacksmith.Spot}'s fields read it. <b>{@code 0} is a real face and a real vertex,
     * not a sentinel.</b> Which end comes first is the first trim's direction and means nothing
     * else: the pair bounds the edge, it does not orient it.
     *
     * <p>{@code closed} where the nodes make one loop, never where {@code runs} has more than
     * one; {@code seam} where one face bounds the edge twice -- a closed surface's seam rather
     * than a real boundary, and both {@code faces} are then that same face.
     *
     * <p>{@code id} is <b>the body's own B-rep edge id</b>, not this mesh's edge index:
     * {@link FemMesh#edges()} is a densely renumbered subset of the body's edges, ascending by
     * id, with every edge collapsed to a point left out, so edge 0 of a STEP body's mesh
     * routinely has an {@code id} in the hundreds. Everything else that names an edge means the
     * <em>index</em> -- a {@link FemMesh#nodeKind()} of 1 read through
     * {@link FemMesh#nodeEntity()}, the third int of a {@link FemMesh#openEdges()} or
     * {@link FemMesh#foldedEdges()} row, and the {@code edge_N} physical group of
     * {@link FemMesh#mshText()} -- and this is the one way back from any of them to the
     * topology the file wrote.
     */
    public record FemEdge(int id, int[] nodes, int[] runs, int[] faces, int[] ends, boolean closed, boolean seam) {
        @Override
        public String toString() {
            return "FemEdge(id=" + id + ", nodes=" + nodes.length + ", runs=" + runs.length
                    + ", faces=" + Arrays.toString(faces) + ", ends=" + Arrays.toString(ends)
                    + ", closed=" + closed + ", seam=" + seam + ")";
        }
    }

    /**
     * One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where the
     * topology says it is, if that is known. Plain data.
     *
     * <p>{@code node} is the mesh node at this vertex, or -1 ({@code CADACLYSM_NONE}) where the
     * mesh has none there. <b>A sentinel here is ordinary, not a fault</b>: the analysis
     * rebuilds a vertex wherever two trims meet, and a pole's polyline runs give a sphere 48 of
     * them where the mesh has 2 points, so a caller walking these skips the sentinel rather than
     * treating it as a gap.
     *
     * <p>{@code point} is where the vertex is, three doubles, in the same space and under the
     * same placement as {@link FemMesh#nodes()} -- the file's own vertex rather than a mesh
     * node, so the two can differ by the reader's rounding. <b>Meaningless unless
     * {@code hasPosition}</b>: it is all zeros then, a point no geometry has and one a solver
     * would read as a node at the origin.
     */
    public record FemVertex(int node, double[] point, boolean hasPosition) {
        @Override
        public String toString() {
            return "FemVertex(node=" + node + ", point=" + Arrays.toString(point) + ", hasPosition=" + hasPosition + ")";
        }
    }

    /** The one handle a {@link FemMesh} holds, freed once by its arena or by
     *  {@link FemMesh#free()}; the address is zeroed first, exactly as
     *  {@link MeshletsReference} does it, and for the same two-ways-over reason. */
    private static final class FemMeshReference implements Runnable {
        private long address;

        FemMeshReference(long address) {
            this.address = address;
        }

        @Override
        public void run() {
            long a = address;
            address = 0;
            if (a == 0) return;
            try {
                FEM_FREE.invokeExact(MemorySegment.ofAddress(a));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    /**
     * One body meshed for a solver: nodes welded by bits, triangles wound outward, every node
     * tagged with the lowest-dimension B-rep entity it lies on, and every crack reported rather
     * than closed. What {@link Node#femMesh(double, double, double[])} returns, and <b>owned by
     * you</b>: close it (a try-with-resources), {@link #free()} it, or drop it: it is freed once
     * nothing reaches it, and a buffer cut from it does.
     *
     * <p>A handle rather than a snapshot, and its big arrays are read-only
     * {@link DoubleBuffer}/{@link IntBuffer} views over the library's own memory, exactly as
     * {@link Mesh}'s are and for the same reason: a solver mesh is megabytes, and copying it to
     * hand it over would cost that twice.
     *
     * <p><b>The owner of these buffers is this object, not the scene.</b> That is the one thing
     * this class does differently from every other view in this binding: {@link Scene#close()}
     * neither frees a FEM mesh nor stales one, and meshing the body again does not either.
     * There is no generation check as {@code Blacksmith.Mesh} has: a FEM view's pointers are
     * built with the handle and never move.
     *
     * <p><b>What the guard does and does not do.</b> Every accessor below asks the handle
     * first, so a buffer <em>asked for</em> after {@link #free()} throws
     * {@link CadaclysmException}. A buffer <em>already in hand</em> is not protected and cannot
     * be: a read-only NIO buffer cut from a reinterpreted address is a window with no owner left
     * to ask. It reads the freed block instead, and hands back whatever is there by then:
     * measured once on this ABI's kernel twin, a {@link DoubleBuffer} taken before the free and
     * read after gave {@code 1.29e-311} where the mesh had {@code 4.0} -- it does <em>not</em>
     * throw, and it does not reliably give the old numbers either. Copy anything that must
     * outlive the handle ({@code nodes().get(new double[..])}), and read the rest inside the
     * try-with-resources.
     *
     * <p>Dropping it instead of freeing it is safe: its buffers are cut from its own arena, so a
     * {@code FemMesh} the program has finished with stays alive while a buffer taken from it is
     * still being read, and is freed once neither is reachable.
     */
    public static final class FemMesh implements AutoCloseable {
        private final FemMeshReference reference;
        private final Arena lifetime = Arena.ofAuto();

        // The view, read once in the constructor. Every pointer in it is built with the handle
        // and good until it is freed -- nothing in this ABI is built lazily -- so asking again
        // per accessor would be one C call per array for the same answer.
        private final long nodes, triangles, triangleFace, nodeKind, nodeEntity;
        private final int nodeCount, triangleCount, faceCount, edgeCount, vertexCount;
        private final int openEdgeCount, foldedEdgeCount, worstTriangle;
        private final boolean watertight, fromMesh;
        private final double minAngle, longestEdge;

        @SuppressWarnings("restricted") // reinterpret: only to attach the free to the arena.
        private FemMesh(MemorySegment raw) {
            reference = new FemMeshReference(raw.address());
            FemMeshReference ref = reference;
            // The cleanup is ref's alone: it must not reach this mesh, or nothing would.
            MemorySegment.ofAddress(raw.address()).reinterpret(lifetime, ignored -> ref.run());
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(FEM_MESH_VIEW);
                boolean ok;
                try {
                    ok = (boolean) FEM_VIEW.invokeExact(raw, out);
                } catch (Throwable t) {
                    throw new RuntimeException(t);
                }
                if (!ok) {
                    String why = lastErrorOr("fem mesh view");
                    free();
                    throw new CadaclysmException(why);
                }
                nodes = out.get(ValueLayout.ADDRESS, offset(FEM_MESH_VIEW, "nodes")).address();
                triangles = out.get(ValueLayout.ADDRESS, offset(FEM_MESH_VIEW, "triangles")).address();
                triangleFace = out.get(ValueLayout.ADDRESS, offset(FEM_MESH_VIEW, "triangle_face")).address();
                nodeKind = out.get(ValueLayout.ADDRESS, offset(FEM_MESH_VIEW, "node_kind")).address();
                nodeEntity = out.get(ValueLayout.ADDRESS, offset(FEM_MESH_VIEW, "node_entity")).address();
                nodeCount = out.get(ValueLayout.JAVA_INT, offset(FEM_MESH_VIEW, "node_count"));
                triangleCount = out.get(ValueLayout.JAVA_INT, offset(FEM_MESH_VIEW, "triangle_count"));
                faceCount = out.get(ValueLayout.JAVA_INT, offset(FEM_MESH_VIEW, "face_count"));
                edgeCount = out.get(ValueLayout.JAVA_INT, offset(FEM_MESH_VIEW, "edge_count"));
                vertexCount = out.get(ValueLayout.JAVA_INT, offset(FEM_MESH_VIEW, "vertex_count"));
                openEdgeCount = out.get(ValueLayout.JAVA_INT, offset(FEM_MESH_VIEW, "open_edge_count"));
                foldedEdgeCount = out.get(ValueLayout.JAVA_INT, offset(FEM_MESH_VIEW, "folded_edge_count"));
                watertight = out.get(ValueLayout.JAVA_BOOLEAN, offset(FEM_MESH_VIEW, "watertight"));
                fromMesh = out.get(ValueLayout.JAVA_BOOLEAN, offset(FEM_MESH_VIEW, "from_mesh"));
                minAngle = out.get(ValueLayout.JAVA_DOUBLE, offset(FEM_MESH_VIEW, "min_angle"));
                worstTriangle = out.get(ValueLayout.JAVA_INT, offset(FEM_MESH_VIEW, "worst_triangle"));
                longestEdge = out.get(ValueLayout.JAVA_DOUBLE, offset(FEM_MESH_VIEW, "longest_edge"));
            }
        }

        /** The handle, refusing a freed one: every pointer in the cached view is the handle's,
         *  and a freed handle's point at nothing. */
        private MemorySegment handle() {
            if (reference.address == 0) throw new CadaclysmException("fem mesh: freed");
            return MemorySegment.ofAddress(reference.address);
        }

        /** Whether {@link #free()} has run. */
        public boolean closed() {
            return reference.address == 0;
        }

        /** Give the mesh back, and with it every buffer taken from it. Idempotent; the
         *  try-with-resources, or nothing reaching it, does it otherwise. */
        public void free() {
            reference.run();
        }

        @Override
        public void close() {
            free();
        }

        /** Every node's position, three doubles each -- placed, and in the space
         *  {@link Node#femMesh(double, double, double[])} and {@link #fromMesh()} describe.
         *  Every node is used by at least one triangle. */
        public DoubleBuffer nodes() {
            handle();
            return doubleView(lifetime, nodes, nodeCount * 3L);
        }

        /** Three node indices a triangle, wound outward -- a mirroring placement is wound
         *  back. */
        public IntBuffer triangles() {
            handle();
            return intView(lifetime, triangles, triangleCount * 3L);
        }

        /** The B-rep face each triangle lies on, one per triangle, into {@link #faceCount()}
         *  faces. */
        public IntBuffer triangleFace() {
            handle();
            return intView(lifetime, triangleFace, triangleCount);
        }

        /** What each node lies on -- 0 a B-rep vertex, 1 an edge, 2 a face -- one per node: the
         *  lowest-dimension entity it lies on, which is the {@code .msh} format's own
         *  classification rule. {@link #nodeEntity()} says which entity of that kind. */
        public IntBuffer nodeKind() {
            handle();
            return intView(lifetime, nodeKind, nodeCount);
        }

        /** Which vertex, edge or face each node lies on, read by the matching
         *  {@link #nodeKind()}: an index into {@link #vertices()}, into {@link #edges()}, or
         *  into the body's faces. One per node. */
        public IntBuffer nodeEntity() {
            handle();
            return intView(lifetime, nodeEntity, nodeCount);
        }

        /** The body's faces; {@link #triangleFace()} and a {@link #nodeKind()} of 2 index them.
         *  The same faces {@link Node#surfaces()} hands over, in the same order. */
        public int faceCount() {
            handle();
            return faceCount;
        }

        /** One {@link FemEdge} per B-rep edge, in the order a {@link #nodeKind()} of 1 indexes
         *  them; empty for a {@link #fromMesh()} body, which has no B-rep edges at all.
         *
         *  <p><b>This list's own numbering, not the body's</b>: each {@link FemEdge#id()}
         *  carries the body's own edge id. Built afresh on every ask, one C call an edge, so
         *  read it once and keep the list. */
        public List<FemEdge> edges() {
            MemorySegment h = handle();
            List<FemEdge> out = new ArrayList<>(edgeCount);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment raw = arena.allocate(FEM_EDGE);
                for (int i = 0; i < edgeCount; i++) {
                    boolean ok;
                    try {
                        ok = (boolean) FEM_EDGE_AT.invokeExact(h, i, raw);
                    } catch (Throwable t) {
                        throw new RuntimeException(t);
                    }
                    if (!ok) throw new CadaclysmException(lastErrorOr("fem mesh edge " + i));
                    out.add(new FemEdge(
                            raw.get(ValueLayout.JAVA_INT, offset(FEM_EDGE, "id")),
                            chain(raw, "nodes", "node_count"),
                            chain(raw, "runs", "run_count"),
                            new int[] {raw.get(ValueLayout.JAVA_INT, offset(FEM_EDGE, "face_a")),
                                       raw.get(ValueLayout.JAVA_INT, offset(FEM_EDGE, "face_b"))},
                            new int[] {raw.get(ValueLayout.JAVA_INT, offset(FEM_EDGE, "end_a")),
                                       raw.get(ValueLayout.JAVA_INT, offset(FEM_EDGE, "end_b"))},
                            raw.get(ValueLayout.JAVA_BOOLEAN, offset(FEM_EDGE, "closed")),
                            raw.get(ValueLayout.JAVA_BOOLEAN, offset(FEM_EDGE, "seam"))));
                }
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
            return out;
        }

        /** One int array out of a {@code FEM_EDGE} pointer/count pair, copied: an edge's chain
         *  cannot be lent, the record outliving the {@link Arena} the struct was read in. */
        private static int[] chain(MemorySegment raw, String pointer, String count) {
            long at = raw.get(ValueLayout.ADDRESS, offset(FEM_EDGE, pointer)).address();
            int n = raw.get(ValueLayout.JAVA_INT, offset(FEM_EDGE, count));
            return at == 0 ? new int[0] : intArray(at, n);
        }

        /** One {@link FemVertex} per B-rep vertex, in the order a {@link #nodeKind()} of 0
         *  indexes them; empty for a {@link #fromMesh()} body. Built afresh on every ask. */
        public List<FemVertex> vertices() {
            MemorySegment h = handle();
            List<FemVertex> out = new ArrayList<>(vertexCount);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment raw = arena.allocate(FEM_VERTEX);
                for (int i = 0; i < vertexCount; i++) {
                    boolean ok;
                    try {
                        ok = (boolean) FEM_VERTEX_AT.invokeExact(h, i, raw);
                    } catch (Throwable t) {
                        throw new RuntimeException(t);
                    }
                    if (!ok) throw new CadaclysmException(lastErrorOr("fem mesh vertex " + i));
                    out.add(new FemVertex(
                            raw.get(ValueLayout.JAVA_INT, offset(FEM_VERTEX, "node")),
                            raw.asSlice(offset(FEM_VERTEX, "point"), 3L * Double.BYTES).toArray(ValueLayout.JAVA_DOUBLE),
                            raw.get(ValueLayout.JAVA_BOOLEAN, offset(FEM_VERTEX, "has_position"))));
                }
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
            return out;
        }

        /**
         * Every crack, as {@code {a, b, brepEdge}}: a directed mesh edge {@code (a, b)} with no
         * {@code (b, a)}, and the B-rep edge <em>index</em> both nodes lie on, or -1 where they
         * share none.
         *
         * <p><b>Empty unless the body's topology is closed -- for a B-rep body</b>, whose mesh
         * is otherwise not asked about at all: such a body reports {@link #watertight()} false
         * with this and {@link #foldedEdges()} <em>both</em> empty, and that trio together says
         * "not asked", not "nothing found".
         *
         * <p><b>A {@link #fromMesh()} body is the other case, and the opposite one.</b> A bare
         * mesh carries no topology to say whether it ought to close, so its census always runs
         * over the welded triangles: an open one lists its cracks here with
         * {@link #watertight()} false, a closed one reports it true, and an empty census there
         * really does mean "nothing found".
         */
        public List<int[]> openEdges() {
            return census(FEM_OPEN_EDGE, openEdgeCount, "open edge");
        }

        /**
         * Every fold, as {@link #openEdges()} reports a crack: a directed mesh edge used by more
         * than one triangle.
         *
         * <p><b>A body can be folded without being open</b> -- a solid no thicker than a line
         * leaves no hole for an open edge to find -- and the closure census's own known-bad
         * bodies are folds rather than open cracks. A caller that checks {@link #openEdges()}
         * alone calls such a body sound. Empty under the same rule as {@link #openEdges()}.
         */
        public List<int[]> foldedEdges() {
            return census(FEM_FOLDED_EDGE, foldedEdgeCount, "folded edge");
        }

        /**
         * Every pair of triangles that pass through each other, as {@code {a, b}} with
         * {@code a < b}, sorted: an edge of one through the other's interior. Their B-rep
         * faces are {@link #triangleFace()}{@code [a]} and {@code [b]}.
         *
         * <p><b>Computed for every body, open or closed.</b> The census {@link #watertight()},
         * {@link #openEdges()} and {@link #foldedEdges()} report is topological and cannot see
         * a surface passing through itself; a mesh is ready for a volume mesher when it is
         * {@link #watertight()} <b>and</b> this is empty -- Gmsh refuses one that crosses. A
         * copy.
         */
        public List<int[]> crossings() {
            MemorySegment h = handle();
            List<int[]> out;
            try {
                int count = invokeIntOf(FEM_CROSSING_COUNT, h);
                out = new ArrayList<>(count);
                try (Arena arena = Arena.ofConfined()) {
                    MemorySegment pair = arena.allocate(ValueLayout.JAVA_INT, 2);
                    for (int i = 0; i < count; i++) {
                        MemorySegment a = pair.asSlice(0, Integer.BYTES);
                        MemorySegment b = pair.asSlice(Integer.BYTES, Integer.BYTES);
                        boolean ok;
                        try {
                            ok = (boolean) FEM_CROSSING.invokeExact(h, i, a, b);
                        } catch (Throwable t) {
                            throw new RuntimeException(t);
                        }
                        if (!ok) throw new CadaclysmException(lastErrorOr("fem mesh crossing " + i));
                        out.add(pair.toArray(ValueLayout.JAVA_INT));
                    }
                }
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
            return out;
        }

        /** The library's two census readers have one shape, so the two lists cannot drift. */
        private List<int[]> census(MethodHandle row, int count, String what) {
            MemorySegment h = handle();
            List<int[]> out = new ArrayList<>(count);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment triple = arena.allocate(ValueLayout.JAVA_INT, 3);
                for (int i = 0; i < count; i++) {
                    MemorySegment a = triple.asSlice(0, Integer.BYTES);
                    MemorySegment b = triple.asSlice(Integer.BYTES, Integer.BYTES);
                    MemorySegment edge = triple.asSlice(2L * Integer.BYTES, Integer.BYTES);
                    boolean ok;
                    try {
                        ok = (boolean) row.invokeExact(h, i, a, b, edge);
                    } catch (Throwable t) {
                        throw new RuntimeException(t);
                    }
                    if (!ok) throw new CadaclysmException(lastErrorOr("fem mesh " + what + " " + i));
                    out.add(triple.toArray(ValueLayout.JAVA_INT));
                }
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
            return out;
        }

        /** The welded mesh closes -- and, for a B-rep body, so does the topology behind it.
         *  <b>False for every B-rep body whose topology is not closed</b>, whose mesh is then
         *  not asked about at all; read {@link #openEdges()} for what an empty census beside a
         *  false here does and does not mean. A {@link #fromMesh()} body has no topology to ask
         *  of, so this says only that its triangles close. */
        public boolean watertight() {
            handle();
            return watertight;
        }

        /** This came from the scene's own mesh rather than from a brep: one face, every node on
         *  face 0, no edges and no vertices.
         *
         *  <p><b>It is also which space the mesh is in.</b> A B-rep body's FEM mesh is in the
         *  <em>file's own units and axes</em>, whatever convention the scene was opened with,
         *  because it is taken off the brep. A node with no brep falls back to the scene's mesh,
         *  which <em>is</em> converted, so it comes back in the scene's convention, wound
         *  counter-clockwise about the outward normal even where the convention winds the other
         *  way. Under a non-NATIVE convention those are two different spaces.
         *
         *  <p>And it is which contract {@link #watertight()} and the two censuses are reporting
         *  under: read {@link #openEdges()}. */
        public boolean fromMesh() {
            handle();
            return fromMesh;
        }

        /** The smallest interior angle of any triangle, in degrees. There is always one: a body
         *  that meshed to no triangles is a refusal, not a mesh. */
        public double minAngle() {
            handle();
            return minAngle;
        }

        /** The triangle with that angle, as an index into {@link #triangles()} by triple. */
        public int worstTriangle() {
            handle();
            return worstTriangle;
        }

        /** The longest triangle edge, placed.
         *
         *  <p><b>The figure to check against {@code maxSize}, and the only one that says what
         *  the mesh actually is.</b> {@code maxSize} bounds the boundary segments and merely
         *  <em>targets</em> the interior: measured at 1.03 x {@code maxSize} on a face whose
         *  parameters run unevenly, where a full-size boundary piece met a much shorter one left
         *  by halving. One small enough beside the body to reach the mesher's own piece and
         *  station ceilings is not honoured at all. A caller that asked for an element size reads
         *  this to find out whether it got one -- and {@code tolerance} alone, not
         *  {@code maxSize}, decides how closely the boundary follows the geometry. */
        public double longestEdge() {
            handle();
            return longestEdge;
        }

        /**
         * The mesh as Gmsh 4.1 ASCII {@code .msh} text: an entity per B-rep vertex, edge and
         * face, a volume where the body closes, and a physical group naming each.
         *
         * <p><b>The library's text is borrowed from this handle</b> and replaced by the next call
         * on it -- this ABI's convention, and the opposite of the kernel library's, where
         * {@code Blacksmith.FemMesh.mshText} is handed an owned string to free with
         * {@code cadaclysm_blacksmith_string_free}. Nothing here has to free anything either
         * way: the {@code char *} is copied into a {@code String} of your own on the way out,
         * which outlives the handle. A reader porting one side's reasoning onto the other leaks
         * or double-frees.
         *
         * <p><b>No unlicensed notice is printed here.</b>
         * {@link Node#femMesh(double, double, double[])} gave it once when the mesh was built,
         * and this ABI deliberately does not repeat it on either {@code .msh} call -- where the
         * kernel library notices on both of its writers and <em>not</em> on its builder. Each
         * matches its own siblings, so moving the call to look like the other side breaks a
         * convention.
         *
         * <p>Throws {@link CadaclysmException} for a mesh the writer refuses, naming the field it
         * cannot honour, and for a freed handle.
         */
        public String mshText() {
            MemorySegment h = handle();
            try {
                MemorySegment raw = (MemorySegment) FEM_MSH_TEXT.invokeExact(h);
                if (raw.address() == 0) throw new CadaclysmException(lastErrorOr("msh text"));
                return string(raw);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
        }

        /** {@link #mshText()} written to {@code path} by the library itself: the same bytes from
         *  the same writer, straight to the file rather than through the borrowed slot, so a
         *  {@link #mshText()} call on this handle from another thread cannot free the text under
         *  the write. Throws for a mesh the writer refuses or a file it cannot write, naming the
         *  path. No notice here either; see {@link #mshText()}. */
        public void saveMsh(String path) {
            MemorySegment h = handle();
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment cPath = arena.allocateFrom(path);
                boolean ok = (boolean) FEM_SAVE_MSH.invokeExact(h, cPath);
                if (!ok) throw new CadaclysmException(lastErrorOr("could not write " + path));
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            } finally {
                java.lang.ref.Reference.reachabilityFence(this);
            }
        }

        @Override
        public String toString() {
            return closed() ? "FemMesh(freed)"
                    : "FemMesh(nodes=" + nodeCount + ", triangles=" + triangleCount
                            + ", watertight=" + watertight + ", fromMesh=" + fromMesh + ")";
        }
    }

    public static final class Placement {
        private final Scene scene;
        private final int index;

        private Placement(Scene scene, int index) {
            this.scene = scene;
            this.index = index;
        }

        public Scene scene() {
            return scene;
        }

        public int index() {
            return index;
        }

        /** The node whose mesh, edges and curves this draws. */
        public Node geometry() {
            return new Node(scene, invokePlacementGeometry(scene.handle(), index));
        }

        /** What a click on this drawing should select -- the placement rather than the shape
         *  it draws, which is shared with every sibling copy. */
        public Node select() {
            return new Node(scene, invokePlacementSelect(scene.handle(), index));
        }

        /** Where to draw it, as a row-major 4x4 double matrix, already composed through every
         *  frame between the document's root and this drawing. */
        public double[][] transform() {
            return toRowMajor(rawTransform());
        }

        /** The same matrix in the ABI's own column-major order, as 16 doubles. */
        public double[] rawTransform() {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 16);
                invokePlacementTransform(scene.handle(), index, out);
                return out.toArray(ValueLayout.JAVA_DOUBLE);
            }
        }
    }

    private static int invokePlacementGeometry(MemorySegment scene, int index) {
        try {
            return (int) PLACEMENT_GEOMETRY.invokeExact(scene, index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static int invokePlacementSelect(MemorySegment scene, int index) {
        try {
            return (int) PLACEMENT_SELECT.invokeExact(scene, index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static void invokePlacementTransform(MemorySegment scene, int index, MemorySegment out) {
        try {
            PLACEMENT_TRANSFORM.invokeExact(scene, index, out);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    // ---- Link / Joint -----------------------------------------------------------------

    /**
     * A rigid body of the file's mechanism: the nodes that move together when a joint moves
     * it. From {@link Scene#links()} -- a STEP file's kinematic links; other formats record
     * none.
     */
    public static final class Link {
        private final Scene scene;
        private final int index;

        private Link(Scene scene, int index) {
            this.scene = scene;
            this.index = index;
        }

        public Scene scene() {
            return scene;
        }

        /** Its position in {@link Scene#links()}. */
        public int index() {
            return index;
        }

        /** Its name, as the file gives it. */
        public String name() {
            return string(invokeStringAt(LINK_NAME, scene.handle(), index));
        }

        /** The topmost node of each subtree this link moves, in node order: moving these
         *  moves everything under them. */
        public List<Node> nodes() {
            MemorySegment h = scene.handle();
            int count = invokeIntAt(LINK_NODE_COUNT, h, index);
            List<Node> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(new Node(scene, invokeIntAt(LINK_NODE, h, index, i)));
            return found;
        }

        @Override
        public boolean equals(Object obj) {
            return obj instanceof Link other && other.index == index && other.scene == scene;
        }

        @Override
        public int hashCode() {
            return System.identityHashCode(scene) * 31 + index;
        }

        @Override
        public String toString() {
            return "<Link " + index + " " + name() + ">";
        }
    }

    /**
     * A connection between two links of the file's mechanism. Its two ends keep the file's
     * order, not a parent and a child, since a mechanism may be a network with loops. From
     * {@link Scene#joints()}.
     */
    public static final class Joint {
        private final Scene scene;
        private final int index;

        private Joint(Scene scene, int index) {
            this.scene = scene;
            this.index = index;
        }

        public Scene scene() {
            return scene;
        }

        /** Its position in {@link Scene#joints()}. */
        public int index() {
            return index;
        }

        /** Its name, as the file gives it. */
        public String name() {
            return string(invokeStringAt(JOINT_NAME, scene.handle(), index));
        }

        /** The link it starts at. */
        public Link start() {
            return new Link(scene, invokeIntAt(JOINT_START, scene.handle(), index));
        }

        /** The link it ends at. */
        public Link end() {
            return new Link(scene, invokeIntAt(JOINT_END, scene.handle(), index));
        }

        /** How this joint moves, or null when the file gives it no pair. */
        public Pair pair() {
            int kind = invokeIntAt(JOINT_PAIR_KIND, scene.handle(), index);
            if (kind < 0) return null;
            String typeName = stringOrNull(invokeStringAt(JOINT_PAIR_TYPE, scene.handle(), index));
            double pitchRaw = invokeDoubleAt(JOINT_PAIR_PITCH, scene.handle(), index);
            Double pitch = Double.isNaN(pitchRaw) ? null : pitchRaw;
            double[] rawStart;
            double[] rawEnd;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment start = arena.allocate(ValueLayout.JAVA_DOUBLE, 16);
                MemorySegment end = arena.allocate(ValueLayout.JAVA_DOUBLE, 16);
                boolean ok = (boolean) JOINT_PAIR_FRAMES.invokeExact(scene.handle(), index, start, end);
                if (!ok) throw new CadaclysmException("joint " + index + " reports a pair kind but no frames");
                rawStart = start.toArray(ValueLayout.JAVA_DOUBLE);
                rawEnd = end.toArray(ValueLayout.JAVA_DOUBLE);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            String kindName = stringOrNull(invokeStringAt(JOINT_PAIR_KIND_NAME, scene.handle(), index));
            if (kindName == null) kindName = PairKind.of(kind).name().toLowerCase(java.util.Locale.ROOT);
            List<Double> parameters = new ArrayList<>();
            try (Arena arena = Arena.ofConfined()) {
                long count = (long) JOINT_PAIR_PARAMETERS.invokeExact(scene.handle(), index, MemorySegment.NULL, 0L);
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, Math.max(1L, count));
                long written = (long) JOINT_PAIR_PARAMETERS.invokeExact(scene.handle(), index, out, count);
                for (long i = 0; i < written; i++) parameters.add(out.getAtIndex(ValueLayout.JAVA_DOUBLE, i));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            int freedomCount = invokeIntAt(JOINT_FREEDOM_COUNT, scene.handle(), index);
            List<Freedom> freedoms = new ArrayList<>(freedomCount);
            for (int i = 0; i < freedomCount; i++) freedoms.add(readFreedom(scene.handle(), index, i));
            return new Pair(PairKind.of(kind), typeName, pitch, toRowMajor(rawStart), toRowMajor(rawEnd),
                    rawStart, rawEnd, List.copyOf(freedoms), kindName, List.copyOf(parameters));
        }

        @Override
        public boolean equals(Object obj) {
            return obj instanceof Joint other && other.index == index && other.scene == scene;
        }

        @Override
        public int hashCode() {
            return System.identityHashCode(scene) * 31 + index;
        }

        @Override
        public String toString() {
            return "<Joint " + index + " " + name() + ">";
        }
    }

    // ---- Pair, Freedom and State ------------------------------------------------------------

    /**
     * A {@link CadaclysmPairKind} value naming how a {@link Joint} moves. Values match the
     * header's {@code CADACLYSM_PAIR_*} order exactly, so {@link #of(int)} can index straight
     * into {@link #values()}.
     */
    public enum PairKind {
        REVOLUTE, PRISMATIC, CYLINDRICAL, SPHERICAL, SPHERICAL_WITH_PIN, PLANAR, UNIVERSAL,
        HOMOKINETIC, SCREW, FULLY_CONSTRAINED, UNCONSTRAINED, LOW_ORDER, OTHER;

        static PairKind of(int raw) {
            PairKind[] values = values();
            if (raw < 0 || raw >= values.length) throw new CadaclysmException("unknown pair kind " + raw);
            return values[raw];
        }
    }

    /** One of {@link CadaclysmMotion}'s values, in the header's order. */
    public enum Motion {
        ROTATION, TRANSLATION;

        static Motion of(int raw) {
            Motion[] values = values();
            if (raw < 0 || raw >= values.length) throw new CadaclysmException("unknown motion " + raw);
            return values[raw];
        }
    }

    /** One of {@link CadaclysmFreedomAxis}'s values, in the header's order. */
    public enum FreedomAxis {
        X, Y, Z;

        static FreedomAxis of(int raw) {
            FreedomAxis[] values = values();
            if (raw < 0 || raw >= values.length) throw new CadaclysmException("unknown freedom axis " + raw);
            return values[raw];
        }
    }

    /**
     * One of a pair's degrees of freedom: which motion, about or along which contact-frame
     * axis, and its optional range. {@code lower}/{@code upper} are null when the pair has no
     * limit on that side.
     */
    public record Freedom(Motion motion, FreedomAxis axis, Double lower, Double upper) {}

    private static Freedom readFreedom(MemorySegment scene, int joint, int i) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment out = arena.allocate(FREEDOM);
            boolean ok = (boolean) JOINT_FREEDOM.invokeExact(scene, joint, i, out);
            if (!ok) throw new CadaclysmException("joint " + joint + " has no freedom " + i);
            Motion motion = Motion.of(out.get(ValueLayout.JAVA_INT, offset(FREEDOM, "motion")));
            FreedomAxis axis = FreedomAxis.of(out.get(ValueLayout.JAVA_INT, offset(FREEDOM, "axis")));
            boolean hasLower = out.get(ValueLayout.JAVA_BOOLEAN, offset(FREEDOM, "has_lower"));
            double lower = out.get(ValueLayout.JAVA_DOUBLE, offset(FREEDOM, "lower"));
            boolean hasUpper = out.get(ValueLayout.JAVA_BOOLEAN, offset(FREEDOM, "has_upper"));
            double upper = out.get(ValueLayout.JAVA_DOUBLE, offset(FREEDOM, "upper"));
            return new Freedom(motion, axis, hasLower ? lower : null, hasUpper ? upper : null);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * How a {@link Joint} moves: its kind, its two contact frames, and its degrees of freedom.
     * From {@link Joint#pair()}.
     *
     * <p>{@code typeName} is set only for {@link PairKind#OTHER} (the file's entity name, e.g.
     * {@code "GEAR_PAIR"}); {@code pitch} only for {@link PairKind#SCREW} (length per
     * revolution). Both are null otherwise. {@code frameStart}/{@code frameEnd} are the two
     * contact frames as row-major 4x4 matrices, exactly as {@link Node#transform()} renders one;
     * {@code rawFrameStart}/{@code rawFrameEnd} are the same frames in the ABI's own
     * column-major sixteen-double form, as {@link Node#rawTransform()} gives.
     *
     * <p>{@code kindName} is the kind by name, finer than {@code kind}: the same thirteen
     * names, and {@code "gear"} and {@code "rack_and_pinion"} for the two coupled pairs
     * {@code kind} reads as {@link PairKind#OTHER}. {@code parameters} are the pair's own
     * numbers, in the order {@code Assembly.pairWith} takes them: screw {@code [pitch]},
     * rack_and_pinion {@code [pinion_radius]}, gear {@code [radius_first, radius_second,
     * ratio, bevel, helical_angle]} (always five, the ratio the second link's rotation over
     * the first's); empty for every other kind.
     */
    public record Pair(PairKind kind, String typeName, Double pitch,
                        double[][] frameStart, double[][] frameEnd,
                        double[] rawFrameStart, double[] rawFrameEnd,
                        List<Freedom> freedoms, String kindName, List<Double> parameters) {}

    /** One row of a {@link State}: a joint the state sets, and the values it sets it to. */
    public record StateValue(Joint joint, double[] values) {}

    /** A named mechanism state the file records, e.g. STEP's
     *  {@code MECHANISM_STATE_REPRESENTATION}. From {@link Scene#states()}. */
    public record State(int index, String name, List<StateValue> values) {}

    private static State readState(Scene scene, int index) {
        String name = string(invokeStringAt(STATE_NAME, scene.handle(), index));
        int rowCount = invokeIntAt(STATE_VALUE_COUNT, scene.handle(), index);
        List<StateValue> values = new ArrayList<>(rowCount);
        for (int row = 0; row < rowCount; row++) values.add(readStateValue(scene, index, row));
        return new State(index, name, List.copyOf(values));
    }

    // ---- Sequences ------------------------------------------------------------------------

    /** One keyframe of a {@link Sequence}: the {@link State} it holds at parameter {@code t}, and
     *  how the sequence runs on from it: {@code "undefined"}, {@code "discontinuous"},
     *  {@code "synchronous"} or {@code "linear"}. */
    public record Segment(State state, double t, String interpolation) {}

    /** A motion sequence the file records, e.g. STEP's {@code INTERPOLATED_CONFIGURATION_SEQUENCE}:
     *  keyframes over states. {@code secondsPerUnit} is null when the file names no time unit.
     *  From {@link Scene#sequences()}. */
    public record Sequence(int index, String name, boolean closed, Double secondsPerUnit,
                           List<Segment> segments, Scene scene) {
        /** The first segment's parameter. */
        public double start() {
            return segments.get(0).t();
        }

        /** The last segment's parameter. */
        public double end() {
            return segments.get(segments.size() - 1).t();
        }

        /** {@link #pose(double, Link)} with the default ground. */
        public Pose pose(double t) {
            return pose(t, null);
        }

        /** The mechanism posed at sequence parameter {@code t}, with {@code ground} held fixed as
         *  {@link Scene#pose(List, Link)} does. Throws {@link CadaclysmException} for a {@code t}
         *  that is not finite. */
        public Pose pose(double t, Link ground) {
            int groundIndex = ground == null ? NONE : ground.index();
            try {
                MemorySegment ptr = (MemorySegment) POSE_SEQUENCE.invokeExact(scene.handle(), index, t, groundIndex);
                if (ptr.address() == 0) throw new CadaclysmException(lastErrorOr("pose_sequence"));
                return scene.copyPose(ptr);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable th) {
                throw new RuntimeException(th);
            }
        }
    }

    private static final String[] INTERPOLATIONS = {"undefined", "discontinuous", "synchronous", "linear"};

    private static Sequence readSequence(Scene scene, int index, List<State> states) {
        String name = string(invokeStringAt(SEQUENCE_NAME, scene.handle(), index));
        boolean closed;
        double seconds;
        int segmentCount;
        try {
            closed = (boolean) SEQUENCE_CLOSED.invokeExact(scene.handle(), index);
            seconds = (double) SEQUENCE_SECONDS_PER_UNIT.invokeExact(scene.handle(), index);
            segmentCount = (int) SEQUENCE_SEGMENT_COUNT.invokeExact(scene.handle(), index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        List<Segment> segments = new ArrayList<>(segmentCount);
        for (int i = 0; i < segmentCount; i++) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment stateOut = arena.allocate(ValueLayout.JAVA_INT);
                MemorySegment tOut = arena.allocate(ValueLayout.JAVA_DOUBLE);
                MemorySegment interpolationOut = arena.allocate(ValueLayout.JAVA_INT);
                boolean ok = (boolean) SEQUENCE_SEGMENT.invokeExact(scene.handle(), index, i, stateOut, tOut, interpolationOut);
                if (!ok) throw new CadaclysmException(lastErrorOr("sequence_segment"));
                int code = interpolationOut.get(ValueLayout.JAVA_INT, 0);
                segments.add(new Segment(states.get(stateOut.get(ValueLayout.JAVA_INT, 0)),
                        tOut.get(ValueLayout.JAVA_DOUBLE, 0),
                        code >= 0 && code < INTERPOLATIONS.length ? INTERPOLATIONS[code] : "undefined"));
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
        return new Sequence(index, name, closed,
                seconds == 0.0 ? null : seconds,
                List.copyOf(segments), scene);
    }

    // ---- Work schedules -------------------------------------------------------------------

    /** Every date pair of a {@link Task}, in seconds since 1970-01-01T00:00 (no zone), each null
     *  where the file gives none; {@code duration} is in seconds. From {@link Task#time()}. */
    public record TaskTime(Double scheduleStart, Double scheduleFinish, Double earlyStart, Double earlyFinish,
                           Double lateStart, Double lateFinish, Double actualStart, Double actualFinish,
                           Double duration) {}

    /** One task of a {@link WorkSchedule} ({@code IfcTask}). {@code kind} is {@code "attendance"},
     *  {@code "construction"}, {@code "demolition"}, {@code "dismantle"}, {@code "disposal"},
     *  {@code "installation"}, {@code "logistic"}, {@code "maintenance"}, {@code "move"},
     *  {@code "operation"}, {@code "removal"}, {@code "renovation"}, {@code "notdefined"} or
     *  {@code "other"}; {@code kindName} is the text of a user-defined kind, empty otherwise.
     *  {@code parent} is the summary task nesting this one, null for a top-level task. From
     *  {@link WorkSchedule#tasks()}. */
    public record Task(int schedule, int index, String name, String identification, String kind, String kindName,
                       String status, boolean milestone, Task parent, TaskTime time, Scene scene) {
        /** The index of the work schedule this task belongs to ({@code scene.schedules().get(i)}). */
        public int scheduleIndex() {
            return schedule;
        }

        /** The nodes this task builds or removes, in node order. */
        public List<Node> nodes() {
            int count = invokeIntAt(TASK_NODE_COUNT, scene.handle(), schedule, index);
            List<Node> found = new ArrayList<>(count);
            if (count == 0) return found;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_INT, count);
                int written = (int) TASK_NODES.invokeExact(scene.handle(), schedule, index, out, count);
                for (int i = 0; i < Math.min(count, written); i++)
                    found.add(new Node(scene, out.getAtIndex(ValueLayout.JAVA_INT, i)));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            return found;
        }
    }

    /** A sequence between two tasks of one schedule ({@code IfcRelSequence}). {@code kind} is
     *  {@code "finish_start"}, {@code "start_start"}, {@code "finish_finish"},
     *  {@code "start_finish"}, {@code "notdefined"} or {@code "other"}; {@code lag} is in seconds,
     *  null where the file gives none. From {@link WorkSchedule#links()}. */
    public record TaskLink(Task from, Task to, String kind, String kindName, Double lag) {}

    /** What one node is doing on a date, from {@link WorkSchedule#at(double)}: its {@code phase}
     *  ({@code "unbuilt"}, {@code "building"}, {@code "built"}, {@code "demolishing"} or
     *  {@code "demolished"}), {@code progress} 0..1 through the window that governs the phase, and
     *  {@code variance} -- seconds late (positive) or early (negative) -- null where there is none. */
    public record ElementState(Node node, String phase, double progress, Double variance) {}

    /** An IFC work schedule ({@code IfcWorkSchedule}): tasks, the links between them and the dates
     *  they run on. {@code name} is its name, else its identification, else {@code "schedule #k"};
     *  {@code kind} is {@code "planned"}, {@code "actual"}, {@code "baseline"},
     *  {@code "notdefined"} or {@code "other"}. {@code start} and {@code finish} are seconds since
     *  1970-01-01T00:00 (no zone), null where the file gives none. From {@link Scene#schedules()}. */
    public record WorkSchedule(int index, String name, String identification, String kind, String kindName,
                               Double start, Double finish, Scene scene) {
        /** The schedule's tasks, in file order. */
        public List<Task> tasks() {
            int count = invokeIntAt(TASK_COUNT, scene.handle(), index);
            Task[] tasks = new Task[count];
            for (int i = 0; i < count; i++) buildTask(tasks, i, new boolean[count]);
            return List.of(tasks);
        }

        // A parent is built before its child, whichever comes first in the file; `visiting`
        // stops a malformed cycle from recursing forever (the parent is then dropped).
        private Task buildTask(Task[] tasks, int i, boolean[] visiting) {
            if (tasks[i] != null) return tasks[i];
            visiting[i] = true;
            Task parent = null;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_INT);
                boolean has = (boolean) TASK_PARENT.invokeExact(scene.handle(), index, i, out);
                int p = out.get(ValueLayout.JAVA_INT, 0);
                if (has && p >= 0 && p < tasks.length && !visiting[p]) parent = buildTask(tasks, p, visiting);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            MemorySegment h = scene.handle();
            boolean milestone;
            try {
                milestone = (boolean) TASK_MILESTONE.invokeExact(h, index, i);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            tasks[i] = new Task(index, i,
                    string(invokeStringAt(TASK_NAME, h, index, i)),
                    string(invokeStringAt(TASK_IDENTIFICATION, h, index, i)),
                    word(TASK_KINDS, invokeIntAt(TASK_KIND, h, index, i)),
                    string(invokeStringAt(TASK_KIND_NAME, h, index, i)),
                    string(invokeStringAt(TASK_STATUS, h, index, i)),
                    milestone, parent, readTaskTime(scene, index, i), scene);
            visiting[i] = false;
            return tasks[i];
        }

        /** The schedule's task links, in file order. */
        public List<TaskLink> links() {
            List<Task> tasks = tasks();
            int count = invokeIntAt(TASK_LINK_COUNT, scene.handle(), index);
            List<TaskLink> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) {
                try (Arena arena = Arena.ofConfined()) {
                    MemorySegment from = arena.allocate(ValueLayout.JAVA_INT);
                    MemorySegment to = arena.allocate(ValueLayout.JAVA_INT);
                    MemorySegment kind = arena.allocate(ValueLayout.JAVA_INT);
                    MemorySegment lag = arena.allocate(ValueLayout.JAVA_DOUBLE);
                    MemorySegment hasLag = arena.allocate(ValueLayout.JAVA_BOOLEAN);
                    boolean ok = (boolean) TASK_LINK.invokeExact(scene.handle(), index, i, from, to, kind, lag, hasLag);
                    if (!ok) continue;
                    found.add(new TaskLink(tasks.get(from.get(ValueLayout.JAVA_INT, 0)), tasks.get(to.get(ValueLayout.JAVA_INT, 0)),
                            word(LINK_KINDS, kind.get(ValueLayout.JAVA_INT, 0)),
                            string(invokeStringAt(TASK_LINK_KIND_NAME, scene.handle(), index, i)),
                            hasLag.get(ValueLayout.JAVA_BOOLEAN, 0) ? lag.get(ValueLayout.JAVA_DOUBLE, 0) : null));
                } catch (Throwable t) {
                    throw new RuntimeException(t);
                }
            }
            return found;
        }

        /** {@link #at(double, String)} on the scheduled dates. */
        public List<ElementState> at(double date) {
            return at(date, "scheduled");
        }

        /** What every node the schedule names is doing on {@code date}, in seconds since
         *  1970-01-01T00:00, under {@code dates}: {@code "scheduled"} or {@code "actual"}. Throws
         *  {@link CadaclysmException} for any other word or a date that is not finite. */
        public List<ElementState> at(double date, String dates) {
            int which;
            if ("scheduled".equals(dates)) which = 0;
            else if ("actual".equals(dates)) which = 1;
            else throw new CadaclysmException("dates must be 'scheduled' or 'actual'");
            MemorySegment h = scene.handle();
            try (Arena arena = Arena.ofConfined()) {
                long count = (long) SCHEDULE_AT.invokeExact(h, index, date, which, MemorySegment.NULL, 0);
                if (count < 0) throw new CadaclysmException(lastErrorOr("schedule_at"));
                List<ElementState> found = new ArrayList<>((int) count);
                if (count == 0) return found;
                MemorySegment out = arena.allocate(ELEMENT_STATE.byteSize() * count, ELEMENT_STATE.byteAlignment());
                long got = (long) SCHEDULE_AT.invokeExact(h, index, date, which, out, (int) count);
                if (got < 0) throw new CadaclysmException(lastErrorOr("schedule_at"));
                long nodeAt = ELEMENT_STATE.byteOffset(MemoryLayout.PathElement.groupElement("node"));
                long phaseAt = ELEMENT_STATE.byteOffset(MemoryLayout.PathElement.groupElement("phase"));
                long progressAt = ELEMENT_STATE.byteOffset(MemoryLayout.PathElement.groupElement("progress"));
                long hasAt = ELEMENT_STATE.byteOffset(MemoryLayout.PathElement.groupElement("has_variance"));
                long varianceAt = ELEMENT_STATE.byteOffset(MemoryLayout.PathElement.groupElement("variance"));
                for (long i = 0; i < Math.min(got, count); i++) {
                    long base = i * ELEMENT_STATE.byteSize();
                    found.add(new ElementState(new Node(scene, out.get(ValueLayout.JAVA_INT, base + nodeAt)),
                            word(PHASES, out.get(ValueLayout.JAVA_INT, base + phaseAt), "unbuilt"),
                            out.get(ValueLayout.JAVA_DOUBLE, base + progressAt),
                            out.get(ValueLayout.JAVA_BOOLEAN, base + hasAt) ? out.get(ValueLayout.JAVA_DOUBLE, base + varianceAt) : null));
                }
                return found;
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    private static final String[] SCHEDULE_KINDS = {"planned", "actual", "baseline", "notdefined", "other"};
    private static final String[] TASK_KINDS = {"attendance", "construction", "demolition", "dismantle", "disposal",
            "installation", "logistic", "maintenance", "move", "operation", "removal", "renovation", "notdefined", "other"};
    private static final String[] LINK_KINDS = {"finish_start", "start_start", "finish_finish", "start_finish", "notdefined", "other"};
    private static final String[] PHASES = {"unbuilt", "building", "built", "demolishing", "demolished"};

    private static String word(String[] words, int code) {
        return word(words, code, "notdefined");
    }

    private static String word(String[] words, int code, String fallback) {
        return code >= 0 && code < words.length ? words[code] : fallback;
    }

    private static Double optionalDouble(MemorySegment s, String has, String value) {
        return s.get(ValueLayout.JAVA_BOOLEAN, TASK_TIME.byteOffset(MemoryLayout.PathElement.groupElement(has)))
                ? s.get(ValueLayout.JAVA_DOUBLE, TASK_TIME.byteOffset(MemoryLayout.PathElement.groupElement(value)))
                : null;
    }

    private static TaskTime readTaskTime(Scene scene, int schedule, int task) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment s = arena.allocate(TASK_TIME);
            boolean ok = (boolean) TASK_TIME_OF.invokeExact(scene.handle(), schedule, task, s);
            if (!ok) throw new CadaclysmException(lastErrorOr("task_time"));
            return new TaskTime(
                    optionalDouble(s, "has_schedule_start", "schedule_start"),
                    optionalDouble(s, "has_schedule_finish", "schedule_finish"),
                    optionalDouble(s, "has_early_start", "early_start"),
                    optionalDouble(s, "has_early_finish", "early_finish"),
                    optionalDouble(s, "has_late_start", "late_start"),
                    optionalDouble(s, "has_late_finish", "late_finish"),
                    optionalDouble(s, "has_actual_start", "actual_start"),
                    optionalDouble(s, "has_actual_finish", "actual_finish"),
                    optionalDouble(s, "has_duration", "duration"));
        } catch (CadaclysmException e) {
            throw e;
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static WorkSchedule readSchedule(Scene scene, int index) {
        MemorySegment h = scene.handle();
        Double start = null, finish = null;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE);
            if ((boolean) SCHEDULE_START.invokeExact(h, index, out)) start = out.get(ValueLayout.JAVA_DOUBLE, 0);
            if ((boolean) SCHEDULE_FINISH.invokeExact(h, index, out)) finish = out.get(ValueLayout.JAVA_DOUBLE, 0);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        return new WorkSchedule(index,
                string(invokeStringAt(SCHEDULE_NAME, h, index)),
                string(invokeStringAt(SCHEDULE_IDENTIFICATION, h, index)),
                word(SCHEDULE_KINDS, invokeIntAt(SCHEDULE_KIND, h, index)),
                string(invokeStringAt(SCHEDULE_KIND_NAME, h, index)),
                start, finish, scene);
    }

    private static StateValue readStateValue(Scene scene, int state, int row) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment jointOut = arena.allocate(ValueLayout.JAVA_INT);
            int count = (int) STATE_VALUE.invokeExact(scene.handle(), state, row, jointOut, MemorySegment.NULL, 0);
            MemorySegment valuesOut = arena.allocate(ValueLayout.JAVA_DOUBLE, Math.max(1, count));
            int written = (int) STATE_VALUE.invokeExact(scene.handle(), state, row, jointOut, valuesOut, count);
            int jointIndex = jointOut.get(ValueLayout.JAVA_INT, 0);
            double[] values = valuesOut.toArray(ValueLayout.JAVA_DOUBLE);
            if (written != values.length) values = java.util.Arrays.copyOf(values, written);
            Joint joint = jointIndex == NONE ? null : new Joint(scene, jointIndex);
            return new StateValue(joint, values);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    // ---- Pose -----------------------------------------------------------------------------

    /** One value given for a joint's freedom that fell outside its range: reported in
     *  {@link Pose#outOfRange()}, used as given rather than clamped. */
    public record OutOfRange(Joint joint, int freedom, double value) {}

    /**
     * A posed mechanism: {@link Scene#pose} or {@link Scene#poseState}'s answer. The document
     * itself is unchanged.
     *
     * <p>Copied eagerly out of the C handle when it is made ({@link Scene}'s private
     * {@code copyPose} helper), so a {@link Pose} holds no C pointer and outlives the call
     * that made it -- closing the scene does not invalidate its transforms. {@link #show} and
     * {@link #view} need the scene open, since they draw it by handle.
     */
    public static final class Pose {
        private final Scene scene;
        private final Link ground;
        private final List<Joint> unsolved;
        private final List<OutOfRange> outOfRange;
        private final List<String> diagnostics;
        private final double[][] transforms;

        private Pose(Scene scene, Link ground, List<Joint> unsolved, List<OutOfRange> outOfRange, List<String> diagnostics, double[][] transforms) {
            this.scene = scene;
            this.ground = ground;
            this.unsolved = unsolved;
            this.outOfRange = outOfRange;
            this.diagnostics = diagnostics;
            this.transforms = transforms;
        }

        /** The link held fixed. */
        public Link ground() {
            return ground;
        }

        /** Joints that close a loop and were not honoured, in file order. */
        public List<Joint> unsolved() {
            return unsolved;
        }

        /** One entry per given value outside its freedom's range. */
        public List<OutOfRange> outOfRange() {
            return outOfRange;
        }

        /** What the couplings (gear, rack and pinion, a loop-closing screw) could not solve, or
         *  found disagreeing, in file order, in the kernel's words:
         *  {@code coupling 'mesh': both 'a' and 'b' are given and disagree by 0.1}. */
        public List<String> diagnostics() {
            return diagnostics;
        }

        /** {@code node}'s posed transform, as a row-major 4x4 double matrix -- the same type
         *  {@link Node#transform()} returns. */
        public double[][] transform(Node node) {
            return toRowMajor(rawTransform(node));
        }

        /** The same matrix in the ABI's own column-major order, as 16 doubles, exactly as
         *  {@link Node#rawTransform()} lays them out. */
        public double[] rawTransform(Node node) {
            return transforms[node.index()].clone();
        }

        /** Draw this pose's scene as Scene.show does -- by handle -- with every node's posed
         *  transform handed to the view (cadaclysm_view_set_node_transforms). An unposed pose
         *  draws exactly what Scene.show does. */
        public void show() {
            View.present(scene, new View.ShowOptions(), false, transforms);
        }

        public void show(View.ShowOptions options) {
            View.present(scene, options, false, transforms);
        }

        /** Pose.show's orbiting twin; returns what Scene.view returns. */
        public View.Camera view() {
            return View.present(scene, new View.ShowOptions(), true, transforms);
        }

        public View.Camera view(View.ShowOptions options) {
            return View.present(scene, options, true, transforms);
        }

        @Override
        public String toString() {
            return "<Pose ground=" + ground + ">";
        }
    }

    // ---- Node -----------------------------------------------------------------------------

    private static final int NONE = -1; // CADACLYSM_NONE is UINT32_MAX, which is -1 as a signed int.

    /**
     * One node of the document: an assembly, a shape, a placement.
     *
     * <p>A handle rather than a snapshot -- every accessor below asks the scene when you ask
     * it, so nothing here goes stale and nothing is read that a caller never looks at.
     */
    public static final class Node {
        private final Scene scene;
        private final int index;

        Node(Scene scene, int index) {
            this.scene = scene;
            this.index = index;
        }

        public Scene scene() {
            return scene;
        }

        public int index() {
            return index;
        }

        /** Draw with the view library in use: blocks until the window is closed; on the terminal, prints a still. */
        public void show() {
            View.present(this, new View.ShowOptions(), false);
        }

        public void show(View.ShowOptions options) {
            View.present(this, options, false);
        }

        /** Orbit until the window is closed; the camera it was left at and the last pick. */
        public View.Camera view() {
            return View.present(this, new View.ShowOptions(), true);
        }

        public View.Camera view(View.ShowOptions options) {
            return View.present(this, options, true);
        }

        public String name() {
            return string(invokeNodeString(NODE_NAME, scene.handle(), index));
        }

        /** What the file calls it -- a STEP {@code #N}, an IFC GlobalId, a Rhino UUID. */
        public String id() {
            return string(invokeNodeString(NODE_ID, scene.handle(), index));
        }

        /** What the file calls it -- an IFC type, an openNURBS class, a shape kind. */
        public String kind() {
            return string(invokeNodeString(NODE_KIND, scene.handle(), index));
        }

        /** Whether the file says to show this when it is opened -- the file's opening state,
         *  not inherited; see {@link #visibleNow()} for that. */
        public boolean visible() {
            try {
                return (boolean) NODE_VISIBLE.invokeExact(scene.handle(), index);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** {@link #visible()}, but with every ancestor consulted. */
        public boolean visibleNow() {
            Node node = this;
            while (node != null) {
                if (!node.visible()) return false;
                node = node.parent();
            }
            return true;
        }

        /** Whether the file says this cannot be selected or edited -- not hiding: a locked
         *  thing is drawn exactly as any other and only refuses to be picked. Only a {@code
         *  Locked} attribute of {@link ValueKind#BOOLEAN} kind counts; one of any other kind
         *  reads as unlocked here, where Python truth-tests whatever value it finds. */
        public boolean locked() {
            for (Attribute attribute : attributes()) {
                if (attribute.name().equals("Locked")) return Boolean.parseBoolean(attribute.value());
            }
            return false;
        }

        /** Something to put in a tree row: the name, else the kind, else {@code #index}. */
        public String label() {
            String name = name();
            if (!name.isEmpty()) return name;
            String kind = kind();
            return !kind.isEmpty() ? kind : "#" + index;
        }

        /** How far down the tree it sits, a root being zero. For indenting. */
        public int depth() {
            try {
                return (int) NODE_DEPTH.invokeExact(scene.handle(), index);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** What its geometry was before it was triangles -- {@code brep}, {@code mesh},
         *  {@code csg}. Empty for a node that draws nothing. */
        public String generator() {
            return string(invokeNodeString(NODE_GENERATOR, scene.handle(), index));
        }

        public Node parent() {
            int p = invokeNodeInt(NODE_PARENT, scene.handle(), index);
            return p == NONE ? null : new Node(scene, p);
        }

        public List<Node> children() {
            int count = invokeNodeInt(NODE_CHILD_COUNT, scene.handle(), index);
            List<Node> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(new Node(scene, invokeNodeChild(scene.handle(), index, i)));
            return found;
        }

        /** The node whose geometry this one is a placement of, or null. */
        public Node instanceOf() {
            int p = invokeNodeInt(NODE_INSTANCE_OF, scene.handle(), index);
            return p == NONE ? null : new Node(scene, p);
        }

        /** What a click on this node's geometry should select -- itself, usually. */
        public Node selectAs() {
            int chosen = invokeNodeInt(NODE_SELECT_AS, scene.handle(), index);
            return chosen == NONE ? this : new Node(scene, chosen);
        }

        /** Everything the file said about this node. */
        public List<Attribute> attributes() {
            int count = invokeNodeInt(NODE_ATTRIBUTE_COUNT, scene.handle(), index);
            List<Attribute> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) {
                Attribute attribute = invokeNodeAttribute(scene.handle(), index, i);
                if (attribute != null) found.add(attribute);
            }
            return found;
        }

        /** Whether this node is drawn -- whether it has geometry of its own to show. Asks for
         *  nothing to be built. */
        public boolean canMesh() {
            try {
                return (boolean) NODE_CAN_MESH.invokeExact(scene.handle(), index);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** {@link #saveMesh(String, String)} at {@code "stl"}. */
        public void saveMesh(String path) {
            saveMesh(path, "stl");
        }

        /**
         * Write this node's mesh to {@code path} in {@code format} -- one of {@link
         * #meshFormats}. Throws if the node draws nothing or the format is not one the library
         * writes. Ask {@link #canMesh()} first if a menu should grey the row out rather than
         * let the click fail.
         *
         * <p>The mesh written is this node's own, without its placement, so a node instanced
         * six times writes one file wherever it is asked from. No tolerance parameter: {@code
         * cadaclysm_node_save_mesh} takes none, and neither does Python's {@code
         * save_mesh(path, fmt="stl")}.
         */
        public void saveMesh(String path, String format) {
            boolean ok;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment p = arena.allocateFrom(path);
                MemorySegment f = arena.allocateFrom(format);
                ok = invokeSaveMesh(scene.handle(), index, p, f);
            }
            if (!ok) throw new CadaclysmException(lastErrorOr("could not write " + path));
        }

        /** {@link #svgText(SvgOptions)} with every default. */
        public String svgText() {
            return svgText(null);
        }

        /** This node's own wireframe as SVG text, in its own frame -- {@link
         *  Scene#svgText(SvgOptions)}'s options, read from just this node rather than every
         *  placement. */
        public String svgText(SvgOptions options) {
            MemorySegment p;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment o = buildSvgOptions(arena, options, scene.defaultUp());
                p = invokeNodeSvgText(scene.handle(), index, o);
            }
            if (p.address() == 0) throw new CadaclysmException(lastErrorOr("svg"));
            return string(p);
        }

        /** {@link #svgText(SvgOptions)} written to {@code path} by the library itself. */
        public void svg(String path) {
            svg(path, null);
        }

        /** {@link #svgText(SvgOptions)} written to {@code path} by the library itself. */
        public void svg(String path, SvgOptions options) {
            boolean ok;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment o = buildSvgOptions(arena, options, scene.defaultUp());
                MemorySegment p = arena.allocateFrom(path);
                ok = invokeNodeSvg(scene.handle(), index, p, o);
            }
            if (!ok) throw new CadaclysmException(lastErrorOr("could not write " + path));
        }

        /** {@link #silhouetteBeziers(SvgOptions)} with every default. */
        public BeziersData64 silhouetteBeziers() {
            return silhouetteBeziers(null);
        }

        /** This node's silhouette from the camera {@code options} describes -- where its
         *  surfaces turn away from the eye, which no edge of it lies on. The same {@link
         *  SvgOptions} that draw a picture: {@code view}, {@code azimuth}, {@code elevation},
         *  {@code up}, {@code fov}, and {@code width} with {@code tolerance}, which matter here
         *  -- the library reads the tolerance as a fraction of the page, {@code tolerance /
         *  width}. Nothing else in the options changes the curves.
         *
         *  <p><b>A copy, unlike {@link #edgeBeziers64()}.</b> The library keeps one silhouette
         *  slot per scene and the next silhouette call on that scene overwrites it, so a view
         *  over it would change under the caller; this copies out of the slot ({@link
         *  Beziers64#copy()}, whose {@code MemorySegment.toArray} allocates the Java arrays)
         *  before it returns. Calls sharing a scene across threads must serialise, as the
         *  library documents.
         *
         *  <p>A body with no silhouette (every face planar) gives a result with {@code count()}
         *  0, which is not an error; a refused option, a body with no measurable geometry or a
         *  node holding no shape of its own throws {@link CadaclysmException}. */
        public BeziersData64 silhouetteBeziers(SvgOptions options) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment o = buildSvgOptions(arena, options, scene.defaultUp());
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BEZIERS64));
                MemorySegment raw = invokeNodeSilhouetteBeziers(allocator, scene.handle(), index, o);
                Beziers64 curves = buildBeziers64(scene, raw);
                if (curves.points == 0 || curves.count == 0) {
                    // The call clears the thread's error at entry and the empty answer sets none:
                    // a reason here is this call's own refusal, none is the empty answer.
                    String reason = lastError();
                    if (!reason.isEmpty()) throw new CadaclysmException(reason);
                    return new BeziersData64(new double[0], new double[0]);
                }
                return curves.copy();
            }
        }

        /** {@code (r, g, b, a)} if the file gave one, else null -- most STEP files carry no
         *  colour at all, and the honest answer lets the caller use its own. */
        public float[] colour() {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment rgba = arena.allocate(ValueLayout.JAVA_FLOAT, 4);
                boolean has = (boolean) NODE_COLOR.invokeExact(scene.handle(), index, rgba);
                return has ? rgba.toArray(ValueLayout.JAVA_FLOAT) : null;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Where this node's geometry sits, as a row-major 4x4 double matrix. */
        public double[][] transform() {
            return toRowMajor(rawTransform());
        }

        /** The same matrix in the ABI's own column-major order, as 16 doubles. */
        public double[] rawTransform() {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 16);
                NODE_TRANSFORM.invokeExact(scene.handle(), index, out);
                return out.toArray(ValueLayout.JAVA_DOUBLE);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** The extent of the geometry this node draws, in that geometry's own frame. Builds
         *  the geometry if it has not been built. */
        public Bounds bounds() {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BOUNDS));
                MemorySegment raw = (MemorySegment) NODE_BOUNDS.invokeExact(allocator,
                        scene.handle(), index);
                return readBounds(raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** {@link #bounds()}, unnarrowed -- exact far from the origin, where {@link #bounds()}'s
         *  widened {@code float} positions are not. */
        public Bounds64 bounds64() {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BOUNDS64));
                MemorySegment raw = (MemorySegment) NODE_BOUNDS64.invokeExact(allocator,
                        scene.handle(), index);
                return readBounds64(raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Its exact B-rep, for {@code Blacksmith.Solid.fromNode} to operate on, or null
         *  where it has none (a mesh, a curve, a CSG body, an open OpenSCAD polyhedron, or an OpenSCAD file read without the kernel). Shared
         *  with the scene, not copied; see {@link Brep}. */
        public Brep brep() {
            MemorySegment raw;
            try {
                raw = (MemorySegment) NODE_BREP.invokeExact(scene.handle(), index);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            return raw.address() == 0 ? null : new Brep(raw);
        }

        /** Its triangles, in their own frame, built now if they have not been -- or null for
         *  a node with no triangles (structure, or geometry drawn only as curves). */
        public Mesh mesh() {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(MESH));
                return meshOf((MemorySegment) NODE_MESH.invokeExact(allocator, scene.handle(), index));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Its triangles at a coarser level of detail: 0 is {@link #mesh()} itself, 1 up to
         *  {@link Cad#lodLevels()} each about a quarter of the triangles of the one before,
         *  and past that null. Every level shares the level-0 vertices -- the same positions
         *  and vertex count, only the indices differ -- so upload the vertices once and switch
         *  level by drawing a different index range. */
        public Mesh meshLod(int level) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(MESH));
                return meshOf((MemorySegment) NODE_MESH_LOD.invokeExact(allocator, scene.handle(), index, level));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** How far {@link #meshLod(int)} at this level moved the surface, in the scene's
         *  units -- what to pick a level by. Zero at level 0. */
        public float lodError(int level) {
            try {
                return (float) NODE_LOD_ERROR.invokeExact(scene.handle(), index, level);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** {@link #femMesh(double, double, double[])} with every default: the chordal
         *  tolerance 0.01, no size ceiling, no placement. */
        public FemMesh femMesh() {
            return femMesh(0.01, 0.0, null);
        }

        /** {@link #femMesh(double, double, double[])} at this chordal tolerance, with no size
         *  ceiling and no placement. */
        public FemMesh femMesh(double tolerance) {
            return femMesh(tolerance, 0.0, null);
        }

        /** {@link #femMesh(double, double, double[])} with no placement. */
        public FemMesh femMesh(double tolerance, double maxSize) {
            return femMesh(tolerance, maxSize, null);
        }

        /**
         * This node's body meshed for a solver, as a {@link FemMesh}: nodes welded by bits,
         * triangles wound outward, each node tagged with the lowest-dimension B-rep entity it
         * lies on, and every crack reported rather than closed. <b>Owned by you</b> -- close it
         * (a try-with-resources) or {@link FemMesh#free()} it.
         *
         * <p>{@code tolerance} is the chordal tolerance in model units, finite and above zero,
         * and <b>it alone governs how closely the mesh follows the geometry</b>.
         * {@code maxSize} is a size ceiling, finite and zero or more, 0 being no ceiling
         * (curvature alone): <b>it bounds the boundary and targets the interior</b>, which is
         * not a longest-element-edge guarantee -- it adds boundary nodes without refining
         * boundary geometry, and {@link FemMesh#longestEdge()} is what the mesh actually came
         * to, the figure to check against it.
         *
         * <p>Those two defaults are {@code FemOptions::default()}'s own, restated here so the
         * signature says what a caller gets. The library's struct is still filled by
         * {@code cadaclysm_fem_options_init} first, so a field added to it later defaults
         * without this line being touched; only these two are overwritten. <b>Neither is
         * checked here</b>: a mesh-only body is meshed by a path that reads no options at all,
         * so a zero, a negative or a NaN comes back with a mesh there and is refused on a B-rep
         * body -- a wrapper that validated either field would refuse calls this ABI accepts. The
         * placement's length is the one thing this wrapper must check, the ABI receiving only a
         * pointer.
         *
         * <p>{@code placement} is 16 numbers, column-major, as
         * {@link #boundsPlaced(double[])} takes them (null for the identity), applied in
         * {@code double} throughout. The kernel library's {@code Solid.femMesh} takes
         * <b>twelve</b> instead -- origin, x, y, z -- so a caller moving between the two
         * reformats the placement.
         *
         * <p><b>The space is the body's, not the scene's, for a B-rep -- and the scene's for a
         * mesh</b>, which {@link FemMesh#fromMesh()} is the flag for; read it there, because
         * under a non-NATIVE convention the two are different spaces. Meshed in the part's own
         * frame and following the hop from an instance to the shape it draws that {@link #mesh()}
         * follows, so a node instanced six times meshes once, where it is defined.
         *
         * <p><b>A cracked body is not a failure</b>: it comes back with
         * {@link FemMesh#watertight()} false and its cracks in {@link FemMesh#openEdges()} /
         * {@link FemMesh#foldedEdges()} -- <em>both</em> lists, a fold being as real a fault as
         * an open crack -- and nothing is welded shut to make it look sound. Throws
         * {@link CadaclysmException} for a tolerance or size the mesher refuses, a placement that
         * is not 16 numbers or is not finite and invertible, a node with neither a brep nor a
         * mesh (an assembly, a storey, a layer, an empty definition, a curve), and a body that
         * meshes to nothing. <b>The unlicensed notice is printed here</b>, once, and not again
         * on either of the mesh's {@code .msh} calls.
         */
        public FemMesh femMesh(double tolerance, double maxSize, double[] placement) {
            if (placement != null && placement.length != 16)
                throw new CadaclysmException("fem_mesh: a placement is 16 numbers, not " + placement.length);
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment options = arena.allocate(FEM_OPTIONS);
                FEM_OPTIONS_INIT.invokeExact(options);
                options.set(ValueLayout.JAVA_LONG, offset(FEM_OPTIONS, "size"), FEM_OPTIONS.byteSize());
                options.set(ValueLayout.JAVA_DOUBLE, offset(FEM_OPTIONS, "tolerance"), tolerance);
                options.set(ValueLayout.JAVA_DOUBLE, offset(FEM_OPTIONS, "max_size"), maxSize);
                MemorySegment matrix = placement == null
                        ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_DOUBLE, placement);
                MemorySegment raw = (MemorySegment) NODE_FEM_MESH.invokeExact(scene.handle(), index, matrix, options);
                if (raw.address() == 0) throw new CadaclysmException(lastErrorOr("fem_mesh"));
                return new FemMesh(raw);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        private Mesh meshOf(MemorySegment raw) {
            long positions = raw.get(ValueLayout.ADDRESS, offset(MESH, "positions")).address();
            long normals = raw.get(ValueLayout.ADDRESS, offset(MESH, "normals")).address();
            long uvs = raw.get(ValueLayout.ADDRESS, offset(MESH, "uvs")).address();
            long colours = raw.get(ValueLayout.ADDRESS, offset(MESH, "colors")).address();
            long indices = raw.get(ValueLayout.ADDRESS, offset(MESH, "indices")).address();
            int vertexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH, "vertex_count"));
            int indexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH, "index_count"));
            if (indexCount == 0 || positions == 0) return null;
            return new Mesh(scene, positions, normals, uvs, colours, indices, vertexCount, indexCount);
        }

        /** {@link #mesh()} in {@code double}, this node's own mesh lent as it is -- see
         *  {@link Mesh64}. Null for a node with no triangles. */
        public Mesh64 mesh64() {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(MESH64));
                return mesh64Of((MemorySegment) NODE_MESH64.invokeExact(allocator, scene.handle(), index));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        private Mesh64 mesh64Of(MemorySegment raw) {
            long positions = raw.get(ValueLayout.ADDRESS, offset(MESH64, "positions")).address();
            long normals = raw.get(ValueLayout.ADDRESS, offset(MESH64, "normals")).address();
            long uvs = raw.get(ValueLayout.ADDRESS, offset(MESH64, "uvs")).address();
            long colours = raw.get(ValueLayout.ADDRESS, offset(MESH64, "colors")).address();
            long indices = raw.get(ValueLayout.ADDRESS, offset(MESH64, "indices")).address();
            int vertexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH64, "vertex_count"));
            int indexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH64, "index_count"));
            if (indexCount == 0 || positions == 0) return null;
            return new Mesh64(scene, positions, normals, uvs, colours, indices, vertexCount, indexCount);
        }

        /** Its faces as surfaces and trim loops, where the reader built them -- empty where
         *  the reader has no parametric read of this body or of this format. */
        public Surfaces surfaces() {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(SURFACES));
                MemorySegment raw = (MemorySegment) NODE_SURFACES.invokeExact(allocator,
                        scene.handle(), index);
                return buildSurfaces(raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Its feature edges, as polylines to draw an overlay from. */
        public Polylines edges() {
            return polylinesOf(NODE_EDGES);
        }

        /** One RGBA per polyline of {@link #edges()}, null for an edge the file does not
         *  style; empty when nothing is styled. */
        public float[][] edgeColours() {
            return coloursOf(NODE_EDGE_COLORS);
        }

        /** Its free curves, as polylines. A 2D drawing is all of these. */
        public Polylines curves() {
            return polylinesOf(NODE_CURVES);
        }

        /** Its interior surface lines, as polylines -- distinct from {@link #edges()}: those
         *  bound the faces, these rule across them. */
        public Polylines isocurves() {
            return polylinesOf(NODE_ISOCURVES);
        }

        private Polylines polylinesOf(MethodHandle function) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(POLYLINES));
                MemorySegment raw = (MemorySegment) function.invokeExact(allocator,
                        scene.handle(), index);
                return buildPolylines(scene, raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        @SuppressWarnings("restricted") // reinterpret: `count` says how far `rgba` reaches.
        private float[][] coloursOf(MethodHandle function) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(EDGE_COLORS));
                MemorySegment raw = (MemorySegment) function.invokeExact(allocator,
                        scene.handle(), index);
                MemorySegment rgba = raw.get(ValueLayout.ADDRESS, offset(EDGE_COLORS, "rgba"));
                int count = raw.get(ValueLayout.JAVA_INT, offset(EDGE_COLORS, "count"));
                if (rgba.address() == 0 || count == 0) return new float[0][];
                float[] flat = rgba.reinterpret(4L * count * Float.BYTES).toArray(ValueLayout.JAVA_FLOAT);
                float[][] out = new float[count][];
                for (int i = 0; i < count; i++) {
                    out[i] = flat[4 * i + 3] < 0 ? null
                            : new float[] { flat[4 * i], flat[4 * i + 1], flat[4 * i + 2], flat[4 * i + 3] };
                }
                return out;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Its feature edges as cubic Bézier curves -- exact where the file's curves were,
         *  where {@link #edges()} are their chords. Builds the geometry if needed. */
        public Beziers edgeBeziers() {
            return beziersOf(NODE_EDGE_BEZIERS);
        }

        /** Its free curves as cubic Béziers; see {@link #edgeBeziers()}. */
        public Beziers curveBeziers() {
            return beziersOf(NODE_CURVE_BEZIERS);
        }

        /** Its isocurves as cubic Béziers; see {@link #edgeBeziers()}. */
        public Beziers isocurveBeziers() {
            return beziersOf(NODE_ISOCURVE_BEZIERS);
        }

        /** Its feature edges as cubic Béziers, in {@code double}; see {@link #edgeBeziers()}. */
        public Beziers64 edgeBeziers64() {
            return beziers64Of(NODE_EDGE_BEZIERS64);
        }

        /** Its free curves as cubic Béziers, in {@code double}; see {@link #edgeBeziers64()}. */
        public Beziers64 curveBeziers64() {
            return beziers64Of(NODE_CURVE_BEZIERS64);
        }

        /** Its isocurves as cubic Béziers, in {@code double}; see {@link #edgeBeziers64()}. */
        public Beziers64 isocurveBeziers64() {
            return beziers64Of(NODE_ISOCURVE_BEZIERS64);
        }

        private Beziers64 beziers64Of(MethodHandle function) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BEZIERS64));
                MemorySegment raw = (MemorySegment) function.invokeExact(allocator, scene.handle(), index);
                return buildBeziers64(scene, raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        private Beziers beziersOf(MethodHandle function) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BEZIERS));
                MemorySegment raw = (MemorySegment) function.invokeExact(allocator, scene.handle(), index);
                return buildBeziers(scene, raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** The collision body for what this node draws, building its mesh if it is not
         *  built. {@code hullBudget} is the most triangles a hull may have; 0 asks for the
         *  Unity limit (255) and is not clamped to it. Null for a node that draws nothing.
         *  Cached per node and budget. */
        public Collision collision(int hullBudget) {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(COLLISION);
                out.set(ValueLayout.JAVA_INT, offset(COLLISION, "size"), (int) COLLISION.byteSize());
                boolean ok = (boolean) NODE_COLLISION.invokeExact(scene.handle(), index, hullBudget, out);
                if (!ok) return null;
                double[] frame = out.asSlice(offset(COLLISION, "frame"), 16 * Double.BYTES).toArray(ValueLayout.JAVA_DOUBLE);
                double[] halfExtent = out.asSlice(offset(COLLISION, "half_extent"), 3 * Double.BYTES).toArray(ValueLayout.JAVA_DOUBLE);
                return new Collision(
                        out.get(ValueLayout.JAVA_INT, offset(COLLISION, "shape")),
                        out.get(ValueLayout.JAVA_INT, offset(COLLISION, "confidence")),
                        out.get(ValueLayout.JAVA_INT, offset(COLLISION, "axis")),
                        frame, halfExtent,
                        out.get(ValueLayout.JAVA_DOUBLE, offset(COLLISION, "radius")),
                        out.get(ValueLayout.JAVA_DOUBLE, offset(COLLISION, "height")),
                        out.get(ValueLayout.JAVA_DOUBLE, offset(COLLISION, "error")),
                        out.get(ValueLayout.JAVA_INT, offset(COLLISION, "hull_vertex_count")),
                        out.get(ValueLayout.JAVA_INT, offset(COLLISION, "hull_index_count")));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** The convex hull {@link #collision(int)} counted, as triangles. Empty for a node
         *  that draws nothing. A view into the scene, good until it closes or this node is
         *  asked for a different {@code hullBudget}, which refits and frees it. */
        public CollisionHull collisionHull(int hullBudget) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(COLLISION_HULL));
                MemorySegment raw = (MemorySegment) NODE_COLLISION_HULL.invokeExact(allocator, scene.handle(), index, hullBudget);
                long positions = raw.get(ValueLayout.ADDRESS, offset(COLLISION_HULL, "positions")).address();
                long indices = raw.get(ValueLayout.ADDRESS, offset(COLLISION_HULL, "indices")).address();
                int vertexCount = raw.get(ValueLayout.JAVA_INT, offset(COLLISION_HULL, "vertex_count"));
                int indexCount = raw.get(ValueLayout.JAVA_INT, offset(COLLISION_HULL, "index_count"));
                return new CollisionHull(scene, positions, indices, vertexCount, indexCount);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        // -- the surface path: for a renderer drawing exact surfaces, never triangles --

        /** The box of what this node draws under {@code placement} (16 doubles, column-major,
         *  as {@link Placement#rawTransform()}; null for the identity), for a part drawn from
         *  its surfaces: every sample is carried through the convention and the placement
         *  before it is boxed, so it is tighter than placing the corners of {@link #bounds()}.
         *  All zeros for a part with no surfaces. */
        public Bounds boundsPlaced(double[] placement) {
            if (placement != null && placement.length != 16) throw new CadaclysmException("bounds_placed: a placement is 16 numbers");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment matrix = placement == null ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_DOUBLE, placement);
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BOUNDS));
                MemorySegment raw = (MemorySegment) NODE_BOUNDS_PLACED.invokeExact(allocator, scene.handle(), index, matrix);
                return readBounds(raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** {@link #boundsPlaced(double[])}, unnarrowed -- exact far from the origin. */
        public Bounds64 boundsPlaced64(double[] placement) {
            if (placement != null && placement.length != 16) throw new CadaclysmException("bounds_placed64: a placement is 16 numbers");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment matrix = placement == null ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_DOUBLE, placement);
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BOUNDS64));
                MemorySegment raw = (MemorySegment) NODE_BOUNDS_PLACED64.invokeExact(allocator, scene.handle(), index, matrix);
                return readBounds64(raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Whether its mesh has been built and is held -- by {@link Scene#realizeAll()}, by an
         *  ask for it, or by anything else that needed it. */
        public boolean isMeshed() {
            try {
                return (boolean) NODE_IS_MESHED.invokeExact(scene.handle(), index);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Its face boundaries taken from its trimmed surfaces -- the outline that costs no
         *  tessellation, where {@link #edges()} meshes the part. In the surfaces' own frame
         *  (see {@link Scene#surfaceMatrix()}); empty without surfaces. */
        public Polylines surfaceEdges() {
            return polylinesOf(NODE_SURFACE_EDGES);
        }

        /** Its edges as the exact curves, where the reader has them without meshing -- a Rhino
         *  extrusion's rims are its profile -- and empty everywhere else, so a caller drawing
         *  from surfaces tries this before {@link #surfaceEdges()}, whose trims are thinned to
         *  the mesh tolerance. The same segments as {@link #edgeBeziers()}, in the same space:
         *  not the surfaces' frame, so no {@link Scene#surfaceMatrix()}. */
        public Beziers surfaceEdgeBeziers() {
            return beziersOf(NODE_SURFACE_EDGE_BEZIERS);
        }

        /** {@link #edgeColours()} for {@link #surfaceEdges()}. */
        public float[][] surfaceEdgeColours() {
            return coloursOf(NODE_SURFACE_EDGE_COLORS);
        }

        /** Its isocurves taken from its trimmed surfaces and clipped to the trims, without
         *  meshing; a flat face gets none. In the surfaces' frame; empty without surfaces. */
        public Polylines surfaceIsocurves() {
            return polylinesOf(NODE_SURFACE_ISOCURVES);
        }

        /** Where the segment {@code from}..{@code to} first meets this part's surfaces, or null
         *  where it meets none. Exact, and in the surfaces' own frame: carry a ray from the
         *  scene's space through the inverse of {@link Scene#surfaceMatrix()} first. */
        public double[] surfacePick(double[] from, double[] to) {
            if (from.length != 3 || to.length != 3) throw new CadaclysmException("surface_pick: from and to are three numbers each");
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment a = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, from);
                MemorySegment b = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, to);
                MemorySegment hit = arena.allocate(ValueLayout.JAVA_DOUBLE, 3);
                boolean ok = (boolean) NODE_SURFACE_PICK.invokeExact(scene.handle(), index, a, b, hit);
                return ok ? hit.toArray(ValueLayout.JAVA_DOUBLE) : null;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** A coarse mesh over its surfaces for what needs triangles and not a picture (ray
         *  tracing, distance fields): each face gridded {@code cells} by {@code cells}, never
         *  welded, built once per part at the first size asked. Null without surfaces or for
         *  zero cells. */
        public Mesh surfaceProxyMesh(int cells) {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(MESH));
                return meshOf((MemorySegment) NODE_SURFACE_PROXY_MESH.invokeExact(allocator, scene.handle(), index, cells));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** About how many triangles {@link #mesh()} would give, without building it; -1 where
         *  the reader cannot say without doing the work. Treat -1 as unknown, never as zero. */
        public long triangleEstimate() {
            try {
                return (long) NODE_TRIANGLE_ESTIMATE.invokeExact(scene.handle(), index);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** This node and every node under it, parents before children. */
        public Iterable<Node> walk() {
            return () -> new NodeWalker(List.of(this));
        }

        @Override
        public boolean equals(Object obj) {
            return obj instanceof Node other && other.index == index && other.scene == scene;
        }

        @Override
        public int hashCode() {
            return System.identityHashCode(scene) * 31 + index;
        }

        @Override
        public String toString() {
            String label = label();
            return "<Node " + index + " " + (label.isEmpty() ? "?" : label) + ">";
        }
    }

    private static MemorySegment invokeNodeString(MethodHandle function, MemorySegment scene, int index) {
        try {
            return (MemorySegment) function.invokeExact(scene, index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static int invokeNodeInt(MethodHandle function, MemorySegment scene, int index) {
        try {
            return (int) function.invokeExact(scene, index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static int invokeNodeChild(MemorySegment scene, int node, int i) {
        try {
            return (int) NODE_CHILD.invokeExact(scene, node, i);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** Two int arguments past the scene handle -- {@code cadaclysm_link_node}'s (link, index). */
    private static int invokeIntAt(MethodHandle h, MemorySegment scene, int a, int b) {
        try {
            return (int) h.invokeExact(scene, a, b);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static Attribute invokeNodeAttribute(MemorySegment scene, int node, int i) {
        try (Arena arena = Arena.ofConfined()) {
            SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(ATTRIBUTE));
            MemorySegment raw = (MemorySegment) NODE_ATTRIBUTE.invokeExact(allocator,
                    scene, node, i);
            return buildAttribute(raw);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static boolean invokeSaveMesh(MemorySegment scene, int node, MemorySegment path, MemorySegment format) {
        try {
            return (boolean) NODE_SAVE_MESH.invokeExact(scene, node, path, format);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static MemorySegment invokeNodeSvgText(MemorySegment scene, int node, MemorySegment options) {
        try {
            return (MemorySegment) NODE_SVG_TEXT.invokeExact(scene, node, options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static MemorySegment invokeNodeSilhouetteBeziers(SegmentAllocator allocator, MemorySegment scene, int node, MemorySegment options) {
        try {
            return (MemorySegment) NODE_SILHOUETTE_BEZIERS.invokeExact(allocator, scene, node, options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static boolean invokeNodeSvg(MemorySegment scene, int node, MemorySegment path, MemorySegment options) {
        try {
            return (boolean) NODE_SVG.invokeExact(scene, node, path, options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** Depth-first from a set of starting nodes, parents before children -- shared by {@link
     *  Node#walk()} and {@link Scene#walk()}. */
    private static final class NodeWalker implements Iterator<Node> {
        private final Deque<Node> stack = new ArrayDeque<>();

        NodeWalker(List<Node> starts) {
            for (int i = starts.size() - 1; i >= 0; i--) stack.push(starts.get(i));
        }

        @Override
        public boolean hasNext() {
            return !stack.isEmpty();
        }

        @Override
        public Node next() {
            if (stack.isEmpty()) throw new NoSuchElementException();
            Node node = stack.pop();
            List<Node> children = node.children();
            for (int i = children.size() - 1; i >= 0; i--) stack.push(children.get(i));
            return node;
        }
    }

    // ---- Scene ------------------------------------------------------------------------

    /** The one document a {@link Scene} holds, and what closes it -- what the scene's arena
     *  runs once nothing reaches the scene, so it holds the bare address and never the
     *  scene. Closed once: the address is zeroed first. */
    private static final class SceneReference implements Runnable {
        private long address;

        SceneReference(long address) {
            this.address = address;
        }

        @Override
        public void run() {
            long a = address;
            address = 0;
            if (a == 0) return;
            try {
                CLOSE.invokeExact(MemorySegment.ofAddress(a));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    /**
     * An open document. Close it when done, or use it in a try-with-resources block --
     * everything it hands back borrows from it. One dropped without {@link #close()} is
     * closed once nothing reaches it: not the scene, a node, a placement, a mesh, a buffer
     * cut from one, nor a view showing it. Its arena is what tracks that -- every buffer it
     * hands out is a segment of that arena, and a view showing it holds the arena too (so the
     * view is destroyed first, as cadaclysm_view.h requires).
     */
    public static final class Scene implements AutoCloseable {
        private MemorySegment handle;
        private final SceneReference reference;
        private final Arena lifetime = Arena.ofAuto();
        // How many times forgetMeshes has run. Only Mesh64 stamps itself with this: it lends
        // the document's own mesh, which a forget frees, where the float mesh and the line
        // views are the library's own caches and outlive one.
        private long forgets;
        private final String label;
        private final String path;
        private final String schemaPath;
        private final Convention convention;

        @SuppressWarnings("restricted") // reinterpret: only to attach the close to the arena.
        private Scene(MemorySegment handle, String label, String path, String schemaPath, Convention convention) {
            this.handle = handle;
            SceneReference ref = new SceneReference(handle.address());
            this.reference = ref;
            // The cleanup is ref's alone: it must not reach this scene, or nothing would.
            MemorySegment.ofAddress(handle.address()).reinterpret(lifetime, ignored -> ref.run());
            this.label = label;
            this.path = path;
            this.schemaPath = schemaPath;
            this.convention = convention;
        }

        /** The file this was read from -- for a scene opened by {@link Cad#openMemory}, which
         *  has no file on disk, this is the {@code name} it was opened with instead, exactly
         *  as Python's own {@code open_memory} sets {@code path = Path(name)} rather than
         *  leaving it unset. */
        public String path() {
            return path;
        }

        /** The {@code .exp} actually used to open this, or null. */
        public String schemaPath() {
            return schemaPath;
        }

        /** The convention this was opened with. */
        public Convention convention() {
            return convention;
        }

        public boolean closed() {
            return handle == null;
        }

        /** The raw handle, refusing to hand over a closed one -- every call goes through here
         *  rather than touching the field directly, so a use-after-close throws at the call
         *  site instead of passing a dangling pointer into the library. */
        MemorySegment handle() {
            if (handle == null) throw new CadaclysmException(label + ": the scene is closed");
            return handle;
        }

        /** The arena every borrowed buffer is cut from, and what a view showing this holds. */
        Arena lifetime() {
            return lifetime;
        }

        /** Give the scene back now rather than when nothing reaches it. Idempotent. Every
         *  borrowed {@link Mesh} and {@link Polylines} buffer still held is reading freed
         *  memory afterwards: an explicit close does not wait for them. */
        @Override
        public void close() {
            if (handle == null) return;
            // What a view shows of this scene is removed first; a view of another thread that
            // still shows it makes this throw, and the scene stays open.
            View.release(this);
            handle = null;
            reference.run();
        }

        /** Draw with the view library in use: blocks until the window is closed; on the terminal, prints a still. */
        public void show() {
            View.present(this, new View.ShowOptions(), false);
        }

        public void show(View.ShowOptions options) {
            View.present(this, options, false);
        }

        /** Orbit until the window is closed; the camera it was left at and the last pick. */
        public View.Camera view() {
            return View.present(this, new View.ShowOptions(), true);
        }

        public View.Camera view(View.ShowOptions options) {
            return View.present(this, options, true);
        }

        /** The version of the library that read it. */
        public String version() {
            return Cad.version();
        }

        /** The schema the file named, or {@code ""} for a format that names none. */
        public String schema() {
            try {
                return string((MemorySegment) SCHEMA.invokeExact(handle()));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** The schema that actually read it, which is not always the one it named. */
        public String schemaRead() {
            try {
                return string((MemorySegment) SCHEMA_READ.invokeExact(handle()));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Whether something other than the file's own schema read it. */
        public boolean substituted() {
            String read = schemaRead();
            if (read.isEmpty()) return false;
            String bareRead = bare(read);
            for (String part : schema().split(",")) {
                if (bare(part).equals(bareRead)) return false;
            }
            return true;
        }

        private static String bare(String entry) {
            int brace = entry.indexOf('{');
            String cut = (brace >= 0 ? entry.substring(0, brace) : entry).strip();
            while (cut.endsWith(".")) cut = cut.substring(0, cut.length() - 1);
            return cut.toLowerCase();
        }

        /** What one length in the file is worth in metres, or 1 where it did not say. */
        public double metresPerUnit() {
            try {
                return (double) METRES_PER_UNIT.invokeExact(handle());
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** What the file declares about its own precision, as {@link Tolerances}: the absolute
         *  tolerance in the file's own unit (beside {@link #metresPerUnit}, whatever convention
         *  the scene was opened into) and the angular one in radians, null for one it does not
         *  declare -- a 3dm's units and tolerances, STEP's uncertainty, SAT's {@code resabs},
         *  IGES's resolution; other formats declare nothing. Each body read from the file
         *  carries a copy, which the kernel's verbs given a tolerance of 0 work from. */
        public Tolerances tolerances() {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment absolute = arena.allocate(ValueLayout.JAVA_DOUBLE);
                MemorySegment angular = arena.allocate(ValueLayout.JAVA_DOUBLE);
                boolean ok = (boolean) TOLERANCES.invokeExact(handle(), absolute, angular);
                if (!ok) throw new CadaclysmException("tolerances: the scene is closed");
                double a = absolute.get(ValueLayout.JAVA_DOUBLE, 0), g = angular.get(ValueLayout.JAVA_DOUBLE, 0);
                return new Tolerances(Double.isNaN(a) ? null : a, Double.isNaN(g) ? null : g);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Everything the model covers, <b>in world coordinates</b>. This meshes all of it,
         *  being the only way to know how far it reaches. */
        public Bounds bounds() {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BOUNDS));
                MemorySegment raw = (MemorySegment) BOUNDS_OF.invokeExact(allocator, handle());
                return readBounds(raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** {@link #bounds()}, unnarrowed -- exact far from the origin. */
        public Bounds64 bounds64() {
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BOUNDS64));
                MemorySegment raw = (MemorySegment) BOUNDS64_ALL.invokeExact(allocator, handle());
                return readBounds64(raw);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** What this file held that the reader could not build. */
        public List<String> diagnostics() {
            int count = invokeIntOf(DIAGNOSTIC_COUNT, handle());
            List<String> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(string(invokeStringAt(DIAGNOSTIC, handle(), i)));
            return found;
        }

        /** The rigid bodies of the file's mechanism, in the file's order: each names the
         *  nodes that move together. Empty for a file that records none. */
        public List<Link> links() {
            int count = invokeIntOf(LINK_COUNT, handle());
            List<Link> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(new Link(this, i));
            return found;
        }

        /** The connections between those links, in the file's order; see {@link Joint#pair()}
         *  for how each one moves. */
        public List<Joint> joints() {
            int count = invokeIntOf(JOINT_COUNT, handle());
            List<Joint> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(new Joint(this, i));
            return found;
        }

        /** The named mechanism states the file records, e.g. STEP's
         *  {@code MECHANISM_STATE_REPRESENTATION}. Empty for a file that records none. */
        public List<State> states() {
            int count = invokeIntOf(STATE_COUNT, handle());
            List<State> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(readState(this, i));
            return found;
        }

        /** The motion sequences the file records, e.g. STEP's
         *  {@code INTERPOLATED_CONFIGURATION_SEQUENCE}. Empty for a file that records none. */
        public List<Sequence> sequences() {
            int count = invokeIntOf(SEQUENCE_COUNT, handle());
            List<State> states = states();
            List<Sequence> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(readSequence(this, i, states));
            return found;
        }

        /** The IFC work schedules the file records, in file order. Empty for a file that records
         *  none. */
        public List<WorkSchedule> schedules() {
            int count = invokeIntOf(SCHEDULE_COUNT, handle());
            List<WorkSchedule> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(readSchedule(this, i));
            return found;
        }

        /** The link the file declares as the mechanism's base, or null when it declares
         *  none (the default ground is then the link on the most joints; see {@link #pose}). */
        public Link base() {
            int index = invokeIntOf(KINEMATICS_BASE, handle());
            return index == NONE ? null : new Link(this, index);
        }

        /** {@link #pose(List, Link)} with the default ground. */
        public Pose pose(List<StateValue> values) {
            return pose(values, null);
        }

        /**
         * The mechanism posed by {@code values}: rows of a joint and the values it sets, one
         * per freedom of its pair, in the pair's freedom order -- exactly {@link
         * State#values()}'s row type, so {@code pose(state.values())} poses like {@code
         * poseState(state)} -- with {@code ground} (a {@link Link}, or null for the default
         * ground) held fixed. Values outside a freedom's range are used as given and reported
         * in the answer's {@link Pose#outOfRange()}.
         *
         * <p>Throws {@link CadaclysmException} on a bad row (a joint given twice, one with the
         * wrong number of values, ...) or a file with no mechanism, carrying {@code
         * cadaclysm_last_error}'s text unchanged.
         */
        public Pose pose(List<StateValue> values, Link ground) {
            int rowCount = values.size();
            int[] jointsArr = new int[rowCount];
            int[] countsArr = new int[rowCount];
            int flatCount = 0;
            for (int i = 0; i < rowCount; i++) {
                StateValue row = values.get(i);
                jointsArr[i] = row.joint().index();
                countsArr[i] = row.values().length;
                flatCount += countsArr[i];
            }
            double[] flat = new double[flatCount];
            int p = 0;
            for (StateValue row : values) for (double v : row.values()) flat[p++] = v;
            int groundIndex = ground == null ? NONE : ground.index();
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment jointsSeg = rowCount == 0 ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_INT, jointsArr);
                MemorySegment countsSeg = rowCount == 0 ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_INT, countsArr);
                MemorySegment valuesSeg = flatCount == 0 ? MemorySegment.NULL : arena.allocateFrom(ValueLayout.JAVA_DOUBLE, flat);
                MemorySegment ptr = (MemorySegment) POSE.invokeExact(handle(), jointsSeg, countsSeg, valuesSeg, rowCount, groundIndex);
                if (ptr.address() == 0) throw new CadaclysmException(lastErrorOr("pose"));
                return copyPose(ptr);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** {@link #poseState(State, Link)} with the default ground. */
        public Pose poseState(State state) {
            return poseState(state, null);
        }

        /** The mechanism posed by {@code state}'s values, with {@code ground} held fixed as
         *  {@link #pose(List, Link)} does. Throws as {@link #pose(List, Link)} does. */
        public Pose poseState(State state, Link ground) {
            int groundIndex = ground == null ? NONE : ground.index();
            try {
                MemorySegment ptr = (MemorySegment) POSE_STATE.invokeExact(handle(), state.index(), groundIndex);
                if (ptr.address() == 0) throw new CadaclysmException(lastErrorOr("pose_state"));
                return copyPose(ptr);
            } catch (CadaclysmException e) {
                throw e;
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Reads everything out of a {@code CadaclysmPose *} into a {@link Pose}, then frees
         *  it (ruling 2 of the posing plan: wrappers copy eagerly, never holding the C
         *  pointer). Runs in a {@code finally} so an exception midway through copying still
         *  frees the handle. */
        private Pose copyPose(MemorySegment ptr) {
            try {
                Link ground = new Link(this, invokeIntOf(POSE_GROUND, ptr));
                int nodeCount = invokeIntOf(POSE_NODE_COUNT, ptr);
                double[][] transforms = new double[nodeCount][];
                for (int node = 0; node < nodeCount; node++) {
                    try (Arena arena = Arena.ofConfined()) {
                        MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 16);
                        POSE_NODE_TRANSFORM.invokeExact(ptr, node, out);
                        transforms[node] = out.toArray(ValueLayout.JAVA_DOUBLE);
                    } catch (Throwable t) {
                        throw new RuntimeException(t);
                    }
                }
                int unsolvedCount = invokeIntOf(POSE_UNSOLVED_COUNT, ptr);
                List<Joint> unsolved = new ArrayList<>(unsolvedCount);
                for (int i = 0; i < unsolvedCount; i++) {
                    int joint = invokeIntAt(POSE_UNSOLVED, ptr, i);
                    if (joint != NONE) unsolved.add(new Joint(this, joint));
                }
                int outOfRangeCount = invokeIntOf(POSE_OUT_OF_RANGE_COUNT, ptr);
                List<OutOfRange> outOfRange = new ArrayList<>(outOfRangeCount);
                for (int i = 0; i < outOfRangeCount; i++) {
                    try (Arena arena = Arena.ofConfined()) {
                        MemorySegment jointOut = arena.allocate(ValueLayout.JAVA_INT);
                        MemorySegment freedomOut = arena.allocate(ValueLayout.JAVA_INT);
                        MemorySegment valueOut = arena.allocate(ValueLayout.JAVA_DOUBLE);
                        boolean ok = (boolean) POSE_OUT_OF_RANGE.invokeExact(ptr, i, jointOut, freedomOut, valueOut);
                        if (ok) {
                            outOfRange.add(new OutOfRange(new Joint(this, jointOut.get(ValueLayout.JAVA_INT, 0)),
                                    freedomOut.get(ValueLayout.JAVA_INT, 0), valueOut.get(ValueLayout.JAVA_DOUBLE, 0)));
                        }
                    } catch (Throwable t) {
                        throw new RuntimeException(t);
                    }
                }
                int diagnosticCount = invokeIntOf(POSE_DIAGNOSTIC_COUNT, ptr);
                List<String> diagnostics = new ArrayList<>(diagnosticCount);
                for (int i = 0; i < diagnosticCount; i++) {
                    String text = stringOrNull(invokeStringAt(POSE_DIAGNOSTIC, ptr, i));
                    if (text != null) diagnostics.add(text);
                }
                return new Pose(this, ground, List.copyOf(unsolved), List.copyOf(outOfRange), List.copyOf(diagnostics), transforms);
            } finally {
                invokePoseFree(ptr);
            }
        }

        /** What the reader built but the geometry stage could not finish -- a face that would
         *  not trim, a surface that would not mesh. {@link #diagnostics()} is what the file
         *  held that could not be read; this is what the geometry did. */
        public List<String> geometryDiagnostics() {
            int count = invokeIntOf(GEOMETRY_DIAGNOSTIC_COUNT, handle());
            List<String> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(string(invokeStringAt(GEOMETRY_DIAGNOSTIC, handle(), i)));
            return found;
        }

        /** The archive member this was read from, or null for a plain file. */
        public String sourceName() {
            try {
                return stringOrNull((MemorySegment) SOURCE_NAME.invokeExact(handle()));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        private int nodeCount() {
            return invokeIntOf(NODE_COUNT, handle());
        }

        /** Every node, in index order. */
        public List<Node> nodes() {
            int count = nodeCount();
            List<Node> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(new Node(this, i));
            return found;
        }

        /**
         * The nodes a filter matches, in document order.
         *
         * <p>The filter is one boolean expression over a node -- {@code class == ON_Brep and
         * within(class == ON_Layer and name == Walls)}. Throws {@link CadaclysmException}
         * carrying the parser's own message if the filter will not parse; an empty result is
         * not an error -- a filter that matches nothing is a perfectly good answer.
         */
        public List<Node> query(String filter) {
            MemorySegment h = handle();
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment f = arena.allocateFrom(filter);
                int total = invokeQuery(h, f, MemorySegment.NULL, 0);
                if (total == 0) {
                    String reason = lastError();
                    if (!reason.isEmpty()) throw new CadaclysmException(label + ": " + reason);
                    return List.of();
                }
                MemorySegment out = arena.allocate(ValueLayout.JAVA_INT, total);
                int written = invokeQuery(h, f, out, total);
                int count = Math.min(written, total);
                List<Node> found = new ArrayList<>(count);
                for (int i = 0; i < count; i++) found.add(new Node(this, out.getAtIndex(ValueLayout.JAVA_INT, i)));
                return found;
            }
        }

        /** What this document draws and where -- <b>not the nodes</b>: a node walk draws a
         *  Rhino block once at its definition's frame and every placement of it not at all.
         *  This is the list to iterate to draw. */
        public List<Placement> placements() {
            int count = invokeIntOf(PLACEMENT_COUNT, handle());
            List<Placement> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(new Placement(this, i));
            return found;
        }

        /** The nodes nothing else contains. */
        public List<Node> roots() {
            MemorySegment h = handle();
            int count = invokeIntOf(ROOT_COUNT, h);
            List<Node> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) {
                int index = invokeRoot(h, i);
                if (index != NONE) found.add(new Node(this, index));
            }
            return found;
        }

        /** Every node reachable from the roots, parents before children. */
        public Iterable<Node> walk() {
            return () -> new NodeWalker(roots());
        }

        /** Build every mesh now, across threads, and say how many were built. Reading is lazy
         *  so a caller can put the tree on screen while the shapes are still to come. */
        public int realizeAll() {
            return invokeIntOf(REALIZE_ALL, handle());
        }

        /** {@link #realizeAll()}, leaving alone every node that carries surfaces when
         *  {@code skipSurfaced} is true: a renderer drawing those from their surfaces never
         *  pays for their triangles. Returns how many were built. */
        public int realizeMeshes(boolean skipSurfaced) {
            try {
                return (int) REALIZE_MESHES.invokeExact(handle(), skipSurfaced ? 1 : 0);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** How many nodes {@link #realizeAll()} has finished with. Safe to read from another
         *  thread. */
        public int realized() {
            return invokeIntOf(REALIZED, handle());
        }

        /** How many there will be in all -- zero until {@link #realizeAll()} starts. */
        public int realizeTotal() {
            return invokeIntOf(REALIZE_TOTAL, handle());
        }

        /** Ask a running {@link #realizeAll()} to stop. One-way, for the life of the scene. */
        public void cancel() {
            try {
                CANCEL.invokeExact(handle());
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }

        /** Drop every mesh the scene has built; the next ask rebuilds. What it frees is the
         *  document's own mesh: the {@link Mesh64}s handed out before it lend that, so this
         *  counts the forget and one of them read afterwards throws a stale view rather than
         *  reading freed memory. {@link Mesh}, {@link Polylines} and the Béziers are the
         *  library's own caches, which a forget does not touch and which stay good until the
         *  scene closes. */
        public void forgetMeshes() {
            try {
                FORGET_MESHES.invokeExact(handle());
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            forgets++;
        }

        /** {@link #save(String, String)} as {@code "glb"}. */
        public void save(String path) {
            save(path, "glb");
        }

        /**
         * Write the whole scene to {@code path}: {@code "glb"} (binary glTF), {@code "gltf"}
         * (text glTF) or {@code "obj"} (Wavefront) -- every placement of every shape, named
         * and placed as the tree is, where {@link Node#saveMesh} writes one node's mesh on its
         * own. Throws on any other format or a failed write.
         */
        public void save(String path, String format) {
            boolean ok;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment p = arena.allocateFrom(path);
                MemorySegment f = arena.allocateFrom(format);
                ok = invokeSceneSave(handle(), p, f);
            }
            if (!ok) throw new CadaclysmException(lastErrorOr("could not write " + path));
        }

        /**
         * "y" or "z": which axis is up by default, from {@link #convention()} -- {@link
         * Convention#UNITY} and {@link Convention#Y_UP} give "y", every other convention "z".
         * What {@link SvgOptions#up()} defaults to when left null.
         */
        String defaultUp() {
            return convention == Convention.UNITY || convention == Convention.Y_UP ? "y" : "z";
        }

        /** {@link #svgText(SvgOptions)} with every default. */
        public String svgText() {
            return svgText(null);
        }

        /**
         * Every visible placement's wireframe as SVG text, from the camera {@code options}
         * describes -- the library's own camera, not a viewer. Borrowed: copied out before
         * this returns, and replaced by this scene's next {@code svgText}/{@code svg} call.
         */
        public String svgText(SvgOptions options) {
            MemorySegment p;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment o = buildSvgOptions(arena, options, defaultUp());
                p = invokeSceneSvgText(handle(), o);
            }
            if (p.address() == 0) throw new CadaclysmException(lastErrorOr("svg"));
            return string(p);
        }

        /** {@link #svgText(SvgOptions)} written to {@code path} by the library itself. */
        public void svg(String path) {
            svg(path, null);
        }

        /** {@link #svgText(SvgOptions)} written to {@code path} by the library itself. */
        public void svg(String path, SvgOptions options) {
            boolean ok;
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment o = buildSvgOptions(arena, options, defaultUp());
                MemorySegment p = arena.allocateFrom(path);
                ok = invokeSceneSvg(handle(), p, o);
            }
            if (!ok) throw new CadaclysmException(lastErrorOr("could not write " + path));
        }

        /** The 4x4 that puts {@link Node#surfaces()} in the space everything else is already
         *  in. Only the surfaces need it -- meshes and polylines arrive already converted. */
        public float[][] surfaceMatrix() {
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment out = arena.allocate(ValueLayout.JAVA_FLOAT, 16);
                SURFACE_MATRIX.invokeExact(handle(), out);
                return toRowMajor(out.toArray(ValueLayout.JAVA_FLOAT));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    private static int invokeIntOf(MethodHandle function, MemorySegment scene) {
        try {
            return (int) function.invokeExact(scene);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static MemorySegment invokeStringAt(MethodHandle function, MemorySegment scene, int a, int b) {
        try {
            return (MemorySegment) function.invokeExact(scene, a, b);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static MemorySegment invokeStringAt(MethodHandle function, MemorySegment scene, int index) {
        try {
            return (MemorySegment) function.invokeExact(scene, index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static int invokeRoot(MemorySegment scene, int index) {
        try {
            return (int) ROOT.invokeExact(scene, index);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static int invokeQuery(MemorySegment scene, MemorySegment filter, MemorySegment out, int capacity) {
        try {
            return (int) QUERY.invokeExact(scene, filter, out, capacity);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static boolean invokeSceneSave(MemorySegment scene, MemorySegment path, MemorySegment format) {
        try {
            return (boolean) SCENE_SAVE.invokeExact(scene, path, format);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static MemorySegment invokeSceneSvgText(MemorySegment scene, MemorySegment options) {
        try {
            return (MemorySegment) SCENE_SVG_TEXT.invokeExact(scene, options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private static boolean invokeSceneSvg(MemorySegment scene, MemorySegment path, MemorySegment options) {
        try {
            return (boolean) SCENE_SVG.invokeExact(scene, path, options);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    // ---- Loader -------------------------------------------------------------------------

    /**
     * Resolves {@code cadaclysm_capi} for every entry point {@link Cad} declares, and {@code
     * cadaclysm_blacksmith} for {@code Blacksmith.java}'s, so both share one search and one
     * arena. Nested in {@link Cad} rather than a second top-level class in this file, because
     * javac's {@code auxiliaryclass} lint (rightly) refuses the latter from another source
     * file: a class only findable when its neighbour is on the same javac line is a build
     * that works by accident.
     *
     * <p>The reader's rule: {@code CADACLYSM_LIBRARY} as a directory or the file itself; then
     * beside this class's own jar or class directory; then {@code lib/} and {@code
     * target/release} or {@code target/debug} in every ancestor; then the platform's own
     * search. A variable naming a file or a directory that holds neither library is a mistake
     * worth failing on, not a hint to fall through and load something else by accident. The
     * kernel has its own rule, {@code cadaclysm_blacksmith.py}'s, in {@code Blacksmith.java};
     * it shares {@link #ARENA} and {@link #codeLocation} from here.
     */
    static final class Loader {
        private Loader() {
        }

        // Never closed: the library stays loaded for the life of the process, and every
        // segment the library hands back is read under this arena before it is copied out.
        static final Arena ARENA = Arena.ofShared();

        // Each spelled in two pieces below, from when `tests/bindings.rs`'s coverage scan
        // matched any quoted cadaclysm_-prefixed string in this file as a declared entry point
        // -- a library's own bare name read as stale against the header. The scan is anchored
        // on the `bind(linker, lib, "..."` lookup now; the split does no harm and stays.
        static final String CAPI_LIBRARY = "cadaclysm" + "_capi";
        static final String BLACKSMITH_LIBRARY = "cadaclysm" + "_blacksmith";
        private static final String[] LIBRARIES = {CAPI_LIBRARY, BLACKSMITH_LIBRARY};

        private static String[] filesOf(String libraryName) {
            String os = System.getProperty("os.name", "").toLowerCase();
            if (os.contains("win")) return new String[]{libraryName + ".dll"};
            if (os.contains("mac")) return new String[]{"lib" + libraryName + ".dylib"};
            return new String[]{"lib" + libraryName + ".so"};
        }

        /** Where this class's own code lives -- a jar file or a class-file directory, either
         *  way the place a shipped SDK keeps {@code lib/} beside it. Null if that cannot be
         *  worked out, which the caller treats as one more place with nothing to find.
         *  Package-private so {@code Blacksmith.defaultSchema()} walks up from the same place. */
        static Path codeLocation() {
            try {
                CodeSource source = Loader.class.getProtectionDomain().getCodeSource();
                return source == null ? null : Path.of(source.getLocation().toURI());
            } catch (Exception e) {
                return null;
            }
        }

        @SuppressWarnings("restricted") // libraryLookup: the two libraries this project ships.
        static SymbolLookup resolve(String libraryName) {
            String[] files = filesOf(libraryName);
            List<Path> candidates = new ArrayList<>();
            for (String variable : new String[]{"CADACLYSM_LIBRARY"}) {
                String env = System.getenv(variable);
                if (env == null || env.isEmpty()) continue;
                Path at = Path.of(env);
                if (Files.isDirectory(at)) {
                    // A directory is taken as the place the library is, as Python takes it:
                    // one holding neither library is the same mistake as a path to nothing,
                    // not a hint to go on searching and load some other copy. One holding
                    // only the other library is simply not for this one (see the file case).
                    boolean holdsThis = false;
                    for (String file : files) {
                        if (Files.exists(at.resolve(file))) {
                            candidates.add(at.resolve(file));
                            holdsThis = true;
                        }
                    }
                    if (!holdsThis && !holdsEither(at)) {
                        throw new CadaclysmException(variable + "=" + env + " names nothing that exists");
                    }
                    continue;
                }
                if (!Files.exists(at)) {
                    throw new CadaclysmException(variable + "=" + env + " names nothing that exists");
                }
                String basename = at.getFileName().toString();
                if (namesOneOf(basename, files)) {
                    candidates.add(at);
                    continue;
                }
                boolean namesEither = false;
                for (String library : LIBRARIES) {
                    if (namesOneOf(basename, filesOf(library))) namesEither = true;
                }
                if (!namesEither) {
                    throw new CadaclysmException(
                            variable + "=" + env + " names neither cadaclysm_capi nor cadaclysm_blacksmith");
                }
                // Names the *other* library: not a mistake, just not for this resolve -- the
                // search continues (the next variable, or the walk below).
            }
            // Beside this class's own code first, as Python looks beside its own file: the
            // class directory itself, or the directory holding the jar -- a deployment that
            // ships the library alongside the program. Then walking up from there: an SDK
            // checkout keeps the library in `lib/` beside the wrappers; the repository this
            // example ships in keeps it in `target/release` (or `target/debug`, a fallback
            // for a debug-only build).
            Path start = codeLocation();
            Path here = start == null || Files.isDirectory(start) ? start : start.getParent();
            if (here != null) for (String file : files) candidates.add(here.resolve(file));
            for (Path at = start; at != null; at = at.getParent()) {
                for (String file : files) candidates.add(at.resolve("lib").resolve(file));
                for (String file : files) candidates.add(at.resolve("target").resolve("release").resolve(file));
                for (String file : files) candidates.add(at.resolve("target").resolve("debug").resolve(file));
            }
            for (Path candidate : candidates) {
                if (Files.exists(candidate)) {
                    return SymbolLookup.libraryLookup(candidate, ARENA);
                }
            }
            // Nothing found by walking up: the platform's own search (PATH, LD_LIBRARY_PATH,
            // DYLD_LIBRARY_PATH).
            return SymbolLookup.libraryLookup(files[0], ARENA);
        }

        private static boolean namesOneOf(String basename, String[] files) {
            for (String file : files) if (file.equalsIgnoreCase(basename)) return true;
            return false;
        }

        /** Whether {@code dir} holds a copy of either library. */
        private static boolean holdsEither(Path dir) {
            for (String library : LIBRARIES) {
                for (String file : filesOf(library)) if (Files.exists(dir.resolve(file))) return true;
            }
            return false;
        }
    }
}
