'use strict';
/**
 * The thread the `*Async` twins run on. One worker per library, started at the
 * first async call and kept; `unref`'d between calls so an idle one never
 * keeps the process alive.
 *
 * Why a worker rather than koffi's own `func.async()`: `cadaclysm_last_error`
 * is thread-local, so a failure's reason has to be read on the thread that
 * failed. Here every op is "the call, then `last_error`, on this thread".
 * Handles cross as their address (a BigInt) -- sound because the scene is
 * `Sync` and a solid is only ever touched by one thread at a time under the
 * owner's `_busy` lock.
 */
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');
const koffi = require('koffi');

if (isMainThread) {
  const workers = new Map(); // module name -> { worker, pending: Map<id, {resolve, reject, onProgress, onOrphan, failed}>, next }

  /** Drop `id` from `entry.pending`, and let the worker go idle once nothing is left. */
  function settle(entry, id) {
    entry.pending.delete(id);
    if (!entry.pending.size) entry.worker.unref();
  }

  function get(module) {
    let entry = workers.get(module);
    if (entry) return entry;
    const worker = new Worker(__filename, { workerData: { module } });
    entry = { worker, pending: new Map(), next: 1 };
    worker.on('message', (m) => {
      const p = entry.pending.get(m.id);
      if (!p) return;
      if (m.progress) {
        // A caller's callback is arbitrary code; if it throws, the call it was
        // watching is done for -- but the worker is still inside the C call,
        // reading the handles the caller's lock protects. So the entry stays
        // pending (the promise settles only when the worker's own reply lands,
        // and the owner's `finally` releases the lock then, not now); later
        // progress for this id is ignored, and the reply is rejected with the
        // callback's error, its result handed to `onOrphan` so the owning
        // module can free what nobody will ever hold.
        if (p.failed) return;
        try { p.onProgress?.(...m.progress); }
        catch (e) { p.failed = e; }
        return;
      }
      settle(entry, m.id);
      if (p.failed) {
        if ('result' in m) { try { p.onOrphan?.(m.result); } catch (_) { /* the reason below matters more */ } }
        p.reject(p.failed);
      } else if ('error' in m) p.reject(Object.assign(new Error(m.error), { workerErrorName: m.name }));
      else p.resolve(m.result);
    });
    // Both handlers only drop *this* entry: after an 'error' has already
    // replaced it, the stale 'exit' that follows must not delete the successor.
    worker.on('error', (e) => {
      for (const p of entry.pending.values()) p.reject(e);
      entry.pending.clear();
      if (workers.get(module) === entry) workers.delete(module);
    });
    // The worker dying outright (crash, forced termination) fires 'exit'
    // without ever firing 'error' for calls already in flight -- without this,
    // those promises would hang forever.
    worker.on('exit', (code) => {
      for (const p of entry.pending.values()) p.reject(new Error(`worker exited with code ${code}`));
      entry.pending.clear();
      if (workers.get(module) === entry) workers.delete(module);
    });
    worker.unref();
    workers.set(module, entry);
    return entry;
  }

  /**
   * Run `message` (`{ op, ... }`) on the `module` worker; typed-array buffers in
   * `transfer` move rather than copy. `onProgress` receives the worker's
   * progress messages; `onOrphan` receives a result that arrives after
   * `onProgress` threw (the call is rejected with that throw), so its owner can
   * free what the worker built.
   */
  function run(module, message, transfer = [], onProgress = null, onOrphan = null) {
    const entry = get(module);
    const id = entry.next++;
    return new Promise((resolve, reject) => {
      entry.pending.set(id, { resolve, reject, onProgress, onOrphan, failed: null });
      entry.worker.ref();
      try {
        entry.worker.postMessage({ id, ...message }, transfer);
      } catch (e) {
        // A non-cloneable value in `message` (an options object holding a
        // function, say) throws synchronously from `postMessage` itself --
        // the worker never sees this call, so undo the bookkeeping above.
        settle(entry, id);
        reject(e);
      }
    });
  }

  module.exports = { run };
} else {
  const mod = workerData.module === 'reader' ? require('./cadaclysm') : require('./cadaclysm_blacksmith');
  const buffersOf = (obj) => [...new Set(Object.values(obj).filter((v) => ArrayBuffer.isView(v)).map((v) => v.buffer))];

  const ops = workerData.module === 'reader' ? {
    open({ path: p, options }) { const { pointer, schemaPath } = mod._openRaw(p, options); return { address: koffi.address(pointer), schemaPath }; },
    openMemory({ bytes, format, options }) {
      const l = mod._lib();
      const pointer = l.open_memory(bytes, bytes.length, format, mod._options(options));
      if (!pointer) throw new mod.CadaclysmError(mod._lastError() || 'open_memory');
      return { address: koffi.address(pointer) };
    },
    // `address` (a BigInt) is accepted directly by koffi wherever a pointer argument
    // is expected -- `koffi.as()` cannot rebuild an external pointer from a raw
    // address (it only tags an existing value for a call), so there is nothing to
    // convert here.
    realizeAll({ address }) { return mod._lib().realize_all(address); },
    mesh({ address, node }) { return plain(mod._meshOf(mod._lib().node_mesh(address, node))); },
    meshLod({ address, node, level }) { return plain(mod._meshOf(mod._lib().node_mesh_lod(address, node, level))); },
    saveMesh({ address, node, path: p, format }) {
      if (!mod._lib().node_save_mesh(address, node, p, format)) throw new mod.CadaclysmError(mod._lastError() || `could not write ${p}`);
      return true;
    },
    save({ address, path: p, format }) {
      if (!mod._lib().scene_save(address, p, format)) throw new mod.CadaclysmError(mod._lastError() || `could not write ${p}`);
      return true;
    },
  } : {
    // `a`/`b`/`handles` are BigInt addresses, which koffi accepts directly
    // wherever a `CadaclysmBlacksmithSolid *` argument is expected -- no cast needed.
    combine({ which, a, b, tolerance }, progress) {
      const r = mod._lib()[which](a, b, tolerance, progress, null);
      if (!r) throw new mod.BuildError(mod._lastError() || which);
      return { address: koffi.address(r) };
    },
    trim({ a, b, keepInside, tolerance }, progress) {
      const r = mod._lib().trim(a, b, keepInside, tolerance, progress, null);
      if (!r) throw new mod.BuildError(mod._lastError() || 'trim');
      return { address: koffi.address(r) };
    },
    fillet({ a, edges, radius, tolerance }, progress) {
      const r = mod._lib().fillet(a, edges, edges.length, radius, tolerance, progress, null);
      if (!r) throw new mod.BuildError(mod._lastError() || 'fillet');
      return { address: koffi.address(r) };
    },
    chamfer({ a, edges, distance, tolerance }) {
      const r = mod._lib().chamfer(a, edges, edges.length, distance, tolerance);
      if (!r) throw new mod.BuildError(mod._lastError() || 'chamfer');
      return { address: koffi.address(r) };
    },
    shell({ a, thickness, open, tolerance }, progress) {
      const r = mod._lib().shell(a, thickness, open, open.length, tolerance, progress, null);
      if (!r) throw new mod.BuildError(mod._lastError() || 'shell');
      return { address: koffi.address(r) };
    },
    mesh({ a, tolerance }) {
      const m = mod._lib().mesh(a, tolerance);
      if (m.positions == null) throw new mod.BuildError(mod._lastError() || 'mesh');
      const n = m.vertex_count;
      return {
        positions: mod._floats(m.positions, n * 3) ?? new Float32Array(0),
        normals: mod._floats(m.normals, n * 3) ?? new Float32Array(0),
        indices: mod._uint32s(m.indices, m.index_count) ?? new Uint32Array(0),
        vertexCount: n, indexCount: m.index_count,
      };
    },
    step({ handles, schemaText, unit }) {
      const text = mod._lib().step(handles, handles.length, schemaText, unit);
      if (text == null) throw new mod.BuildError(mod._lastError() || 'step');
      return text;
    },
  };

  /** A `Mesh` as a plain object of typed arrays, for the structured clone. */
  function plain(mesh) { return { positions: mesh.positions, normals: mesh.normals, uvs: mesh.uvs, colors: mesh.colors, indices: mesh.indices, vertexCount: mesh.vertexCount, indexCount: mesh.indexCount }; }

  parentPort.on('message', (m) => {
    const progress = (phase, done, total) => parentPort.postMessage({ id: m.id, progress: [String(phase), Number(done), Number(total)] });
    try {
      const result = ops[m.op](m, m.withProgress ? progress : null);
      const transfer = result && typeof result === 'object' ? buffersOf(result).filter((b) => b.byteLength) : [];
      parentPort.postMessage({ id: m.id, result }, transfer);
    } catch (e) {
      parentPort.postMessage({ id: m.id, error: e.message || e.name, name: e.name });
    }
  });
}
