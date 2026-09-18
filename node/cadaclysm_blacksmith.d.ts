/// <reference types="node" />
/** The cadaclysm_blacksmith C ABI for Node.js. See cadaclysm_blacksmith.js for the semantics. */
import type { Node, Scene } from './cadaclysm';

export class BuildError extends Error {}
export const NONE: number;
export const UNITS: { readonly m: 0; readonly mm: 1; readonly in: 2 };
export type Unit = keyof typeof UNITS;
export declare const Axis: { readonly X: 0; readonly Y: 1; readonly Z: 2 };
export type AxisValue = 0 | 1 | 2;

/** A `Frame`, twelve numbers (origin, x, y, z) or four triples. */
export type FrameLike = Frame | ArrayLike<number> | [ArrayLike<number>, ArrayLike<number>, ArrayLike<number>, ArrayLike<number>];
/** Six numbers (point, direction) or two triples. */
export type AxisLine = ArrayLike<number> | [ArrayLike<number>, ArrayLike<number>];
export type Point2 = [number, number] | ArrayLike<number>;
export type Point3 = [number, number, number] | ArrayLike<number>;
export type Progress = (phase: string, done: number, total: number) => void;

export function libraryPath(): string;
export function defaultSchema(): string;
export function version(): string;
export function buildDate(): string;
export function license(textOrPath: string): void;
export function licenseInfo(): string;
export function licenseNoticeCount(): number;

export class Profile {
  private constructor();
  static rect(w: number, h: number): Profile;
  static circle(r: number): Profile;
  static slot(centre: Point2, length: number, r: number): Profile;
  static polygon(points: Point2[]): Profile;
  static regularPolygon(centre: Point2, radius: number, sides: number, angle?: number): Profile;
  static spline(points: Point2[], degree?: number, weights?: ArrayLike<number> | null, closed?: boolean): Profile;
  static path(start: Point2): Path;
  static chain(pieces: Iterable<Profile>, tolerance?: number): Profile;
  static fromLoops(loops: Iterable<Profile>): Profile;
  closeLoop(): Profile;
  withHole(hole: Profile): Profile;
  translate(dx: number, dy: number): Profile;
  round(radius: number, corners?: Iterable<number> | null, open?: boolean): Profile;
}
export class Path {
  constructor(start: Point2);
  lineTo(x: number, y: number): this;
  arcTo(x: number, y: number, centre: Point2, ccw?: boolean): this;
  bezierTo(c1: Point2, c2: Point2, to: Point2): this;
  nurbsTo(control: Point2[], knots: ArrayLike<number>, degree: number, weights?: ArrayLike<number> | null): this;
  end(): Profile;
  endOpen(): Profile;
}
export class SweepPath {
  constructor(at: Point3);
  static at(point: Point3): SweepPath;
  static along(curve: Profile, frame: FrameLike, tolerance?: number, open?: boolean): SweepPath;
  lineTo(point: Point3): this;
  arc(centre: Point3, axis: Point3, angle: number): this;
  close(): void;
  [Symbol.dispose](): void;
}

