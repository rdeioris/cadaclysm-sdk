// The cadaclysm C ABI, and nothing else: this file is the whole binding.
//
// Through the Foreign Function and Memory API, declared by hand from the published header.
// No JNI, no generated bindings, no third-party interop library — if this draws your part,
// so will your engine.
//
// FFM is final since JDK 22 (JEP 454), which is what this file is written against: it
// needs JDK 22 or later and no flags. The 20 and 21 previews spelt a handful of these
// calls differently (Arena.openConfined, SegmentScope, getUtf8String, padding in bits) and
// are not supported.
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SegmentAllocator;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;

/** An open document. Close it when done; everything read out of it is copied first. */
public final class Cad implements AutoCloseable {

    // The coordinate space to open a file into -- the header's CadaclysmConvention, as
    // plain ints because that is what the ABI takes and because FILE_UNITS and UV_WORLD
    // ride in the same word. The library converts on the way out, so nothing here rotates
    // anything: a caller names the space it draws in and reads geometry already in it.

    /** The file's own axes and its own units. */
    public static final int NATIVE = 0;
    /** Z up, left-handed, centimetres. */
    public static final int UNREAL = 1;
    /** Y up, left-handed, metres. */
    public static final int UNITY = 2;
    /** Y up, right-handed, metres -- glTF, three.js, Bevy, wgpu. */
    public static final int Y_UP = 3;
    /** Z up, right-handed, metres. {@link #NATIVE}'s axes at Blender's unit, which is the
     *  only difference between the two. */
    public static final int BLENDER = 4;

    /** OR into a convention: keep the preset's axes but the file's own units. Bit 8, so it
     *  cannot collide with a sixth preset. */
    public static final int FILE_UNITS = 0x100;

    /**
     * OR into a convention: ask for texture coordinates at world scale, which fills
     * {@link Mesh#uvs()}.
     *
     * <p>Off by default in the library and unused by this viewer, which draws no textures
     * -- it is here because the struct has the field and a caller reaching for it needs the
     * bit that fills it. What it turns on is <em>generating</em> coordinates from a
     * surface's own parameters; a format that stores them is not gated by it.
     */
    public static final int UV_WORLD = 0x200;

    // The structs the header declares, laid out the way C lays them out.
    private static final MemoryLayout BOUNDS = MemoryLayout.structLayout(
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("min"),
            MemoryLayout.sequenceLayout(3, ValueLayout.JAVA_FLOAT).withName("max"));

