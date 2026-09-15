// Open one file through the Java binding and check what comes back. The exit code is
// the verdict: the release pipeline runs this against every library it ships.
public final class Smoke {
    public static void main(String[] args) {
        String path = args.length > 0 ? args[0] : "samples/cube.scad";
        if (args.length > 1 && !Cad.licenseSet(args[1])) fail("license: " + Cad.lastError());
        System.out.println("cadaclysm " + Cad.version() + " built " + Cad.buildDate());
        String info = Cad.licenseInfo();
        System.out.println("license: " + (info != null ? info : "none (" + Cad.lastError() + ")"));
        Cad scene = Cad.open(path, null, Cad.NATIVE);
        if (scene == null) fail(path + ": " + Cad.lastError());
        // Six floats: min x, y, z then max x, y, z.
        float[] b = scene.bounds();
        System.out.printf("bounds min=(%s,%s,%s) max=(%s,%s,%s)%n", b[0], b[1], b[2], b[3], b[4], b[5]);
        int triangles = 0;
        for (int part = 0; part < scene.partCount(); part++) {
            if (!scene.canMesh(part)) continue;
            Cad.Mesh mesh = scene.mesh(part);
            if (mesh != null) triangles += mesh.indices().length / 3;
        }
        System.out.println("triangles=" + triangles);
        scene.close();
        // All six bounds values, not just the three the brief's own draft checked: a bug that
        // only flips the Y axis (min/max swapped, or Y left at zero on both ends) still passes
        // min[0]/max[0]/max[2]/triangles alone, so every component of both corners is compared.
        boolean cube = b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 20 && b[4] == 20 && b[5] == 20;
        if (path.endsWith("cube.scad") && (!cube || triangles != 12))
            fail("the cube did not come back as a 20-unit cube of 12 triangles");
    }

    private static void fail(String why) {
        System.err.println(why);
        System.exit(1);
    }
}
