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
// points into the open document and dies with it. `Mesh` and `Polylines` hand back read-only
// `FloatBuffer`/`IntBuffer` *views* straight over the library's own memory rather than copies:
// an assembly with tens of millions of triangles makes a defensive copy of every mesh a cost
// most callers never asked for, most meshes being uploaded to a GPU and dropped. Call
// `Mesh.copy()` for arrays that must outlive the scene, or read the buffers before
// `Scene.close()` runs.
//
// Strings are the easy half: every `char *` this ABI returns is copied into a `String` on the
// way out, so `Node.name()` and friends outlive anything.
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

    private static final MemoryLayout POLYLINES = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.ADDRESS.withName("counts"),
            ValueLayout.JAVA_INT.withName("polyline_count"),
            ValueLayout.JAVA_INT.withName("vertex_count"));

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

    // CadaclysmSurfaces: a pointer then a count, five times over. Each count needs four bytes
    // of padding to bring the next pointer back onto an eight-byte boundary -- not pinned by
    // bindings.rs (only Mesh, Polylines and OpenOptions are), but built to the header's own
    // field order regardless.
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
            MemoryLayout.paddingLayout(4));

    // ---- loading the library, and every entry point ----------------------------------

    private static final MethodHandle LAST_ERROR, VERSION, LICENSE_SET, LICENSE_INFO,
            LICENSE_NOTICE_COUNT, BUILD_DATE, OPEN, OPEN_MEMORY, OPEN_OPTIONS_INIT, CLOSE,
            SOURCE_NAME, NODE_COUNT, ROOT_COUNT, ROOT, SCHEMA, SCHEMA_READ, METRES_PER_UNIT,
            BOUNDS_OF, NODE_PARENT, NODE_CHILD_COUNT, NODE_CHILD, NODE_DEPTH, NODE_NAME,
            NODE_KIND, NODE_VISIBLE, NODE_SAVE_MESH, SCENE_SAVE, MESH_FORMAT_COUNT,
            MESH_FORMAT, MESH_FORMAT_EXTENSION, QUERY, PICK_FILE, NODE_ID, NODE_COLOR,
            NODE_TRANSFORM, NODE_ATTRIBUTE_COUNT, NODE_ATTRIBUTE, PLACEMENT_COUNT,
            PLACEMENT_GEOMETRY, PLACEMENT_SELECT, PLACEMENT_TRANSFORM, NODE_CAN_MESH,
            NODE_MESH, NODE_SURFACES, SURFACE_MATRIX, NODE_BOUNDS, NODE_INSTANCE_OF,
            NODE_SELECT_AS, NODE_GENERATOR, DIAGNOSTIC_COUNT, DIAGNOSTIC, NODE_EDGES,
            NODE_CURVES, NODE_ISOCURVES, REALIZE_ALL, REALIZED, REALIZE_TOTAL, CANCEL,
            NODE_BREP, BREP_RELEASE, BREP_LAYOUT_ID, BREP_MANIFOLD;

    static {
        SymbolLookup lib = Loader.resolve(Loader.CAPI_LIBRARY);
        Linker linker = Linker.nativeLinker();
        ValueLayout.OfInt I = ValueLayout.JAVA_INT;
        ValueLayout.OfLong L = ValueLayout.JAVA_LONG;
        ValueLayout.OfDouble D = ValueLayout.JAVA_DOUBLE;
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

    /** One format {@link Node#saveMesh} writes, as its bare name and its file extension. */
    public record MeshFormat(String name, String extension) {
    }

    /**
     * Every format {@link Node#saveMesh} writes. Ask rather than hard-code: a format added to
     * the library turns up in a menu built from this without the client being touched.
     */
    public static List<MeshFormat> meshFormats() {
        int count = invokeMeshFormatCount();
        List<MeshFormat> out = new ArrayList<>(count);
        for (int i = 0; i < count; i++) {
            out.add(new MeshFormat(invokeMeshFormatName(i), invokeMeshFormatExtension(i)));
        }
        return out;
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
     * Open a CAD file, or a {@code .zip} holding one.
     *
     * <p>{@code options.schema()} names an EXPRESS schema ({@code .exp}) beyond the ones built
     * into the library -- every schema the project ships is compiled in, so a STEP or IFC file
     * opens with none. A directory is allowed and is matched against what the file says it
     * speaks. {@code options.convention()} is the space to read the file into; the library
     * does the converting, so every array a caller reads out is already in it.
     *
     * <p>A {@code .zip} opens its first readable member; {@link Scene#sourceName()} says
     * which. Throws {@link CadaclysmException} on failure, carrying what the library said.
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
            return floatView(positions, vertexCount * 3L);
        }

        public FloatBuffer normals() {
            open();
            return floatView(normals, vertexCount * 3L);
        }

        /** Two floats a vertex, not three. Null for a node whose reader produced none. */
        public FloatBuffer uvs() {
            open();
            return floatView(uvs, vertexCount * 2L);
        }

        /** Four floats a vertex, RGBA -- present only for a body opened asking for per-vertex
         *  colour whose faces carry more than one between them. */
        public FloatBuffer colours() {
            open();
            return floatView(colours, vertexCount * 4L);
        }

        public IntBuffer indices() {
            open();
            return intView(indices, indexCount);
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
            return floatView(positions, vertexCount * 3L);
        }

        /** {@code polylineCount} vertex counts saying where each run stops. */
        public IntBuffer counts() {
            scene.handle();
            return intView(counts, polylineCount);
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

        /** Give this reference back. Idempotent. */
        @Override
        public void close() {
            cleanable.clean();
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

        /** Its exact B-rep, for {@code Blacksmith.Solid.fromNode} to operate on, or null
         *  where it has none (a mesh, a curve, a CSG body, a JT or OpenSCAD part). Shared
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
            long positions, normals, uvs, colours, indices;
            int vertexCount, indexCount;
            try (Arena arena = Arena.ofConfined()) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(MESH));
                MemorySegment raw = (MemorySegment) NODE_MESH.invokeExact(allocator,
                        scene.handle(), index);
                positions = raw.get(ValueLayout.ADDRESS, offset(MESH, "positions")).address();
                normals = raw.get(ValueLayout.ADDRESS, offset(MESH, "normals")).address();
                uvs = raw.get(ValueLayout.ADDRESS, offset(MESH, "uvs")).address();
                colours = raw.get(ValueLayout.ADDRESS, offset(MESH, "colors")).address();
                indices = raw.get(ValueLayout.ADDRESS, offset(MESH, "indices")).address();
                vertexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH, "vertex_count"));
                indexCount = raw.get(ValueLayout.JAVA_INT, offset(MESH, "index_count"));
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
            if (indexCount == 0 || positions == 0) return null;
            return new Mesh(scene, positions, normals, uvs, colours, indices, vertexCount, indexCount);
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

    /**
     * An open document. Close it when done, or use it in a try-with-resources block --
     * everything it hands back borrows from it.
     */
    public static final class Scene implements AutoCloseable {
        private MemorySegment handle;
        private final String label;
        private final String path;
        private final String schemaPath;
        private final Convention convention;

        private Scene(MemorySegment handle, String label, String path, String schemaPath, Convention convention) {
            this.handle = handle;
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
        private MemorySegment handle() {
            if (handle == null) throw new CadaclysmException(label + ": the scene is closed");
            return handle;
        }

        /** Give the scene back. Idempotent. Every borrowed {@link Mesh} and {@link Polylines}
         *  still held is reading freed memory afterwards. */
        @Override
        public void close() {
            if (handle == null) return;
            MemorySegment h = handle;
            handle = null;
            try {
                CLOSE.invokeExact(h);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
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

        /** What this file held that the reader could not build. */
        public List<String> diagnostics() {
            int count = invokeIntOf(DIAGNOSTIC_COUNT, handle());
            List<String> found = new ArrayList<>(count);
            for (int i = 0; i < count; i++) found.add(string(invokeStringAt(DIAGNOSTIC, handle(), i)));
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
