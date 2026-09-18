/// <reference types="node" />
/** The cadaclysm C ABI for Node.js. See cadaclysm.js for the semantics. */

// `Symbol.dispose` (explicit resource management) is TS >= 5.2 and needs the
// `esnext.disposable` lib; this shim lets `[Symbol.dispose]` type-check under
// a plain `--target es2022` without requiring callers to change their `lib`.
declare global { interface SymbolConstructor { readonly dispose: unique symbol } }

export class CadaclysmError extends Error {}
export const NONE: number;

export declare const Convention: {
  readonly NATIVE: 0; readonly UNREAL: 1; readonly UNITY: 2; readonly Y_UP: 3; readonly BLENDER: 4;
  readonly FILE_UNITS: 0x100; readonly UV_WORLD: 0x200;
  parse(text: string): number;
};
export type ValueKind = 0 | 1 | 2 | 3 | 4 | 5 | 6;
export declare const ValueKind: { readonly NONE: 0; readonly TEXT: 1; readonly INTEGER: 2; readonly REAL: 3; readonly BOOLEAN: 4; readonly LIST: 5; readonly REFERENCE: 6 };

export function libraryPath(): string;
export function version(): string;
export function buildDate(): string;
export function license(textOrPath: string): void;
export function licenseInfo(): string;
export function licenseNoticeCount(): number;
export function meshFormats(): [name: string, extension: string, label: string][];
export function formats(): [name: string, extensions: string[]][];
export function lodLevels(): number;
export function pickFile(): string | null;
export function pickSave(suggestedName?: string): string | null;
export function declaredSchema(model: string): string;
export function resolveSchema(model: string, schema: string | null | undefined): { chosen: string | null; fallbacks: string[] };

export interface OpenOptions {
  /** An `.exp` file, or a directory of them matched against the file's FILE_SCHEMA. */
  schema?: string | null;
  /** A `Convention` value, OR'd with `Convention.FILE_UNITS` / `Convention.UV_WORLD`. */
  convention?: number;
  colors?: boolean;
  sourceMetersPerUnit?: number;
}
export interface OpenMemoryOptions extends OpenOptions { name?: string }
export type Bytes = Buffer | Uint8Array | ArrayBuffer | string;

export function open(path: string, options?: OpenOptions): Scene;
export function openMemory(bytes: Bytes, format: string, options?: OpenMemoryOptions): Scene;
export function openAsync(path: string, options?: OpenOptions): Promise<Scene>;
export function openMemoryAsync(bytes: Bytes, format: string, options?: OpenMemoryOptions): Promise<Scene>;

export class Bounds {
  private constructor();
  min: Float32Array; max: Float32Array;
  readonly isEmpty: boolean; readonly size: number[]; readonly centre: number[];
}
export class Attribute {
  private constructor();
  name: string; kind: ValueKind; value: string | number | boolean | null;
  readonly text: string;
}
export class Mesh {
  private constructor();
  positions: Float32Array; normals: Float32Array | null; uvs: Float32Array | null; colors: Float32Array | null;
  indices: Uint32Array; vertexCount: number; indexCount: number;
  readonly triangleCount: number;
}
export class Polylines {
  private constructor();
  positions: Float32Array; counts: Uint32Array; polylineCount: number; vertexCount: number;
  segmentIndices(): Uint32Array;
  segments(): Float32Array;
}
export class Beziers { private constructor(); points: Float32Array; weights: Float32Array; count: number }
export class Face {
  private constructor();
  kind: number; reversed: boolean; transposed: boolean;
  origin: Float32Array; ax: Float32Array; ay: Float32Array; az: Float32Array;
  domain: Float32Array; scalars: Float32Array;
  loops: Float32Array[]; profile: Float32Array; profile2: Float32Array; nurbs: Float32Array;
}
export class Surfaces implements Iterable<Face> {
  private constructor();
  faces: Face[];
  readonly length: number;
  [Symbol.iterator](): Iterator<Face>;
}
export class Collision {
  private constructor();
  shape: number; confidence: number; axis: number;
  frame: Float64Array; halfExtent: Float64Array;
  radius: number; height: number; error: number;
  hullVertexCount: number; hullIndexCount: number;
  readonly shapeName: string;
}
export class CollisionHull { private constructor(); positions: Float32Array; indices: Uint32Array; vertexCount: number; indexCount: number }

