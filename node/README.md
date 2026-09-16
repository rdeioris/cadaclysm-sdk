# cadaclysm for Node.js

The two cadaclysm C ABIs -- the CAD readers (`cadaclysm_capi`) and the
blacksmith B-rep builder (`cadaclysm_blacksmith`) -- as JavaScript objects,
over the shipped shared libraries. No compiled addon: the one dependency,
[`koffi`](https://koffi.dev), loads the same `.dll` / `.so` / `.dylib` every
other language uses. Node 18.18 or later (`Symbol.dispose`, and the `using`
declarations that call it, need it).

## Install

The package is not on npm. From your own project, install it from the SDK
checkout, after `fetch.py` has put the libraries in the SDK's `lib/`:

```bash
npm install /path/to/cadaclysm-sdk/node
```

and then, in your script:

```js
const cad = require('cadaclysm');
const bs = require('cadaclysm/blacksmith');
```

Or skip the install and require the files by path:

```js
const cad = require('/path/to/cadaclysm-sdk/node/cadaclysm.js');
const bs = require('/path/to/cadaclysm-sdk/node/cadaclysm_blacksmith.js');
```

(then `koffi` has to be installed where those files can find it: `npm install`
once in `cadaclysm-sdk/node`).

The wrappers find the libraries on their own: beside themselves, then in
`lib/` of any directory above (the SDK layout), then in `target/release` of
any directory above (the repository layout). Anywhere else, point them at the
libraries:

```bash
CADACLYSM_LIBRARY=/path/to/cadaclysm_capi.dll CADACLYSM_BLACKSMITH_LIBRARY=/path/to/cadaclysm_blacksmith.dll node my-script.js
```

Each variable takes the library itself or the directory holding it.

## The license

No license is needed to try it: without one the libraries run in full, with
a notice printed to stderr on every file opened (`open`, `openMemory`) and
every file written (a mesh export -- STL, Gmsh -- through `Node.saveMesh`,
or the kernel's STEP export) -- never on meshing, walking, or a kernel
operation in the middle of a modelling loop. For a per-seat license, put the
file where the library looks -- `CADACLYSM_LICENSE` naming it, or
`cadaclysm.lic` beside the executable or in the working directory -- or pass
it in:

```js
const cad = require('cadaclysm');
cad.license('/path/to/cadaclysm.lic');   // the text of the file works too
console.log(cad.licenseInfo());          // never null: the license line, or `unlicensed`
```

## Reading a file

```js
const cad = require('cadaclysm');

const scene = cad.open('model.stp');
for (const node of scene.walk()) {
  console.log('  '.repeat(node.depth) + node.label);
}
for (const node of scene.nodes()) {
  if (!node.canMesh) continue;
  const mesh = node.mesh();               // Float32Array positions/normals, Uint32Array indices
  console.log(node.label, mesh.triangleCount, 'triangles', node.bounds.size);
  node.saveMesh(`${node.index}.stl`);
}
scene.close();
```

Iterate `scene.placements()` to *draw* -- a block placed six times is one
node and six placements -- and nodes to build a tree. Every array is a copy;
keep it as long as you like.

Every schema the project ships -- the IFC releases, the STEP application
protocols -- is built into the library, so STEP and IFC open with no schema
given. `{ schema: 'house.exp' }` (or a directory of `.exp` files, matched
against what the file declares) adds to that set: a house schema, a newer IFC,
replacing a built-in of the same name.

## Building a solid

```js
const { Axis, Profile, Selector, Workplane } = require('cadaclysm/blacksmith');

const outline = Profile.rect(80, 40).withHole(Profile.circle(4)).withHole(Profile.slot([25, 0], 24, 5));
const plate = Workplane.xy().extrude(outline, 6).solid();
const pin = Workplane.fromSolid(plate).faces(Selector.max(Axis.Z)).workplane().cylinder(4, 10).solid();
const part = plate.join(pin);
const corners = part.edges().filter((e) => e.isLine && Math.abs(e.direction[2]) > 0.99);
part.fillet(corners, 1).step('plate.stp');
```

Every call returns a new `Solid`; `close()` frees one early. `join`, `cut`
and `common` take a tolerance (default `0.05`) and a progress callback.

Writing STEP -- `step()`, `stepText()`, `writeStep`, `writeStepText`,
`toScene()` -- needs the AP203 schema text, which the builder library does
not carry. With no `schema` argument, `defaultSchema()` finds it as
`$CADACLYSM_SCHEMAS/ap203.exp`, else `schemas/ap203.exp` in any directory
above the wrapper -- the SDK checkout's own `schemas/ap203.exp` -- and throws
naming what it looked for otherwise. Pass a path, or the schema's text, to
use another.

## Off the event loop

Opening a big file, `realizeAll()`, a heavy `mesh()`, and the builder's
booleans, fillets and shells can take seconds to minutes. Each has an
`...Async` twin returning a Promise and running on a worker thread:

```js
const scene = await cad.openAsync('big.stp');
const building = scene.realizeAllAsync();
const poll = setInterval(() => console.log(scene.realized, 'of', scene.realizeTotal), 500);
await building;                           // scene.cancel() stops it from the main thread
clearInterval(poll);
const mesh = await scene.node(3).meshAsync();
const part = await plate.joinAsync(pin, 0.05, (phase, done, total) => console.log(phase, done, total));
```

While an async call is in flight the scene (or solid) is locked: any other
call on it throws `busy: ... in progress`, `close()` included -- the promise
settles first. The exceptions are the three the library allows from another
thread: `cancel()`, and `realized` / `realizeTotal`, which is how a
`realizeAllAsync` is polled for progress. A progress callback that throws
rejects the call with its error, but the lock holds until the worker's own
reply arrives -- the C call is still reading those handles until then.

## TypeScript

Typings ship beside the modules: `import * as cad from 'cadaclysm'` and
`import * as bs from 'cadaclysm/blacksmith'`.

## Tests and the smoke program

```bash
npm test
node smoke.js [sample] [license]
```

`npm test` runs against the built libraries (`cargo build --release -p cadaclysm-capi -p cadaclysm-blacksmith-capi`
in the repository) with the CI license; it skips when they are not there.
`smoke.js` is the program the release pipeline runs against every release
and the SDK ships in `samples/`: `sample` defaults to `samples/cube.scad`
(relative to the working directory, as the Java and Go smokes do) and
`license` loads into both modules. It prints the version and build date,
opens `sample` with the reader and prints its bounds and meshed triangle
count -- checking both exactly when `sample` is a `cube.scad` -- then builds
a cuboid with the blacksmith, writes it as STEP, and opens that text back
with the reader to print its node count and bounds -- exiting non-zero on
any error. Read it for the smallest complete use of both modules.
