# Python

`cadaclysm.py` (import and meshing) and `cadaclysm_blacksmith.py` (the exact
kernel) are single-file ctypes bindings: copy them into your project, or add
this directory to `sys.path`. They find the library in `../lib/` (this
checkout), in `CADACLYSM_LIBRARY`, or beside themselves. numpy is used for
mesh arrays.

    import sys; sys.path.insert(0, "python")
    import cadaclysm as c
    c.license("path/to/cadaclysm.lic")          # or CADACLYSM_LICENSE
    scene = c.open("samples/cube.scad")
    print(scene.bounds)
    for node in scene.nodes():
        if node.can_mesh:
            mesh = node.mesh()
            print(node.name, len(mesh.indices) // 3, "triangles")

Coverage: see the release notes. The docstrings in the file are the reference.
