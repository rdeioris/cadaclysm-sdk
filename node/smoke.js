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

  // STEP out needs the AP203 schema text, found beside the SDK or through
  // CADACLYSM_SCHEMAS; without it there is nothing to read back.
  let schema;
  try { schema = bs.defaultSchema(); } catch (e) { console.log(`STEP skipped: ${e.message}`); return; }
  const text = box.stepText(schema);
  console.log(`STEP: ${text.length} bytes with ${path.basename(schema)}`);
  box.close();

  // The reader, on the text the builder just wrote. The built-in schemas
  // read it on their own; the file found above is passed as well so a
  // library built before them reads it too.
  const built = cad.openMemory(text, 'stp', { schema, name: 'cuboid.stp' });
  try {
    const b = built.bounds;
    console.log(`scene: ${built.nodeCount} nodes, bounds min=(${fmt(b.min)}) max=(${fmt(b.max)})`);
    const size = b.size.map(Math.round);
    if (size.join() !== '10,20,30') throw new Error(`the cuboid did not come back 10 x 20 x 30, but ${size.join(' x ')}`);
  } finally { built.close(); }
}

try { main(); } catch (e) { console.error(e.message); process.exit(1); }
