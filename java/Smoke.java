// Open one file through the Java binding and check what comes back, then build a part
// through the kernel binding, write it as STEP and read it back. The exit code is the
// verdict: the release pipeline runs this against every library it ships.
import java.io.IOException;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

// "try": a smoke builds things inside try-with-resources only to prove the call succeeds
// or is refused, and never touches them after; and it closes the read-back STEP scene by
// hand, early, to check a solid made from it (Solid.fromNode) outlives it. Both are the
// point of the check, so javac's lint on them is off here and nowhere else.
@SuppressWarnings("try")
public final class Smoke {
    public static void main(String[] args) {
        String path = args.length > 0 ? args[0] : "samples/cube.scad";
        try {
            run(path, args.length > 1 ? args[1] : null);
            kernel(args.length > 1 ? args[1] : null);
        } catch (Cad.CadaclysmException | Blacksmith.BuildException e) {
            fail(e.getMessage());
        } catch (IOException e) {
            fail(e.toString());
        }
    }

    private static void run(String path, String license) throws IOException {
        if (license != null) Cad.license(license);
        System.out.println("cadaclysm " + Cad.version() + " built " + Cad.buildDate());
        System.out.println("license: " + Cad.licenseInfo());

        try (Cad.Scene scene = Cad.open(path)) {
            Cad.Bounds bounds = scene.bounds();
            System.out.printf("bounds min=(%s,%s,%s) max=(%s,%s,%s)%n",
                    bounds.min()[0], bounds.min()[1], bounds.min()[2],
                    bounds.max()[0], bounds.max()[1], bounds.max()[2]);

            int triangles = 0;
            for (Cad.Node node : scene.walk()) {
                if (!node.canMesh()) continue;
                Cad.Mesh mesh = node.mesh();
                if (mesh != null) triangles += mesh.triangleCount();
            }
            System.out.println("triangles=" + triangles);

            // All six bounds values, not just three: a bug that only flips one axis still
            // passes a partial check, so every component of both corners is compared.
            boolean cube = bounds.min()[0] == 0 && bounds.min()[1] == 0 && bounds.min()[2] == 0
                    && bounds.max()[0] == 20 && bounds.max()[1] == 20 && bounds.max()[2] == 20;
            if (path.endsWith("cube.scad") && (!cube || triangles != 12)) {
                fail("the cube did not come back as a 20-unit cube of 12 triangles");
            }

            // The reader's own extras: a query, the diagnostics, an in-memory open of the same
            // bytes, and a round trip through save_mesh. "class == solid" is the OpenSCAD
            // reader's own node.kind() for cube.scad, not "mesh".
            List<Cad.Node> matched = scene.query("class == solid");
            System.out.println("query: " + matched.size() + " node(s)");
            System.out.println("diagnostics: " + scene.diagnostics().size());

            boolean iges = Cad.formats().stream().anyMatch(f -> f.name().equals("IGES") && f.extensions().equals(List.of("iges", "igs")));
            if (!iges) fail("formats() lacks IGES iges;igs");
            if (Cad.meshFormats().stream().noneMatch(f -> f.name().equals("stl") && f.label().equals("STL (binary)"))) fail("mesh format label is not the library's");
            System.out.println("geometry diagnostics: " + scene.geometryDiagnostics().size());

            // Kinematics: a file with no mechanism carries no links or joints; mechanism.stp,
            // beside whatever sample this smoke was given, carries the fixed two-link
            // one-joint mechanism.
            if (path.endsWith("cube.scad") && (!scene.links().isEmpty() || !scene.joints().isEmpty())) fail("the cube scene has links or joints");
            Path mechanismPath = Path.of(path).toAbsolutePath().getParent().resolve("mechanism.stp");
            try (Cad.Scene mechanism = Cad.open(mechanismPath.toString())) {
                List<Cad.Link> links = mechanism.links();
                if (links.size() != 2 || !links.get(0).name().equals("base") || !links.get(1).name().equals("arm"))
                    fail("mechanism links are not [base, arm]");
                for (Cad.Link link : links) {
                    List<Cad.Node> nodes = link.nodes();
                    if (nodes.size() != 1 || !nodes.get(0).name().equals(link.name()))
                        fail("link " + link.name() + " does not name exactly one node of its own name");
                }
                List<Cad.Joint> joints = mechanism.joints();
                if (joints.size() != 1 || !joints.get(0).name().equals("hinge"))
                    fail("mechanism does not carry exactly one joint named hinge");
                Cad.Joint joint = joints.get(0);
                Cad.Link start = joint.start(), end = joint.end();
                // The file's order, (arm, base): a swap into (parent, child) would fail here.
                if (!start.name().equals("arm") || start.index() != 1 || !end.name().equals("base") || end.index() != 0)
                    fail("joint hinge reads start=" + start.name() + "#" + start.index() + " end=" + end.name() + "#" + end.index());
                System.out.println("kinematics: links " + links.size() + ", joints " + joints.size()
                        + ", hinge " + start.name() + "->" + end.name());
            }
            scene.forgetMeshes();
            long rebuiltTriangles = 0;
            for (Cad.Node n : scene.walk()) { Cad.Mesh m = n.canMesh() ? n.mesh() : null; if (m != null) rebuiltTriangles += m.triangleCount(); }
            if (rebuiltTriangles != triangles) fail("forgetMeshes did not rebuild");

            if (Cad.lodLevels() != 3) fail("lodLevels is not 3");
            Cad.Node first = null;
            for (Cad.Node n : scene.walk()) if (n.canMesh()) { first = n; break; }
            if (first.meshLod(0).triangleCount() != first.mesh().triangleCount()) fail("LOD 0 is not the mesh");
            if (first.lodError(0) != 0f || first.meshLod(4) != null) fail("LOD errors or levels are off");
            if (path.endsWith("cube.scad") && (first.meshLod(1).triangleCount() != 3 || first.edgeBeziers().count() != 12 || first.edgeBeziers().points().remaining() != 12 * 12)) fail("the cube's LOD 1 or Béziers are off");

            // f64 twins: mesh64, beziers64 and bounds64 mirror their f32 twins, narrowed
            // exactly, on this small-coordinate cube -- see the far-from-origin note in the
            // task report for what this comparison cannot see.
            Cad.Mesh mesh32 = first.mesh();
            Cad.Mesh64 mesh64 = first.mesh64();
            if (mesh64 == null || mesh64.vertexCount() != mesh32.vertexCount() || mesh64.indexCount() != mesh32.indexCount())
                fail("mesh64's vertex/index counts do not equal mesh's");
            double[] positions64 = mesh64.copy().positions();
            float[] positions32 = mesh32.copy().positions();
            if (positions32.length >= 3 &&
                    ((float) positions64[0] != positions32[0] || (float) positions64[1] != positions32[1] || (float) positions64[2] != positions32[2]))
                fail("mesh64's first position narrowed to float does not equal mesh's first position");
            Cad.Beziers edgeBeziers32 = first.edgeBeziers();
            Cad.Beziers64 edgeBeziers64 = first.edgeBeziers64();
            if (edgeBeziers64.count() != edgeBeziers32.count() || edgeBeziers64.points().remaining() != edgeBeziers32.points().remaining())
                fail("edgeBeziers64's count/length does not equal edgeBeziers's");
            if (edgeBeziers32.points().remaining() >= 3 && (float) edgeBeziers64.copy().points()[0] != edgeBeziers32.copy().points()[0])
                fail("edgeBeziers64's first point narrowed does not equal edgeBeziers's");
            if (first.curveBeziers64().count() != first.curveBeziers().count()) fail("curveBeziers64's count does not equal curveBeziers's");
            if (first.isocurveBeziers64().count() != first.isocurveBeziers().count()) fail("isocurveBeziers64's count does not equal isocurveBeziers's");
            Cad.Bounds64 nodeBounds64 = first.bounds64();
            Cad.Bounds nodeBounds32 = first.bounds();
            if ((float) nodeBounds64.max()[0] != nodeBounds32.max()[0] || (float) nodeBounds64.max()[1] != nodeBounds32.max()[1] || (float) nodeBounds64.max()[2] != nodeBounds32.max()[2])
                fail("bounds64's max does not equal bounds's max widened");
            Cad.Bounds64 sceneBounds64 = scene.bounds64();
            if ((float) sceneBounds64.max()[0] != bounds.max()[0] || (float) sceneBounds64.max()[1] != bounds.max()[1] || (float) sceneBounds64.max()[2] != bounds.max()[2])
                fail("scene bounds64's max does not equal bounds's max widened");
            System.out.printf("reader f64 twins: mesh64 %d triangles, edgeBeziers64 %d, bounds64 max (%s,%s,%s)%n",
                    mesh64.triangleCount(), edgeBeziers64.count(), sceneBounds64.max()[0], sceneBounds64.max()[1], sceneBounds64.max()[2]);

            Cad.Collision fit = first.collision(0);
            if (fit == null || fit.error() != 0 || fit.frame().length != 16 || fit.hullVertexCount() != 8) fail("the collision fit is off");
            if (first.collisionHull(0).vertexCount() != 8 || first.collisionHull(0).indices().remaining() != 36) fail("the collision hull is off");

            Cad.Mesh full = first.mesh();
            try (Cad.Meshlets meshlets = Cad.Meshlets.build(full.copy().positions(), full.copy().normals(), full.copy().indices(), 124, 64, 0)) {
                if (meshlets.count() < 1) fail("no meshlets");
                Cad.Meshlet one = meshlets.meshlet(0);
                if (one.positions().length != one.vertexCount() * 3 || one.indices().length != one.triangleCount() * 3 || one.level() != 0) fail("meshlet 0 is off");
                if (path.endsWith("cube.scad") && (meshlets.count() != 1 || one.triangleCount() != 12 || one.vertexCount() != 36)) fail("the cube's meshlets are off");
            }
            try { Cad.Meshlets.build(full.copy().positions(), null, full.copy().indices(), 0, 64, 0); fail("a zero budget was accepted"); }
            catch (Cad.CadaclysmException expected) { }

            long est = first.triangleEstimate();
            if (est <= 0 && est != -1) fail("triangle estimate is neither a count nor -1");
            if (path.endsWith("cube.scad")) {
                if (est != 12 || first.surfaceEdges().polylineCount() != 0 || first.surfaceProxyMesh(4) != null) fail("the cube has no surface products");
                if (first.surfacePick(new double[] {10, 10, 100}, new double[] {10, 10, -100}) != null || !first.boundsPlaced(null).isEmpty()) fail("the cube picks or bounds through surfaces");
                if (!first.boundsPlaced64(null).isEmpty()) fail("the cube's boundsPlaced64 is not empty");
                if (first.surfaceEdgeBeziers().count() != 0) fail("the cube hands exact edges to the surface path");
                if (first.edgeColours().length != 0 || first.surfaceEdgeColours().length != 0) fail("the unpainted cube has edge colours");
            }
            // Edge colours: samples/edge-colours.stp sits beside the given sample and paints
            // one edge teal (0.1, 0.6, 0.55) on the body -- everything else, edge and
            // surface-edge alike, stays unstyled.
            try (Cad.Scene edgeColoursScene = Cad.open(Path.of(path).resolveSibling("edge-colours.stp").toString())) {
                Cad.Node body = null;
                for (Cad.Node n : edgeColoursScene.walk()) if (n.edges().polylineCount() > 0) { body = n; break; }
                if (body == null) fail("edge colours: edge-colours.stp has no node with edges");
                int[] counts = { body.edges().polylineCount(), body.surfaceEdges().polylineCount() };
                float[][][] colours = { body.edgeColours(), body.surfaceEdgeColours() };
                for (int i = 0; i < 2; i++) {
                    if (colours[i].length != counts[i]) fail("edge colours: " + colours[i].length + " entries for " + counts[i] + " polylines");
                    int styledCount = 0, nullCount = 0;
                    float[] styled = null;
                    for (float[] c : colours[i]) {
                        if (c == null) nullCount++;
                        else { styledCount++; styled = c; }
                    }
                    if (styledCount != 1 || nullCount != colours[i].length - 1) fail("edge colours: " + styledCount + " styled entries, not exactly one");
                    if (Math.abs(styled[0] - 0.1f) > 1e-6 || Math.abs(styled[1] - 0.6f) > 1e-6
                            || Math.abs(styled[2] - 0.55f) > 1e-6 || Math.abs(styled[3] - 1.0f) > 1e-6)
                        fail("edge colours: the styled entry reads (" + styled[0] + "," + styled[1] + "," + styled[2] + "," + styled[3] + "), not (0.1,0.6,0.55,1.0)");
                }
                // The STEP body has surfaces to hand over, so this reads them through SURFACES,
                // the layout cadaclysm_node_surfaces returns by value. A short one is written
                // past silently -- the layout itself is pinned by tests/bindings.rs, not here.
                int faces = body.surfaces().size();
                if (faces == 0) fail("surfaces: the STEP body came back with no faces");
                System.out.println("surfaces: " + faces + " face(s)");
            }
            try (Cad.Scene fresh = Cad.open(path)) {
                Cad.Node body = null;
                for (Cad.Node n : fresh.walk()) if (n.canMesh()) { body = n; break; }
                if (body.isMeshed()) fail("a fresh scene is already meshed");
                if (fresh.realizeMeshes(false) == 0 || !body.isMeshed()) fail("realizeMeshes(false) did not build");
            }
            // A Rhino extrusion hands its exact edges to the surface path without meshing, in
            // both conventions: UNREAL goes through the decorator that maps every getter into
            // the caller's space. The fixture is the repository's, not an SDK checkout's, so
            // this runs where found.
            Path sampleRoot = Path.of(path).toAbsolutePath().getParent().getParent();
            Path extrusions = sampleRoot == null ? null : sampleRoot.resolve("crates/cadaclysm-acis/tests/fixtures/rhino/extrusion-objects.3dm");
            if (extrusions != null && Files.exists(extrusions)) {
                for (Cad.Convention convention : new Cad.Convention[] {Cad.Convention.NATIVE, Cad.Convention.UNREAL}) {
                    Cad.OpenOptions options = new Cad.OpenOptions(convention, false, false, null, false, 0.0);
                    try (Cad.Scene surfaced = Cad.open(extrusions.toString(), options)) {
                        int found = 0;
                        for (Cad.Node n : surfaced.walk()) {
                            if (!n.canMesh() || n.surfaceEdges().polylineCount() == 0) continue;
                            int exact = n.surfaceEdgeBeziers().count();
                            if (exact == 0 || n.isMeshed()) fail("an extrusion's exact edges are not free");
                            if (exact != n.edgeBeziers().count()) fail("surfaceEdgeBeziers is not edgeBeziers' segments");
                            found++;
                        }
                        if (found == 0) fail("extrusion-objects.3dm has no surfaced extrusion");
                        System.out.printf("surfaceEdgeBeziers (%s): %d extrusions, exact and unmeshed%n", convention, found);
                    }
                }
            }

            byte[] bytes = Files.readAllBytes(Path.of(path));
            Cad.Mesh borrowed;
            try (Cad.Scene again = Cad.openMemory(bytes, Path.of(path).getFileName().toString())) {
                if (again.bounds().max()[2] != bounds.max()[2]) fail("open_memory disagrees with open");
                borrowed = again.query("class == solid").get(0).mesh();
            }
            // A view borrowed from a scene since closed refuses to read, as the kernel's stale
            // views do, rather than handing out a buffer over freed memory.
            try {
                borrowed.positions();
                fail("a mesh view read a closed scene");
            } catch (Cad.CadaclysmException expected) {
                // the scene's own "closed" exception
            }
            // The format given on its own, as Python's open_memory takes it -- the name has no
            // extension to fall back on here, so the argument is what opens it.
            try (Cad.Scene typed = Cad.openMemory(bytes, "cube-bytes", "scad")) {
                if (!Arrays.equals(typed.bounds().max(), bounds.max())) fail("open_memory with an explicit format disagrees with open");
            }

            Path stl = Files.createTempFile("cadaclysm-smoke", ".stl");
            scene.roots().get(0).saveMesh(stl.toString(), "stl");
            if (Files.size(stl) < 84) fail("save_mesh wrote no triangles");

            femReader(first, path);

            // SVG: the library's own camera, no viewer. fov = 200 is a refusal it words the
            // same way as the kernel's.
            String svgText = scene.svgText();
            if (!svgText.startsWith("<svg") || !svgText.contains("<path")) fail("scene SVG text did not look like an SVG wireframe");
            Path svgPath = Files.createTempFile("cadaclysm-smoke", ".svg");
            scene.svg(svgPath.toString());
            if (Files.size(svgPath) == 0) fail("Scene.svg wrote an empty file");
            String nodeSvgText = first.svgText();
            if (!nodeSvgText.startsWith("<svg") || !nodeSvgText.contains("<path")) fail("node SVG text did not look like an SVG wireframe");
            try {
                scene.svgText(new Cad.SvgOptions(null, null, null, null, 200.0, 1000.0, 1000.0, 0.05, 0.1,
                        "#000000", 1.0, null, true, false, false, false));
                fail("scene svg: fov=200 was accepted");
            } catch (Cad.CadaclysmException expected) {
                // the library's own refusal
            }
            System.out.println("svg: scene and node text, file written, fov=200 refused");
        }
    }