/** A plane read as a height over the sketch plane: `at + grad . (x, y)`. */
/** An origin and three unit, square, right-handed axes; iterates as twelve numbers, so it goes wherever a frame does. */
export class Frame implements Iterable<number> {
  constructor(origin: Point3, x: Point3, y: Point3, z: Point3);
  static of(frame: FrameLike): Frame;
  static xy(origin?: Point3): Frame;
  static xz(origin?: Point3): Frame;
  static yz(origin?: Point3): Frame;
  static at(origin: Point3, normal: Point3, x?: Point3 | null): Frame;
  readonly origin: number[];
  readonly x: number[];
  readonly y: number[];
  readonly z: number[];
  translate(dx: number, dy: number, dz: number): Frame;
  offset(distance: number): Frame;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

export class Slant {
  constructor(at: number, grad?: Point2);
  readonly at: number;
  readonly grad: readonly [number, number];
  static flat(at: number): Slant;
  static ofPlane(frame: FrameLike, point: Point3, normal: Point3): Slant;
}
/** A `Slant`, or a bare number for `Slant.flat(number)`. */
export type SlantLike = Slant | number;

/** Whether a solid's faces make a manifold, read off its topology (`Solid.manifold`). */
export interface Manifold {
  faces: number; edges: number; vertices: number;
  boundaryEdges: number; nonManifoldEdges: number; nonManifoldVertices: number;
  isManifold: boolean; isClosed: boolean;
}
export interface SolidMesh { positions: Float32Array; normals: Float32Array; indices: Uint32Array; vertexCount: number; indexCount: number }

export class Solid {
  private constructor();
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  static cuboid(x: number, y: number, z: number): Solid;
  static cylinder(r: number, h: number): Solid;
  static cone(r: number, h: number): Solid;
  static sphere(r: number): Solid;
  static torus(major: number, minor: number): Solid;
  static wedge(x: number, y: number, z: number, topX: number): Solid;
  static extrude(profile: Profile, frame: FrameLike, height: number): Solid;
  static extrudeOpen(profile: Profile, frame: FrameLike, height: number): Solid;
  static extrudeTapered(profile: Profile, frame: FrameLike, height: number, taper: number): Solid;
  static extrudeOpenTapered(profile: Profile, frame: FrameLike, height: number, taper: number): Solid;
  static extrudeBetween(profile: Profile, frame: FrameLike, bottom: SlantLike, top: SlantLike): Solid;
  static extrudeOpenBetween(profile: Profile, frame: FrameLike, bottom: SlantLike, top: SlantLike): Solid;
  static loft(a: Profile, frameA: FrameLike, b: Profile, frameB: FrameLike): Solid;
  static loftOpen(a: Profile, frameA: FrameLike, b: Profile, frameB: FrameLike): Solid;
  static revolve(profile: Profile, axis: AxisLine, angle: number): Solid;
  static revolveOpen(profile: Profile, axis: AxisLine, angle: number): Solid;
  static revolveInPlane(profile: Profile, frame: FrameLike, a: Point2, b: Point2, angle: number): Solid;
  static revolveOpenInPlane(profile: Profile, frame: FrameLike, a: Point2, b: Point2, angle: number): Solid;
  static sweep(profile: Profile, frame: FrameLike, path: SweepPath): Solid;
  static sweepOpen(profile: Profile, frame: FrameLike, path: SweepPath): Solid;
  extrudeFaces(height: number): Solid;
  static face(profile: Profile, frame: FrameLike): Solid;
  faceSheet(face: number): Solid;
  dropFaces(faces: Iterable<number>): Solid;
  trim(tool: Solid, keep?: 'outside' | 'inside', tolerance?: number, progress?: Progress | null): Solid;
  trimAsync(tool: Solid, keep?: 'outside' | 'inside', tolerance?: number, progress?: Progress | null): Promise<Solid>;
  place(frame: FrameLike): Solid;
  translate(dx: number, dy: number, dz: number): Solid;
  rotate(axis: AxisLine, radians: number): Solid;
  mirror(plane: FrameLike): Solid;
  join(other: Solid, tolerance?: number, progress?: Progress | null, merge?: boolean): Solid;
  cut(other: Solid, tolerance?: number, progress?: Progress | null, merge?: boolean): Solid;
  common(other: Solid, tolerance?: number, progress?: Progress | null, merge?: boolean): Solid;
  joinAsync(other: Solid, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  cutAsync(other: Solid, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  commonAsync(other: Solid, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  splitSheet(tool: Solid, tolerance?: number, progress?: Progress | null): Solid;
  splitSheetAsync(tool: Solid, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  readonly faces: number;
  faceKind(face: number): string;
  readonly bounds: [number[], number[]];
  boundsAt(tolerance: number): [number[], number[]];
  leakedEdges(tolerance?: number): number;
  unpairedEdges(tolerance?: number): number;
  isWatertight(tolerance?: number): boolean;
  readonly manifold: Manifold;
  mesh(tolerance?: number): SolidMesh;
  meshAsync(tolerance?: number): Promise<SolidMesh>;
  edgePolylines(tolerance?: number): Float32Array[];
  stepText(schema?: string | null, unit?: Unit): string;
  stepAsync(schema?: string | null, unit?: Unit): Promise<string>;
  step(path: string, schema?: string | null, unit?: Unit): void;
  selectFace(selector: Selector): number;
  faceFrame(face: number): number[];
  coloured(colour: string | Iterable<number>, face?: number | null): Solid;
  readonly colour: [number, number, number] | null;
  faceColour(face: number): [number, number, number] | null;
  edges(): Edge[];
  fillet(edges: Iterable<Edge | number>, radius: number, tolerance?: number, progress?: Progress | null): Solid;
  chamfer(edges: Iterable<Edge | number>, distance: number, tolerance?: number): Solid;
  pushPull(face: number, distance: number, tolerance?: number, progress?: Progress | null): Solid;
  mergeFlush(): Solid;
  shell(thickness: number, open?: Iterable<number>, tolerance?: number, progress?: Progress | null): Solid;
  filletAsync(edges: Iterable<Edge | number>, radius: number, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  chamferAsync(edges: Iterable<Edge | number>, distance: number, tolerance?: number): Promise<Solid>;
  shellAsync(thickness: number, open?: Iterable<number>, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  toScene(schema?: string | null): Scene;
  static fromNode(scene: Scene, node: Node | number, placed?: boolean): Solid;
  static open(path: string, body?: number | null): Solid;
  static openAll(path: string): Solid[];
}
export function brepLayoutId(): string;

export class Selector {
  static max(axis: AxisValue): Selector;
  static min(axis: AxisValue): Selector;
  static normal(direction: Point3): Selector;
  static index(i: number): Selector;
}
export class Edge {
  private constructor();
  index: number; kind: string; faces: number[]; segments: [number[], number[]][];
  readonly isLine: boolean;
  readonly direction: number[] | null;
}
export class Workplane {
  frame: number[];
  constructor(frame: FrameLike, solid?: Solid | null);
  static xy(): Workplane; static xz(): Workplane; static yz(): Workplane;
  static on(frame: FrameLike): Workplane;
  static fromSolid(solid: Solid): Workplane;
  cuboid(x: number, y: number, z: number): this;
  cylinder(r: number, h: number): this;
  extrude(profile: Profile, height: number): this;
  face(profile: Profile): this;
  revolve(profile: Profile, angle: number): this;
  translate(dx: number, dy: number, dz: number): this;
  faces(selector: Selector): this;
  workplane(): this;
  solid(): Solid;
}
export function writeStepText(solids: Iterable<Solid>, schema?: string | null, unit?: Unit): string;
export function writeStep(path: string, solids: Iterable<Solid>, schema?: string | null, unit?: Unit): void;
