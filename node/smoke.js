'use strict';
// The smallest complete use of both modules, and the verdict on a shipped
// library: the release pipeline runs this against every library it ships, and
// the SDK carries it in `samples/`. The exit code is the result -- anything
// thrown, from either library, exits 1.
//
//     node smoke.js [sample] [license]
//
// `sample` defaults to `samples/cube.scad`, relative to the working
// directory, as the Java and Go smokes do. `license` -- CADACLYSM_LICENSE /
// cadaclysm.lic as the libraries look for it otherwise -- is loaded into
// both modules.
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

/** The wrapper `name` beside this file (`node/`), beside a sibling `node/` (the SDK's `samples/`), or installed. */
function load(name) {
  const tried = [];
  for (const candidate of [path.join(__dirname, name), path.join(__dirname, '..', 'node', name), name === 'cadaclysm' ? 'cadaclysm' : 'cadaclysm/blacksmith']) {
    try { return require(candidate); } catch (e) {
      // Only *this* module missing moves on; a wrapper found but failing to
      // load (koffi not installed, say) is the real news.
      if (e.code !== 'MODULE_NOT_FOUND' || !e.message.split('\n')[0].includes(candidate)) throw e;
      tried.push(candidate);
    }
  }
  throw new Error(`${name} not found; tried ${tried.join(', ')}`);
}

const cad = load('cadaclysm');
const bs = load('cadaclysm_blacksmith');

const fmt = (v) => Array.from(v, (x) => Number(x.toFixed(4))).join(', ');

/**
 * One body meshed for a solver, whichever library built it: the flat arrays agree
 * with the counts, and the `.msh` text comes back the same twice.
 *
 * **That second ask is why asking at all is worth a line in a smoke.** The
 * reader's text is a slot borrowed from the handle; the kernel's is an owned
 * string the wrapper must release with `cadaclysm_blacksmith_string_free`. A
 * missed release leaks silently and a doubled one takes the process down, so two
 * equal texts is the one check that separates the two conventions at run time.
 */
function femCheck(mesh, what) {
  const nodes = mesh.nodes(), triangles = mesh.triangles();
  if (!nodes.length || nodes.length % 3 || triangles.length % 3) throw new Error(`${what}: the nodes or triangles are not triples`);
  if (mesh.nodeKind().length !== nodes.length / 3 || mesh.triangleFace().length !== triangles.length / 3) {
    throw new Error(`${what}: the arrays disagree with the counts`);
  }
  const text = mesh.mshText();
  if (!text.startsWith('$MeshFormat')) throw new Error(`${what}: the .msh text is not Gmsh 4.1 ASCII`);
  if (mesh.mshText() !== text) throw new Error(`${what}: two asks for the same mesh's .msh text disagree`);
  console.log(`${what}: ${nodes.length / 3} nodes, ${triangles.length / 3} triangles, ${mesh.edges().length} edges, `
    + `watertight=${mesh.watertight}, fromMesh=${mesh.fromMesh}, longestEdge=${mesh.longestEdge.toFixed(4)}`);
  return nodes.length / 3;
}

