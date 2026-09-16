/// <reference types="node" />
/** The cadaclysm_blacksmith C ABI for Node.js. See cadaclysm_blacksmith.js for the semantics. */
import type { Scene } from './cadaclysm';

export class BuildError extends Error {}
export const NONE: number;
export const UNITS: { readonly m: 0; readonly mm: 1; readonly in: 2 };
export type Unit = keyof typeof UNITS;
export declare const Axis: { readonly X: 0; readonly Y: 1; readonly Z: 2 };
export type AxisValue = 0 | 1 | 2;

/** Twelve numbers (origin, x, y, z) or four triples. */
export type Frame = ArrayLike<number> | [ArrayLike<number>, ArrayLike<number>, ArrayLike<number>, ArrayLike<number>];
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
  static path(start: Point2): Path;
  withHole(hole: Profile): Profile;
  translate(dx: number, dy: number): Profile;
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
  lineTo(point: Point3): this;
  arc(centre: Point3, axis: Point3, angle: number): this;
  close(): void;
  [Symbol.dispose](): void;
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
  static extrude(profile: Profile, frame: Frame, height: number): Solid;
  static extrudeOpen(profile: Profile, frame: Frame, height: number): Solid;
  static extrudeTapered(profile: Profile, frame: Frame, height: number, taper: number): Solid;
  static extrudeOpenTapered(profile: Profile, frame: Frame, height: number, taper: number): Solid;
  static loft(a: Profile, frameA: Frame, b: Profile, frameB: Frame): Solid;
  static loftOpen(a: Profile, frameA: Frame, b: Profile, frameB: Frame): Solid;
  static revolve(profile: Profile, axis: AxisLine, angle: number): Solid;
  static revolveOpen(profile: Profile, axis: AxisLine, angle: number): Solid;
  static sweep(profile: Profile, frame: Frame, path: SweepPath): Solid;
  static sweepOpen(profile: Profile, frame: Frame, path: SweepPath): Solid;
  extrudeFaces(height: number): Solid;
  place(frame: Frame): Solid;
  translate(dx: number, dy: number, dz: number): Solid;
  rotate(axis: AxisLine, radians: number): Solid;
  mirror(plane: Frame): Solid;
  join(other: Solid, tolerance?: number, progress?: Progress | null): Solid;
  cut(other: Solid, tolerance?: number, progress?: Progress | null): Solid;
  common(other: Solid, tolerance?: number, progress?: Progress | null): Solid;
  joinAsync(other: Solid, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  cutAsync(other: Solid, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  commonAsync(other: Solid, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  readonly faces: number;
  faceKind(face: number): string;
  readonly bounds: [number[], number[]];
  boundsAt(tolerance: number): [number[], number[]];
  mesh(tolerance?: number): SolidMesh;
  meshAsync(tolerance?: number): Promise<SolidMesh>;
  edgePolylines(tolerance?: number): Float32Array[];
  stepText(schema?: string | null, unit?: Unit): string;
  stepAsync(schema?: string | null, unit?: Unit): Promise<string>;
  step(path: string, schema?: string | null, unit?: Unit): void;
  selectFace(selector: Selector): number;
  faceFrame(face: number): number[];
  edges(): Edge[];
  fillet(edges: Iterable<Edge | number>, radius: number, tolerance?: number, progress?: Progress | null): Solid;
  chamfer(edges: Iterable<Edge | number>, distance: number, tolerance?: number): Solid;
  shell(thickness: number, open?: Iterable<number>, tolerance?: number, progress?: Progress | null): Solid;
  filletAsync(edges: Iterable<Edge | number>, radius: number, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  chamferAsync(edges: Iterable<Edge | number>, distance: number, tolerance?: number): Promise<Solid>;
  shellAsync(thickness: number, open?: Iterable<number>, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  toScene(schema?: string | null): Scene;
}

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
  constructor(frame: Frame, solid?: Solid | null);
  static xy(): Workplane; static xz(): Workplane; static yz(): Workplane;
  static on(frame: Frame): Workplane;
  static fromSolid(solid: Solid): Workplane;
  cuboid(x: number, y: number, z: number): this;
  cylinder(r: number, h: number): this;
  extrude(profile: Profile, height: number): this;
  revolve(profile: Profile, angle: number): this;
  translate(dx: number, dy: number, dz: number): this;
  faces(selector: Selector): this;
  workplane(): this;
  solid(): Solid;
}
export function writeStepText(solids: Iterable<Solid>, schema?: string | null, unit?: Unit): string;
export function writeStep(path: string, solids: Iterable<Solid>, schema?: string | null, unit?: Unit): void;