    // The kernel: the plate with a hole and a pin, filleted, as STEP -- then read back.
    // Every profile and solid is closed by its try-with-resources; the unfilleted `part`
    // outlives `rounded` because `edges()` and `faceKind()` were read off it.
    private static void kernel(String license) throws IOException {
        if (license != null) Blacksmith.license(license);
        System.out.println("blacksmith " + Blacksmith.version() + " built " + Blacksmith.buildDate());
        System.out.println("license: " + Blacksmith.licenseInfo());

        try (Blacksmith.Profile hole = Blacksmith.Profile.circle(4);
             Blacksmith.Profile rect = Blacksmith.Profile.rect(80, 40);
             Blacksmith.Profile outline = rect.withHole(hole);
             Blacksmith.Solid plate = Blacksmith.Workplane.xy().extrude(outline, 6).solid();
             Blacksmith.Solid pin = Blacksmith.Workplane.fromSolid(plate)
                     .faces(Blacksmith.Selector.max(Blacksmith.Axis.Z)).onFace()
                     .cylinder(5, 10).solid();
             Blacksmith.Solid part = plate.join(pin)) {
            List<Blacksmith.Edge> corners = part.edges().stream()
                    .filter(e -> e.isLine() && Math.abs(e.direction()[2]) > 0.99)
                    .filter(e -> Arrays.stream(e.faces()).allMatch(f -> part.faceKind(f).equals("plane")))
                    .toList();
            // `released` and `scene` outlive the block below: the block's own close of
            // `rounded` is what the checks after it are about.
            Blacksmith.Solid released;
            Cad.Scene scene;
            sheetVerbs(plate);
            frames();
            hits();
            edgeCurves();
            intersections();
            solidHits();
            assemblies();
            try (Blacksmith.Solid rounded = part.fillet(corners, 1.0)) {
                released = rounded;
                int faces = rounded.faces();
                boolean watertight = rounded.isWatertight();
                System.out.println("faces=" + faces + " watertight=" + watertight);
                if (!watertight) fail("the filleted part is not watertight");
                Cad.Manifold shape = rounded.manifold();
                System.out.println("manifold: " + shape);
                if (!shape.isClosed() || shape.faces() != faces) fail("the filleted part is not a closed manifold: " + shape);
                // A plate has 6 faces, the hole adds 1 cylinder, the pin 2 (its wall and its
                // top), and each of the four corners rounded trades one edge for one face.
                if (faces != 15) fail("the filleted part has " + faces + " faces, not 15");

                // Colour: a gold plate joined with a blue pin -- the part is gold, the pin's
                // top keeps its blue.
                try (Blacksmith.Solid gold = plate.coloured(0.8, 0.6, 0.4);
                     Blacksmith.Solid blue = pin.coloured(0.2, 0.4, 1.0);
                     Blacksmith.Solid coloured = gold.join(blue)) {
                    double[] top = coloured.faceColour(coloured.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z)));
                    System.out.println("colour=" + Arrays.toString(coloured.colour()) + " pin top=" + Arrays.toString(top));
                    if (!Arrays.equals(coloured.colour(), new double[] {0.8, 0.6, 0.4})
                            || !Arrays.equals(top, new double[] {0.2, 0.4, 1.0}) || plate.colour() != null)
                        fail("the colours did not carry through the join");
                }

                // Edge and profile colour: all of a plate's edges gold, then edge 0 blue over it;
                // a profile carries its own colour too.
                try (Blacksmith.Solid goldEdges = plate.edgesColoured(0.8, 0.6, 0.4);
                     Blacksmith.Solid blueEdge = goldEdges.edgesColoured(new int[] { 0 }, 0.2, 0.4, 1.0);
                     Blacksmith.Profile goldRect = Blacksmith.Profile.rect(10, 4).coloured(0.8, 0.6, 0.4)) {
                    double[][] edgeColours = blueEdge.edgePolylineColours();
                    System.out.println("edge 0=" + Arrays.toString(blueEdge.edgeColour(0)) + " edge 1=" + Arrays.toString(blueEdge.edgeColour(1))
                            + " polylines=" + edgeColours.length + " rect=" + Arrays.toString(goldRect.colour()));
                    if (!Arrays.equals(blueEdge.edgeColour(0), new double[] { 0.2, 0.4, 1.0 }) || !Arrays.equals(blueEdge.edgeColour(1), new double[] { 0.8, 0.6, 0.4 })
                            || edgeColours.length == 0 || !Arrays.equals(goldRect.colour(), new double[] { 0.8, 0.6, 0.4 }) || plate.edgeColour(0) != null)
                        fail("edge or profile colours");
                    // An empty edges list colours no edge -- not "every edge" (which null would
                    // mean, and Java has no overload for) -- so edge 0 stays blue and edge 1 gold.
                    try (Blacksmith.Solid untouched = blueEdge.edgesColoured(new int[0], 0.1, 0.1, 0.1)) {
                        if (!Arrays.equals(untouched.edgeColour(0), new double[] { 0.2, 0.4, 1.0 })
                                || !Arrays.equals(untouched.edgeColour(1), new double[] { 0.8, 0.6, 0.4 }))
                            fail("an empty edge list should colour nothing");
                    }
                }

                // A face: the outline as a sheet, which pushed out is the plate again.
                try (Blacksmith.Solid sheet = Blacksmith.Solid.face(outline, new double[] {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1});
                     Blacksmith.Solid pushed = sheet.extrudeFaces(6)) {
                    System.out.println("face: " + sheet.faces() + " face, pushed out " + pushed.faces() + " faces");
                    if (sheet.faces() != 1 || pushed.faces() != plate.faces() || !pushed.isWatertight())
                        fail("the outline's face did not push out to the plate");
                }

                // The plate is 80 x 40 x 6 centred on the origin and the pin adds 10, so the
                // far corner sits at (40, 20, 16) -- checked on the kernel's own bounds, on
                // the STEP read back through the reader, and on toScene's scene.
                Blacksmith.Bounds own = rounded.bounds();
                if (!near(own.max(), 40, 20, 16)) fail("the kernel's own bounds are off: " + Arrays.toString(own.max()));

                // No schema at all: the kernel writes against its built-in AP203, no
                // ap203.exp needed.
                String noSchemaText = rounded.stepText();
                if (!noSchemaText.startsWith("ISO-10303-21;")) fail("stepText() with no schema did not write valid STEP");
                System.out.println("stepText() with no schema: ISO-10303-21; ok");

                // A single-line custom EXPRESS schema is text, not a path, even though it
                // holds ':' and ';' -- characters java.nio.file.Path.of() refuses on
                // Windows (InvalidPathException). schemaText must treat that as "not a
                // file" and pass the string through, so the failure below is the ABI's own
                // parse error, not a Java path exception.
                try {
                    rounded.stepText("SCHEMA x; ENTITY a; s : STRING := 'x'; END_ENTITY; END_SCHEMA;", "mm");
                    fail("a bogus single-line custom schema should have failed to parse");
                } catch (Blacksmith.BuildException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("step: schema:"))
                        fail("expected the ABI's step: schema: parse error, got: " + e.getMessage());
                    System.out.println("single-line custom schema text reached the ABI: " + e.getMessage());
                }