/** A body's exact B-rep, shared with the scene; for `Solid.fromNode`. `release()` gives the reference back. */
export class Brep {
  private constructor();
  readonly pointer: unknown;
  readonly released: boolean;
  static layoutId(): string;
  readonly manifold: Manifold;
  release(): void;
}

/** Whether a brep's faces make a manifold, read off its topology (`Brep.manifold`). */
export interface Manifold {
  faces: number; edges: number; vertices: number;
  boundaryEdges: number; nonManifoldEdges: number; nonManifoldVertices: number;
  isManifold: boolean; isClosed: boolean;
}

export class Placement {
  private constructor();
  scene: Scene; index: number;
  readonly geometry: Node; readonly select: Node;
  readonly rawTransform: Float64Array; readonly transform: number[][];
}

export class Node {
  private constructor();
  scene: Scene; index: number;
  equals(other: unknown): boolean;
  readonly name: string; readonly id: string; readonly kind: string; readonly label: string;
  readonly depth: number; readonly generator: string;
  readonly visible: boolean; readonly visibleNow: boolean; readonly locked: boolean; readonly canMesh: boolean;
  readonly parent: Node | null; readonly instanceOf: Node | null; readonly selectAs: Node;
  children(): Node[];
  walk(): IterableIterator<Node>;
  attributes(): Attribute[];
  readonly color: number[] | null;
  readonly rawTransform: Float64Array; readonly transform: number[][];
  readonly bounds: Bounds;
  mesh(): Mesh;
  meshLod(level: number): Mesh;
  lodError(level: number): number;
  meshAsync(): Promise<Mesh>;
  meshLodAsync(level: number): Promise<Mesh>;
  surfaces(): Surfaces;
  readonly brep: Brep | null;
  edges(): Polylines; curves(): Polylines; isocurves(): Polylines;
  edgeBeziers(): Beziers; curveBeziers(): Beziers; isocurveBeziers(): Beziers;
  collision(hullBudget?: number): Collision | null;
  collisionHull(hullBudget?: number): CollisionHull;
  saveMesh(path: string, format?: string): void;
  saveMeshAsync(path: string, format?: string): Promise<void>;
}

export class Scene {
  private constructor();
  path: string; schemaPath: string | null; convention: number;
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  readonly version: string; readonly schema: string; readonly schemaRead: string; readonly substituted: boolean;
  readonly sourceName: string | null;
  readonly metresPerUnit: number; readonly bounds: Bounds; readonly surfaceMatrix: Float32Array;
  diagnostics(): string[]; geometryDiagnostics(): string[];
  readonly nodeCount: number;
  node(index: number): Node; nodes(): Node[]; roots(): Node[];
  walk(): IterableIterator<Node>;
  query(filter: string): number[];
  placements(): Placement[];
  realizeAll(): number;
  realizeAllAsync(): Promise<number>;
  readonly realized: number; readonly realizeTotal: number;
  cancel(): void;
  forgetMeshes(): void;
  /** `format`: `'glb'` (the default), `'gltf'` or `'obj'`. */
  save(path: string, format?: string): void;
  saveAsync(path: string, format?: string): Promise<void>;
}

export interface Meshlet {
  index: number; level: number; group: number; error: number;
  vertexCount: number; triangleCount: number;
  positions: Float32Array; normals: Float32Array; indices: Uint32Array; children: Uint32Array;
}
export class Meshlets {
  private constructor();
  static build(positions: ArrayLike<number>, normals: ArrayLike<number> | null, indices: ArrayLike<number>, limits: { maxTriangles: number; maxVertices: number; levels?: number }): Meshlets;
  readonly count: number;
  triangleCount(i: number): number; vertexCount(i: number): number; level(i: number): number; group(i: number): number; error(i: number): number; childCount(i: number): number;
  meshlet(i: number): Meshlet;
  free(): void;
  [Symbol.dispose](): void;
}