function main() {
  const sample = process.argv[2] || 'samples/cube.scad';
  const licensePath = process.argv[3];
  if (licensePath) { cad.license(licensePath); bs.license(licensePath); }
  console.log(`cadaclysm ${cad.version()} built ${cad.buildDate()}`);
  console.log(`license: ${cad.licenseInfo() ?? 'none'}`);

  // The reader: open the sample, print its bounds and the meshed triangle
  // count, and -- for the shared cube.scad fixture -- check both exactly.
  const scene = cad.open(sample);
  let bounds, triangles;
  try {
    bounds = scene.bounds;
    console.log(`bounds min=(${fmt(bounds.min)}) max=(${fmt(bounds.max)})`);
    triangles = scene.nodes().filter((n) => n.canMesh).reduce((sum, n) => sum + n.mesh().triangleCount, 0);
    console.log(`triangles=${triangles}`);
    // The solver mesh of the first body that can be meshed, and its `.msh` text.
    // A FEM mesh is a handle of its own: the scene's `close()` below neither frees
    // it nor stales it, which is why this one is freed by hand.
    const body = scene.nodes().find((n) => n.canMesh);
    if (body) {
      const fem = body.femMesh();
      try { femCheck(fem, 'fem (reader)'); } finally { fem.free(); }
    }
    // The scene saved as a Rhino .3dm (its meshes), read back to the same meshable nodes.
    const sceneRhino = path.join(os.tmpdir(), `cadaclysm-smoke-node-${process.pid}.3dm`);
    scene.save(sceneRhino, '3dm');
    const savedRhino = cad.open(sceneRhino);
    try {
      const meshable = savedRhino.nodes().filter((n) => n.canMesh).length;
      if (!meshable || meshable !== scene.nodes().filter((n) => n.canMesh).length) throw new Error(`save 3dm: the scene reads back with ${meshable} meshable nodes`);
      console.log(`save 3dm: ${meshable} meshable node(s) read back`);
    } finally { savedRhino.close(); fs.rmSync(sceneRhino, { force: true }); }
  } finally { scene.close(); }
  if (sample.endsWith('cube.scad')) {
    const cube = [0, 1, 2].every((i) => bounds.min[i] === 0 && bounds.max[i] === 20);
    if (!cube || triangles !== 12) throw new Error(`the cube did not come back as a 20-unit cube of 12 triangles`);
  }

  // The builder: an exact B-rep solid, its faces and its box.
  const box = bs.Solid.cuboid(10, 20, 30);
  const [lo, hi] = box.bounds;
  console.log(`cuboid: ${box.faces} faces, bounds min=(${fmt(lo)}) max=(${fmt(hi)})`);
  if (box.faces !== 6) throw new Error(`a cuboid has 6 faces, not ${box.faces}`);

  // The kernel's own solver mesh, and the placement asymmetry: **twelve** numbers
  // here where the reader's `femMesh` takes sixteen column-major. A quarter turn
  // about z then 100 along x, so (x, y, z) -> (100 - y, x, z); the box is built at
  // the origin and moved to (30, 7, 5) first, because a body centred on the
  // rotation's own axis maps onto itself and the check would say nothing.
  const placed = bs.Solid.cuboid(20, 10, 4).translate(30, 7, 5);
  const fem = placed.femMesh(0.05, 0, [100, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, 1]);
  try {
    femCheck(fem, 'fem (kernel)');
    const xs = [], ys = [];
    const nodes = fem.nodes();
    for (let i = 0; i < nodes.length; i += 3) { xs.push(nodes[i]); ys.push(nodes[i + 1]); }
    const want = [88, 98, 20, 40];
    const got = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
    if (got.some((v, i) => Math.abs(v - want[i]) > 1e-6)) {
      throw new Error(`the frame did not turn the cuboid into x 88..98, y 20..40, but x ${got[0]}..${got[1]}, y ${got[2]}..${got[3]}`);
    }
    console.log(`fem (kernel): the frame turns and moves the cuboid into x ${got[0]}..${got[1]}, y ${got[2]}..${got[3]}`);
  } finally { fem.free(); placed.close(); }

  // A Rhino .3dm, bytes and file, read back through the reader -- the file with
  // `Solid.openAll`, the bytes with `openMemory` and `Solid.fromNode` -- to the box's six
  // faces and its volume.
  const rhino = box.rhino3dmBytes();
  if (!rhino.subarray(0, 24).equals(Buffer.from('3D Geometry File Format '))) throw new Error('3dm: the bytes are not an openNURBS file');
  const rhinoPath = path.join(os.tmpdir(), `cadaclysm-smoke-node-brick-${process.pid}.3dm`);
  try {
    box.write3dm(rhinoPath);
    if (!fs.readFileSync(rhinoPath).equals(rhino)) throw new Error('3dm: the file is not the bytes');
    const brick = (s, what) => {
      const volume = s.mass().volume;
      if (s.faces !== 6 || Math.abs(volume - 6000) > 6e-6) throw new Error(`3dm: ${what} reads back as ${s.faces} faces, volume ${volume}`);
    };
    const back = bs.Solid.openAll(rhinoPath);
    if (back.length !== 1) throw new Error(`3dm: the file reads back as ${back.length} solids`);
    brick(back[0], 'the file');
    back[0].close();
    const memory = cad.openMemory(rhino, '3dm', { name: 'brick.3dm' });
    try {
      const bodies = memory.nodes().filter((n) => n.canMesh);
      if (bodies.length !== 1) throw new Error(`3dm: the bytes open as ${bodies.length} meshable nodes`);
      const fromBytes = bs.Solid.fromNode(memory, bodies[0]);
      brick(fromBytes, 'the bytes');
      fromBytes.close();
    } finally { memory.close(); }
  } finally { fs.rmSync(rhinoPath, { force: true }); }
  console.log(`3dm: ${rhino.length} bytes, read back to 6 faces and 6000 mm3`);

  // STEP out, with no schema: the kernel writes against its own built-in AP203.
  const text = box.stepText();
  console.log(`STEP: ${text.length} bytes with the built-in AP203`);
  box.close();

  // The reader, on the text the builder just wrote. With no schema, it reads
  // against its own built-in AP203 too.
  const built = cad.openMemory(text, 'stp', { name: 'cuboid.stp' });
  try {
    const b = built.bounds;
    console.log(`scene: ${built.nodeCount} nodes, bounds min=(${fmt(b.min)}) max=(${fmt(b.max)})`);
    const size = b.size.map(Math.round);
    if (size.join() !== '10,20,30') throw new Error(`the cuboid did not come back 10 x 20 x 30, but ${size.join(' x ')}`);
  } finally { built.close(); }

  // Tolerances: hole2.3dm (a root sample beside samples/, scripts/link-samples.py) declares an
  // absolute 0.01 and one degree; a boolean given a null tolerance works at the inputs'
  // effective one, declares nothing for built primitives, and is the explicit-effective boolean.
  const hole2 = path.join(path.dirname(path.dirname(path.resolve(sample))), 'hole2.3dm');
  if (require('node:fs').existsSync(hole2)) {
    const declared = cad.open(hole2);
    try {
      const t = declared.tolerances;
      if (t.absolute !== 0.01 || t.angular !== 0.017453292519943295) throw new Error(`hole2.3dm declares ${JSON.stringify(t)}`);
    } finally { declared.close(); }
  } else if (!process.env.CADACLYSM_SAMPLES_OPTIONAL) {
    throw new Error(`${hole2} is missing: run scripts/link-samples.py`);
  }
  const block = bs.Solid.cuboid(10, 10, 10);
  const pin = bs.Solid.cylinder(3, 20).translate(0, 0, -5);
  const at = bs.effectiveTolerance(block, pin);
  if (!(Math.abs(at - 1e-4 * 20) < 1e-3)) throw new Error(`effective_tolerance reads ${at}`);
  const unset = block.cut(pin, null);
  const explicit = block.cut(pin, at);
  const none = unset.tolerances;
  if (none.absolute !== null || none.angular !== null) throw new Error(`an unset cut declares ${JSON.stringify(none)}`);
  if (unset.mass(1e-7).volume !== explicit.mass(1e-7).volume) throw new Error('an unset cut is not the explicit-effective one');
  if (unset.mesh(null).indexCount !== explicit.mesh(bs.effectiveTolerance(explicit)).indexCount) throw new Error('an unset mesh is not the explicit-effective one');
  const loose = block.withTolerances(0.1);
  if (loose.tolerances.absolute !== 0.1 || loose.tolerances.angular !== null || bs.effectiveTolerance(loose, pin) !== 0.1) throw new Error('with_tolerances: 0.1 is not declared');
  if (loose.cut(pin, 0).tolerances.absolute !== 0.1) throw new Error('a cut does not inherit the loosest declaration');
  if (block.vertexTolerance([5, 5, 5]) !== null) throw new Error('a built cuboid records a vertex tolerance');
  let refusedNegative = '';
  try { block.withTolerances(-1); } catch (e) { refusedNegative = e.message; }
  if (!refusedNegative.startsWith('solid_with_tolerances: ')) throw new Error(`with_tolerances: -1 reads '${refusedNegative}'`);
  if (bs.effectiveTolerance() !== 0) throw new Error('effective_tolerance of nothing is not 0');
  console.log(`tolerances: effective ${at}, an unset cut is the explicit one`);
}

try { main(); } catch (e) { console.error(e.message); process.exit(1); }