                Path step = Files.createTempFile("cadaclysm-smoke", ".stp");
                rounded.step(step.toString());
                try (Cad.Scene back = Cad.open(step.toString())) {
                    float[] max = back.bounds().max();
                    System.out.printf("step read back: bounds max=(%s,%s,%s)%n", max[0], max[1], max[2]);
                    if (!near(max, 40, 20, 16)) fail("the STEP did not read back as the plate with its pin");
                    // And back into the kernel: the read body's brep, shared with the scene
                    // rather than copied, as a solid that outlives the scene it came from.
                    Cad.Node body = null;
                    for (Cad.Placement p : back.placements()) {
                        try (Cad.Brep brep = p.geometry().brep()) {
                            if (brep != null) {
                                Cad.Manifold read = brep.manifold();
                                if (!read.isClosed() || read.faces() != 15) fail("the read body is not the closed manifold written: " + read);
                                body = p.geometry();
                                break;
                            }
                        }
                    }
                    if (body == null) fail("no placement of the read-back STEP has a brep");
                    try (Blacksmith.Solid imported = Blacksmith.Solid.fromNode(back, body)) {
                        back.close();
                        if (imported.faces() != faces) fail("fromNode gave " + imported.faces() + " faces, not " + faces);
                        try (Blacksmith.Solid opened = Blacksmith.Solid.open(step.toString())) {
                            if (opened.faces() != faces) fail("Solid.open gave " + opened.faces() + " faces, not " + faces);
                        }
                        System.out.println("fromNode: " + imported.faces() + " faces after the scene closed; Solid.open: the same");
                    }
                }

                femKernel(rounded, faces);
                femBrep(step, faces);

                // The same solid as SAT, written by the library itself, read back the same way.
                Path sat = Files.createTempFile("cadaclysm-smoke", ".sat");
                rounded.sat(sat.toString());
                if (!rounded.satText().startsWith("400 0 1 0")) fail("the SAT text does not open with the record version");
                try (Cad.Scene back = Cad.open(sat.toString())) {
                    float[] max = back.bounds().max();
                    System.out.printf("sat read back: bounds max=(%s,%s,%s)%n", max[0], max[1], max[2]);
                    if (!near(max, 40, 20, 16)) fail("the SAT did not read back as the plate with its pin");
                }

                // The OCCT .brep writer, and its reader.
                Path brep = Files.createTempFile("cadaclysm-smoke", ".brep");
                rounded.brep(brep.toString());
                if (!rounded.brepText().startsWith("DBRep_DrawableShape")) fail("the .brep text does not begin as one");
                try (Cad.Scene back = Cad.open(brep.toString())) {
                    float[] max = back.bounds().max();
                    System.out.printf("brep read back: bounds max=(%s,%s,%s)%n", max[0], max[1], max[2]);
                    if (!near(max, 40, 20, 16)) fail("the .brep did not read back as the plate with its pin");
                }

                // SVG: the kernel's own camera, no viewer -- fov = 200 is a refusal it words
                // the same way as the reader's.
                String solidSvgText = rounded.svgText();
                if (!solidSvgText.startsWith("<svg") || !solidSvgText.contains("<path")) fail("solid SVG text did not look like an SVG wireframe");
                Path solidSvgPath = Files.createTempFile("cadaclysm-smoke-solid", ".svg");
                rounded.svg(solidSvgPath.toString());
                if (Files.size(solidSvgPath) == 0) fail("Solid.svg wrote an empty file");
                try {
                    rounded.svgText(new Blacksmith.SvgOptions(null, null, null, null, 200.0, 1000.0, 1000.0, 0.05, 0.1,
                            "#000000", 1.0, null, true, false, false, false));
                    fail("blacksmith svg: fov=200 was accepted");
                } catch (Blacksmith.BuildException expected) {
                    // the library's own refusal
                }
                System.out.println("blacksmith svg: solid text, file written, fov=200 refused");

                // A profile draws its own plane, top by default -- unlike a solid, a sketch has
                // no camera-facing convention of its own, so its plane (z = 0) is already the
                // page. The default is pinned against an explicit iso view, not just checked
                // non-empty: a top default silently left at iso would make the two calls equal.
                String profileSvgText = outline.svgText();
                if (!profileSvgText.startsWith("<svg") || !profileSvgText.contains("<path")) fail("profile SVG text did not look like an SVG wireframe");
                String profileSvgIso = outline.svgText(new Blacksmith.SvgOptions(Blacksmith.SvgView.ISO, null, null, null,
                        0.0, 1000.0, 1000.0, 0.05, 0.1, "#000000", 1.0, null, true, false, false, false));
                if (profileSvgText.equals(profileSvgIso)) fail("profile svg: top default did not differ from an explicit iso view");
                Path profileSvgPath = Files.createTempFile("cadaclysm-smoke-profile", ".svg");
                outline.svg(profileSvgPath.toString());
                if (Files.size(profileSvgPath) == 0) fail("Profile.svg wrote an empty file");
                System.out.println("blacksmith svg: profile text, file written, top default confirmed against iso");

                // The module writer draws a solid and a profile on one page: one <g> per
                // drawable, an id each -- the overload writeSvgText/writeSvg take, widened
                // from the solids-only ones.
                String mixedSvgText = Blacksmith.writeSvgText(List.of(rounded), List.of(outline), null);
                if (!mixedSvgText.contains("<path") || !mixedSvgText.contains("id=\"solid-0\"") || !mixedSvgText.contains("id=\"profile-0\""))
                    fail("mixed solid+profile SVG did not carry both group ids");
                Path mixedSvgPath = Files.createTempFile("cadaclysm-smoke-mixed", ".svg");
                Blacksmith.writeSvg(mixedSvgPath.toString(), List.of(rounded), List.of(outline), null);
                if (Files.size(mixedSvgPath) == 0) fail("writeSvg (solids and profiles) wrote an empty file");
                System.out.println("blacksmith svg: solid and profile drawn together, both group ids present");

                // toScene: a reader scene over the same STEP text, and one that stands on
                // its own -- the solid's close must not take it down.
                scene = rounded.toScene();
                float[] sceneMax = scene.bounds().max();
                if (!near(sceneMax, 40, 20, 16)) fail("toScene's bounds disagree: " + Arrays.toString(sceneMax));

                // The stale-view rule: a mesh view is tied to one filling of the solid's
                // cache. Meshing at another tolerance replaces the cache, and coming back to
                // the first tolerance fills it afresh rather than restoring the old memory,
                // so the first view must refuse to read even though its tolerance is current.
                Blacksmith.Mesh first = rounded.mesh(0.05);
                int triangles = first.triangleCount();
                FloatBuffer positions = first.positions();
                if (positions.remaining() != first.vertexCount() * 3) fail("the mesh view is the wrong length");
                rounded.mesh(0.5);
                Blacksmith.Mesh third = rounded.mesh(0.05);
                if (third.positions().remaining() != positions.remaining()) fail("re-meshing at 0.05 changed the mesh");
                boolean stale;
                try {
                    first.positions();
                    stale = false;
                } catch (IllegalStateException e) {
                    stale = true;
                }
                if (!stale) fail("a view from before a tolerance change still reads");
                System.out.println("triangles=" + triangles + " stale view throws=" + stale);

