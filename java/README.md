# Java

`Cad.java` binds through the Foreign Function & Memory API, final since JDK 22
-- no JNI, no native glue, no preview flags. It finds the library in
`CADACLYSM_LIBRARY`, in `../lib/` or a `target/release/` in an ancestor of the
working directory.

    javac --release 22 -d classes java/Cad.java java/Blacksmith.java java/Smoke.java
    java --enable-native-access=ALL-UNNAMED -cp classes Smoke samples/cube.scad path/to/cadaclysm.lic



Coverage: see the release notes; the header is the reference.

## The kernel

`Blacksmith.java` binds the exact-geometry kernel through the same Foreign
Function & Memory API, found the same way. It keeps its own license state,
so a program using both classes licenses each one:

    try (Blacksmith.Profile hole = Blacksmith.Profile.circle(4);
         Blacksmith.Profile rect = Blacksmith.Profile.rect(80, 40);
         Blacksmith.Profile outline = rect.withHole(hole);
         Blacksmith.Solid plate = Blacksmith.Workplane.xy().extrude(outline, 6).solid();
         Blacksmith.Solid pin = Blacksmith.Workplane.fromSolid(plate)
                 .faces(Blacksmith.Selector.max(Blacksmith.Axis.Z)).onFace()
                 .cylinder(5, 10).solid();
         Blacksmith.Solid part = plate.join(pin);
         Blacksmith.Solid rounded = part.fillet(corners, 1.0)) {
        rounded.step("part.stp");
    }

A mesh or a polyline is a view onto the solid's own cache, not a copy: it
dies when the solid is closed, and it goes stale in place too -- meshing the
solid again at a different tolerance frees the memory an earlier view still
points at, so reading that view throws `IllegalStateException` even after
re-meshing back at the tolerance it was taken at.

Coverage: see the release notes; `include/cadaclysm_blacksmith.h` is the
reference.
