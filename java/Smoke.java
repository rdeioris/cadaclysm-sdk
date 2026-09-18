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
            try (Blacksmith.Solid rounded = part.fillet(corners, 1.0)) {
                released = rounded;
                int faces = rounded.faces();
                boolean watertight = rounded.isWatertight();
                System.out.println("faces=" + faces + " watertight=" + watertight);
                if (!watertight) fail("the filleted part is not watertight");
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

                // The plate is 80 x 40 x 6 centred on the origin and the pin adds 10, so the
                // far corner sits at (40, 20, 16) -- checked on the kernel's own bounds, on
                // the STEP read back through the reader, and on toScene's scene.
                Blacksmith.Bounds own = rounded.bounds();
                if (!near(own.max(), 40, 20, 16)) fail("the kernel's own bounds are off: " + Arrays.toString(own.max()));

                Path step = Files.createTempFile("cadaclysm-smoke", ".stp");
                rounded.step(step.toString());
                try (Cad.Scene back = Cad.open(step.toString())) {
                    float[] max = back.bounds().max();
                    System.out.printf("step read back: bounds max=(%s,%s,%s)%n", max[0], max[1], max[2]);
                    if (!near(max, 40, 20, 16)) fail("the STEP did not read back as the plate with its pin");
                }

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

    private static void fail(String why) {
        System.err.println(why);
        System.exit(1);
    }
}
