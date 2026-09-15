# Java

`Cad.java` binds through the Foreign Function & Memory API, final since JDK 22
-- no JNI, no native glue, no preview flags. It finds the library in
`CADACLYSM_LIBRARY`, in `../lib/` or a `target/release/` in an ancestor of the
working directory.

    javac --release 22 -d classes java/Cad.java java/Smoke.java
    java --enable-native-access=ALL-UNNAMED -cp classes Smoke samples/cube.scad path/to/cadaclysm.lic

Coverage: see the release notes; the header is the reference.
