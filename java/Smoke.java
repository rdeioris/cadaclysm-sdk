// Open one file through the Java binding and check what comes back, then build a part
// through the kernel binding, write it as STEP and read it back. The exit code is the
// verdict: the release pipeline runs this against every library it ships.
import java.io.IOException;
import java.nio.FloatBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;

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
            }
            try (Cad.Scene fresh = Cad.open(path)) {
                Cad.Node body = null;
                for (Cad.Node n : fresh.walk()) if (n.canMesh()) { body = n; break; }
                if (body.isMeshed()) fail("a fresh scene is already meshed");
                if (fresh.realizeMeshes(false) == 0 || !body.isMeshed()) fail("realizeMeshes(false) did not build");
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

    private static double norm(double[] v) {
        return Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
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
                    + slab.faces() + " faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, spline: ok");
        }
    }

    private static void fail(String why) {
        System.err.println(why);
        System.exit(1);
    }
}
