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

/** front back left right top bottom iso, `[azimuth, elevation]` degrees each. */
export type SvgViewName = 'front' | 'back' | 'left' | 'right' | 'top' | 'bottom' | 'iso';
export declare const SvgView: Readonly<Record<SvgViewName, readonly [number, number]>>;

/** How an SVG drawing is made -- see `svgOptionsDefaults` for the defaults every field falls back to. */
export interface SvgOptions {
  /** Fills `azimuth`/`elevation` unless they are set directly. Default 'iso'. */
  view?: SvgViewName;
  /** Degrees about the up axis from +X, overriding `view`'s. -90 looks from -Y, the front. */
  azimuth?: number | null;
  /** Degrees above the horizon, overriding `view`'s. */
  elevation?: number | null;
  /** 'y' or 'z'; null keeps the scene's own convention (`Convention.UNITY`/`Convention.Y_UP` give 'y', every other 'z'). */
  up?: 'y' | 'z' | null;
  /** Vertical field of view in degrees; 0 (the default) is orthographic. */
  fov?: number;
  /** The page's viewBox, page units; 0 is 1000. */
  width?: number;
  height?: number;
  /** Fraction of the content's extent left each side. Default 0.05. */
  margin?: number;
  /** How far a written curve may stray, in page units. Default 0.1. */
  tolerance?: number;
  /** `'#rgb'`, `'#rrggbb'` or `[r, g, b]` in 0..255. Default '#000000'. */
  stroke?: string | ArrayLike<number>;
  /** The pen's width, page units. Default 1. */
  strokeWidth?: number;
  /** As `stroke`, or null (the default) for no `<rect>` behind the drawing. */
  background?: string | ArrayLike<number> | null;
  /** Each shape's feature edges. Default true. */
  edges?: boolean;
  /** Each shape's free curves. Default false. */
  curves?: boolean;
  /** Each shape's isocurves. Default false. */
  isocurves?: boolean;
  /** Straight segments within `tolerance` instead of fitted Béziers. Default false. */
  polylines?: boolean;
}
/** `SvgOptions`'s own defaults, as `cadaclysm_svg_options_init` fills them. */
export function svgOptionsDefaults(): Required<Pick<SvgOptions, 'view' | 'fov' | 'width' | 'height' | 'margin' | 'tolerance' | 'stroke' | 'strokeWidth' | 'edges' | 'curves' | 'isocurves' | 'polylines'>>
  & Pick<SvgOptions, 'azimuth' | 'elevation' | 'up' | 'background'>;

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
/** `Bounds` in `double`: the same box, unnarrowed -- exact far from the origin. */
export class Bounds64 {
  private constructor();
  min: Float64Array; max: Float64Array;
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
/** `Mesh` in `double`: the document's own mesh, copied out at call time as `mesh()`'s copy is -- positions/normals/uvs the exact f64 values `mesh()`'s `float` ones are narrowed from, colors stay `Float32Array`. */
export class Mesh64 {
  private constructor();
  positions: Float64Array; normals: Float64Array | null; uvs: Float64Array | null; colors: Float32Array | null;
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
/** `Beziers` in `double`: the same segments, unnarrowed. */
export class Beziers64 { private constructor(); points: Float64Array; weights: Float64Array; count: number }
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

/** A rigid body of the file's mechanism: the nodes that move together when a joint moves it. */
export class Link {
  private constructor();
  scene: Scene; index: number;
  equals(other: unknown): boolean;
  readonly name: string;
  nodes(): Node[];
}

/** A connection between two links of the file's mechanism. Topology only. */
export class Joint {
  private constructor();
  scene: Scene; index: number;
  equals(other: unknown): boolean;
  readonly name: string;
  readonly start: Link; readonly end: Link;
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
  /** `bounds` in `double`: exact far from the origin. */
  readonly bounds64: Bounds64;
  mesh(): Mesh;
  /** `mesh()` in `double`, copied at call time -- null with nothing to mesh; survives `Scene.forgetMeshes()` and `Scene.close()` as `mesh()`'s copy does. */
  mesh64(): Mesh64 | null;
  meshLod(level: number): Mesh;
  lodError(level: number): number;
  /**
   * This node's body meshed for a solver, as a `FemMesh` **owned by the caller**:
   * `free()` it, or `using` it. `tolerance` and `maxSize` default to
   * `FemOptions::default()`'s own **0.01 and 0**, not `mesh()`'s 0.05; `placement` is
   * 16 numbers, column-major, as `boundsPlaced` takes them, where the kernel's
   * `Solid.femMesh` takes twelve. Prints the unlicensed notice once, here.
   */
  femMesh(tolerance?: number, maxSize?: number, placement?: ArrayLike<number> | null): FemMesh;
  meshAsync(): Promise<Mesh>;
  meshAsync64(): Promise<Mesh64 | null>;
  meshLodAsync(level: number): Promise<Mesh>;
  surfaces(): Surfaces;
  readonly brep: Brep | null;
  edges(): Polylines; curves(): Polylines; isocurves(): Polylines;
  edgeColours(): (number[] | null)[];
  edgeBeziers(): Beziers; curveBeziers(): Beziers; isocurveBeziers(): Beziers;
  edgeBeziers64(): Beziers64; curveBeziers64(): Beziers64; isocurveBeziers64(): Beziers64;
  collision(hullBudget?: number): Collision | null;
  collisionHull(hullBudget?: number): CollisionHull;
  boundsPlaced(placement?: ArrayLike<number> | null): Bounds;
  boundsPlaced64(placement?: ArrayLike<number> | null): Bounds64;
  readonly isMeshed: boolean;
  surfaceEdges(): Polylines; surfaceEdgeBeziers(): Beziers; surfaceIsocurves(): Polylines;
  surfaceEdgeColours(): (number[] | null)[];
  surfacePick(from: ArrayLike<number>, to: ArrayLike<number>): number[] | null;
  surfaceProxyMesh(cells: number): Mesh;
  readonly triangleEstimate: number;
  saveMesh(path: string, format?: string): void;
  saveMeshAsync(path: string, format?: string): Promise<void>;
  svgText(options?: SvgOptions): string;
  svg(path: string, options?: SvgOptions): void;
  svgAsync(options?: SvgOptions): Promise<string>;
}

export class Scene {
  private constructor();
  path: string; schemaPath: string | null; convention: number;
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  readonly version: string; readonly schema: string; readonly schemaRead: string; readonly substituted: boolean;
  readonly sourceName: string | null;
  readonly metresPerUnit: number; readonly bounds: Bounds; readonly bounds64: Bounds64; readonly surfaceMatrix: Float32Array;
  diagnostics(): string[]; geometryDiagnostics(): string[];
  readonly nodeCount: number;
  node(index: number): Node; nodes(): Node[]; roots(): Node[];
  walk(): IterableIterator<Node>;
  query(filter: string): number[];
  placements(): Placement[];
  links(): Link[]; joints(): Joint[];
  realizeAll(): number;
  realizeAllAsync(): Promise<number>;
  realizeMeshes(skipSurfaced?: boolean): number;
  readonly realized: number; readonly realizeTotal: number;
  cancel(): void;
  forgetMeshes(): void;
  /** `format`: `'glb'` (the default), `'gltf'` or `'obj'`. */
  save(path: string, format?: string): void;
  saveAsync(path: string, format?: string): Promise<void>;
  svgText(options?: SvgOptions): string;
  svg(path: string, options?: SvgOptions): void;
  svgAsync(options?: SvgOptions): Promise<string>;
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

/**
 * One B-rep edge of a `FemMesh`: `nodes` in order along the edge, `runs` saying where
 * the chain breaks (`chains()` cuts it), `faces` and `ends` (`[a, b]`, the second
 * `NONE` where there is none -- `0` is a real face and a real vertex), `closed`, `seam`,
 * and `id`, the **body's own** edge id rather than this mesh's index.
 */
export class FemEdge {
  private constructor();
  id: number;
  nodes: Uint32Array; runs: Uint32Array;
  faces: [number, number]; ends: [number, number];
  closed: boolean; seam: boolean;
  /** `nodes` cut into one polyline per run, as views into it; nothing joined across a run boundary. */
  chains(): Uint32Array[];
}
/**
 * One B-rep vertex of a `FemMesh`: `node` is the mesh node there or `NONE` (ordinary,
 * not a fault), `point` where the topology says it is -- **meaningless unless
 * `hasPosition`**, when it is all zeros.
 */
export class FemVertex {
  private constructor();
  node: number;
  point: Float64Array;
  hasPosition: boolean;
}
/**
 * One body meshed for a solver: what `Node.femMesh` returns, **owned by the caller**.
 * Every array is a fresh copy decoded at call time, as `Node.mesh()`'s typed arrays are
 * -- so one in hand survives `free()`, `Scene.close()` and the collector, and nothing of
 * the library's is left in it to go stale. A call on a freed handle throws.
 */
export class FemMesh {
  private constructor();
  readonly freed: boolean;
  free(): void;
  [Symbol.dispose](): void;
  nodes(): Float64Array;
  triangles(): Uint32Array;
  triangleFace(): Uint32Array;
  nodeKind(): Uint32Array;
  nodeEntity(): Uint32Array;
  readonly faceCount: number;
  edges(): FemEdge[];
  vertices(): FemVertex[];
  /** Every crack, as `[a, b, brepEdge]`; `brepEdge` is `NONE` where the two nodes share none. */
  openEdges(): [number, number, number][];
  /** Every fold, as `openEdges` reports a crack. A body can be folded without being open. */
  foldedEdges(): [number, number, number][];
  readonly watertight: boolean;
  readonly fromMesh: boolean;
  readonly minAngle: number;
  readonly worstTriangle: number;
  readonly longestEdge: number;
  /** Gmsh 4.1 ASCII `.msh` text. The library's is borrowed from the handle here; koffi copies it out, so this string is yours. No unlicensed notice -- `Node.femMesh` gave it. */
  mshText(): string;
  saveMsh(path: string): void;
}
