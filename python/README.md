# Python

The quickest way in is pip:

    pip install cadaclysm            # the reader and the kernel, with their libraries
    pip install "cadaclysm[numpy]"   # plus numpy, for mesh arrays

    import cadaclysm                 # the reader
    from cadaclysm import blacksmith # the kernel (or: import cadaclysm_blacksmith)

Wheels for Windows x64, macOS 11+ (Apple silicon and Intel) and Linux x64 and
arm64 (glibc 2.17+), Python 3.8 or later; each carries the libraries of one
release, so the modules and the libraries always match.
<https://pypi.org/project/cadaclysm/>

Without pip, use the files here: `cadaclysm.py` (import and meshing) and
`cadaclysm_blacksmith.py` (the exact kernel) are single-file ctypes bindings:
copy them into your project, or add this directory to `sys.path`. They find
the library in `../lib/` (this checkout), in `CADACLYSM_LIBRARY`, or beside
themselves. numpy is used for mesh arrays.

    import sys; sys.path.insert(0, "python")
    import cadaclysm as c
    c.license("path/to/cadaclysm.lic")          # or CADACLYSM_LICENSE
    scene = c.open("samples/cube.scad")
    print(scene.bounds)
    for node in scene.nodes:
        if node.can_mesh:
            mesh = node.mesh
            print(node.name, mesh.triangle_count, "triangles")

Coverage: see the release notes. The docstrings in the file are the reference.