                // f64 twins on the kernel: mesh64 shares mesh's cache and bounds64 the same
                // tessellation's unnarrowed positions.
                Blacksmith.Mesh kMesh32 = rounded.mesh(0.05);
                Blacksmith.Mesh64 kMesh64 = rounded.mesh64(0.05);
                if (kMesh64.vertexCount() != kMesh32.vertexCount() || kMesh64.indexCount() != kMesh32.indexCount())
                    fail("blacksmith mesh64(0.05)'s counts do not equal mesh(0.05)'s");
                double[] kPositions64 = kMesh64.copy().positions();
                float[] kPositions32 = kMesh32.copy().positions();
                if (kPositions32.length >= 3 &&
                        ((float) kPositions64[0] != kPositions32[0] || (float) kPositions64[1] != kPositions32[1] || (float) kPositions64[2] != kPositions32[2]))
                    fail("blacksmith mesh64's first position narrowed does not equal mesh's");
                Blacksmith.Bounds kBounds = rounded.boundsAt(0.05);
                Blacksmith.Bounds kBounds64 = rounded.boundsAt64(0.05);
                if (Math.abs(kBounds64.min()[0] - kBounds.min()[0]) > 1e-9 || Math.abs(kBounds64.min()[1] - kBounds.min()[1]) > 1e-9 || Math.abs(kBounds64.min()[2] - kBounds.min()[2]) > 1e-9
                        || Math.abs(kBounds64.max()[0] - kBounds.max()[0]) > 1e-9 || Math.abs(kBounds64.max()[1] - kBounds.max()[1]) > 1e-9 || Math.abs(kBounds64.max()[2] - kBounds.max()[2]) > 1e-9)
                    fail("blacksmith bounds64(0.05) does not equal bounds(0.05)");
                System.out.printf("blacksmith f64 twins: mesh64 %d triangles, bounds64 max z %s%n", kMesh64.triangleCount(), kBounds64.max()[2]);
            }

            try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(1, 2, 3); Blacksmith.Solid big = box.scaled(2)) {
                Blacksmith.Bounds bb = big.bounds();
                if (Math.abs(bb.max()[0] - bb.min()[0] - 2) > 1e-9 || Math.abs(bb.max()[2] - bb.min()[2] - 6) > 1e-9) fail("scaled bounds");
                try { box.scaled(0); fail("scaled(0) not refused"); }
                catch (Blacksmith.BuildException e) { if (!e.getMessage().startsWith("scaled:")) fail("scaled message: " + e.getMessage()); }
            }

            // Leaving the block closed `rounded`: a call on it now throws, and the scene
            // from toScene is its own document, still readable after the solid that made
            // it is gone.
            if (!released.closed()) fail("leaving the block did not close the solid");
            boolean closedThrows;
            try {
                released.faces();
                closedThrows = false;
            } catch (IllegalStateException e) {
                closedThrows = true;
            }
            if (!closedThrows) fail("a call on a closed solid did not throw");
            try (scene) {
                if (!near(scene.bounds().max(), 40, 20, 16)) fail("toScene's scene died with the solid");
            }
            System.out.println("toScene ok, closed solid throws");
        }
    }

    // The FEM surface mesh, the reader's side. cube.scad carries no brep, so this is the
    // mesh-only path: one face, every node on it, no B-rep topology at all, and the scene's own
    // convention rather than the file's. Every check below names the wrong implementation it
    // catches; `#` marks the ones a break-the-code proof was run against.
    private static void femReader(Cad.Node first, String path) throws IOException {
        try (Cad.FemMesh fem = first.femMesh(0.5)) {
            int nodeCount = fem.nodes().remaining() / 3;
            int triangleCount = fem.triangles().remaining() / 3;
            if (fem.nodes().remaining() % 3 != 0 || fem.triangles().remaining() % 3 != 0 || nodeCount == 0)
                fail("fem: the node and triangle buffers read " + fem.nodes().remaining() + " and " + fem.triangles().remaining());
            // Catches `triangles` lent over `node_count` (or `nodes` over `triangle_count`): the
            // buffers would be the wrong length and the indices would run past the nodes.
            if (fem.triangleFace().remaining() != triangleCount) fail("fem: triangleFace is not one per triangle");
            IntBuffer triangles = fem.triangles();
            for (int i = 0; i < triangles.remaining(); i++)
                if (triangles.get(i) < 0 || triangles.get(i) >= nodeCount)
                    fail("fem: a triangle names node " + triangles.get(i) + " of " + nodeCount);
            IntBuffer triangleFace = fem.triangleFace();
            for (int i = 0; i < triangleFace.remaining(); i++)
                if (triangleFace.get(i) < 0 || triangleFace.get(i) >= fem.faceCount())
                    fail("fem: a triangle lies on face " + triangleFace.get(i) + " of " + fem.faceCount());
            // Catches nodeKind and nodeEntity lent from each other's pointer: a kind would then be
            // a face index and an entity a 0/1/2. Bounding each entity by the list its own kind
            // names is what tells the two apart -- the widths cannot, both being one uint32 array
            // per node.
            if (fem.nodeKind().remaining() != nodeCount || fem.nodeEntity().remaining() != nodeCount)
                fail("fem: nodeKind/nodeEntity are not one per node");
            // Read once, outside the loop: every ask rebuilds the list from the handle at one C
            // call an element, and the two are empty here only because this body has no B-rep
            // topology.
            List<Cad.FemEdge> edges = fem.edges();
            List<Cad.FemVertex> vertices = fem.vertices();
            IntBuffer kinds = fem.nodeKind(), entities = fem.nodeEntity();
            for (int k = 0; k < nodeCount; k++) {
                int kind = kinds.get(k), entity = entities.get(k);
                int limit = switch (kind) {
                    case 0 -> vertices.size();
                    case 1 -> edges.size();
                    case 2 -> fem.faceCount();
                    default -> 0;
                };
                if (kind < 0 || kind > 2 || entity < 0 || entity >= limit)
                    fail("fem: node " + k + " lies on kind " + kind + " entity " + entity + ", of " + limit);
            }
            if (fem.minAngle() <= 0 || fem.minAngle() >= 90 || fem.longestEdge() <= 0 || fem.worstTriangle() >= triangleCount)
                fail("fem: the quality figures read " + fem);
            if (path.endsWith("cube.scad")) {
                // # Catches fromMesh read off the neighbouring `watertight` field -- true for this
                // body too, so only a body where the two differ separates them (the B-rep below).
                if (!fem.fromMesh() || fem.faceCount() != 1 || !edges.isEmpty() || !vertices.isEmpty())
                    fail("fem: the cube reads " + fem + ", not a mesh-only body of one face");
                for (int k = 0; k < nodeCount; k++)
                    if (kinds.get(k) != 2 || entities.get(k) != 0) fail("fem: a mesh body's nodes all lie on face 0");
                if (!fem.watertight() || !fem.openEdges().isEmpty() || !fem.foldedEdges().isEmpty())
                    fail("fem: the closed cube reads " + fem.openEdges().size() + " cracks and " + fem.foldedEdges().size() + " folds");
            }
            String msh = fem.mshText();
            if (!msh.startsWith("$MeshFormat") || !msh.contains("$Nodes")) fail("fem: mshText is not Gmsh 4.1 ASCII");
            // The borrowed slot is copied into a String on the way through, so a second ask does
            // not free the first answer: both are this program's own and both still read.
            if (fem.mshText().length() != msh.length()) fail("fem: a second mshText disagrees with the first");
            Path mshPath = Files.createTempFile("cadaclysm-smoke", ".msh");
            fem.saveMsh(mshPath.toString());
            if (Files.size(mshPath) < msh.length() / 2) fail("fem: saveMsh wrote less than mshText");
            // The reader's placement is sixteen numbers, column-major; the kernel's is twelve. A
            // caller handing one ABI the other's is refused here rather than read as garbage --
            // and the length is the one thing a wrapper must check itself, the ABI seeing only a
            // pointer.
            try {
                first.femMesh(0.5, 0.0, new double[12]);
                fail("fem: a twelve-number placement was accepted");
            } catch (Cad.CadaclysmException e) {
                if (!e.getMessage().contains("16 numbers")) fail("fem: the placement refusal reads " + e.getMessage());
            }
            // A mesh-only body is meshed by a path that takes no options at all
            // (`fem::fem_mesh_of_mesh`), so neither field is read here, let alone validated: a
            // zero, a negative and a NaN all come back with the mesh. What is pinned is the
            // wrapper's pass-through, not the mesher's checking -- a wrapper that validated
            // `tolerance` or `maxSize` itself would refuse calls this ABI accepts. (Both *are*
            // refused on a B-rep body; femBrep checks the tolerance half.)
            double[][] unread = {{0, 0}, {-1, 0}, {Double.NaN, 0}, {0.5, -1}, {0.5, Double.NaN}, {0.5, Double.POSITIVE_INFINITY}};
            for (double[] pair : unread) {
                try (Cad.FemMesh any = first.femMesh(pair[0], pair[1])) {
                    if (any.nodes().remaining() != nodeCount * 3)
                        fail("fem: a mesh-only body read its options after all (tolerance " + pair[0]
                                + ", maxSize " + pair[1] + " gave " + any + ")");
                }
            }
            // # A freed handle refuses every accessor rather than reading the pointers it left
            // behind: the view struct is cached, so an accessor that does not ask the handle first
            // hands out a buffer over freed memory instead of throwing. The kernel's own sweep in
            // femKernel is the twin -- the guard is per wrapper class, so proving one says nothing
            // about the other.
            //
            // What this does *not* prove, because Java cannot: a buffer already in hand is a
            // window on an address with no owner left to ask. Measured once while writing this,
            // on the kernel side: a DoubleBuffer taken before free() and read after did not
            // throw -- it read the freed block and handed back 1.29e-311 where the mesh had 4.0.
            // Not checked here on purpose: a deliberate read of freed memory in the smoke the
            // release pipeline runs on nine platforms is an intermittent crash waiting to
            // happen. Both wrappers' docs say which half is guarded.
            Cad.FemMesh staleReader = first.femMesh(0.5);
            staleReader.free();
            if (!staleReader.closed()) fail("fem: a freed mesh does not say so");
            staleReader.free();   // idempotent
            List<Runnable> reads = List.of(
                    staleReader::nodes, staleReader::triangles, staleReader::triangleFace,
                    staleReader::nodeKind, staleReader::nodeEntity, staleReader::faceCount,
                    staleReader::edges, staleReader::vertices, staleReader::openEdges,
                    staleReader::foldedEdges, staleReader::watertight, staleReader::fromMesh,
                    staleReader::minAngle, staleReader::worstTriangle, staleReader::longestEdge,
                    staleReader::mshText, () -> staleReader.saveMsh(mshPath.toString()));
            if (reads.size() != 17) fail("fem: the freed sweep covers " + reads.size() + " reads, not 17");
            for (Runnable read : reads) {
                try {
                    read.run();
                    fail("fem: a freed mesh read anyway");
                } catch (Cad.CadaclysmException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("freed")) fail("fem: a freed mesh said " + e.getMessage());
                }
            }
            System.out.println("fem (reader): " + fem + ", minAngle " + fem.minAngle() + ", longestEdge " + fem.longestEdge()
                    + "; a freed mesh refuses all seventeen reads");
        }
        if (path.endsWith("cube.scad")) femCensusWiring(Path.of(path).resolveSibling("open-sheet.scad"));
    }

    // # Which count feeds which entry point -- the census *wiring*, which nothing else here pins.
    // Every other FEM check proves a row is extracted correctly; none proves openEdges() reads
    // openEdgeCount rows through cadaclysm_fem_mesh_open_edge rather than the folded count or the
    // folded call. samples/open-sheet.scad is the only body in this repository where both censuses
    // are non-empty and of different lengths: the B-rep path computes no census unless the topology
    // is closed (the documented "not asked" pair) and every closed body has none, while the mesh
    // path always computes one -- so a polyhedron with a flap over one of its own directed edges is
    // the way in. Six cracks, one fold, and the fold is not the first crack.
    private static void femCensusWiring(Path sheet) {
        try (Cad.Scene scene = Cad.open(sheet.toString())) {
            Cad.Node body = null;
            for (Cad.Node n : scene.walk()) if (n.canMesh()) { body = n; break; }
            if (body == null) fail("fem census: open-sheet.scad has no meshable node");
            try (Cad.FemMesh census = body.femMesh()) {
                if (census.nodes().remaining() != 15 || census.triangles().remaining() != 9
                        || !census.fromMesh() || census.watertight())
                    fail("fem census: open-sheet.scad reads " + census + ", not five open, folded, mesh-only nodes");
                List<int[]> cracks = census.openEdges(), folds = census.foldedEdges();
                // The counts are what separate the two lists: a swapped count reads 1 where 6
                // belongs, and a swapped call cannot read row 1 of a one-row table at all.
                if (cracks.size() != 6 || folds.size() != 1)
                    fail("fem census: " + cracks.size() + " cracks and " + folds.size() + " folds, not 6 and 1");
                // And the contents, which separates a wrapper that swapped both consistently.
                int[] fold = folds.get(0), crack = cracks.get(0);
                if (fold[0] != 2 || fold[1] != 0 || fold[2] != -1)
                    fail("fem census: the fold reads (" + fold[0] + "," + fold[1] + "," + fold[2] + "), not (2,0,NONE)");
                if (crack[0] != 1 || crack[1] != 2)
                    fail("fem census: the first crack reads (" + crack[0] + "," + crack[1] + "), not (1,2)");
                System.out.println("fem census: open-sheet.scad reads " + cracks.size() + " cracks and "
                        + folds.size() + " fold at (" + fold[0] + "," + fold[1] + ")");
            }
        }
    }

    // The FEM surface mesh on a B-rep body, read back from the STEP this run wrote: the topology
    // the mesh-only body has none of -- edges with the body's own ids, vertices, and nodes on all
    // three kinds of entity.
    private static void femBrep(Path step, int faces) {
        try (Cad.Scene back = Cad.open(step.toString())) {
            Cad.Node body = null;
            for (Cad.Node n : back.walk()) if (n.canMesh()) { body = n; break; }
            if (body == null) fail("fem: the read-back STEP has no meshable body");
            try (Cad.FemMesh fem = body.femMesh(0.5)) {
                // # The other half of the fromMesh proof: false here where it was true on the
                // cube, the neighbouring watertight being true for both.
                if (fem.fromMesh() || !fem.watertight() || fem.faceCount() != faces)
                    fail("fem: the read plate reads " + fem + ", not a closed B-rep of " + faces + " faces");
                List<Cad.FemEdge> edges = fem.edges();
                List<Cad.FemVertex> vertices = fem.vertices();
                if (edges.isEmpty() || vertices.isEmpty()) fail("fem: a B-rep body carries edges and vertices");
                Set<Integer> kinds = new HashSet<>();
                IntBuffer nodeKind = fem.nodeKind();
                for (int i = 0; i < nodeKind.remaining(); i++) kinds.add(nodeKind.get(i));
                if (!kinds.equals(Set.of(0, 1, 2))) fail("fem: the plate's nodes lie on kinds " + kinds + ", not 0, 1 and 2");
                // # `id` is the body's own B-rep edge id, not this list's index: the list is a
                // densely renumbered subset ascending by id. Catches an `id` filled from the loop
                // counter -- which a body whose ids happened to run 0, 1, 2 would hide, so both
                // halves are checked.
                boolean ascending = true, offIndex = false;
                for (int i = 0; i < edges.size(); i++) {
                    if (i > 0 && edges.get(i).id() < edges.get(i - 1).id()) ascending = false;
                    if (edges.get(i).id() != i) offIndex = true;
                }
                if (!ascending) fail("fem: the edge ids do not ascend");
                if (!offIndex) fail("fem: every edge id equals its own index -- id is the index, not the body's id");
                int nodeCount = fem.nodes().remaining() / 3;
                for (Cad.FemEdge edge : edges) {
                    int[] runs = edge.runs(), nodes = edge.nodes();
                    if (runs.length == 0 || runs[0] != 0 || runs[runs.length - 1] >= nodes.length)
                        fail("fem: " + edge + "'s runs do not start at 0 inside its chain");
                    for (int node : nodes) if (node < 0 || node >= nodeCount) fail("fem: " + edge + " names a node past the mesh");
                    // # A closed body has no rim, so every edge has two faces and neither is the
                    // NONE sentinel.
                    if (edge.faces()[0] < 0 || edge.faces()[0] >= faces || edge.faces()[1] < 0 || edge.faces()[1] >= faces)
                        fail("fem: " + edge + " on a closed body bounds faces " + Arrays.toString(edge.faces()) + " of " + faces);
                    if (edge.closed() && runs.length > 1) fail("fem: " + edge + " is one loop with a broken chain");
                    if (edge.seam() && edge.faces()[0] != edge.faces()[1]) fail("fem: " + edge + " is a seam whose two faces differ");
                    // # The chain includes its end vertices, so the two ends name the nodes it
                    // begins and finishes at -- which is what tells `ends` from `faces`, both a
                    // pair of indices a swap would leave in range on a body of this shape.
                    Set<Integer> ends = new HashSet<>();
                    for (int end : edge.ends()) if (end != -1) ends.add(vertices.get(end).node());
                    if (!ends.equals(new HashSet<>(List.of(nodes[0], nodes[nodes.length - 1]))))
                        fail("fem: " + edge + " does not end at its own vertices");
                }
                boolean placed = false;
                for (Cad.FemVertex vertex : vertices) {
                    if (vertex.hasPosition()) placed = true;
                    if (vertex.point().length != 3 || (vertex.node() != -1 && vertex.node() >= nodeCount))
                        fail("fem: " + vertex + " is not a node of this mesh");
                }
                if (!placed) fail("fem: no vertex of the plate has a position");
                // A B-rep body *does* have geometry to follow, so here the tolerance is read and
                // refused -- in the library's own words, not a message this wrapper invented.
                try {
                    body.femMesh(0);
                    fail("fem: a zero tolerance was accepted on a B-rep body");
                } catch (Cad.CadaclysmException e) {
                    if (!e.getMessage().contains("tolerance must be finite and > 0"))
                        fail("fem: the tolerance refusal reads " + e.getMessage());
                }
                System.out.println("fem (read brep): " + fem + ", " + edges.size() + " edges, "
                        + vertices.size() + " vertices, edge 0 " + edges.get(0));
            }
        }
    }

    // The kernel's own FEM mesh: the same solid through `cadaclysm_blacksmith_fem_mesh`, whose
    // placement is twelve numbers and whose `.msh` text is owned rather than borrowed.
    private static void femKernel(Blacksmith.Solid rounded, int faces) throws IOException {
        Path mshPath = Files.createTempFile("cadaclysm-smoke-kernel", ".msh");
        try (Blacksmith.FemMesh fem = rounded.femMesh(0.5)) {
            if (fem.fromMesh() || !fem.watertight() || fem.faceCount() != faces || fem.nodes().remaining() == 0)
                fail("kernel fem: the filleted part reads " + fem);
            if (!fem.openEdges().isEmpty() || !fem.foldedEdges().isEmpty())
                fail("kernel fem: a watertight solid reads " + fem.openEdges().size() + " cracks and " + fem.foldedEdges().size() + " folds");
            // maxSize bounds the boundary segments and only targets the interior, so the figure a
            // solver caller checks is longestEdge -- not the ceiling it asked for. Catches a
            // wrapper that dropped maxSize on the floor: the mesh would not refine at all.
            try (Blacksmith.FemMesh fine = rounded.femMesh(0.5, 3.0)) {
                // 1.05 and not 3.0 exactly: the ceiling is not a guarantee (1.03 x was measured on
                // a face whose parameters run unevenly), so a tighter pin here would assert
                // something the ABI deliberately does not promise.
                if (fine.longestEdge() > 3.0 * 1.05) fail("kernel fem: maxSize 3 came to longestEdge " + fine.longestEdge());
                if (fine.nodes().remaining() <= fem.nodes().remaining() || fine.longestEdge() >= fem.longestEdge())
                    fail("kernel fem: maxSize 3 gave " + fine.nodes().remaining() / 3 + " nodes and longestEdge "
                            + fine.longestEdge() + ", no finer than " + fem.nodes().remaining() / 3 + "/" + fem.longestEdge());
            }
            String msh = fem.mshText();
            if (!msh.startsWith("$MeshFormat")) fail("kernel fem: mshText is not Gmsh 4.1 ASCII");
            // Owned on this side, not borrowed: two asks give two independent texts, each released
            // by `cadaclysm_blacksmith_string_free` on the way out, and neither dies with the other
            // or with the handle.
            if (fem.mshText().length() != msh.length()) fail("kernel fem: a second mshText disagrees with the first");
            fem.saveMsh(mshPath.toString());
            if (Files.size(mshPath) < msh.length() / 2) fail("kernel fem: saveMsh wrote less than mshText");
            // # The kernel's placement is twelve numbers where the reader's is sixteen.
            try {
                rounded.femMesh(0.5, 0.0, new double[16]);
                fail("kernel fem: a sixteen-number placement was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().contains("12 numbers")) fail("kernel fem: the placement refusal reads " + e.getMessage());
            }
            try {
                rounded.femMesh(0);
                fail("kernel fem: a zero tolerance was accepted");
            } catch (Blacksmith.BuildException expected) {
                // the library's own refusal, not this wrapper's
            }
            System.out.println("kernel fem: " + fem + ", minAngle " + fem.minAngle() + ", longestEdge " + fem.longestEdge());
        }
        // An open sheet: the one body where the sentinel and the "not asked" census trio show.
        try (Blacksmith.Profile square = Blacksmith.Profile.rect(20, 20);
             Blacksmith.Solid sheet = Blacksmith.Solid.face(square, new double[] {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1});
             Blacksmith.FemMesh sheetFem = sheet.femMesh(0.5)) {
            // # watertight false with *both* censuses empty is "not asked", not "nothing found": a
            // sheet makes no claim to enclose anything. A caller reading only openEdges cannot tell
            // this from a sound body, which is why foldedEdges is checked beside it.
            if (sheetFem.watertight() || !sheetFem.openEdges().isEmpty() || !sheetFem.foldedEdges().isEmpty())
                fail("kernel fem: the sheet reads " + sheetFem + " rather than open with an unasked census");
            // # Catches `face_b` filled with 0 instead of the NONE sentinel: every rim edge of a
            // one-faced sheet bounds face 0 and nothing else, so a 0 there reads as a real second
            // face -- a coherent wrong answer no field count or width can catch.
            StringBuilder rim = new StringBuilder();
            for (Blacksmith.FemEdge edge : sheetFem.edges()) rim.append(edge.faces()[0]).append("/").append(edge.faces()[1]).append("; ");
            if (sheetFem.faceCount() != 1) fail("kernel fem: the sheet has " + sheetFem.faceCount() + " faces, not 1");
            for (Blacksmith.FemEdge edge : sheetFem.edges())
                if (edge.faces()[0] != 0 || edge.faces()[1] != -1) fail("kernel fem: the sheet's rim reads " + rim);
            System.out.println("kernel fem: the sheet's rim reads " + rim);
        }
        // # The freed sweep, the kernel's own: seventeen reads, each refusing rather than reading
        // the pointers the handle left behind.
        Blacksmith.FemMesh stale = rounded.femMesh(0.5);
        stale.free();
        if (!stale.closed()) fail("kernel fem: a freed mesh does not say so");
        stale.free();   // idempotent
        List<Runnable> reads = List.of(
                stale::nodes, stale::triangles, stale::triangleFace, stale::nodeKind,
                stale::nodeEntity, stale::faceCount, stale::edges, stale::vertices,
                stale::openEdges, stale::foldedEdges, stale::watertight, stale::fromMesh,
                stale::minAngle, stale::worstTriangle, stale::longestEdge, stale::mshText,
                () -> stale.saveMsh(mshPath.toString()));
        if (reads.size() != 17) fail("kernel fem: the freed sweep covers " + reads.size() + " reads, not 17");
        for (Runnable read : reads) {
            try {
                read.run();
                fail("kernel fem: a freed mesh read anyway");
            } catch (IllegalStateException e) {
                if (e.getMessage() == null || !e.getMessage().contains("freed")) fail("kernel fem: a freed mesh said " + e.getMessage());
            }
        }
        System.out.println("kernel fem: a freed mesh refuses all seventeen reads");
    }

    private static boolean near(float[] v, double x, double y, double z) {
        return Math.abs(v[0] - x) <= 0.01 && Math.abs(v[1] - y) <= 0.01 && Math.abs(v[2] - z) <= 0.01;
    }

    private static boolean near(double[] v, double x, double y, double z) {
        return Math.abs(v[0] - x) <= 0.01 && Math.abs(v[1] - y) <= 0.01 && Math.abs(v[2] - z) <= 0.01;
    }

    // Hits: two radius-5 circles six apart cross at two points, (3, -4) and (3, 4). At
    // (3, 4) the first circle's upper arc is at t 0.2952 and the moved one's at 0.7048; at
    // (3, -4) the other way round -- which catches the two sides read swapped.
    private static void hits() {
        try (Blacksmith.Profile left = Blacksmith.Profile.circle(5);
             Blacksmith.Profile five = Blacksmith.Profile.circle(5);
             Blacksmith.Profile right = five.translate(6, 0)) {
            List<Blacksmith.Hit> crossing = left.hits(right);
            if (crossing.size() != 2) fail("hits: two circles hit " + crossing.size() + " times, not 2");
            double[] ys = crossing.stream().mapToDouble(h -> h.start()[1]).sorted().toArray();
            if (Math.abs(ys[0] + 4) > 1e-9 || Math.abs(ys[1] - 4) > 1e-9)
                fail("hits: y " + ys[0] + ", " + ys[1] + ", not -4 and 4");
            for (Blacksmith.Hit h : crossing) {
                double ta = h.start()[1] > 0 ? 0.2952 : 0.7048, tb = h.start()[1] > 0 ? 0.7048 : 0.2952;
                if (h.run() || h.touch() || h.aStart().loopIndex() != 0 || Math.abs(h.start()[0] - 3) > 1e-9
                        || Math.abs(h.aStart().t() - ta) > 1e-3 || Math.abs(h.bStart().t() - tb) > 1e-3)
                    fail("hits: " + h + " is not a crossing at (3, +-4) at t " + ta + " on a and " + tb + " on b");
            }
            System.out.println("hits: " + crossing.get(0) + ", " + crossing.get(1));
            // Common: the same two circles share one lens, four arcs (each circle's own seam
            // stays a join) between two caps once extruded; moved apart they share nothing.
            List<Blacksmith.Profile> lenses = left.common(right);
            if (lenses.size() != 1) fail("common: two circles share " + lenses.size() + " regions, not 1");
            try (Blacksmith.Profile lens = lenses.get(0);
                 Blacksmith.Solid lensSolid = Blacksmith.Workplane.xy().extrude(lens, 1).solid();
                 Blacksmith.Profile far = five.translate(100, 0)) {
                if (lensSolid.faces() != 6) fail("common: the lens extrudes to " + lensSolid.faces() + " faces, not 6");
                if (!left.common(far).isEmpty()) fail("common: circles 100 apart share a region");
                try {
                    left.common(right, 0.0);
                    fail("common: a zero tolerance was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (!e.getMessage().contains("profile_common: tolerance must be positive and finite")) throw e;
                }
                System.out.println("common: one lens, " + lensSolid.faces() + " faces extruded");
            }
        }
    }

    // Edge curves: a cylinder's rims are circles of its radius about a cap centre in a unit
    // frame, a whole turn each; a cuboid's edges are lines whose origin + x is the far end;
    // an extruded closed spline keeps a nurbs edge with knots = poles + degree + 1.
    private static void edgeCurves() {
        try (Blacksmith.Solid cyl = Blacksmith.Solid.cylinder(5, 3);
             Blacksmith.Solid box = Blacksmith.Solid.cuboid(2, 4, 6);
             Blacksmith.Profile square = Blacksmith.Profile.spline(
                     new double[][] {{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, null, true);
             Blacksmith.Solid loop = Blacksmith.Workplane.xy().extrude(square, 2).solid()) {
            List<Blacksmith.Curve> rims = cyl.edges().stream()
                    .filter(e -> e.kind().equals("circle")).map(Blacksmith.Edge::curve).toList();
            if (rims.size() < 2 || rims.stream().anyMatch(c -> c == null)) fail("edge_curve: the cylinder's rims have no curve");
            for (Blacksmith.Curve c : rims) {
                boolean unit = Math.abs(norm(c.x()) - 1) < 1e-9 && Math.abs(norm(c.y()) - 1) < 1e-9
                        && Math.abs(c.x()[0] * c.y()[0] + c.x()[1] * c.y()[1] + c.x()[2] * c.y()[2]) < 1e-9;
                boolean centred = Math.abs(c.origin()[0]) < 1e-9 && Math.abs(c.origin()[1]) < 1e-9
                        && Math.min(Math.abs(c.origin()[2]), Math.abs(c.origin()[2] - 3)) < 1e-9;
                if (!c.kind().equals("circle") || Math.abs(c.radius() - 5) > 1e-9 || !unit || !centred
                        || Math.abs(Math.abs(c.t1() - c.t0()) - 2 * Math.PI) > 1e-9
                        || c.degree() != 0 || c.knots().length != 0 || c.weights() != null)
                    fail("edge_curve: a rim reads " + c);
            }
            for (Blacksmith.Edge e : box.edges()) {
                Blacksmith.Curve c = e.curve();
                if (c == null || !c.kind().equals("line") || c.t0() != 0 || c.t1() != 1) fail("edge_curve: a cuboid edge reads " + c);
                double[] far = {c.origin()[0] + c.x()[0], c.origin()[1] + c.x()[1], c.origin()[2] + c.x()[2]};
                boolean atOrigin = false, atFar = false;
                for (Blacksmith.Edge.Segment s : e.segments()) {
                    for (double[] p : new double[][] {s.a(), s.b()}) {
                        atOrigin |= norm(new double[] {p[0] - c.origin()[0], p[1] - c.origin()[1], p[2] - c.origin()[2]}) < 1e-9;
                        atFar |= norm(new double[] {p[0] - far[0], p[1] - far[1], p[2] - far[2]}) < 1e-9;
                    }
                }
                if (!atOrigin || !atFar) fail("edge_curve: a cuboid line's ends are not its own vertices: " + c);
            }
            List<Blacksmith.Curve> splines = loop.edges().stream()
                    .filter(e -> e.kind().equals("nurbs")).map(Blacksmith.Edge::curve).toList();
            if (splines.isEmpty()) fail("edge_curve: the extruded spline keeps no nurbs edge");
            for (Blacksmith.Curve c : splines) {
                if (!c.kind().equals("nurbs") || c.degree() != 3
                        || c.knots().length != c.poles().length / 3 + c.degree() + 1 || c.weights() != null)
                    fail("edge_curve: the spline edge reads " + c);
            }
            System.out.println("edge_curve: " + rims.get(0) + "; " + box.edges().get(0).curve() + "; " + splines.get(0));
        }
    }

    // Intersect: two equal pipes crossing at right angles meet on ellipse chains whose points
    // lie on both pipes; apart, nothing; a zero tolerance refused in the kernel's words. Two
    // coaxial pipes overlapping in height share a wall band: an overlap whose rings lie on it.
    private static void intersections() {
        double tol = 1e-3;
        try (Blacksmith.Solid pipeA = Blacksmith.Solid.cylinder(1, 6);
             Blacksmith.Solid upright = Blacksmith.Solid.cylinder(1, 6);
             Blacksmith.Solid pipeB = upright.rotate(new double[] {0, 0, 3, 1, 0, 0}, Math.PI / 2);
             Blacksmith.Solid far = pipeB.translate(10, 0, 0);
             Blacksmith.Solid lower = Blacksmith.Solid.cylinder(1, 4);
             Blacksmith.Solid base = Blacksmith.Solid.cylinder(1, 4);
             Blacksmith.Solid upper = base.translate(0, 0, 2)) {
            Blacksmith.Intersection found = pipeA.intersect(pipeB, tol);
            if (found.chains().size() < 2 || !found.overlaps().isEmpty()) fail("intersect: the crossed pipes read " + found);
            int ellipses = 0;
            for (Blacksmith.Chain c : found.chains()) {
                if (c.faceA() < 0 || c.faceA() >= pipeA.faces() || c.faceB() < 0 || c.faceB() >= pipeB.faces() || c.points().length < 2)
                    fail("intersect: a chain reads " + c);
                for (double[] p : c.points())
                    if (offA(p) > 50 * tol || offB(p) > 50 * tol) fail("intersect: a chain leaves the pipes: " + c);
                Blacksmith.Curve curve = c.curve();
                if (curve == null) continue;
                if (!curve.kind().equals("ellipse") && !curve.kind().equals("nurbs")) fail("intersect: a chain's curve reads " + curve);
                if (!curve.kind().equals("ellipse")) continue;
                ellipses++;
                double t = (curve.t0() + curve.t1()) / 2;
                double[] q = new double[3];
                for (int k = 0; k < 3; k++)
                    q[k] = curve.origin()[k] + curve.x()[k] * curve.radius() * Math.cos(t) + curve.y()[k] * curve.radius2() * Math.sin(t);
                if (offA(q) > 50 * tol || offB(q) > 50 * tol) fail("intersect: the ellipse leaves the pipes at " + curve);
            }
            if (ellipses == 0) fail("intersect: two equal pipes cross on ellipses");
            Blacksmith.Intersection apart = pipeA.intersect(far);
            if (!apart.chains().isEmpty() || !apart.overlaps().isEmpty()) fail("intersect: pipes apart read " + apart);
            try {
                pipeA.intersect(pipeB, 0.0);
                fail("intersect: a zero tolerance was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().contains("intersect: tolerance must be positive and finite")) throw e;
            }
            Blacksmith.Intersection shared = lower.intersect(upper, tol);
            if (shared.overlaps().isEmpty() || shared.overlaps().get(0).loops().length < 1) fail("intersect: the coaxial pipes read " + shared);
            for (double[][] ring : shared.overlaps().get(0).loops()) {
                if (ring.length < 3) fail("intersect: an overlap ring is not a polygon: " + shared.overlaps().get(0));
                for (double[] p : ring)
                    if (offA(p) > 50 * tol || p[2] < 2 - 50 * tol || p[2] > 4 + 50 * tol)
                        fail("intersect: an overlap ring leaves the shared band: " + shared.overlaps().get(0));
            }
            System.out.println("intersect: " + found + " (" + ellipses + " ellipses); " + shared.overlaps().get(0));
        }
    }

    // Solid x profile hits: a line through a cuboid pierces two faces and is cut into three
    // pieces, outside/inside/outside, the middle one spanning the box and sweeping; a loop no
    // hit cuts is one piece; an open sheet has no pieces; a zero tolerance refused verbatim.
    private static void solidHits() {
        double[] xy = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        try (Blacksmith.Solid box = Blacksmith.Solid.cuboid(10, 20, 30);
             Blacksmith.Profile line = Blacksmith.Profile.path(new double[] {-20, 0}).lineTo(20, 0).endOpen();
             Blacksmith.Profile circle = Blacksmith.Profile.circle(1);
             Blacksmith.Profile square = Blacksmith.Profile.rect(20, 20);
             Blacksmith.Solid flat = Blacksmith.Solid.face(square, xy);
             Blacksmith.Profile upright = Blacksmith.Profile.path(new double[] {0, -20}).lineTo(0, 20).endOpen()) {
            Blacksmith.SolidHits found = box.hits(line, xy);
            if (found.hits().size() != 2 || found.pieces().size() != 3) fail("solid hits: a line through a cuboid reads " + found);
            for (int k = 0; k < 2; k++) {
                Blacksmith.Hit h = found.hits().get(k);
                if (h.run() || h.touch() || Math.abs(h.start()[0] - (k == 0 ? -5 : 5)) > 0.05 || h.aStart().segment() != 0
                        || h.aStart().face() != -1 || h.bStart().face() == -1
                        || !Double.isFinite(h.bStart().u()) || !Double.isFinite(h.bStart().v()))
                    fail("solid hits: hit " + k + " reads " + h + " (" + h.aStart() + ", " + h.bStart() + ")");
            }
            List<Blacksmith.Piece> p = found.pieces();
            if (p.get(0).inside() || !p.get(1).inside() || p.get(2).inside()) fail("solid hits: the pieces read " + p);
            if (p.get(0).start().t() != 0 || p.get(2).end().t() != 1 || p.get(0).end().t() != p.get(1).start().t()
                    || p.get(1).end().t() != p.get(2).start().t())
                fail("solid hits: the pieces do not run head to tail: " + p);
            try (Blacksmith.Solid middle = Blacksmith.Solid.extrudeOpen(p.get(1).profile(), xy, 1);
                 Blacksmith.SweepPath along = Blacksmith.SweepPath.along(p.get(1).profile(), xy, 0.05, true)) {
                Blacksmith.Bounds b = middle.bounds();
                if (Math.abs(b.min()[0] + 5) > 0.05 || Math.abs(b.max()[0] - 5) > 0.05)
                    fail("solid hits: the middle piece spans x " + b.min()[0] + " .. " + b.max()[0] + ", not the box");
            }
            for (Blacksmith.Piece piece : p) piece.profile().close();
            Blacksmith.SolidHits far = box.hits(circle, new double[] {100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1});
            if (!far.hits().isEmpty() || far.pieces().size() != 1 || far.pieces().get(0).inside()) fail("solid hits: a circle far off reads " + far);
            Blacksmith.SolidHits across = flat.hits(upright, new double[] {0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0});
            if (across.hits().isEmpty() || !across.pieces().isEmpty()) fail("solid hits: a line across a sheet reads " + across);
            try {
                box.hits(line, xy, 0.0);
                fail("solid hits: a zero tolerance was accepted");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("solid_profile_hits: tolerance must be positive and finite")) throw e;
            }
            System.out.println("solid hits: " + found + "; " + p.get(1));
        }
    }

    /** How far {@code p} is off the pipe up z (radius 1). */
    private static double offA(double[] p) {
        return Math.abs(Math.sqrt(p[0] * p[0] + p[1] * p[1]) - 1);
    }

    /** How far {@code p} is off the pipe along y through (0, 0, 3) (radius 1). */
    private static double offB(double[] p) {
        return Math.abs(Math.sqrt(p[0] * p[0] + (p[2] - 3) * (p[2] - 3)) - 1);
    }

    private static double norm(double[] v) {
        return Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    }

    // Assemblies: Assembly, Solid.named and Solid.name, at parity with the Python reference's
    // _shared_assembly() and the tests built on it.
    private static void assemblies() {
        try (Blacksmith.Solid asmBolt = Blacksmith.Solid.cylinder(1, 6).named("bolt");
             Blacksmith.Solid asmPlate = Blacksmith.Solid.cuboid(20, 10, 2).named("plate").coloured(1, 0.5, 0);
             Blacksmith.Assembly bracket = new Blacksmith.Assembly("bracket")) {
            String platePlacement = bracket.place(asmPlate, Blacksmith.Frame.xy().toArray());
            String bolt1Placement = bracket.place(asmBolt, Blacksmith.Frame.xy(new double[] {5, 5, 2}).toArray());
            String bolt2Placement = bracket.place(asmBolt, Blacksmith.Frame.xy(new double[] {15, 5, 2}).toArray());
            if (!platePlacement.equals("plate") || !bolt1Placement.equals("bolt") || !bolt2Placement.equals("bolt 2"))
                fail("assembly: bracket placements were \"" + platePlacement + "\", \"" + bolt1Placement + "\", \"" + bolt2Placement + "\", not plate/bolt/bolt 2");

            try (Blacksmith.Assembly asmFrame = new Blacksmith.Assembly("frame")) {
                String leftPlacement = asmFrame.place(bracket, Blacksmith.Frame.xy(new double[] {0, 0, 0}).toArray(), "left");
                String rightPlacement = asmFrame.place(bracket,
                        new Blacksmith.Frame(new double[] {100, 0, 0}, new double[] {0, 1, 0}, new double[] {-1, 0, 0}, new double[] {0, 0, 1}).toArray(),
                        "right");
                String rootBoltPlacement = asmFrame.place(asmBolt, Blacksmith.Frame.xy(new double[] {50, 50, 0}).toArray());
                if (!leftPlacement.equals("left") || !rightPlacement.equals("right") || !rootBoltPlacement.equals("bolt"))
                    fail("assembly: frame placements were \"" + leftPlacement + "\", \"" + rightPlacement + "\", \"" + rootBoltPlacement + "\", not left/right/bolt");

                String frameStepText = asmFrame.stepText();
                int manifoldCount = countOf(frameStepText, "=MANIFOLD_SOLID_BREP(");
                int productCount = countOf(frameStepText, "=PRODUCT(");
                int nauoCount = countOf(frameStepText, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(");
                if (manifoldCount != 2 || productCount != 4 || nauoCount != 6)
                    fail("assembly: frame step_text has " + manifoldCount + " breps, " + productCount + " products, " + nauoCount + " NAUOs, not 2/4/6");
                if (!frameStepText.contains("'left'") || !frameStepText.contains("'right'") || !frameStepText.contains("'bolt 2'"))
                    fail("assembly: frame step_text is missing 'left', 'right' or 'bolt 2'");
                System.out.println("assembly: frame writes " + manifoldCount + " breps, " + productCount + " products, " + nauoCount + " NAUOs");

                // Read-back, through the same reader door as Solid.toScene -- structure only, at
                // this (pre-late-placement) text: one root "frame", two "bracket" containers each
                // holding plate/bolt/bolt, and one root-level "bolt". The world origins are
                // Python's to check.
                try (Cad.Scene readScene = Cad.openMemory(frameStepText.getBytes(java.nio.charset.StandardCharsets.UTF_8), "frame.stp")) {
                    List<Cad.Node> roots = readScene.roots();
                    if (roots.size() != 1 || !roots.get(0).name().equals("frame")) fail("assembly: the read-back root is not one node named \"frame\"");
                    List<Cad.Node> rootChildren = roots.get(0).children();
                    if (rootChildren.size() != 3) fail("assembly: the read-back root has " + rootChildren.size() + " children, not 3");
                    List<Cad.Node> containers = rootChildren.stream().filter(c -> c.name().equals("bracket")).toList();
                    List<Cad.Node> rootBolts = rootChildren.stream().filter(c -> c.name().equals("bolt")).toList();
                    if (containers.size() != 2 || rootBolts.size() != 1)
                        fail("assembly: the read-back root does not have two bracket containers and one bolt");
                    for (Cad.Node container : containers) {
                        List<String> names = container.children().stream().map(Cad.Node::name).sorted().toList();
                        if (!names.equals(List.of("bolt", "bolt", "plate")))
                            fail("assembly: a read-back bracket container does not hold plate, bolt, bolt");
                    }
                }
                System.out.println("assembly: the read-back tree has one root, two bracket containers of plate+bolt+bolt, and one root bolt");

                // A late placement into bracket shows up wherever bracket is placed (left and
                // right both).
                bracket.place(asmBolt, Blacksmith.Frame.xy(new double[] {10, 8, 2}).toArray());
                int laterNauoCount = countOf(asmFrame.stepText(), "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(");
                if (laterNauoCount != 7) fail("assembly: a late placement gave " + laterNauoCount + " NAUOs, not 7");
                System.out.println("assembly: a late placement into bracket shows up wherever it is placed");

                // A cycle, a duplicate placement name, a mirrored frame, and an assembly (or one
                // reachable from it) that places nothing are all refused.
                try {
                    bracket.place(asmFrame, Blacksmith.Frame.xy().toArray());
                    fail("assembly: a cycle (bracket -> frame -> bracket) was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("bracket → frame → bracket")) fail("assembly: cycle message: " + e.getMessage());
                }
                try {
                    asmFrame.place(bracket, Blacksmith.Frame.xy().toArray(), "left");
                    fail("assembly: a duplicate placement name was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("left")) fail("assembly: duplicate name message: " + e.getMessage());
                }
                // A raw twelve-number frame, not the Frame type, which refuses a left-handed
                // triple before place is ever called -- the one way to drive a mirrored frame
                // into the ABI's own rigidity check.
                try {
                    asmFrame.place(bracket, new double[] {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1});
                    fail("assembly: a mirrored raw frame was accepted");
                } catch (Blacksmith.BuildException e) {
                    if (e.getMessage() == null || !e.getMessage().contains("right-handed and orthonormal")) fail("assembly: mirrored frame message: " + e.getMessage());
                }
                try (Blacksmith.Assembly x = new Blacksmith.Assembly("x")) {
                    x.stepText();
                    fail("assembly: an empty assembly wrote step text");
                } catch (Blacksmith.BuildException expected) {
                    // the library's own refusal
                }
                try (Blacksmith.Assembly outer = new Blacksmith.Assembly("outer");
                     Blacksmith.Assembly hollow = new Blacksmith.Assembly("hollow")) {
                    outer.place(hollow, Blacksmith.Frame.xy().toArray());
                    try {
                        outer.stepText();
                        fail("assembly: an assembly reachable from the root that places nothing wrote step text");
                    } catch (Blacksmith.BuildException e) {
                        if (e.getMessage() == null || !e.getMessage().contains("hollow")) fail("assembly: empty-reachable message: " + e.getMessage());
                    }
                }
                System.out.println("assembly: a cycle, a duplicate name, a mirrored frame, and an empty assembly are all refused");
            }

            // Solid.named/Solid.name: the name rides through a one-source operation (place,
            // coloured) and is dropped by a two-source one (join) or a fresh primitive.
            if (!"bolt".equals(asmBolt.name())) fail("assembly: bolt.name() is not \"bolt\"");
            try (Blacksmith.Solid placedBolt = asmBolt.place(Blacksmith.Frame.xy(new double[] {1, 2, 3}).toArray())) {
                if (!"bolt".equals(placedBolt.name())) fail("assembly: bolt.place(...).name() is not \"bolt\"");
            }
            try (Blacksmith.Solid colouredBolt = asmBolt.coloured(1, 0, 0)) {
                if (!"bolt".equals(colouredBolt.name())) fail("assembly: bolt.coloured(...).name() is not \"bolt\"");
            }
            try (Blacksmith.Solid cube = Blacksmith.Solid.cuboid(1, 1, 1);
                 Blacksmith.Solid joinedBolt = asmBolt.join(cube)) {
                if (joinedBolt.name() != null) fail("assembly: bolt.join(...).name() is not null");
            }
            try (Blacksmith.Solid freshCube = Blacksmith.Solid.cuboid(1, 1, 1)) {
                if (freshCube.name() != null) fail("assembly: a fresh cuboid's name() is not null");
            }
            System.out.println("assembly: named()/name() ride through one-source operations and drop through two-source ones");
        }
    }

    private static int countOf(String haystack, String needle) {
        int count = 0;
        for (int at = haystack.indexOf(needle); at >= 0; at = haystack.indexOf(needle, at + needle.length())) count++;
        return count;
    }

    // Frames: built, checked, and passed wherever twelve numbers go.
    private static void frames() {
        if (!Blacksmith.Frame.at(new double[3], new double[] {0, -1, 0}).equals(Blacksmith.Frame.xz())
                || !Blacksmith.Frame.at(new double[] {1, 2, 3}, new double[] {0, 0, 5}).equals(Blacksmith.Frame.xy(new double[] {1, 2, 3}))
                || !Blacksmith.Frame.xy().offset(5).equals(Blacksmith.Frame.xy(new double[] {0, 0, 5}))
                || !Arrays.equals(Blacksmith.Frame.yz().toArray(), Blacksmith.Workplane.yz().frame()))
            fail("Frame.at / xy / xz / offset disagree");
        try {
            new Blacksmith.Frame(new double[3], new double[] {1, 0, 0}, new double[] {0, 1, 0}, new double[] {0, 0, -1});
            fail("a left-handed frame did not throw");
        } catch (Blacksmith.BuildException e) {
            if (!e.getMessage().contains("left-handed")) fail("a left-handed frame: " + e.getMessage());
        }
        try (Blacksmith.Profile rect = Blacksmith.Profile.rect(10, 4);
             Blacksmith.Solid lid = Blacksmith.Solid.extrude(rect, Blacksmith.Frame.xy(new double[] {0, 0, 5}).toArray(), 2);
             Blacksmith.Solid wall = Blacksmith.Workplane.on(Blacksmith.Frame.xz(new double[] {0, 3, 0}).toArray()).extrude(rect, 1).solid()) {
            Blacksmith.Frame top = Blacksmith.Frame.of(lid.faceFrame(lid.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z))));
            Blacksmith.Bounds b = lid.bounds();
            if (Math.abs(b.min()[2] - 5) > 1e-6 || Math.abs(b.max()[2] - 7) > 1e-6 || Math.abs(wall.bounds().max()[1] - 3) > 1e-6
                    || Math.abs(top.origin()[2] - 7) > 1e-6 || Math.abs(top.z()[2] - 1) > 1e-9)
                fail("frames: lid " + Arrays.toString(b.min()) + ".." + Arrays.toString(b.max()) + ", top " + top);
        }
        System.out.println("frames: " + Blacksmith.Frame.at(new double[3], new double[] {1, 1, 1}) + ": ok");
    }

    // The sheet verbs: a face from a profile, a solid's face alone, faces dropped, a trim, a
    // rounded profile and a path along a curve -- checked by their face counts.
    private static void sheetVerbs(Blacksmith.Solid plate) {
        double[] xy = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        int top = plate.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z));
        try (Blacksmith.Profile square = Blacksmith.Profile.rect(20, 20);
             Blacksmith.Profile circle = Blacksmith.Profile.circle(4);
             Blacksmith.Solid sheet = Blacksmith.Solid.face(square, xy);
             Blacksmith.Solid peg = Blacksmith.Solid.extrude(circle, new double[] {0, 0, -6, 1, 0, 0, 0, 1, 0, 0, 0, 1}, 12);
             Blacksmith.Solid holed = sheet.trim(peg);
             Blacksmith.Solid disc = sheet.trim(peg, "inside");
             Blacksmith.Solid lid = plate.faceSheet(top);
             Blacksmith.Solid walls = plate.dropFaces(new int[] {0, 1});
             Blacksmith.Profile rounded = square.round(2);
             Blacksmith.Solid slab = Blacksmith.Solid.extrude(rounded, xy, 1);
             Blacksmith.Profile wave = Blacksmith.Profile.path(new double[] {0, 0})
                     .bezierTo(new double[] {20, 0}, new double[] {20, 20}, new double[] {40, 10}).endOpen();
             Blacksmith.SweepPath along = Blacksmith.SweepPath.along(wave, xy, 0.01, true);
             Blacksmith.Profile ring = Blacksmith.Profile.circle(1);
             Blacksmith.Solid tube = Blacksmith.Solid.sweep(ring, new double[] {0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0}, along);
             Blacksmith.Solid onPlane = Blacksmith.Workplane.xy().face(square).solid();
             Blacksmith.Solid away = peg.translate(100, 0, 0)) {
            if (sheet.faces() != 1 || holed.faces() < 1 || disc.faces() < 1 || lid.faces() != 1
                    || walls.faces() != plate.faces() - 2 || slab.faces() != 10 || !tube.isWatertight() || onPlane.faces() != 1)
                fail("sheet verbs: sheet=" + sheet.faces() + " holed=" + holed.faces() + " disc=" + disc.faces()
                        + " lid=" + lid.faces() + " walls=" + walls.faces() + " slab=" + slab.faces());
            try {
                sheet.trim(away, "inside").close();
                fail("a trim with nothing inside the tool did not throw");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().contains("trim: nothing of the sheet lies inside the tool")) fail("trim: " + e.getMessage());
            }
            // Chain: an L's two sides, the second drawn back to front, joined -- open, two walls.
            try (Blacksmith.Profile sideA = Blacksmith.Profile.path(new double[] {0, 0}).lineTo(10, 0).endOpen();
                 Blacksmith.Profile sideB = Blacksmith.Profile.path(new double[] {10, 8}).lineTo(10, 0).endOpen();
                 Blacksmith.Profile ell = Blacksmith.Profile.chain(List.of(sideA, sideB));
                 Blacksmith.Solid ellWalls = Blacksmith.Solid.extrudeOpen(ell, xy, 2)) {
                if (ellWalls.faces() != 2) fail("chain: an L extruded open has " + ellWalls.faces() + " walls, not 2");
            }
            // Close: the open L's first side and a line back -- closed, a triangle's three walls.
            try (Blacksmith.Profile openL = Blacksmith.Profile.path(new double[] {0, 0}).lineTo(10, 0).lineTo(10, 8).endOpen();
                 Blacksmith.Profile closedL = openL.closeLoop();
                 Blacksmith.Solid closedWalls = Blacksmith.Solid.extrudeOpen(closedL, xy, 2)) {
                if (closedWalls.faces() != 3) fail("close_loop: a closed L has " + closedWalls.faces() + " walls, not 3");
            }
            // Push-pull: a cube's top raised is one taller box, six faces, not a box and a prism.
            try (Blacksmith.Solid cube = Blacksmith.Solid.cuboid(10, 10, 10);
                 Blacksmith.Solid raised = cube.pushPull(cube.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z)), 5)) {
                if (raised.faces() != 6 || !raised.isWatertight()) fail("push_pull: the raised cube has " + raised.faces() + " faces, not 6");
                // Its top and a side pushed together: a 15 x 10 x 15 box, still six faces.
                int[] twoWays = {cube.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.Z)), cube.selectFace(Blacksmith.Selector.max(Blacksmith.Axis.X))};
                try (Blacksmith.Solid grown = cube.pushPull(twoWays, 5)) {
                    if (grown.faces() != 6 || !grown.isWatertight()) fail("push_pull: the cube grown two ways has " + grown.faces() + " faces, not 6");
                }
                // Quick solids: a coiled wire and a pipe close; a cube split by a plane is two bodies.
                try (Blacksmith.Profile unit = Blacksmith.Profile.circle(1);
                     Blacksmith.Profile wire = unit.translate(10, 0);
                     Blacksmith.Solid spring = Blacksmith.Solid.coil(wire, new double[] {0, 0, 0, 0, 0, 1}, 4, 2);
                     Blacksmith.SweepPath pipePath = Blacksmith.SweepPath.at(new double[] {0, 0, 0}).lineTo(new double[] {0, 0, 10});
                     Blacksmith.Solid pipe = Blacksmith.Solid.pipe(pipePath, 2, 0.5)) {
                    if (!spring.isWatertight()) fail("coil: the spring leaks");
                    if (pipe.faces() != 6) fail("pipe: the tube has " + pipe.faces() + " faces, not 6");
                    List<Blacksmith.Solid> halves = cube.splitByPlane(new double[] {2, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0});
                    if (halves.size() != 2 || halves.get(0).faces() != 6) fail("split_by_plane: " + halves.size() + " bodies, not 2");
                    for (Blacksmith.Solid half : halves) half.close();
                }
            }
            // From loops: a circle given before the square it lies in -- the square is the boundary.
            try (Blacksmith.Profile loopHole = Blacksmith.Profile.circle(4);
                 Blacksmith.Profile loopSquare = Blacksmith.Profile.rect(30, 30);
                 Blacksmith.Profile fromLoops = Blacksmith.Profile.fromLoops(List.of(loopHole, loopSquare));
                 Blacksmith.Solid holedSquare = Blacksmith.Solid.extrude(fromLoops, xy, 2)) {
                if (holedSquare.faces() != 8) fail("from_loops: the holed square has " + holedSquare.faces() + " faces, not 8");
            }
            // Revolve in plane: a plate drawn beside the y axis turns into a tube of four walls.
            try (Blacksmith.Profile beside = Blacksmith.Profile.polygon(new double[][] {{5, 0}, {8, 0}, {8, 10}, {5, 10}});
                 Blacksmith.Solid turned = Blacksmith.Solid.revolveInPlane(beside, xy, new double[] {0, 0}, new double[] {0, 1}, 2 * Math.PI);
                 Blacksmith.Solid turnedWalls = Blacksmith.Solid.revolveOpenInPlane(beside, xy, new double[] {0, 0}, new double[] {0, 1}, Math.PI)) {
                if (turned.faces() != 4 || !turned.isWatertight() || turnedWalls.faces() != 4) fail("revolve_in_plane: " + turned.faces() + " and " + turnedWalls.faces() + " faces, not 4");
            }
            // A hexagon: six walls and two caps. A closed spline through a square's corners: one wall.
            try (Blacksmith.Profile hexagon = Blacksmith.Profile.regularPolygon(new double[] {0, 0}, 10, 6);
                 Blacksmith.Solid hexPrism = Blacksmith.Solid.extrude(hexagon, xy, 2);
                 Blacksmith.Profile loopSpline = Blacksmith.Profile.spline(new double[][] {{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, null, true);
                 Blacksmith.Solid loopSolid = Blacksmith.Solid.extrude(loopSpline, xy, 2)) {
                if (hexPrism.faces() != 8 || loopSolid.faces() != 3 || !loopSolid.isWatertight()) fail("shapes: " + hexPrism.faces() + " and " + loopSolid.faces() + " faces, not 8 and 3");
            }
            // A five-pointed star: ten walls and two caps.
            try (Blacksmith.Profile star = Blacksmith.Profile.star(new double[] {0, 0}, 10, 4, 5);
                 Blacksmith.Solid starPrism = Blacksmith.Solid.extrude(star, xy, 2)) {
                if (starPrism.faces() != 12 || !starPrism.isWatertight()) fail("star: " + starPrism.faces() + " faces, not 12");
            }
            // Text: an `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring with spline edges.
            java.util.List<Blacksmith.Profile> word = Blacksmith.Profile.text("io", 10);
            try (Blacksmith.Solid textRing = Blacksmith.Solid.extrude(word.get(2), xy, 2)) {
                boolean spline = textRing.edges().stream().anyMatch(e -> e.kind().equals("nurbs"));
                if (word.size() != 3 || !textRing.isWatertight() || !spline) fail("text: " + word.size() + " shapes, spline edges " + spline);
            }
            for (Blacksmith.Profile p : word) p.close();
            // A reflector: the parabola from rim to rim, closed and revolved -- watertight.
            try (Blacksmith.Profile dish = Blacksmith.Profile.parabola(new double[] {0, 0}, new double[] {0, 1}, 20, 0, 50)
                    .lineTo(0, 31.25).lineTo(0, 0).end();
                 Blacksmith.Solid bowl = Blacksmith.Solid.revolveInPlane(dish, xy, new double[] {0, 0}, new double[] {0, 1}, 2 * Math.PI)) {
                if (!bowl.isWatertight()) fail("parabola: the bowl leaks");
            }
            // The library reads a fixed count of weights: a wrong count is refused, not read past.
            double[][] corners = {{0, 0}, {10, 0}, {10, 10}, {0, 10}};
            double[][] control = {{5, 5}, {10, 0}};
            double[] knots = {0, 0, 0, 1, 1, 1};
            try (Blacksmith.Profile weighted = Blacksmith.Profile.spline(corners, 3, new double[] {1, 2, 1, 1}, true);
                 Blacksmith.Profile rational = Blacksmith.Profile.path(new double[] {0, 0}).nurbsTo(control, knots, 2, new double[] {1, 0.5, 1}).endOpen()) {
                // built: the right counts pass
            }
            try (Blacksmith.Profile p = Blacksmith.Profile.spline(corners, 3, new double[] {1, 1}, true)) {
                fail("a short spline weight list was not refused");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("spline: 2 weights for 4 points; give one per point")) fail("a short weight list: " + e.getMessage());
            }
            try (Blacksmith.Path p = Blacksmith.Profile.path(new double[] {0, 0}).nurbsTo(control, knots, 2, new double[] {1, 1})) {
                fail("a short nurbs_to weight list was not refused");
            } catch (Blacksmith.BuildException e) {
                if (!e.getMessage().equals("nurbs_to: 2 weights for 3 control points (the current point and 2 given); give one per point")) fail("a short weight list: " + e.getMessage());
            }
            System.out.println("sheet verbs: face, trim (" + holed.faces() + "+" + disc.faces() + "), face_sheet, drop_faces, round ("
                    + slab.faces() + " faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, star, text, spline, parabola: ok");
        }
    }

    private static void fail(String why) {
        System.err.println(why);
        System.exit(1);
    }
}