    // Field order must match the header's CadaclysmMesh exactly; `mesh` below reads the
    // struct by these names, so a field missing or misplaced here reads the wrong word
    // there. `uvs` and `colors` sit between `normals` and `indices`, which is where the
    // header puts them; a copy that leaves one out still compiles and still runs, and reads
    // a null pointer as `indices` and the halves of the real indices pointer as the counts.
    //
    // cadaclysm-capi/tests/bindings.rs pins this against the header, by field order and by
    // whether each field is a pointer -- ADDRESS against JAVA_INT. It does not pin the
    // exact layout, so JAVA_INT becoming JAVA_LONG is still yours to get right.
    private static final MemoryLayout MESH = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("positions"),
            ValueLayout.ADDRESS.withName("normals"),
            ValueLayout.ADDRESS.withName("uvs"),
            ValueLayout.ADDRESS.withName("colors"),
            ValueLayout.ADDRESS.withName("indices"),
            ValueLayout.JAVA_INT.withName("vertex_count"),
            ValueLayout.JAVA_INT.withName("index_count"));

    /**
     * {@code CadaclysmOpenOptions}. {@code size} is the contract for {@code open}: the
     * library reads only the fields that fit inside it and defaults the rest. But
     * {@code open} here lets {@code cadaclysm_open_options_init} fill the defaults, and
     * init writes the <em>whole</em> struct the library was built with, so this layout
     * must be at least as long as the header's or init corrupts the heap past it --
     * intermittently, which is how a missing {@code pick}/{@code pick_user} pair showed
     * up as STATUS_HEAP_CORRUPTION on one smoke run in three. It may never reorder.
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
            // library's own choice among a file's candidates.
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
    // struct back up to 8-byte alignment. Verified against sizeof(CadaclysmAttribute) from
    // the published header rather than trusted -- see Step 7 of the task brief. Padding is
    // counted in bytes, as the final API counts it; the preview counted bits.
    private static final MemoryLayout ATTRIBUTE = MemoryLayout.structLayout(
            ValueLayout.ADDRESS.withName("name"),
            ValueLayout.JAVA_INT.withName("kind"),
            MemoryLayout.paddingLayout(4),
            ValueLayout.ADDRESS.withName("text"),
            ValueLayout.JAVA_LONG.withName("integer"),
            ValueLayout.JAVA_DOUBLE.withName("real"),
            ValueLayout.JAVA_BOOLEAN.withName("boolean"),
            MemoryLayout.paddingLayout(7));

    // Never closed: the library stays loaded for the life of the process, and every
    // segment the library hands back is read under this arena before it is copied out.
    private static final Arena ARENA = Arena.ofShared();

    private static final MethodHandle OPEN_OPTIONS_INIT;
    private static final MethodHandle LAST_ERROR, VERSION, LICENSE_SET, LICENSE_INFO, BUILD_DATE,
            OPEN, CLOSE, PART_COUNT, SCHEMA,
            METRES_PER_UNIT, BOUNDS_OF, TRANSFORM, COLOR, CAN_MESH, MESH_OF, EDGES, CURVES, ISOCURVES,
            REALIZE_ALL, PART_PARENT, PART_DEPTH, PART_INSTANCE_OF, PART_ATTR_COUNT, PART_NAME,
            PART_KIND, PART_ID, PART_GENERATOR, PART_ATTRIBUTE;

    static {
        SymbolLookup lib = SymbolLookup.libraryLookup(library(), ARENA);
        Linker linker = Linker.nativeLinker();
        LAST_ERROR = bind(linker, lib, "cadaclysm_last_error", FunctionDescriptor.of(ValueLayout.ADDRESS));
        VERSION = bind(linker, lib, "cadaclysm_version", FunctionDescriptor.of(ValueLayout.ADDRESS));
        LICENSE_SET = bind(linker, lib, "cadaclysm_license_set",
                FunctionDescriptor.of(ValueLayout.JAVA_BOOLEAN, ValueLayout.ADDRESS));
        LICENSE_INFO = bind(linker, lib, "cadaclysm_license_info", FunctionDescriptor.of(ValueLayout.ADDRESS));
        BUILD_DATE = bind(linker, lib, "cadaclysm_build_date", FunctionDescriptor.of(ValueLayout.ADDRESS));
        OPEN = bind(linker, lib, "cadaclysm_open",
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.ADDRESS));
        OPEN_OPTIONS_INIT = bind(linker, lib, "cadaclysm_open_options_init",
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS));
        CLOSE = bind(linker, lib, "cadaclysm_close", FunctionDescriptor.ofVoid(ValueLayout.ADDRESS));
        PART_COUNT = bind(linker, lib, "cadaclysm_node_count",
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS));
        SCHEMA = bind(linker, lib, "cadaclysm_schema",
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS));
        METRES_PER_UNIT = bind(linker, lib, "cadaclysm_metres_per_unit",
                FunctionDescriptor.of(ValueLayout.JAVA_DOUBLE, ValueLayout.ADDRESS));
        BOUNDS_OF = bind(linker, lib, "cadaclysm_bounds",
                FunctionDescriptor.of(BOUNDS, ValueLayout.ADDRESS));
        TRANSFORM = bind(linker, lib, "cadaclysm_node_transform",
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS, ValueLayout.JAVA_INT, ValueLayout.ADDRESS));
        COLOR = bind(linker, lib, "cadaclysm_node_color",
                FunctionDescriptor.of(ValueLayout.JAVA_BOOLEAN, ValueLayout.ADDRESS,
                        ValueLayout.JAVA_INT, ValueLayout.ADDRESS));
        CAN_MESH = bind(linker, lib, "cadaclysm_node_can_mesh",
                FunctionDescriptor.of(ValueLayout.JAVA_BOOLEAN, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        MESH_OF = bind(linker, lib, "cadaclysm_node_mesh",
                FunctionDescriptor.of(MESH, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        EDGES = bind(linker, lib, "cadaclysm_node_edges",
                FunctionDescriptor.of(POLYLINES, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        CURVES = bind(linker, lib, "cadaclysm_node_curves",
                FunctionDescriptor.of(POLYLINES, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        ISOCURVES = bind(linker, lib, "cadaclysm_node_isocurves",
                FunctionDescriptor.of(POLYLINES, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        REALIZE_ALL = bind(linker, lib, "cadaclysm_realize_all",
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS));
        // uint32_t f(const CadaclysmScene*, uint32_t)
        PART_PARENT = bind(linker, lib, "cadaclysm_node_parent",
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        PART_DEPTH = bind(linker, lib, "cadaclysm_node_depth",
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        PART_INSTANCE_OF = bind(linker, lib, "cadaclysm_node_instance_of",
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        PART_ATTR_COUNT = bind(linker, lib, "cadaclysm_node_attribute_count",
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        // const char* f(const CadaclysmScene*, uint32_t)
        PART_NAME = bind(linker, lib, "cadaclysm_node_name",
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        PART_KIND = bind(linker, lib, "cadaclysm_node_kind",
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        PART_ID = bind(linker, lib, "cadaclysm_node_id",
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        PART_GENERATOR = bind(linker, lib, "cadaclysm_node_generator",
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_INT));
        // CadaclysmAttribute f(const CadaclysmScene*, uint32_t, uint32_t) -- returns a struct
        // by value, so the descriptor names its layout, exactly as MESH and POLYLINES already
        // do.
        PART_ATTRIBUTE = bind(linker, lib, "cadaclysm_node_attribute",
                FunctionDescriptor.of(ATTRIBUTE, ValueLayout.ADDRESS, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT));
    }

    /** The shared library: CADACLYSM_LIBRARY (the file or its directory), else a `lib/`
     *  or `target/release/` in any ancestor of the working directory -- the SDK checkout's
     *  layout and this repository's, respectively. */
    private static Path library() {
        String name = System.getProperty("os.name").toLowerCase();
        String file = name.contains("win") ? "cadaclysm_capi.dll"
                : name.contains("mac") ? "libcadaclysm_capi.dylib" : "libcadaclysm_capi.so";
        String env = System.getenv("CADACLYSM_LIBRARY");
        if (env != null && !env.isEmpty()) {
            Path p = Path.of(env);
            return Files.isDirectory(p) ? p.resolve(file) : p;
        }
        Path here = Path.of("").toAbsolutePath();
        for (Path at = here; at != null; at = at.getParent()) {
            Path candidate = at.resolve("lib").resolve(file);
            if (Files.exists(candidate)) return candidate;
        }
        for (Path at = here; at != null; at = at.getParent()) {
            Path candidate = at.resolve("target").resolve("release").resolve(file);
            if (Files.exists(candidate)) return candidate;
        }
        // Not found by walking up: let the loader try its own search, and say so if it fails.
        return Path.of(file);
    }

    private static MethodHandle bind(Linker linker, SymbolLookup lib, String name, FunctionDescriptor fd) {
        return linker.downcallHandle(
                lib.find(name).orElseThrow(() -> new UnsatisfiedLinkError(name)), fd);
    }

    /** A named field's byte offset in one of the struct layouts above. */
    private static long offset(MemoryLayout struct, String field) {
        return struct.byteOffset(MemoryLayout.PathElement.groupElement(field));
    }

    private final MemorySegment handle;

    private Cad(MemorySegment handle) {
        this.handle = handle;
    }

    /** A C string at an address the library owns. */
    private static String string(MemorySegment address) {
        if (address.address() == 0) return "";
        // A pointer comes back as a zero-length segment; reinterpreting it to an unbounded
        // one lets getString read to the terminator the library wrote.
        return address.reinterpret(Long.MAX_VALUE).getString(0);
    }

    public static String lastError() {
        try {
            return string((MemorySegment) LAST_ERROR.invokeExact());
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** The version of the library actually loaded, which is the one worth reporting. */
    public static String version() {
        try {
            return string((MemorySegment) VERSION.invokeExact());
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** Load a license: the certificate text, or the path of a file holding it. Without this
     *  the library looks in CADACLYSM_LICENSE, then for cadaclysm.lic beside the executable
     *  and in the working directory. False, with the reason in lastError(), when the text
     *  does not verify; the previous license stays. */
    public static boolean licenseSet(String textOrPath) {
        try (Arena arena = Arena.ofConfined()) {
            return (boolean) LICENSE_SET.invokeExact(arena.allocateFrom(textOrPath));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** One line about the license in use, or null (see lastError()) when none resolves. */
    public static String licenseInfo() {
        try {
            MemorySegment p = (MemorySegment) LICENSE_INFO.invokeExact();
            return p.address() == 0 ? null : string(p);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** When the loaded library was built, YYYY-MM-DD. */
    public static String buildDate() {
        try {
            return string((MemorySegment) BUILD_DATE.invokeExact());
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * Open a file. {@code schema} is the EXPRESS schema STEP and IFC need and every other
     * format ignores; null for none. Returns null where the library refused it.
     *
     * <p>{@code convention} is the space to read the file into: one of {@link #NATIVE},
     * {@link #UNREAL}, {@link #UNITY}, {@link #Y_UP} or {@link #BLENDER}, optionally OR'd
     * with {@link #FILE_UNITS} and {@link #UV_WORLD}. The library does the converting, so
     * every array read out of the document is already in it and there is nothing left for
     * the caller to rotate or scale. An unrecognised value is refused rather than read as
     * {@code NATIVE}, so it comes back null with the reason at {@link #lastError()}.
     */
    public static Cad open(String path, String schema, int convention) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment p = arena.allocateFrom(path);
            MemorySegment s = schema == null ? MemorySegment.NULL : arena.allocateFrom(schema);
            MemorySegment options = arena.allocate(OPEN_OPTIONS);
            OPEN_OPTIONS_INIT.invokeExact(options);
            options.set(ValueLayout.JAVA_INT, offset(OPEN_OPTIONS, "convention"),
                    convention & ~(FILE_UNITS | UV_WORLD));
            options.set(ValueLayout.JAVA_BOOLEAN, offset(OPEN_OPTIONS, "file_units"),
                    (convention & FILE_UNITS) != 0);
            options.set(ValueLayout.JAVA_INT, offset(OPEN_OPTIONS, "uvs"),
                    (convention & UV_WORLD) != 0 ? 1 : 0);
            if (schema != null) {
                MemorySegment list = arena.allocate(ValueLayout.ADDRESS);
                list.set(ValueLayout.ADDRESS, 0, s);
                options.set(ValueLayout.ADDRESS, offset(OPEN_OPTIONS, "schemas"), list);
                options.set(ValueLayout.JAVA_LONG, offset(OPEN_OPTIONS, "schema_count"), 1L);
            }
            MemorySegment handle = (MemorySegment) OPEN.invokeExact(p, options);
            return handle.address() == 0 ? null : new Cad(handle);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * A packed convention from a name a user typed, as {@code Viewer} takes it: {@code
     * "unreal"}, or {@code "unreal+file-units"} to keep the file's own units under the
     * preset's axes.
     *
     * <p>Throws rather than falling back to {@link #NATIVE}: an unrecognised name silently
     * read as the file's own space is the one outcome that looks like success and draws the
     * wrong thing.
     */
    public static int convention(String text) {
        String[] parts = text.trim().toLowerCase().split("\\+");
        int packed = switch (parts.length == 0 ? "" : parts[0]) {
            case "native" -> NATIVE;
            case "unreal" -> UNREAL;
            case "unity" -> UNITY;
            case "y-up" -> Y_UP;
            case "blender" -> BLENDER;
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

    @Override
    public void close() {
        try {
            CLOSE.invokeExact(handle);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public int partCount() {
        try {
            return (int) PART_COUNT.invokeExact(handle);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public String schema() {
        try {
            return string((MemorySegment) SCHEMA.invokeExact(handle));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public double metresPerUnit() {
        try {
            return (double) METRES_PER_UNIT.invokeExact(handle);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public boolean canMesh(int part) {
        try {
            return (boolean) CAN_MESH.invokeExact(handle, part);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * Tessellate every part up front, across threads, and say how many were built.
     *
     * <p>Asking part by part instead meshes them one at a time on one core, because the
     * reader is lazy and each mesh call realizes only the part it is asked about. On a large
     * STEP file that is the difference between a demo and a wait.
     */
    public int realizeAll() {
        try {
            return (int) REALIZE_ALL.invokeExact(handle);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** The scene's box: six floats, min then max. */
    public float[] bounds() {
        try (Arena arena = Arena.ofConfined()) {
            SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(BOUNDS));
            MemorySegment b = (MemorySegment) BOUNDS_OF.invokeExact(allocator, handle);
            return b.toArray(ValueLayout.JAVA_FLOAT);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** Where a part's own frame sits in the world, column-major as OpenGL writes it. */
    public double[] transform(int part) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment out = arena.allocate(ValueLayout.JAVA_DOUBLE, 16);
            TRANSFORM.invokeExact(handle, part, out);
            return out.toArray(ValueLayout.JAVA_DOUBLE);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * The colour the file gave a part, or null where it gave none. A part with no colour is
     * the caller's to decide about — see Viewer.UNSTYLED.
     */
    public float[] color(int part) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment rgba = arena.allocate(ValueLayout.JAVA_FLOAT, 4);
            boolean has = (boolean) COLOR.invokeExact(handle, part, rgba);
            return has ? rgba.toArray(ValueLayout.JAVA_FLOAT) : null;
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * A part's triangles, copied out, in the part's own frame.
     *
     * <p>{@code uvs} is two floats a vertex where the other two arrays are three, and null
     * for a part whose reader produced none -- which is most of them unless the scene was
     * opened with {@link #UV_WORLD}.
     */
    public record Mesh(float[] positions, float[] normals, float[] uvs, int[] indices) {}

    public Mesh mesh(int part) {
        try (Arena arena = Arena.ofConfined()) {
            SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(MESH));
            MemorySegment m = (MemorySegment) MESH_OF.invokeExact(allocator, handle, part);
            // Read by the layout's own field names, not by hand-written byte offsets: when
            // `colors` joined MESH the offsets written here for four pointers went on reading
            // `indices` out of `colors` and the counts out of `indices`, which the layout
            // guard in bindings.rs could not see. Named offsets move with the layout.
            long positions = m.get(ValueLayout.ADDRESS, offset(MESH, "positions")).address();
            long normals = m.get(ValueLayout.ADDRESS, offset(MESH, "normals")).address();
            long uvs = m.get(ValueLayout.ADDRESS, offset(MESH, "uvs")).address();
            long indices = m.get(ValueLayout.ADDRESS, offset(MESH, "indices")).address();
            int vertexCount = m.get(ValueLayout.JAVA_INT, offset(MESH, "vertex_count"));
            int indexCount = m.get(ValueLayout.JAVA_INT, offset(MESH, "index_count"));
            if (indexCount == 0 || positions == 0) return null;
            return new Mesh(
                    floats(positions, vertexCount * 3L),
                    normals == 0 ? null : floats(normals, vertexCount * 3L),
                    uvs == 0 ? null : floats(uvs, vertexCount * 2L),
                    ints(indices, indexCount));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** A part's feature edges, or its free curves, as runs of points. */
    public record Polylines(float[] positions, int[] counts) {}

    public Polylines polylines(int part, boolean edges) {
        try (Arena arena = Arena.ofConfined()) {
            SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(POLYLINES));
            MethodHandle call = edges ? EDGES : CURVES;
            MemorySegment p = (MemorySegment) call.invokeExact(allocator, handle, part);
            return polylines(p);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** A CadaclysmPolylines the library just returned, copied out by field name. */
    private static Polylines polylines(MemorySegment p) {
        long positions = p.get(ValueLayout.ADDRESS, offset(POLYLINES, "positions")).address();
        long counts = p.get(ValueLayout.ADDRESS, offset(POLYLINES, "counts")).address();
        int polylineCount = p.get(ValueLayout.JAVA_INT, offset(POLYLINES, "polyline_count"));
        int vertexCount = p.get(ValueLayout.JAVA_INT, offset(POLYLINES, "vertex_count"));
        if (vertexCount == 0 || positions == 0) return null;
        return new Polylines(floats(positions, vertexCount * 3L), ints(counts, polylineCount));
    }

    /** A part's isocurves — the interior isoparametric lines across a curved face,
     * which a flat face draws as its own outline instead. */
    public Polylines isocurves(int part) {
        try (Arena arena = Arena.ofConfined()) {
            SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(POLYLINES));
            MemorySegment p = (MemorySegment) ISOCURVES.invokeExact(allocator, handle, part);
            return polylines(p);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * The part containing this one, or -1 for a root.
     */
    public int parent(int part) {
        try {
            int p = (int) PART_PARENT.invokeExact(handle, part);
            return p == -1 ? -1 : p;   // CADACLYSM_NONE is UINT32_MAX, which is -1 as an int
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** How far down the tree a part sits, a root being zero. For indenting. */
    public int depth(int part) {
        try {
            return (int) PART_DEPTH.invokeExact(handle, part);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public String name(int part) {
        try {
            return string((MemorySegment) PART_NAME.invokeExact(handle, part));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public String kind(int part) {
        try {
            return string((MemorySegment) PART_KIND.invokeExact(handle, part));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public String id(int part) {
        try {
            return string((MemorySegment) PART_ID.invokeExact(handle, part));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /**
     * What a part's geometry was before it was triangles — "brep", "mesh", "csg". Empty for a
     * part that draws nothing, there being no geometry to have come from anything.
     */
    public String generator(int part) {
        try {
            return string((MemorySegment) PART_GENERATOR.invokeExact(handle, part));
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** The part whose geometry this one is a placement of, or -1 for none. */
    public int instanceOf(int part) {
        try {
            int p = (int) PART_INSTANCE_OF.invokeExact(handle, part);
            return p == -1 ? -1 : p;   // CADACLYSM_NONE is UINT32_MAX, which is -1 as an int
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    private int attributeCount(int part) {
        try {
            return (int) PART_ATTR_COUNT.invokeExact(handle, part);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    /** One thing the file said about a part, rendered as text. */
    public record Attribute(String name, String value) {}

    public Attribute[] attributes(int part) {
        int count = attributeCount(part);
        Attribute[] out = new Attribute[count];
        int n = 0;
        try (Arena arena = Arena.ofConfined()) {
            for (int i = 0; i < count; i++) {
                SegmentAllocator allocator = SegmentAllocator.prefixAllocator(arena.allocate(ATTRIBUTE));
                MemorySegment a = (MemorySegment) PART_ATTRIBUTE.invokeExact(allocator, handle, part, i);
                MemorySegment name = a.get(ValueLayout.ADDRESS, offset(ATTRIBUTE, "name"));
                if (name.address() == 0) continue;
                int kind = a.get(ValueLayout.JAVA_INT, offset(ATTRIBUTE, "kind"));
                // The kinds, in the header's declaration order: none, text, integer, real,
                // boolean, list, reference. List and reference both arrive already rendered
                // into `text`, same as text itself.
                String value = switch (kind) {
                    case 2 -> Long.toString(a.get(ValueLayout.JAVA_LONG, offset(ATTRIBUTE, "integer")));
                    case 3 -> formatReal(a.get(ValueLayout.JAVA_DOUBLE, offset(ATTRIBUTE, "real")));
                    case 4 -> Boolean.toString(a.get(ValueLayout.JAVA_BOOLEAN, offset(ATTRIBUTE, "boolean")));
                    default -> string(a.get(ValueLayout.ADDRESS, offset(ATTRIBUTE, "text")));
                };
                out[n++] = new Attribute(string(name), value);
            }
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        return n == count ? out : java.util.Arrays.copyOf(out, n);
    }

    /**
     * A real the same way cadaclysm's own {@code Display for Value} renders it in Rust: the
     * shortest decimal that round-trips, never forcing a trailing {@code .0}, and never in
     * exponent notation for any magnitude a CAD property plausibly holds.
     *
     * {@code Double.toString} already picks the shortest round-tripping digits, but always
     * carries a decimal point (so {@code 1.0} stays {@code "1.0"}, never {@code "1"}) and
     * switches to scientific notation outside {@code 1e-3..1e7} (so a IFC precision like
     * {@code 1e-5} — a real value this project's own sample files carry — would print as
     * {@code "1.0E-5"} where Rust prints {@code "0.00001"}). Routing the same digits through
     * {@link BigDecimal#toPlainString()} expands any exponent back to fixed notation without
     * adding or losing precision, and {@link BigDecimal#stripTrailingZeros()} is what removes
     * the forced {@code .0}.
     */
    private static String formatReal(double value) {
        if (Double.isNaN(value)) {
            return "NaN";
        }
        if (Double.isInfinite(value)) {
            return value > 0 ? "inf" : "-inf";
        }
        if (value == 0.0) {
            // stripTrailingZeros() on zero is a documented trap (pre-JDK 8u25 it could hand
            // back "0E-1"), and zero's sign is otherwise lost going through BigDecimal at all.
            return (1 / value < 0) ? "-0" : "0";
        }
        return new BigDecimal(Double.toString(value)).stripTrailingZeros().toPlainString();
    }

    // The library's own arrays, copied out. ofAddress gives a zero-length segment; the
    // reinterpret to the array's byte size is what lets toArray read it.
    private static float[] floats(long address, long count) {
        return MemorySegment.ofAddress(address).reinterpret(count * Float.BYTES)
                .toArray(ValueLayout.JAVA_FLOAT);
    }

    private static int[] ints(long address, long count) {
        return MemorySegment.ofAddress(address).reinterpret(count * Integer.BYTES)
                .toArray(ValueLayout.JAVA_INT);
    }
}
