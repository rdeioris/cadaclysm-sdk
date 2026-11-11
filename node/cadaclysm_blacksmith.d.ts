/// <reference types="node" />
/** The cadaclysm_blacksmith C ABI for Node.js. See cadaclysm_blacksmith.js for the semantics. */
import type { Node, Scene } from './cadaclysm';
import type { ShowOptions, Camera } from './cadaclysm_view';

export class BuildError extends Error {
  constructor(message: string, ids?: number[]);
  /** The sketch ids a `Sketch` refusal names; empty for every other refusal. */
  ids: number[];
}

/** What `Solid.silhouetteBeziers` answers: `points` twelve numbers a curve, `weights` four. */
export interface SilhouetteCurves { points: Float64Array; weights: Float64Array; count: number }
export const NONE: number;
export const UNITS: { readonly m: 0; readonly mm: 1; readonly in: 2 };
export type Unit = keyof typeof UNITS;
export declare const Axis: { readonly X: 0; readonly Y: 1; readonly Z: 2 };
export type AxisValue = 0 | 1 | 2;

/** front back left right top bottom iso, `[azimuth, elevation]` degrees each. */
export type SvgViewName = 'front' | 'back' | 'left' | 'right' | 'top' | 'bottom' | 'iso';
export declare const SvgView: Readonly<Record<SvgViewName, readonly [number, number]>>;

/** How an SVG drawing is made -- see `svgOptionsDefaults` for the defaults every field falls back to. No scene here, so `up` defaults to 'z': a solid carries no convention of its own. */
export interface SvgOptions {
  /** Fills `azimuth`/`elevation` unless they are set directly. Default 'iso'. */
  view?: SvgViewName;
  /** Degrees about the up axis from +X, overriding `view`'s. -90 looks from -Y, the front. */
  azimuth?: number | null;
  /** Degrees above the horizon, overriding `view`'s. */
  elevation?: number | null;
  /** 'y' or 'z'; default 'z'. */
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
  /** `'#rgb'`, `'#rrggbb'`, a CSS colour name or `[r, g, b]` in 0..255. Default '#000000'. */
  stroke?: string | ArrayLike<number>;
  /** The pen's width, page units. Default 1. */
  strokeWidth?: number;
  /** As `stroke`, or null (the default) for no `<rect>` behind the drawing. */
  background?: string | ArrayLike<number> | null;
  /** Each shape's feature edges. Default true. */
  edges?: boolean;
  /** A solid has no free curves of its own; ignored. Default false. */
  curves?: boolean;
  /** A solid has no isocurves of its own; ignored. Default false. */
  isocurves?: boolean;
  /** Straight segments within `tolerance` instead of fitted Béziers. Default false. */
  polylines?: boolean;
  /**
   * Also draw where each solid's surfaces turn away from the eye -- the
   * outline a sphere has no edge for. Default true: a sphere's and a torus's
   * only curves are their seams, which are not edges of the body and are
   * never drawn, so without it those two draw a blank page. A line set in its
   * own right, so `silhouettes` with `edges: false` draws the outline alone.
   */
  silhouettes?: boolean;
}
/** `SvgOptions`'s own defaults, as `cadaclysm_blacksmith_svg_options_init` fills them. */
export function svgOptionsDefaults(): SvgOptions;

/** A `Frame`, twelve numbers (origin, x, y, z) or four triples. */
export type FrameLike = Frame | ArrayLike<number> | [ArrayLike<number>, ArrayLike<number>, ArrayLike<number>, ArrayLike<number>];
/** Six numbers (point, direction) or two triples. */
export type AxisLine = ArrayLike<number> | [ArrayLike<number>, ArrayLike<number>];
export type Point2 = [number, number] | ArrayLike<number>;
export type Point3 = [number, number, number] | ArrayLike<number>;
export type Progress = (phase: string, done: number, total: number) => void;
/** A document evaluation's progress: the id of the node being built, then as `Progress`. */
export type DocumentProgress = (node: string, phase: string, done: number, total: number) => void;

export function libraryPath(): string;
/**
 * `schemas/ap203.exp`, found by walking up from this file.
 *
 * The `ap203.exp` file this finds is no longer needed: the kernel writes against its
 * built-in AP203 when no schema is given. This function stays for compatibility and the
 * parity gates; nothing here calls it to write STEP any more.
 */
export function defaultSchema(): string;
export function version(): string;
export function buildDate(): string;
export function license(textOrPath: string): void;
export function licenseInfo(): string;
export function licenseNoticeCount(): number;
/**
 * Set a kernel option, by its name, for the whole process from the next call on:
 * `boolean.mesh_budget`, `boolean.finest_tolerance`, `profile_boolean.point_budget`,
 * `measure.default_accuracy`, `step.validation_properties`, `step.validation_accuracy`,
 * `tolerance.relative` or `tolerance.angular`.
 * Throws `BuildError` -- and changes nothing -- for a name that
 * is not an option or a value it does not take. The last two stamp a written STEP part file
 * with each body's measured area, volume and centroid, there for the kernel that reads the
 * file to check the transfer against; off by default, since it measures every body in the
 * file at `step.validation_accuracy` (1e-5).
 */
export function setOption(name: string, value: number): void;
/** A kernel option's value, by its name: what `setOption` last set, else its default. Throws `BuildError` for a name that is not an option. */
export function option(name: string): number;
/** What a solid declares about its own precision: `absolute`, a length, and `angular`, radians -- null where nothing declared it. */
export interface Tolerances { readonly absolute: number | null; readonly angular: number | null }
/** The tolerance a verb given a null (or 0) `tolerance` works at over `solids` (0 for none). */
export function effectiveTolerance(...solids: Solid[]): number;

export class Profile {
  private constructor();
  static rect(w: number, h: number): Profile;
  static circle(r: number): Profile;
  static slot(centre: Point2, length: number, r: number): Profile;
  static polygon(points: Point2[]): Profile;
  static regularPolygon(centre: Point2, radius: number, sides: number, angle?: number): Profile;
  /**
   * A regular polygon of `sides` sides (at least 3) whose sides touch the circle of `radius` about
   * `centre` (the polygon across flats): its corners on the circle of `radius / cos(pi / sides)`,
   * on the same rays as `regularPolygon`'s for the same `angle`. `sides` a whole number from 0 to 4294967295.
   */
  static circumscribedPolygon(centre: Point2, radius: number, sides: number, angle?: number): Profile;
  static star(centre: Point2, outer: number, inner: number, points: number, angle?: number): Profile;
  static spline(points: Point2[], degree?: number, weights?: ArrayLike<number> | null, closed?: boolean): Profile;
  static path(start: Point2): Path;
  static parabola(vertex: Point2, axis: Point2, focal: number, from: number, to: number): Path;
  static chain(pieces: Iterable<Profile>, tolerance?: number | null): Profile;
  /** A polyline through `points` (at least two), open, or `closed` with a side back to the first. */
  static polyline(points: Point2[], closed?: boolean): Profile;
  /** The arc of radius `r` about `centre` from angle `a0` counter-clockwise to `a1` (radians); equal angles are the whole circle. */
  static arc(centre: Point2, r: number, a0: number, a1: number): Profile;
  /** The arc from `start` through `through` to `end`; throws when the three are in a line. */
  static arcThrough(start: Point2, through: Point2, end: Point2): Profile;
  /** The ellipse about `centre` with semi-axes `rx` along x and `ry` along y, closed. */
  static ellipse(centre: Point2, rx: number, ry: number): Profile;
  /** Rational cubic Béziers end to end (sixteen numbers each, `x y z w` per control point) as one open profile; `recognise` turns straight ones into lines and circular ones into arcs. */
  static fromBeziers(beziers: ArrayLike<number>, recognise?: boolean): Profile;
  /** This profile as rational cubic Béziers, sixteen numbers each, on the sketch plane or carried onto `frame` (twelve numbers). */
  beziers(frame?: ArrayLike<number> | null): Float64Array;
  /** The closed loops among `pieces`: each the pieces' indices in the order it runs. */
  static loops(pieces: Iterable<Profile>, tolerance?: number | null): number[][];
  /** The order `chain` takes `pieces` in: per piece its index and whether it was turned round. */
  static chainOrder(pieces: Iterable<Profile>, tolerance?: number | null): Array<[number, boolean]>;
  static fromLoops(loops: Iterable<Profile>): Profile;
  closeLoop(): Profile;
  /** This curve cut where the cutters cross it -- the sketch trim's pieces, in order along the curve. */
  pieces(cutters: Iterable<Profile>, tolerance?: number | null): Profile[];
  /** This curve with piece `piece` of `pieces` taken away: what is left, as open profiles. */
  trim(cutters: Iterable<Profile>, piece: number, tolerance?: number | null): Profile[];
  withHole(hole: Profile): Profile;
  /** The perimeter of the outer loop -- holes are not counted -- measured to the relative `accuracy` (0: the default). */
  length(accuracy?: number): Length;
  /** The point `s` along the outer loop from its start; `segment` is the side. */
  pointAtLength(s: number, accuracy?: number): At;
  /** The outer loop in `n` (1 to 1,000,000) pieces of equal arc length: `n` samples (a profile's outer loop is closed). */
  divideByCount(n: number, accuracy?: number): At[];
  /** The outer loop every `step` of arc length; the short last piece is kept. */
  divideByLength(step: number, accuracy?: number): At[];
  /** The outline, then each hole, as x, y, z runs at z = 0 within `tolerance` (0.05 by default). */
  polylines(tolerance?: number | null): Float32Array[];
  /** Every free-form side as lines and arcs within `tolerance` (0.01 by default). */
  toArcs(tolerance?: number | null): Profile;
  /** Grown by `distance` (shrunk where negative), as zero or more line-and-arc profiles. */
  offset(distance: number, tolerance?: number | null): Profile[];
  hits(other: Profile, tolerance?: number | null): Hit[];
  common(other: Profile, tolerance?: number | null): Profile[];
  static text(text: string, size?: number, font?: string, halign?: 'left' | 'center' | 'right', valign?: 'baseline' | 'bottom' | 'center' | 'top', spacing?: number, direction?: 'ltr' | 'rtl', fontBytes?: Uint8Array | ArrayBuffer | null): Profile[];
  translate(dx: number, dy: number): Profile;
  /** This outline turned `radians` (counter-clockwise) about `centre`. */
  rotate(centre: Point2, radians: number): Profile;
  /** This outline scaled by `sx`, `sy` about `centre`; an arc becomes exact conics where the two differ, a zero factor throws. */
  scale(centre: Point2, sx: number, sy: number): Profile;
  /** This outline reflected across the line through `point` along `direction`. */
  mirror(point: Point2, direction: Point2): Profile;
  /** This outline under the 2D affine map `m`, six numbers row-major: `x' = m0 x + m1 y + m2`, `y' = m3 x + m4 y + m5`. */
  transform2d(m: ArrayLike<number>): Profile;
  /** This outline coloured -- '#rgb', '#rrggbb', a CSS colour name or [r, g, b] in 0..1: how it is drawn.
   *  The verbs that make a profile from one carry it; a solid made from it takes nothing. */
  coloured(colour: string | Iterable<number>): Profile;
  readonly colour: [number, number, number] | null;
  /** This profile as a `Document`'s `profile.path` node holds it, parsed: `{start, segments, holes, colour}`, its exact segments never flattened. What `Document.addProfile` puts in a document. */
  documentPath(): { [key: string]: any };
  round(radius: number, corners?: Iterable<number> | null, open?: boolean): Profile;
  /** This profile's own loops as SVG text, from directly above by default (`view: 'top'`) -- a sketch lies in z = 0, so its own plane already is the page. */
  svgText(options?: SvgOptions): string;
  svgAsync(options?: SvgOptions): Promise<string>;
  /** `svgText` written to `path` by the library itself. */
  svg(path: string, options?: SvgOptions): void;
}
export class Path {
  constructor(start: Point2);
  lineTo(x: number, y: number): this;
  arcTo(x: number, y: number, centre: Point2, ccw?: boolean): this;
  bezierTo(c1: Point2, c2: Point2, to: Point2): this;
  conicTo(x: number, y: number, control: Point2, weight: number): Path;
  parabolaTo(x: number, y: number, control: Point2): Path;
  hyperbolaTo(x: number, y: number, control: Point2, weight: number): Path;
  parabolaByVertex(x: number, y: number, vertex: Point2): Path;
  parabolaByFocus(x: number, y: number, focus: Point2): Path;
  nurbsTo(control: Point2[], knots: ArrayLike<number>, degree: number, weights?: ArrayLike<number> | null): this;
  end(): Profile;
  endOpen(): Profile;
}
export class SweepPath {
  constructor(at: Point3);
  static at(point: Point3): SweepPath;
  static along(curve: Profile, frame: FrameLike, tolerance?: number | null, open?: boolean): SweepPath;
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
  /** The plane midway between the planes of `a` and `b`. */
  static midplane(a: FrameLike, b: FrameLike): Frame;
  /** The plane through three points: origin `p`, x towards `q`, z the normal they turn about counter-clockwise. */
  static through(p: Point3, q: Point3, r: Point3): Frame;
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
  /** The same plane facing the other way: x and y swapped, z reversed. */
  flipped(): Frame;
  /** This frame turned `radians` about `axis` through its origin. */
  rotated(radians: number, axis: Point3): Frame;
  /** `p` in this frame's coordinates. */
  toLocal(p: Point3): number[];
  /** `p` dropped onto the plane along z. */
  closestPoint(p: Point3): number[];
  /** How far `p` sits above the plane, along z (negative below). */
  distanceTo(p: Point3): number;
  /** The least-squares plane through `points`, and the largest distance any point sits off it. */
  static fit(points: Iterable<Point3>): { frame: Frame; deviation: number };
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** Sixteen numbers row-major, or four rows of four. */
export type MatrixLike = ArrayLike<number> | [ArrayLike<number>, ArrayLike<number>, ArrayLike<number>, ArrayLike<number>];
/** `Solid.convertToNurbs`'s level. */
export type NurbsLevel = 'procedural' | 'analytic' | 'all';

/** An affine map of space: 16 numbers, row-major, the bottom row `0 0 0 1`. Immutable; `a.compose(b)` is `a` after `b`. */
export class Transform implements Iterable<number> {
  constructor(rows?: MatrixLike);
  static fromRows(rows: MatrixLike): Transform;
  static identity(): Transform;
  static translation(v: Point3): Transform;
  static rotation(point: Point3, direction: Point3, radians: number): Transform;
  static mirror(plane: FrameLike): Transform;
  static scale(centre: Point3, k: number): Transform;
  static scaleXyz(frame: FrameLike, sx: number, sy: number, sz: number): Transform;
  static shear(plane: FrameLike, direction: Point3, factor: number): Transform;
  static planeToPlane(a: FrameLike, b: FrameLike): Transform;
  static changeBasis(from: FrameLike, to: FrameLike): Transform;
  static planarProjection(plane: FrameLike): Transform;
  static projectAlong(plane: FrameLike, direction: Point3): Transform;
  /** The 16 numbers, row-major (a copy). */
  readonly rows: number[];
  point(p: Point3): [number, number, number];
  /** This map after `other`. */
  compose(other: Transform): Transform;
  inverse(): Transform;
  isRigid(tolerance?: number): boolean;
  /** The scale `k`, or null for a map that is not a similarity. */
  isSimilarity(tolerance?: number): number | null;
  decomposeRigid(tolerance?: number): { translation: number[]; orthogonal: Transform } | null;
  decomposeSimilarity(tolerance?: number): { translation: number[]; orthogonal: Transform; k: number } | null;
  /** The polar split: the linear part is `rotation · axes · diag(stretch) · axesᵀ`; null for a singular map. */
  decomposeAffine(): { translation: number[]; rotation: Transform; axes: Transform; stretch: number[] } | null;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** A rotation as `w + xi + yj + zk`. Immutable; `a.multiply(b)` turns by `b`, then `a`. */
export class Quaternion implements Iterable<number> {
  constructor(w?: number, x?: number, y?: number, z?: number);
  static fromAxisAngle(direction: Point3, radians: number): Quaternion;
  static fromTransform(t: Transform | MatrixLike): Quaternion;
  static slerp(a: Quaternion, b: Quaternion, s: number): Quaternion;
  toTransform(centre?: Point3): Transform;
  readonly w: number;
  readonly x: number;
  readonly y: number;
  readonly z: number;
  readonly length: number;
  /** The turn, in `[0, 2π]`. */
  readonly angle: number;
  /** The turn's axis, null for the identity. */
  readonly axis: [number, number, number] | null;
  conjugate(): Quaternion;
  normalized(): Quaternion;
  multiply(o: Quaternion): Quaternion;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** An `Interval`, or two numbers. */
export type IntervalLike = Interval | ArrayLike<number> | Iterable<number>;
/** A parameter range `t0..t1`, in either order: the set operations answer increasing. Immutable; iterates as `[t0, t1]`. */
export class Interval implements Iterable<number> {
  constructor(t0: number, t1: number);
  /** An `Interval`, or two numbers, as an `Interval`. */
  static of(value: IntervalLike): Interval;
  readonly t0: number;
  readonly t1: number;
  /** `t1 - t0`: negative for a decreasing interval. */
  readonly length: number;
  readonly mid: number;
  readonly min: number;
  readonly max: number;
  readonly isIncreasing: boolean;
  readonly isSingleton: boolean;
  swapped(): Interval;
  grown(t: number): Interval;
  union(o: IntervalLike): Interval;
  /** The increasing overlap; null where the two are apart. */
  intersect(o: IntervalLike): Interval | null;
  contains(t: number): boolean;
  parameterAt(s: number): number;
  /** Null for a singleton. */
  normalizedParameterAt(t: number): number | null;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The closest point of a curve value; `unique` false where it is a fixed pick among equals. */
export class CurveFoot {
  constructor(t: number, point: number[], unique: boolean);
  readonly t: number;
  readonly point: number[];
  readonly unique: boolean;
}
/** The closest point of a surface value; `unique` false where it is a fixed pick among equals. */
export class SurfaceFoot {
  constructor(u: number, v: number, point: number[], unique: boolean);
  readonly u: number;
  readonly v: number;
  readonly point: number[];
  readonly unique: boolean;
}

/** What `Curve.value` gives. */
export type CurveValue = Line | Circle | Arc | Ellipse;

/** The segment from `start` to `end`; its parameter runs 0..1. Immutable, nothing to free. */
export class Line implements Iterable<number> {
  constructor(start: Point3, end: Point3);
  /** From the six numbers `values` gives, checked as the constructor checks. */
  static fromValues(values: ArrayLike<number>): Line;
  readonly start: number[];
  readonly end: number[];
  /** The canonical numbers (a copy). */
  readonly values: number[];
  pointAt(t: number): number[];
  tangentAt(t: number): number[];
  length(): number;
  closestPoint(p: Point3): CurveFoot;
  distanceTo(p: Point3): number;
  /** `[min, max]`. */
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Line;
  /** The exact NURBS form. */
  toNurbs(): NurbsCurve;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The circle of `radius` about the frame's origin in its x-y plane. Immutable, nothing to free. */
export class Circle implements Iterable<number> {
  constructor(frame: FrameLike, radius: number);
  static fromValues(values: ArrayLike<number>): Circle;
  static through(a: Point3, b: Point3, c: Point3): Circle;
  readonly frame: Frame;
  readonly radius: number;
  readonly values: number[];
  pointAt(t: number): number[];
  tangentAt(t: number): number[];
  length(): number;
  closestPoint(p: Point3): CurveFoot;
  distanceTo(p: Point3): number;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Circle;
  /** The exact NURBS form. */
  toNurbs(): NurbsCurve;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The part of a circle over `angle`, increasing by at most a full turn. Immutable, nothing to free. */
export class Arc implements Iterable<number> {
  constructor(frame: FrameLike, radius: number, angle: IntervalLike);
  static fromValues(values: ArrayLike<number>): Arc;
  static through(a: Point3, b: Point3, c: Point3): Arc;
  static fromStartTangentEnd(a: Point3, tangent: Point3, c: Point3): Arc;
  readonly frame: Frame;
  readonly radius: number;
  readonly angle: Interval;
  readonly start: number[];
  readonly end: number[];
  readonly mid: number[];
  readonly values: number[];
  pointAt(t: number): number[];
  tangentAt(t: number): number[];
  length(): number;
  closestPoint(p: Point3): CurveFoot;
  distanceTo(p: Point3): number;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Arc;
  /** The exact NURBS form. */
  toNurbs(): NurbsCurve;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The ellipse of radius `r1` along the frame's x and `r2` along its y. Immutable, nothing to free. */
export class Ellipse implements Iterable<number> {
  constructor(frame: FrameLike, r1: number, r2: number);
  static fromValues(values: ArrayLike<number>): Ellipse;
  static fromCircle(circle: Circle): Ellipse;
  readonly frame: Frame;
  readonly r1: number;
  readonly r2: number;
  readonly values: number[];
  pointAt(t: number): number[];
  tangentAt(t: number): number[];
  length(): number;
  closestPoint(p: Point3): CurveFoot;
  distanceTo(p: Point3): number;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Ellipse;
  /** The exact NURBS form. */
  toNurbs(): NurbsCurve;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The sphere of `radius` about the frame's origin. Immutable, nothing to free. */
export class Sphere implements Iterable<number> {
  constructor(frame: FrameLike, radius: number);
  static fromValues(values: ArrayLike<number>): Sphere;
  readonly frame: Frame;
  readonly radius: number;
  readonly values: number[];
  pointAt(u: number, v: number): number[];
  normalAt(u: number, v: number): number[];
  closestPoint(p: Point3): SurfaceFoot;
  distanceTo(p: Point3): number;
  domain(): [Interval, Interval];
  toNurbsSheet(): Solid;
  contains(p: Point3, tolerance?: number): boolean;
  area(): number;
  volume(): number;
  toSolid(): Solid;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Sphere;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The capped cylinder of `radius` about the frame's z over `height`. Immutable, nothing to free. */
export class Cylinder implements Iterable<number> {
  constructor(frame: FrameLike, radius: number, height: IntervalLike);
  static fromValues(values: ArrayLike<number>): Cylinder;
  readonly frame: Frame;
  readonly radius: number;
  readonly height: Interval;
  readonly values: number[];
  pointAt(u: number, v: number): number[];
  normalAt(u: number, v: number): number[];
  closestPoint(p: Point3): SurfaceFoot;
  distanceTo(p: Point3): number;
  domain(): [Interval, Interval];
  toNurbsSheet(): Solid;
  contains(p: Point3, tolerance?: number): boolean;
  area(): number;
  volume(): number;
  toSolid(): Solid;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Cylinder;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The capped cone of base `radius`, its apex `height` up the frame's z. Immutable, nothing to free. */
export class Cone implements Iterable<number> {
  constructor(frame: FrameLike, radius: number, height: number);
  static fromValues(values: ArrayLike<number>): Cone;
  readonly frame: Frame;
  readonly radius: number;
  readonly height: number;
  readonly values: number[];
  pointAt(u: number, v: number): number[];
  normalAt(u: number, v: number): number[];
  closestPoint(p: Point3): SurfaceFoot;
  distanceTo(p: Point3): number;
  domain(): [Interval, Interval];
  toNurbsSheet(): Solid;
  contains(p: Point3, tolerance?: number): boolean;
  area(): number;
  volume(): number;
  toSolid(): Solid;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Cone;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The torus of `major` radius about the frame's z and `minor` radius about that circle. Immutable, nothing to free. */
export class Torus implements Iterable<number> {
  constructor(frame: FrameLike, major: number, minor: number);
  static fromValues(values: ArrayLike<number>): Torus;
  readonly frame: Frame;
  readonly major: number;
  readonly minor: number;
  readonly values: number[];
  pointAt(u: number, v: number): number[];
  normalAt(u: number, v: number): number[];
  closestPoint(p: Point3): SurfaceFoot;
  distanceTo(p: Point3): number;
  domain(): [Interval, Interval];
  toNurbsSheet(): Solid;
  contains(p: Point3, tolerance?: number): boolean;
  area(): number;
  volume(): number;
  toSolid(): Solid;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Torus;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The box over `x`, `y`, `z` along its frame's axes. Immutable, nothing to free. */
export class Cuboid implements Iterable<number> {
  constructor(frame: FrameLike, x: IntervalLike, y: IntervalLike, z: IntervalLike);
  static fromValues(values: ArrayLike<number>): Cuboid;
  static fromBounds(min: Point3, max: Point3): Cuboid;
  static around(frame: FrameLike, points: Iterable<Point3>): Cuboid;
  readonly frame: Frame;
  readonly x: Interval;
  readonly y: Interval;
  readonly z: Interval;
  readonly values: number[];
  /** The eight corners, the `z0` face then the `z1` face. */
  corners(): number[][];
  pointAt(sx: number, sy: number, sz: number): number[];
  closestPoint(p: Point3): number[];
  contains(p: Point3, tolerance?: number): boolean;
  area(): number;
  volume(): number;
  toSolid(): Solid;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Cuboid;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/**
 * The rectangle over `x` and `y` in its frame's x-y plane. As a curve it is its boundary: `t` runs
 * 0..4, one unit a side from corner `(x0, y0)` counter-clockwise about the frame's z. Immutable,
 * nothing to free.
 */
export class Rectangle implements Iterable<number> {
  constructor(frame: FrameLike, x: IntervalLike, y: IntervalLike);
  static fromValues(values: ArrayLike<number>): Rectangle;
  readonly frame: Frame;
  readonly x: Interval;
  readonly y: Interval;
  readonly values: number[];
  /** The four corners: `(x0, y0)`, `(x1, y0)`, `(x1, y1)`, `(x0, y1)`. */
  corners(): number[][];
  area(): number;
  pointAt(t: number): number[];
  tangentAt(t: number): number[];
  length(): number;
  closestPoint(p: Point3): CurveFoot;
  distanceTo(p: Point3): number;
  closestPointIn(p: Point3, includeInterior?: boolean): number[];
  /** `'inside'`, `'outside'` or `'on'`; a null (or NaN) tolerance is the rectangle's own effective one, 0 exact. */
  contains(p: Point3, tolerance?: number | null): 'inside' | 'outside' | 'on';
  toSheet(): Solid;
  /** The boundary as its exact closed degree-1 curve, a knot at each corner, so its parameter is `t`. */
  toNurbs(): NurbsCurve;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Rectangle;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The triangle `a`, `b`, `c`. Immutable, nothing to free. */
export class Triangle implements Iterable<number> {
  constructor(a: Point3, b: Point3, c: Point3);
  static fromValues(values: ArrayLike<number>): Triangle;
  readonly a: number[];
  readonly b: number[];
  readonly c: number[];
  readonly values: number[];
  area(): number;
  perimeter(): number;
  centroid(): number[];
  circumcircle(): Circle;
  pointAt(wa: number, wb: number, wc: number): number[];
  barycentric(p: Point3): number[];
  closestPoint(p: Point3): number[];
  distanceTo(p: Point3): number;
  edge(i: number): Line;
  toSheet(): Solid;
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Triangle;
  equals(other: unknown): boolean;
  [Symbol.iterator](): Iterator<number>;
}

/** The half-line from `position` along `direction` (kept as given). Immutable, nothing to free. */
export class Ray implements Iterable<number> {
  constructor(position: Point3, direction: Point3);
  static fromValues(values: ArrayLike<number>): Ray;
  readonly position: number[];
  readonly direction: number[];
  readonly values: number[];
  pointAt(t: number): number[];
  closestPoint(p: Point3): CurveFoot;
  distanceTo(p: Point3): number;
  /** A ray has no box: this throws. */
  bounds(): [number[], number[]];
  transform(t: Transform | MatrixLike): Ray;
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

/** What a small feature is: a `SmallFeature`'s, `HealFix`'s or `HealRefusal`'s `kind`. */
export type SmallFeatureKind = 'short_edge' | 'collapsed_edge' | 'sliver_face' | 'tiny_face' | 'tiny_body' | 'small_hole';
/** Why `healed` left a small feature: a `HealRefusal`'s `why`. */
export type HealWhy = 'would_empty_loop' | 'closed' | 'seam' | 'chain' | 'neighbours_part' | 'uneven' | 'non_manifold'
  | 'has_holes' | 'body_guard' | 'toggled' | 'unsupported';
/** One free edge: a side only one face bounds, with its nearest partner (a row of `freeEdges`) and the gap to it (`Infinity` without one). */
export class FreeEdge {
  constructor(trim: number, edge: number | null, face: number, wire: number, partner: number | null, sharedEnds: number, length: number, gap: number);
  trim: number;
  /** The edge it lies on; null for a side that has no edge. */
  edge: number | null;
  face: number;
  wire: number;
  /** The nearest free edge across the gap, as an index into `freeEdges`; null if there is none. */
  partner: number | null;
  sharedEnds: number;
  length: number;
  gap: number;
}
/** A chain of free edges end to end: the rows `first` to `first + count` of `freeEdges`. */
export class FreeWire {
  constructor(first: number, count: number, closed: boolean, length: number, widestGap: number);
  first: number; count: number; closed: boolean; length: number; widestGap: number;
}
/** Something below the tolerance: its kind, its edge, face, body or loop number, and how small. */
export class SmallFeature {
  constructor(kind: SmallFeatureKind, index: number, size: number);
  kind: SmallFeatureKind; index: number; size: number;
}
/** What a mesh of the body shows (`health({ mesh: true })`); only a closed body's cracks are counted. */
export class Cracks {
  constructor(watertight: boolean, open: number, folded: number, crossings: number, edges: number[]);
  watertight: boolean; open: number; folded: number; crossings: number; edges: number[];
}
/** What is wrong with a body, as plain data (`health`); nothing in it moves the body. */
export class HealthReport {
  constructor(tolerance: number, rounding: number, extent: number, freeEdges: FreeEdge[], wires: FreeWire[], small: SmallFeature[],
    looseEdges: number, worstLoose: number, sewPairs: number, sewRefused: number, sewWorstGap: number, cracks: Cracks | null, worstGap: number);
  tolerance: number; rounding: number; extent: number;
  freeEdges: FreeEdge[]; wires: FreeWire[]; small: SmallFeature[];
  looseEdges: number; worstLoose: number;
  sewPairs: number; sewRefused: number; sewWorstGap: number;
  /** Where the mesh cracks; null unless the call asked for the mesh. */
  cracks: Cracks | null;
  /** The widest gap between a free edge and its partner. */
  worstGap: number;
  /** The free edges of wire number `wire`, in order. */
  wireEdges(wire: number): FreeEdge[];
}
/** One small feature `healed` removed: what it was, its number in the input, its size, and how far the vertices it merged moved. */
export class HealFix {
  constructor(kind: SmallFeatureKind, index: number, size: number, moved: number);
  kind: SmallFeatureKind; index: number; size: number; moved: number;
}
/** One small feature `healed` left, and why; `figure` the chain's width or the neighbours' gap, else 0. */
export class HealRefusal {
  constructor(kind: SmallFeatureKind, index: number, why: HealWhy, figure: number);
  kind: SmallFeatureKind; index: number; why: HealWhy; figure: number;
}
/** What `healed` did: the fixes, the features left and why, and the body's health before and after. */
export class HealReport {
  constructor(tolerance: number, moved: number, guarded: boolean, fixes: HealFix[], refused: HealRefusal[], smallBefore: number, smallAfter: number,
    freeBefore: number, freeAfter: number, closedBefore: boolean, closedAfter: boolean, nonmanifoldBefore: number, nonmanifoldAfter: number);
  tolerance: number; moved: number; guarded: boolean;
  fixes: HealFix[]; refused: HealRefusal[];
  smallBefore: number; smallAfter: number;
  freeBefore: number; freeAfter: number;
  closedBefore: boolean; closedAfter: boolean;
  nonmanifoldBefore: number; nonmanifoldAfter: number;
}
/** `health`'s options: `tolerance` (omitted takes the default, `1e-4` times the diagonal) and `mesh` (also mesh the body and report its cracks). */
export interface HealthOptions { tolerance?: number; mesh?: boolean }
/** `healed`'s options: `tolerance` as `health`'s, and the three kinds of fix, each on unless `false`. */
export interface HealOptions { tolerance?: number; edges?: boolean; faces?: boolean; holes?: boolean }
/** Whether a solid's faces make a manifold, read off its topology (`Solid.manifold`). */
export interface Manifold {
  faces: number; edges: number; vertices: number;
  boundaryEdges: number; nonManifoldEdges: number; nonManifoldVertices: number;
  isManifold: boolean; isClosed: boolean;
}
/**
 * What a solid measures, per unit density, each figure beside a bound on its own error.
 *
 * Per unit density is the primitive: a body's weight is `density * volume` and its inertia scales
 * the same way, so `weight` is the only figure that takes one. `volume`, `centroid`, `inertia` and
 * `principalMoments` mean something only where `closed`; where `accuracyMet` is false the
 * refinement stopped early and the figures are honest but less certain, which the errors say.
 */
export interface Mass {
  /** Closed, so the volume-side figures mean something. */
  closed: boolean;
  /** Every face pointed inward; the figures are given as if they had not. */
  inverted: boolean;
  /** Every error came under the accuracy asked for. */
  accuracyMet: boolean;
  /** Measured on a mesh rather than exact surfaces, so the errors are the rounding floor. */
  fromMesh: boolean;
  /** The surface area. */
  area: number;
  /** A bound on `area`'s own error. */
  areaError: number;
  /** The volume enclosed, where `closed`. */
  volume: number;
  /** A bound on `volume`'s own error. */
  volumeError: number;
  /** The volume's centroid, where `closed`. */
  centroid: number[];
  /** A bound on the distance from `centroid` to the true centroid. */
  centroidError: number;
  /** Three rows of three about the centroid, products of inertia negated. */
  inertia: number[][];
  /** A bound on every entry of `inertia`. */
  inertiaError: number;
  /** Ascending. */
  principalMoments: number[];
  /** Unit, orthogonal, right-handed; row `i` belongs to moment `i`. */
  principalAxes: number[][];
  /** `density * volume`, in whatever units the model and the density agree on. */
  weight(density: number): number;
}
/**
 * A closed solid's box on its principal axes (`Solid.orientedBox`). Not the minimal box in
 * general, and with equal moments the axes are a free choice.
 */
export interface OrientedBox {
  /** The box's middle, not the body's centroid. */
  readonly centre: number[];
  /** The three unit axes, one row each: orthonormal and right-handed. */
  readonly axes: number[][];
  /** The half-extent along each axis, grown by the tolerance the measurement settled on. */
  readonly half: number[];
}
/** A measured length (`Solid.edgeLength`, `Profile.length`) beside an estimate of its error. */
export interface Length {
  /** The length. */
  readonly length: number;
  /** An estimate of how far `length` is from the true length. */
  readonly error: number;
  /** The error came under the accuracy asked for. */
  readonly accuracyMet: boolean;
  /** The curve was a sampled polyline: exact for its points, not for what they were sampled from. */
  readonly fromPolyline: boolean;
}
/** A point at an arc length (`Solid.edgePointAtLength`, `Profile.pointAtLength`, a divide's samples). */
export interface At {
  readonly point: number[];
  /** The unit tangent. */
  readonly tangent: number[];
  /** The curve's parameter; on a profile, that side's own. */
  readonly parameter: number;
  /** The profile side the point is on; null on a solid's edge. */
  readonly segment: number | null;
  /** An estimate of how far the arc length is from the true one. */
  readonly error: number;
  /** The curve was a sampled polyline. */
  readonly fromPolyline: boolean;
}
/** Where a point is relative to a closed solid's boundary. */
export type Containment = 'outside' | 'inside' | 'on';
/**
 * The closest points between two solids' boundaries (`Solid.closest`), side `a` the solid asked
 * and side `b` the other.
 */
export interface Closest {
  /** The distance between the two points. */
  readonly distance: number;
  /** The point on side `a`. */
  readonly onA: number[];
  /** The point on side `b`. */
  readonly onB: number[];
  /** What side `a`'s point lies on. */
  readonly kindA: 'face' | 'edge' | 'vertex';
  /** The kernel's id for side `a`'s feature. */
  readonly indexA: number;
  /** The index `fillet` and `Solid.edges` use for side `a`'s edge; null for a face, a vertex, or an edge the fillet table does not hold. */
  readonly edgeA: number | null;
  /** What side `b`'s point lies on. */
  readonly kindB: 'face' | 'edge' | 'vertex';
  /** The kernel's id for side `b`'s feature. */
  readonly indexB: number;
  /** The index `fillet` and `Solid.edges` use for side `b`'s edge, or null. */
  readonly edgeB: number | null;
  /** The answer was refined on the exact surfaces; false is the mesh's answer, within the tolerance. */
  readonly refined: boolean;
}
/**
 * The nearest point of a solid (or of one face) to a query point (`Solid.closestPoint`,
 * `Projector.closestPoint`, `Solid.faceClosestPoint`). What the point lies on is named as
 * `Closest` names each side.
 */
export class PointFoot {
  private constructor();
  /** The nearest point, on the body's boundary (a query inside a closed body is answered by its nearest boundary point). */
  readonly point: number[];
  /** From the query point to `point`. */
  readonly distance: number;
  /** What the point lies on. */
  readonly kind: 'face' | 'edge' | 'vertex';
  /** The kernel's id for the face, edge or vertex. */
  readonly index: number;
  /** The index `Solid.edges` uses (what `edgeLength`, `fillet` and `edgeClosestPoint` take) for an edge foot; null for a face, a vertex, and an edge the fillet table does not hold. Read this, not `index`. */
  readonly edge: number | null;
  /** The face parameter of a foot inside a face; null for an edge or a vertex foot. */
  readonly uv: [number, number] | null;
  /** Unit: a face foot's outward normal; an edge or vertex foot's direction from the foot to the query point; on the body the mean of the adjacent faces' outward normals. */
  readonly normal: number[];
  /** Refined onto the exact geometry; false is the mesh's answer, within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`. */
  readonly refined: boolean;
}
/** The nearest point of one edge to a query point (`Solid.edgeClosestPoint`): `t` the edge curve's own parameter. */
export interface EdgeFoot {
  readonly t: number;
  readonly point: number[];
  readonly distance: number;
}
/** The nearest points of two curves (`NurbsCurve.closestPoints`, a `NearestObject`'s answer for a curve): side `a` on the curve asked, side `b` on the other. Exact. */
export class CurvePair {
  private constructor();
  /** From `pointA` to `pointB`; 0 where the curves cross. */
  readonly distance: number;
  /** The parameter of `pointA` on the curve asked. */
  readonly tA: number;
  readonly pointA: number[];
  /** The parameter of `pointB` on the other curve. */
  readonly tB: number;
  readonly pointB: number[];
}
/** The nearest points of a curve and a solid's boundary (`Solid.curveClosestPoints`, `Projector.curveClosestPoints`, a `NearestObject`'s answer for a solid or a projector). The body's side is named as `PointFoot` names its point. */
export class CurveBodyFoot {
  private constructor();
  /** From `pointOnCurve` to `pointOnBody`. */
  readonly distance: number;
  /** The curve's parameter at `pointOnCurve`. */
  readonly t: number;
  readonly pointOnCurve: number[];
  readonly pointOnBody: number[];
  /** What the body's point lies on. */
  readonly kind: 'face' | 'edge' | 'vertex';
  /** The kernel's id for the face, edge or vertex. */
  readonly index: number;
  /** The public edge number (what `edgeLength` and `edgeClosestPoint` take) for an edge foot; null otherwise. Read this, not `index`. */
  readonly edge: number | null;
  /** The face parameter of a foot inside a face; null for an edge or a vertex foot. */
  readonly uv: [number, number] | null;
  /** Unit, as `PointFoot.normal`. */
  readonly normal: number[];
  /** Refined onto the exact geometry; false is the mesh's answer, within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`. */
  readonly refined: boolean;
  /** The curve passes through the boundary: `distance` is exactly 0 and the earliest crossing in `t` answers. */
  readonly crossing: boolean;
}
/** The nearest of a list of things to a curve (`NurbsCurve.closestObject`). */
export class NearestObject {
  private constructor();
  /** The item's index in the list asked. */
  readonly which: number;
  /** From `pointOnCurve` to `pointOnItem`. */
  readonly distance: number;
  /** The curve's parameter at `pointOnCurve`. */
  readonly t: number;
  readonly pointOnCurve: number[];
  readonly pointOnItem: number[];
  /** A solid's or a projector's answer; null for a curve or a point. */
  readonly body: CurveBodyFoot | null;
  /** A curve's answer, side `a` the curve asked; null for a solid, a projector or a point. */
  readonly pair: CurvePair | null;
}
export interface SolidMesh { positions: Float32Array; normals: Float32Array; indices: Uint32Array; vertexCount: number; indexCount: number }
/** `SolidMesh` in `double`: the same tessellation's own unnarrowed positions/normals. */
export interface SolidMesh64 { positions: Float64Array; normals: Float64Array; indices: Uint32Array; vertexCount: number; indexCount: number }

export class Solid {
  private constructor();
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  /** Draw with the view library in use: the shared window (returns) or a still. */
  show(options?: ShowOptions): void;
  /** Orbit until the window is closed; the camera it was left at and the last pick. */
  view(options?: ShowOptions): Camera;
  static cuboid(x: number, y: number, z: number): Solid;
  static cylinder(r: number, h: number): Solid;
  static cone(r: number, h: number): Solid;
  static sphere(r: number): Solid;
  static torus(major: number, minor: number): Solid;
  static wedge(x: number, y: number, z: number, topX: number): Solid;
  /** A right pyramid of `sides` sides (at least 3): its base the regular polygon of circumradius `r` on z=0, its first corner on +x, its tip at (0, 0, `h`). */
  static pyramid(sides: number, r: number, h: number): Solid;
  /** The sheet lofted through the section curves, `degree` across them; `loose` shapes it by them, `closed` makes it periodic across them. */
  static loftCurves(sections: Iterable<NurbsCurve>, degree?: number, loose?: boolean, closed?: boolean): Solid;
  /** `sections` swept along `rail`; `frame` `'rmf'` rotation-minimising or `'fixed'` keeping `up` upright. The sheet's `sheetError` says how close the fit is. */
  static sweepRail(rail: NurbsCurve, sections: Iterable<NurbsCurve>, frame?: SweepFrame, up?: Point3 | null, tolerance?: number | null): Solid;
  /** `sections` swept between two rails. */
  static sweepTwoRails(railA: NurbsCurve, railB: NurbsCurve, sections: Iterable<NurbsCurve>, tolerance?: number | null): Solid;
  /** The Coons sheet of 2, 3 or 4 boundary curves meeting end to end. */
  static edgeSurface(curves: Iterable<NurbsCurve>, tolerance?: number | null): Solid;
  /** The Gordon sheet of a curve network. */
  static networkSurface(uCurves: Iterable<NurbsCurve>, vCurves: Iterable<NurbsCurve>, tolerance?: number | null): Solid;
  /** The rolling-ball fillet between two faces: `[sheet, railA, railB]`, the rails `NurbsCurve`s the caller owns. */
  static filletSurfaces(a: Solid, b: Solid, radius: number, radiusEnd?: number | null, flipA?: boolean, flipB?: boolean, tolerance?: number | null, faceA?: number, faceB?: number): [Solid, NurbsCurve, NurbsCurve];
  /** A sheet spanning from `a`'s side to `b`'s, meeting each at G`level` (1 or 2). */
  static blendSides(a: Solid, sideA: SheetSide, b: Solid, sideB: SheetSide, level?: number, bulge?: number, faceA?: number, faceB?: number): Solid;
  /** The sheet filling a hole of 3 or more sides; its `patchReport` holds the worst continuity. */
  static nSidedPatch(boundaries: Iterable<PatchBoundary>, bulge?: number, tolerance?: number | null): Solid;
  /** The sheets joined into one body, and what the join did. */
  static joinSheets(sheets: Iterable<Solid>, tolerance?: number | null): [Solid, JoinReport];
  static extrude(profile: Profile, frame: FrameLike, height: number): Solid;
  static extrudeOpen(profile: Profile, frame: FrameLike, height: number): Solid;
  static extrudeTapered(profile: Profile, frame: FrameLike, height: number, taper: number): Solid;
  static extrudeOpenTapered(profile: Profile, frame: FrameLike, height: number, taper: number): Solid;
  static extrudeBetween(profile: Profile, frame: FrameLike, bottom: SlantLike, top: SlantLike): Solid;
  static extrudeOpenBetween(profile: Profile, frame: FrameLike, bottom: SlantLike, top: SlantLike): Solid;
  static loft(a: Profile, frameA: FrameLike, b: Profile, frameB: FrameLike): Solid;
  static loftOpen(a: Profile, frameA: FrameLike, b: Profile, frameB: FrameLike): Solid;
  static loftThrough(sections: Iterable<[Profile, FrameLike]>): Solid;
  static loftThroughOpen(sections: Iterable<[Profile, FrameLike]>): Solid;
  static revolve(profile: Profile, axis: AxisLine, angle: number): Solid;
  static revolveOpen(profile: Profile, axis: AxisLine, angle: number): Solid;
  static coil(profile: Profile, axis: AxisLine, pitch: number, turns: number): Solid;
  static revolveInPlane(profile: Profile, frame: FrameLike, a: Point2, b: Point2, angle: number): Solid;
  static revolveOpenInPlane(profile: Profile, frame: FrameLike, a: Point2, b: Point2, angle: number): Solid;
  static sweep(profile: Profile, frame: FrameLike, path: SweepPath): Solid;
  static sweepOpen(profile: Profile, frame: FrameLike, path: SweepPath): Solid;
  static pipe(path: SweepPath, radius: number, thickness?: number): Solid;
  extrudeFaces(height: number): Solid;
  static face(profile: Profile, frame: FrameLike): Solid;
  faceSheet(face: number): Solid;
  dropFaces(faces: Iterable<number>): Solid;
  /** What is wrong with this solid: free edges and wires, small features, loose edges, what sewing would do, and, asked for, the mesh's cracks. Nothing moves. */
  health(options?: HealthOptions): HealthReport;
  /** This solid with its small features removed, and what was done; this one is left as it was. */
  healed(options?: HealOptions): { solid: Solid; report: HealReport };
  /** How far brep edge `edge` may lie off its curve: 0 exact, the distance healing or sewing moved it, null when no trim names the id. */
  edgeTolerance(edge: number): number | null;
  /** What this solid declares about its own precision; null in a field nothing declared. */
  readonly tolerances: Tolerances;
  /** This solid declaring `absolute` and `angular` (radians); null (or 0) declares nothing. */
  withTolerances(absolute?: number | null, angular?: number | null): Solid;
  /** The recorded tolerance of the vertex at `point`, or null. */
  vertexTolerance(point: ArrayLike<number>): number | null;
  trim(tool: Solid, keep?: 'outside' | 'inside', tolerance?: number | null, progress?: Progress | null): Solid;
  trimAsync(tool: Solid, keep?: 'outside' | 'inside', tolerance?: number | null, progress?: Progress | null): Promise<Solid>;
  place(frame: FrameLike): Solid;
  /** The closed outlines where the plane `Z = z` cuts this solid, as profiles with holes. */
  section(z: number, tolerance?: number | null): Profile[];
  translate(dx: number, dy: number, dz: number): Solid;
  /** This solid scaled by `factor` about the origin: every length times `factor`, exactly. */
  scaled(factor: number): Solid;
  rotate(axis: AxisLine, radians: number): Solid;
  mirror(plane: FrameLike): Solid;
  /** Through the affine map `t` -- a `Transform` or 16 numbers -- exactly, colours and name kept. */
  transform(t: Transform | MatrixLike): Solid;
  /** Its surfaces rewritten as their exact NURBS, `'all'` by default. */
  convertToNurbs(level?: NurbsLevel): Solid;
  /** The trims the `transform` / `convertToNurbs` call that made this solid lost; 0 otherwise. */
  readonly inexactTrims: number;
  /** On a fitted sheet (`sweepRail`, `sweepTwoRails`, `edgeSurface`, `networkSurface`, `filletSurfaces`, `flange`, `extrudeTo`, `faired`) how far its fit is from what was asked; null elsewhere. */
  readonly sheetError: number | null;
  /** On the sheet from `nSidedPatch`, its report; null elsewhere. */
  readonly patchReport: PatchReport | null;
  /** How well this face's side meets `other`'s along `otherSide`. */
  continuity(side: SheetSide, other: Solid, otherSide: SheetSide, face?: number, otherFace?: number, samples?: number): Continuity;
  /** How well the two faces of edge `edge` meet along it (a square crease reads an angle of pi/2). */
  edgeContinuity(edge: Edge | number, samples?: number): Continuity;
  /** Face `face` faired within `tolerance` as a sheet of its own (its `sheetError` set): `controls` null on its own net raised to `degree`, `[nU, nV]` a uniform net; `keep` one level for every side or per side (null free, 0 position, 1 tangent, 2 curvature); `noInflection` holds those isocurves from turning over. */
  faired(tolerance?: number | null, degree?: number, controls?: [number, number] | null, keep?: SheetKeep, noInflection?: 'u' | 'v' | 'uv' | null, face?: number): Solid;
  /** Where face `face`'s Gaussian and mean curvature change sign, on a `samples`-step grid each way. */
  curvatureTurns(face?: number, samples?: number): CurvatureTurns;
  /** The worst kink of the highlight lines crossing edge `edge`, at `samples` points along it. */
  highlightKink(edge: Edge | number, samples?: number): HighlightKink;
  /** The face as a sheet of its own, its side bent to meet `other`'s at G`level` (0, 1 or 2). */
  matched(side: SheetSide, other: Solid, otherSide: SheetSide, level?: number, face?: number, otherFace?: number): Solid;
  /** This sheet cut along `curve`, nothing removed. */
  splitByCurve(curve: NurbsCurve, direction?: Point3 | null, tolerance?: number | null): Solid;
  /** This sheet cut along `curve` and one side thrown away. */
  trimByCurve(curve: NurbsCurve, keep?: TrimKeep, direction?: Point3 | null, tolerance?: number | null): Solid;
  /** `section` (a curve in z = 0 from the origin) swept along naked `edges` on the face's frame: x outward, y along the normal; sewn on with `join`. */
  flange(edges: Iterable<Edge | number>, section: NurbsCurve, tolerance?: number | null, join?: boolean): Solid;
  /** Naked `edges` slid along `direction` to their first hits on `target`: one wall per edge, sewn on with `join`. */
  extrudeTo(edges: Iterable<Edge | number>, direction: Point3, target: Solid, tolerance?: number | null, join?: boolean): Solid;
  /** This sheet cut along `curve`, a curve lying on it, with no direction: in each face's own parameters. */
  splitAlongCurve(curve: NurbsCurve, tolerance?: number | null): Solid;
  /** This sheet parted along `curve` into two flanged panels `gap` apart: `[left, right]`. */
  panelGap(curve: NurbsCurve, gap?: number, flange?: number, tolerance?: number | null): [Solid, Solid];
  /** This sheet with an opening recessed into it along the closed `outline`, and its face counts `[sheet, fillet, walls, pane]`. */
  recess(outline: NurbsCurve, depth: number, draft?: number, fillet?: number, pane?: boolean, tolerance?: number | null): [Solid, [number, number, number, number]];
  /** This half and its reflection across `plane` joined into one symmetric body, the half's faces first, and how well the seam meets. */
  mirrorJoin(plane: FrameLike, snap?: number, tolerance?: number | null): [Solid, SymmetryReport];
  join(other: Solid, tolerance?: number | null, progress?: Progress | null, merge?: boolean): Solid;
  cut(other: Solid, tolerance?: number | null, progress?: Progress | null, merge?: boolean): Solid;
  common(other: Solid, tolerance?: number | null, progress?: Progress | null, merge?: boolean): Solid;
  joinAsync(other: Solid, tolerance?: number | null, progress?: Progress | null): Promise<Solid>;
  cutAsync(other: Solid, tolerance?: number | null, progress?: Progress | null): Promise<Solid>;
  commonAsync(other: Solid, tolerance?: number | null, progress?: Progress | null): Promise<Solid>;
  splitSheet(tool: Solid, tolerance?: number | null, progress?: Progress | null): Solid;
  /**
   * This solid and `other` as one non-manifold body that keeps every piece: its regions are this
   * solid less `other`, the two together and `other` less this one. The manifold verbs refuse it;
   * take its cells with `regions` and `regionSolid`.
   */
  merge(other: Solid, tolerance?: number | null, progress?: Progress | null): Solid;
  /** The regions of space this solid's faces bound, region 0 the infinite one. */
  regions(): Region[];
  /** Finite region `region` (an index into `regions()`, a whole number from 0 to 4294967295) as a closed solid of its own. */
  regionSolid(region: number): Solid;
  /**
   * Where this solid's faces cross or coincide with `other`'s: chains along the curves the faces
   * meet on (one per face pair per branch -- join them by matching ends) and overlaps where a face
   * pair coincides. Neither solid is changed; no crossing is an empty result.
   */
  intersect(other: Solid, tolerance?: number | null, progress?: Progress | null): Intersection;
  /**
   * Where `profile`, placed on `frame`, pierces this solid's faces, and the pieces its loops cut
   * into, as a `SolidHits`. Neither is changed.
   *
   * A point hit lies within `tolerance` of the segment's exact curve and of the face's exact
   * surface, inside the face's trim; its profile spot (`aStart`: loop, segment, t) and face spot
   * (`bStart`: face, u, v) evaluate to the point within `tolerance`; `touch` where the curve's
   * tangent lies within 1e-3 (sine) of the surface's tangent plane there (a graze), false at a
   * crossing. A run is a stretch of one segment lying within `tolerance` of one face and inside
   * it, longer than `tolerance`. Hits within `tolerance` of each other merge (a hit at a segment
   * join reported once, as `(k, t = 1)`; a closed loop's closing join reads `(0, 0)`).
   * Every point is in world space (the frame applied).
   *
   * Pieces only for a closed body -- an open body has none -- in loop order, covering every loop
   * exactly; a piece's spots read a segment join as the next segment's start `(k + 1, 0)`, and an
   * open chain runs from `(0, 0)` to `(n - 1, 1)`; a loop no hit cuts is one closed piece.
   * `inside` by the piece middle's winding number over the body's mesh; a piece lying on the
   * surface is inside. Known limit: a segment passing within `tolerance` of a face without
   * crossing its mesh can be missed (near-tangent grazes).
   *
   * `progress(phase, done, total)` hears `mesh`, `cull`, `hits` and `pieces`. Throws
   * `BuildError` for a `tolerance` not positive and finite, a solid with no faces or that meshes
   * to nothing, a profile with no segments, or a free-form segment that is not an evaluable
   * NURBS curve.
   */
  hits(profile: Profile, frame: FrameLike, tolerance?: number | null, progress?: Progress | null): SolidHits;
  splitSheetAsync(tool: Solid, tolerance?: number | null, progress?: Progress | null): Promise<Solid>;
  readonly faces: number;
  faceKind(face: number): string;
  /** The solid's box at a thousandth of its own extent, in `double`: the same cost at any size. */
  readonly bounds: [number[], number[]];
  /** `bounds` in `double`: exact far from the origin. */
  readonly bounds64: [number[], number[]];
  boundsAt(tolerance: number): [number[], number[]];
  /** `boundsAt` in `double`, from the same tessellation's own unnarrowed positions. */
  boundsAt64(tolerance: number): [number[], number[]];
  leakedEdges(tolerance?: number | null): number;
  unpairedEdges(tolerance?: number | null): number;
  isWatertight(tolerance?: number | null): boolean;
  readonly manifold: Manifold;
  /** The radius of the round face `face` belongs to (a fillet's face `unfillet` can take back), 0 where it is none; throws for a face the solid does not have. */
  faceRoundRadius(face: number): number;
  /** The distance of the chamfer face `face` belongs to (a bevel `unchamfer` can take back), 0 where it is none; throws for a face the solid does not have. */
  faceChamferDistance(face: number): number;
  /** The edges as rational cubic Béziers, sixteen numbers each (`x y z w` per control point): exact where the curve has a Bézier form, flattened within `tolerance` elsewhere (null: the effective tolerance). */
  edgeBeziers(tolerance?: number | null): Float64Array;
  /** The curved faces' isoparametric curves as rational cubic Béziers, sixteen numbers each, `density` interior lines each way; a flat face draws none. */
  isocurveBeziers(density?: number, tolerance?: number | null): Float64Array;
  /**
   * What this solid measures, per unit density, each figure beside a bound on its own error.
   * `accuracy` is relative and 0 asks for the library's default.
   */
  mass(accuracy?: number): Mass;
  /** This closed solid's box on its principal axes; `accuracy` 0 or less asks for the box's own default, 1e-5. */
  orientedBox(accuracy?: number): OrientedBox;
  /** The length of edge `edge` (an index into `edges()`), measured to the relative `accuracy` (0: the default). */
  edgeLength(edge: number, accuracy?: number): Length;
  /** The point of edge `edge` `s` along it from the start of its curve range; `accuracy` 0 or less asks for the default. */
  edgePointAtLength(edge: number, s: number, accuracy?: number): At;
  /** Edge `edge` in `n` (1 to 1,000,000) pieces of equal arc length: `n + 1` samples, or `n` for a closed edge. */
  edgeDivideByCount(edge: number, n: number, accuracy?: number): At[];
  /** Edge `edge` every `step` of arc length; the short last piece is kept. */
  edgeDivideByLength(edge: number, step: number, accuracy?: number): At[];
  /** Where `point` is: inside, outside, or on within `tolerance` (0.05 by default) of the boundary. Meshes every call. */
  contains(point: Point3, tolerance?: number | null): Containment;
  /** A `Classifier` for this closed solid at `tolerance` (0.05 by default): meshed once, asked point after point. */
  classifier(tolerance?: number | null): Classifier;
  /** The closest points between this solid's boundary and `other`'s, to `tolerance` (0.05 by default); this solid is side `a`. `progress` hears 'meshing', 'pruning' and 'refining'; over the wasm it is never called. */
  closest(other: Solid, tolerance?: number | null, progress?: Progress | null): Closest;
  /** The nearest point of this solid's boundary to `p`, or null beyond `maxDistance` (undefined, null, NaN or Infinity: no limit). `tolerance` undefined, null, 0 or NaN is unset (the solid's effective tolerance); it sizes the mesh search only: a `refined` false answer is within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`. Meshes every call. */
  closestPoint(p: Point3, maxDistance?: number | null, tolerance?: number | null): PointFoot | null;
  /** A `Projector` for this solid at `tolerance` (undefined, null, 0 or NaN: unset): meshed once, asked point after point. */
  projector(tolerance?: number | null): Projector;
  /** The nearest point to `p` of face `face` alone, inside its trims or on its boundary: exact, always `refined`. */
  faceClosestPoint(face: number, p: Point3): PointFoot;
  /** The nearest point to `p` of edge `edge` (an index into `edges()`, or the `Edge`) on its own curve over its range. Exact. */
  edgeClosestPoint(edge: number | Edge, p: Point3): EdgeFoot;
  /** The nearest points of `curve` and this solid's boundary (`crossing` true, distance 0, where the curve passes through it: the earliest crossing in `t`), or null beyond `maxDistance` (undefined, null, NaN or Infinity: no limit). `tolerance` undefined, null, 0 or NaN is unset (the solid's effective tolerance); a `refined` false answer is within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`. Meshes every call. */
  curveClosestPoints(curve: NurbsCurve, maxDistance?: number | null, tolerance?: number | null): CurveBodyFoot | null;
  /** This solid's box at `tolerance`: its boolean mesh, padded by twice that -- the
   *  broad phase's own bound (`Collider` builds one per part at construction). */
  boundsBox(tolerance?: number | null): Box;
  /** One thickness for face `face` of this solid alone, on a `ThicknessGauge` meshed at `tolerance` (0.01 by default), used once and freed; null where nothing is found. `maximum` has no default. */
  thicknessAtFace(face: number, options: ThicknessAtFaceOptions & { tolerance?: number | null }): FaceThickness | null;
  mesh(tolerance?: number | null): SolidMesh;
  /** `mesh` in `double`, from the same tessellation cache -- unnarrowed positions/normals. */
  mesh64(tolerance?: number | null): SolidMesh64;
  meshAsync(tolerance?: number | null): Promise<SolidMesh>;
  meshAsync64(tolerance?: number | null): Promise<SolidMesh64>;
  edgePolylines(tolerance?: number | null): Float32Array[];
  /** A colour per polyline of `edgePolylines(tolerance)`, as drawn: [r, g, b], or null for a polyline
   *  on no coloured edge; an empty array where the solid has no edge paint at all. Fills the solid's
   *  cache at `tolerance`, as `edgePolylines` does. */
  edgePolylineColours(tolerance?: number | null): Array<[number, number, number] | null>;
  /**
   * This solid meshed for a solver, as a `FemMesh` **owned by the caller**: `free()`
   * it, or `using` it. `tolerance` and `maxSize` default to `FemOptions::default()`'s
   * own **0.01 and 0**, not the 0.05 every other tolerance here takes; `placement` is a
   * `Frame` or **twelve** numbers, where the reader's `Node.femMesh` takes sixteen
   * column-major. `progress` hears `'meshing'` and `'welding'`. No unlicensed notice
   * here -- `FemMesh.mshText` and `FemMesh.saveMsh` print it.
   */
  femMesh(tolerance?: number, maxSize?: number, placement?: FrameLike | null, progress?: Progress | null): FemMesh;
  /**
   * `schema`: null/undefined (the kernel's built-in AP203); the path of a schema file
   * (no newline in it, naming an existing file), read and sent as EXPRESS text; the
   * bare name of a built-in schema (case-insensitive, e.g.
   * `"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"` -- an unknown name throws
   * `BuildError`); or a custom schema's own EXPRESS text.
   */
  stepText(schema?: string | null, unit?: Unit): string;
  stepAsync(schema?: string | null, unit?: Unit): Promise<string>;
  step(path: string, schema?: string | null, unit?: Unit): void;
  /** The solid as ACIS SAT text: analytic surfaces as their own records, splines and swept surfaces as exact NURBS. */
  satText(unit?: Unit): string;
  satAsync(unit?: Unit): Promise<string>;
  /** `satText` written to `path` by the library itself. */
  sat(path: string, unit?: Unit): void;
  /** The solid as a Rhino `.3dm`'s bytes: its exact brep, named and coloured as the solid is; see `rhino3dmBytes`. */
  rhino3dmBytes(unit?: Unit): Buffer;
  /** `rhino3dmBytes` written to `path` by the library itself. */
  write3dm(path: string, unit?: Unit): void;
  /** This solid as OCCT `.brep` text: exact surfaces and curves, a curve in
   *  each face's own parameters for every edge, no unit declared. */
  brepText(): string;
  /** `brepText()` written to `path` by the library itself. */
  brep(path: string): void;
  /** This solid's own wireframe as SVG text, from the camera `options` describes. */
  svgText(options?: SvgOptions): string;
  svgAsync(options?: SvgOptions): Promise<string>;
  /** `svgText` written to `path` by the library itself. */
  svg(path: string, options?: SvgOptions): void;
  /**
   * Where this solid's surfaces turn away from the eye (the camera `options` describes), as rational
   * cubic Beziers in `double`: `points` is twelve numbers a curve (four control points, x y z),
   * `weights` four. Copied out of the library's own block, which is released before this returns.
   * `count` 0 with empty arrays for a body with no silhouette (not an error); `BuildError` for a
   * refused option or a body with no measurable geometry.
   */
  silhouetteBeziers(options?: SvgOptions): SilhouetteCurves;
  selectFace(selector: Selector): number;
  /** An `RTree` over this solid's faces: one entry per face, its id the face index, its box holding the face (grown by a thousandth of the solid's extent). The tree outlives the solid. */
  faceTree(): RTree;
  faceFrame(face: number): number[];
  /** Face `face` by what it is, eight numbers (kind, point x y z, normal x y z, extent): what a feature made on the face keeps, to find the face again with `findFace` on a rebuilt solid. */
  faceRef(face: number): number[];
  /** The face `faceRef` refers to, `hint` the index it had; null where it is gone. */
  findFace(faceRef: Iterable<number>, hint?: number | null, tolerance?: number | null): number | null;
  /** Edge `edge` by what it is, fifteen numbers (kind, midpoint x y z, tangent x y z, length, the two faces' normals, span): `faceRef`'s twin, found again with `findEdge`. */
  edgeRef(edge: number): number[];
  /** The edge `edgeRef` refers to; null where it is gone. Throws for a reference that is not fifteen finite numbers. */
  findEdge(edgeRef: Iterable<number>, tolerance?: number | null): number | null;
  /** How many vertices this solid has: its edges' ends, welded. */
  readonly vertexCount: number;
  /** Vertex `vertex` by where it is: `[x, y, z]`. */
  vertexRef(vertex: number): number[];
  /** The vertex nearest `vertexRef` within `tolerance`; null where none is that near. */
  findVertex(vertexRef: Iterable<number>, tolerance?: number | null): number | null;
  /** This solid tracked: faces numbered 1..n, edges 1..m, each its own origin; tracking rides on through every verb. */
  tracked(): Solid;
  /** Whether this solid carries face and edge ids. */
  readonly isTracked: boolean;
  /** Face `face`'s id, null where this solid is untracked. Ids are numbers (they count up from 1 per solid). */
  faceId(face: number): number | null;
  /** The face whose id is `id`, null where no face has it. */
  faceWithId(id: number | bigint): number | null;
  /** The input faces face `face` came from, as `[operand, id]` pairs; empty for a generated face or an untracked solid. */
  faceOrigins(face: number): Origin[];
  /** Edge `edge`'s id, as `faceId`. */
  edgeId(edge: number): number | null;
  /** The edge whose id is `id`, null where no edge has it. */
  edgeWithId(id: number | bigint): number | null;
  /** The input edge edge `edge` lies on: one `[operand, id]`, or none for a new edge. */
  edgeOrigins(edge: number): Origin[];
  /** What the verb that made this solid did to the faces of `inputs`, passed in its operand order. */
  history(...inputs: Solid[]): History;
  /** `history` for the edges, by edge id. */
  edgeHistory(...inputs: Solid[]): History;
  /** This solid's attributes, read-only, in key order; written to STEP as user-defined attributes. */
  readonly attributes: ReadonlyMap<string, string>;
  /** Attribute `key`, null where this solid has none. */
  attribute(key: string): string | null;
  /** This solid with attribute `key` set to `value`: a new solid, tracked if this one was not. */
  withAttribute(key: string, value: string): Solid;
  /** This solid with every attribute given set, in key order. */
  withAttributes(attributes: Attributes): Solid;
  /** This solid without attribute `key`. */
  withoutAttribute(key: string): Solid;
  /** Face `face`'s attributes, read-only, in key order; they stay in memory. */
  faceAttributes(face: number): ReadonlyMap<string, string>;
  /** Face `face`'s attribute `key`, null where it has none. */
  faceAttribute(face: number, key: string): string | null;
  /** This solid with face `face`'s attribute `key` set to `value`. */
  withFaceAttribute(face: number, key: string, value: string): Solid;
  /** This solid with every attribute given set on face `face`, in key order. */
  withFaceAttributes(face: number, attributes: Attributes): Solid;
  /** This solid without face `face`'s attribute `key`. */
  withoutFaceAttribute(face: number, key: string): Solid;
  /** This solid, named `name`. The name rides through a one-source operation (`place`, `coloured`, ...),
   *  dropped by a two-source one (`join`, `cut`, `common`, ...) or a fresh primitive; see `name`. */
  named(name: string): Solid;
  /** This solid's name, or null if it has none -- what `named` set, kept or dropped by whatever built this solid. */
  readonly name: string | null;
  /** This solid made of `material`, written to STEP as its product's MATERIAL_DESIGNATION; kept by
   *  operations as its colour is (a boolean's result takes its first solid's). Refused when blank. */
  withMaterial(material: string): Solid;
  /** What this solid is made of, or null. */
  readonly material: string | null;
  /** This solid drawn in a style defined outside the file (`identification` in the library at
   *  `location`: a MaterialX or MDL file), written to STEP as an EXTERNALLY_DEFINED_STYLE beside
   *  its colour. Either may be null, not both. */
  styled(location?: string | null, identification?: string | null): Solid;
  /** Where this solid's outside style lives, or null. */
  readonly styleLocation: string | null;
  /** This solid's outside style's name in its library, or null. */
  readonly styleIdentification: string | null;
  coloured(colour: string | Iterable<number>, face?: number | null): Solid;
  readonly colour: [number, number, number] | null;
  faceColour(face: number): [number, number, number] | null;
  /** This solid with its edges coloured: every edge, or with `edges` (`Edge` objects or indices,
   *  as `fillet` takes them) just those, whose colour then wins over the all-edges one. An empty
   *  list colours no edge. Inherited as face colours are: a move keeps every one, a boolean or a
   *  fillet gives each edge the colour of the input edge it lies on, a new edge the all-edges one. */
  edgesColoured(colour: string | Iterable<number>, edges?: Iterable<Edge | number> | null): Solid;
  /** Edge `edge`'s (an `Edge` or its index) colour as drawn -- its own, else the solid's edge colour -- or null. */
  edgeColour(edge: Edge | number): [number, number, number] | null;
  /** This solid as a `Document`'s `solid.body` node holds it, parsed: the kernel's own B-rep as a record of its tables, and its colours. What `Document.addSolid` puts in a document. */
  documentBody(): { [key: string]: any };
  edges(): Edge[];
  /** A `radiusEnd` other than `radius` runs the radius along a spline edge (the varying fillet). */
  fillet(edges: Iterable<Edge | number>, radius: number, tolerance?: number | null, progress?: Progress | null, radiusEnd?: number | null): Solid;
  /** A chain of spline edges rounded with the radius following a law of `[share, radius]` stations along it (share: 0 to 1 of the chain's arc length). */
  filletLaw(edges: Iterable<Edge | number>, law: Iterable<[number, number]>, tolerance?: number | null): Solid;
  chamfer(edges: Iterable<Edge | number>, distance: number, tolerance?: number | null): Solid;
  pushPull(face: number | Iterable<number>, distance: number, tolerance?: number | null, progress?: Progress | null): Solid;
  mergeFlush(): Solid;
  refillet(face: number, radius: number, tolerance?: number | null): Solid;
  unfillet(face: number): Solid;
  rechamfer(face: number, distance: number, tolerance?: number | null): Solid;
  unchamfer(face: number): Solid;
  split(tool: Solid, tolerance?: number | null, progress?: Progress | null): Solid[];
  splitByPlane(plane: FrameLike, tolerance?: number | null, progress?: Progress | null): Solid[];
  splitByProfile(profile: Profile, frame: FrameLike, tolerance?: number | null, progress?: Progress | null): Solid[];
  lumps(): Solid[];
  shell(thickness: number, open?: Iterable<number>, tolerance?: number | null, progress?: Progress | null): Solid;
  thicken(thickness: number, tolerance?: number | null, progress?: Progress | null): Solid;
  filletAsync(edges: Iterable<Edge | number>, radius: number, tolerance?: number | null, progress?: Progress | null): Promise<Solid>;
  chamferAsync(edges: Iterable<Edge | number>, distance: number, tolerance?: number | null): Promise<Solid>;
  shellAsync(thickness: number, open?: Iterable<number>, tolerance?: number | null, progress?: Progress | null): Promise<Solid>;
  thickenAsync(thickness: number, tolerance?: number | null, progress?: Progress | null): Promise<Solid>;
  /**
   * `schema` as `stepText` takes it; the reader is given the schema's path only when
   * it names an existing file, since it carries every built-in schema itself.
   */
  toScene(schema?: string | null): Scene;
  static fromNode(scene: Scene, node: Node | number, placed?: boolean): Solid;
  static open(path: string, body?: number | null): Solid;
  static openAll(path: string): Solid[];
}
export function brepLayoutId(): string;
/** The pair kind `kind`'s freedom count (`spherical` 3, `revolute` 1, `fully_constrained` 0, and 0 for an unknown name). */
export function pairFreedomCount(kind: string): number;

/** One freedom's range for `Assembly.pair`'s `ranges`: `null` (unbounded) or a `[lower, upper]` pair with either side `null`. */
export type PairRange = [number | null, number | null] | null;
export interface PairOptions {
  endFrame?: FrameLike | null;
  ranges?: Iterable<PairRange> | null;
  pitch?: number | null;
}

/** A joint (or state) key: a path string, or an array of names that `posed` escapes and joins. */
export type JointKey = string | Iterable<string>;
export type PosedValues = Map<JointKey, number | Iterable<number>> | Iterable<[JointKey, number | Iterable<number>]> | { [joint: string]: number | Iterable<number> };
export interface PosedOptions {
  /** A state's path, applied first and overridden row by row. */
  state?: JointKey | null;
  /** One of the assembly's own links, held fixed. */
  ground?: string | null;
}
/** `Assembly.sweptClash`'s options. */
export interface AssemblySweptClashOptions {
  /** How close counts as a clash, 0 by default. */
  clearance?: number;
  /** The meshing tolerance, 0.05 by default. */
  tolerance?: number;
  /** How closely an interval's end is found, in (0, 1], 1e-3 by default. */
  resolution?: number;
  /** The pose-wise tests one pair may take, 100000 by default. */
  maxSteps?: number;
  /** Pairs of part indices never tested, flattened: `[a0, b0, a1, b1, ...]`. */
  allowed?: ArrayLike<number>;
  /** One of this assembly's links held fixed; null for its default. */
  ground?: string | null;
  /** Test pairs on two links a joint joins too. */
  joined?: boolean;
}

export interface PairWithOptions {
  endFrame?: FrameLike | null;
  ranges?: Iterable<PairRange> | null;
  params?: Iterable<number>;
}

/**
 * A mutable tree of placements: a name, and zero or more solids or other assemblies placed in
 * it at a frame. Unlike `Solid`, placing shares rather than copies. `close()` frees this
 * handle; it does not free what was placed in it if that is still reachable elsewhere.
 */
export class Assembly {
  constructor(name: string);
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  readonly name: string;
  /**
   * Place `thing` (a `Solid` or another `Assembly`) at `frame` in this assembly, called `name`
   * -- or, left null, `thing`'s own name (`Solid.name`, `"part"` for an unnamed solid, or the
   * placed assembly's own `name`), numbered past any already taken here (`"bolt"`, `"bolt 2"`,
   * ...). Throws for a duplicate explicit name or a cycle. Returns the placement's name.
   */
  place(thing: Solid | Assembly, frame: FrameLike, name?: string | null): string;
  /**
   * Declare a rigid link called `name` over `placements` (names of placements of this
   * assembly itself). Throws for an empty name, a name taken by another link here, no
   * placements, a placement named twice, one this assembly does not have, or one already
   * in another link. A bare string for `placements` throws a `TypeError` before any call.
   */
  link(name: string, placements: Iterable<string>): void;
  /**
   * Connect this assembly's links `start` and `end` (kept in that order) as a joint called
   * `name`. Throws for an empty name, a name taken by another joint here, a link this
   * assembly does not have, a link joined to itself, or a (start, end) pair already joined.
   */
  joint(name: string, start: string, end: string): void;
  /**
   * Give joint `joint` its pair: `kind` (`revolute`, `prismatic`, `cylindrical`, `screw`,
   * `spherical`, `spherical_with_pin`, `planar`, `universal`, `homokinetic`,
   * `fully_constrained` or `unconstrained`), the contact `frame` at rest, and `options`.
   * Throws the kernel's own text when a rule refuses it; the assembly is then unchanged.
   */
  pair(joint: string, kind: string, frame: FrameLike, options?: PairOptions): void;
  /**
   * `pair` with the kind's own numbers in place of the pitch, for the coupled pairs: `kind` any
   * name `pair` takes, or `gear` or `rack_and_pinion`; `params` `[pitch]` for a screw,
   * `[pinionRadius]` for a rack and pinion, `[radiusFirst, radiusSecond, ratio]` or those plus
   * `[bevel, helicalAngle]` (radians) for a gear -- the ratio the second link's rotation over the
   * first's, signed -- and none for any other kind. Throws the kernel's own text when a rule
   * refuses it (a wrong number of parameters among them); the assembly is then unchanged.
   */
  pairWith(joint: string, kind: string, frame: FrameLike, options?: PairWithOptions): void;
  /**
   * Add a named state to this assembly: `rows` is a `Map` or an iterable of `[joint, values]`
   * pairs, each joint's values in its pair's freedom order. Throws the kernel's own text when
   * a rule refuses it; the assembly is then unchanged.
   */
  state(name: string, rows: Map<string, Iterable<number>> | Iterable<[string, Iterable<number>]>): void;
  /**
   * This assembly with its mechanism posed, as a NEW `Assembly` the caller owns (`close()` it);
   * this one is unchanged either way. `values` maps joint keys to values: a key a path of
   * placement names then the joint's name joined by "/" (a "/" or backslash inside a name escaped
   * with a backslash), or an array of the names, which this escapes and joins; a value one number
   * for a one-freedom joint, else a list in the pair's freedom order. Throws the kernel's own text
   * when it refuses (an ambiguous name, a value out of range, an unknown state).
   */
  posed(values?: PosedValues | null, options?: PosedOptions): Assembly;
  /**
   * The placement path of every solid under this assembly, at any depth: depth first,
   * placements in order, names joined by "/" with a "/" or backslash inside a name escaped with
   * a backslash (as `posed`'s keys). The index `sweptClash`'s rows use.
   */
  parts(): string[];
  /**
   * Every pair of this assembly's solids (indexed as `parts()` lists them) that penetrates,
   * touches or comes within `clearance` (0 by default) of the other anywhere while this
   * assembly's own mechanism moves through `keyframes`, as `SweptClash` rows. Each keyframe is
   * `posed`'s `values`, and every keyframe names the same joints with as many values each (the
   * first fixes their order); keyframe `k` is at time `k`. Between two keyframes each joint value
   * moves linearly, so a link swinging about a joint goes round its arc. Only this assembly's own
   * joints move: a sub-assembly rides the link its placement is in. `ground` one of this
   * assembly's links held fixed; pairs on two links a joint joins are tested only when `joined`;
   * `allowed` flattened pairs of part indices never tested. `tolerance` (0.05) meshes the parts;
   * `resolution` (1e-3) and `maxSteps` (100000) as `Collider.sweptClash`. Throws in the
   * kernel's `swept_clash:` words.
   */
  sweptClash(keyframes: Iterable<PosedValues>, options?: AssemblySweptClashOptions): SweptClash[];
  /**
   * Add a named motion sequence over this assembly's states: `segments` are `[state, t,
   * interpolation]` rows, the interpolation `'undefined'`, `'discontinuous'`, `'synchronous'` or
   * `'linear'`; `seconds` writes the parameter's unit as the second. Closed unless the last
   * segment is `'discontinuous'`. Throws the kernel's own text when a rule refuses it.
   */
  sequence(name: string, segments: Iterable<[string, number, 'undefined' | 'discontinuous' | 'synchronous' | 'linear']>, seconds?: boolean): void;
  /** Declare this assembly's base link. Throws the kernel's own text when a rule refuses it. */
  base(link: string): void;
  stepText(schema?: string | null, unit?: Unit): string;
  step(path: string, schema?: string | null, unit?: Unit): void;
  /**
   * This assembly, and everything placed under it, as one Rhino `.3dm`: each distinct part a
   * block holding its body, each sub-assembly a block of references to what it places, and
   * this assembly's own placements references at the top of the file, on a layer named after
   * it. `unit` and the warnings as `rhino3dmBytes`; throws, as `stepText` does, for an
   * assembly reachable from this one that places nothing.
   */
  rhino3dmBytes(unit?: Unit): Buffer;
  /** `rhino3dmBytes` written to `path` by the library itself. */
  write3dm(path: string, unit?: Unit): void;
  /** This assembly as a reader `Scene`, through STEP text; see `Solid.toScene`. */
  toScene(schema?: string | null): Scene;
}

export class Selector {
  static max(axis: AxisValue): Selector;
  static min(axis: AxisValue): Selector;
  static normal(direction: Point3): Selector;
  static index(i: number): Selector;
}
/**
 * One edge's exact curve, as plain data (`Edge.curve`): `kind` is `line`, `circle`, `ellipse`, `parabola`, `hyperbola` or `nurbs`.
 *
 * `t0..t1` is the edge's parameter range on its own curve: a line's fraction (0..1 over
 * `origin -> origin + x`, where `x` is the full `to - from`, NOT unit -- so `point(t) = origin + x*t`);
 * a circle's or ellipse's angle in radians about `origin` in the `x, y` plane
 * (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`, `radius2 = radius` for a circle);
 * a NURBS's knot parameter (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are
 * unit for conics; for a line `x` is the direction with length = the line's length and `y, z` are zero.
 *
 * For a NURBS the frame is zero and so are the radii; for a conic or a line `degree` is 0 and
 * `knots`, `poles` are empty. `knots.length === poles.length + degree + 1`; `weights` is one per
 * pole, or null for a non-rational (plain B-spline) curve, a conic or a line.
 */
export class Curve {
  private constructor();
  kind: string;
  origin: number[]; x: number[]; y: number[]; z: number[];
  radius: number; radius2: number; t0: number; t1: number;
  degree: number; knots: number[]; poles: number[][]; weights: number[] | null;
  /** This curve as a value: a `Line`, a `Circle` (a full turn), an `Arc` or an `Ellipse`; null for any other kind. */
  readonly value: CurveValue | null;
}
/** An input face (or edge) a result's face came from: `[operand, id]`, the operand its input's index in the verb's operand order. */
export type Origin = readonly [number, number];
/** Attributes to set: a `Map`, `[key, value]` pairs, or an object. */
export type Attributes = ReadonlyMap<string, string> | Iterable<readonly [string, string]> | Readonly<Record<string, string>>;
/** What a verb did to its inputs' faces (or edges): `Solid.history`, `Solid.edgeHistory`. Frozen. */
export class History {
  private constructor();
  /** The inputs that became exactly one output and kept their id: `[input, outId]`. */
  readonly kept: readonly (readonly [Origin, number])[];
  /** The inputs split, merged or renumbered: `[input, outIds]`, a split's id-keeping piece first. */
  readonly modified: readonly (readonly [Origin, readonly number[]])[];
  /** The outputs with no origin, in id order. */
  readonly generated: readonly number[];
  /** The inputs no output names. */
  readonly deleted: readonly Origin[];
  /** `History(kept=6, modified=1, generated=0, deleted=2)`. */
  toString(): string;
}
/** What `Solid.hits` found: `hits` (a on the profile, b on the solid's faces) and `pieces` (empty for an open body). */
export class SolidHits {
  private constructor();
  hits: Hit[];
  pieces: Piece[];
}
/**
 * One stretch of a profile loop between two cuts: `inside` (a piece lying on the surface is
 * inside), `start`/`end` profile spots, and `profile`, the piece's own open chain.
 */
export class Piece {
  private constructor();
  inside: boolean;
  start: Spot; end: Spot;
  profile: Profile;
}
/**
 * What `Solid.intersect` found: `chains` (one per face pair per branch) and `overlaps` (one per
 * coincident face pair). Both empty where the solids do not meet.
 */
export class Intersection {
  private constructor();
  chains: Chain[];
  overlaps: Overlap[];
}
/**
 * One branch of one face pair's crossing: `points` in walk order (a closed chain does not repeat
 * its first point), `closed`, `faces` (`[face in a, face in b]`), `tangent` (the surfaces
 * near-tangent along it, or the snap unsettled) and `curve`, its exact curve over the chain's own
 * `t0..t1`, or null where the kernel found none. A chain may stop at a face boundary or a closed
 * curve's seam and continue as another: join chains by matching ends.
 */
export class Chain {
  private constructor();
  points: number[][];
  closed: boolean;
  faces: [number, number];
  tangent: boolean;
  curve: Curve | null;
}
/**
 * A coincident face pair: `faces` (`[face in a, face in b]`) and `loops`, the shared region's rings
 * (outer first, holes after; each ring closed without repeating its first point) -- empty for a
 * partial overlap of curved faces whose outlines cross.
 */
export class Overlap {
  private constructor();
  faces: [number, number];
  loops: number[][][];
}
/** An axis-aligned box: `lo` and `hi`, three-tuples. The broad phase's own shape
 *  (`Solid.boundsBox`, `Collider`'s own boxes). */
export class Box {
  lo: [number, number, number];
  hi: [number, number, number];
  constructor(lo: ArrayLike<number>, hi: ArrayLike<number>);
  /** This box moved by `frame` (rigid), boxed again on the world axes. */
  moved(frame: FrameLike): Box;
  /** Whether this box and `other` share a point (touching counts). */
  overlaps(other: Box): boolean;
}
/**
 * True only if box `a` at `frameA` and box `b` at `frameB` cannot touch -- a separating axis
 * among the boxes' face normals and edge-direction crosses; touching is not apart. Sharper than
 * moving each box and asking `overlaps`, which boxes the *result* on the world axes again.
 */
export function boxesApart(a: Box, frameA: FrameLike, b: Box, frameB: FrameLike): boolean;
/** Counts of one `Collider.check` call -- see `CadaclysmBlacksmithColliderStats`'s own doc. */
export interface ColliderStats {
  considered: number;
  worldBoxes: number;
  orientedBoxes: number;
  skippedShare: number;
  cached: number;
  closedForm: number;
  meshed: number;
  refused: number;
  confirmed: number;
}
/**
 * One pair `Collider.check` found overlapping (`kind === 'overlap'`), or could not decide
 * (`kind === 'refused'`, `text` says why): `depth` the thinnest side of the overlap's world box (0
 * for a refused pair), `positions`/`normals` world xyz triples (three per triangle, unwelded) and
 * `indices` into them -- all empty for a refused pair.
 */
export class CollisionHit {
  private constructor();
  a: number;
  b: number;
  kind: 'overlap' | 'refused';
  depth: number;
  text: string;
  positions: Float64Array;
  normals: Float64Array;
  indices: Uint32Array;
  /** The exact overlap of this pair at the frames it was found at, as a new solid. Throws for a
   *  refused pair, or a collisions handle already closed some other way. */
  solid(): Solid;
}
/** What a clash row found: the parts' interiors overlap, their boundaries lie within the
 *  tolerance of each other, they are apart by less than the clearance, or the pair could not be
 *  decided. */
export type ClashKind = 'penetrating' | 'touching' | 'too_close' | 'refused';
/**
 * One pair `Collider.clash` or `clash` found: `a`, `b` the part indices (for one set or a collider
 * `a < b`; for two sets `a` indexes the first and `b` the second), `kind` (see `ClashKind`;
 * `text` says why for a refused pair). `distance` is the gap between the two boundaries (0 for a
 * penetrating or refused pair); `onA`/`onB` world points -- the closest pair, or for a
 * penetrating pair the centre of the overlap's world box. `kindA`, `indexA`, `edgeA` (and `B`)
 * say what each point lies on as `Solid.closest` does; for a penetrating or refused pair the
 * kinds are `'none'` and the indices and edges null. `refined` is true where the distance is
 * measured on the exact surfaces; `depth` the thinnest side of a penetrating pair's overlap box
 * (0 otherwise). Every row of one call keeps that call's handle alive until the last of them is
 * unreachable.
 */
export class Clash {
  private constructor();
  a: number;
  b: number;
  kind: ClashKind;
  distance: number;
  onA: number[];
  onB: number[];
  kindA: 'face' | 'edge' | 'vertex' | 'none';
  /** The kernel's id for side `a`'s feature; null for kind `'none'`. */
  indexA: number | null;
  /** The index `fillet` and `Solid.edges` use for side `a`'s edge; null for a face, a vertex, an edge the fillet table does not hold, or kind `'none'`. */
  edgeA: number | null;
  kindB: 'face' | 'edge' | 'vertex' | 'none';
  indexB: number | null;
  edgeB: number | null;
  refined: boolean;
  depth: number;
  text: string;
  /** The exact shared volume of this penetrating pair at the placement it was found at, as a new
   *  solid. Throws for a pair that is not penetrating. */
  solid(): Solid;
  /** Where this pair's two parts cross or coincide at the placement it was found at, as
   *  `Solid.intersect` reports it (a touching pair's shared face is an `Overlap`). Throws for a
   *  refused pair. */
  intersect(): Intersection;
}
/**
 * One pair `Collider.sweptClash` or `sweptClash` found: `a`, `b` the part indices (for one set or
 * a collider `a < b`; for two sets `a` indexes the first and `b` the second). `firstTime` is the
 * first time the pair came within the clearance, in pose units (pose `k` at time `k`; for a
 * refused pair the time it was refused at), and `first` the `Clash` there, at the frames the
 * motion places the parts at that time, so `first.solid()` and `first.intersect()` rebuild the
 * contact there. `intervals` are the time ranges the pair stays in clash, `[start, end]` pairs,
 * ascending and disjoint (none for a refused pair).
 */
export class SweptClash {
  private constructor();
  a: number;
  b: number;
  firstTime: number;
  first: Clash;
  intervals: [number, number][];
}
/**
 * A closed solid meshed once and asked where point after point lies (`Solid.classifier`). It keeps
 * its own reference to the body, so it answers on after that solid is closed. `close()` frees this
 * handle; so does leaving a `using` block or the garbage collector.
 */
export class Classifier {
  constructor(solid: Solid, tolerance?: number | null);
  close(): void;
  readonly closed: boolean;
  [Symbol.dispose](): void;
  /** Where `point` is: inside, outside, or on within the tolerance of the boundary. */
  contains(point: Point3): Containment;
}
/**
 * A solid meshed once and asked for its nearest point to point after point (`Solid.projector`).
 * It keeps its own reference to the body, so it answers on after that solid is closed. `close()`
 * frees this handle; so does leaving a `using` block or the garbage collector.
 */
export class Projector {
  constructor(solid: Solid, tolerance?: number | null);
  close(): void;
  readonly closed: boolean;
  [Symbol.dispose](): void;
  /** `Solid.closestPoint`'s answer at the projector's tolerance; null beyond `maxDistance` (undefined, null, NaN or Infinity: no limit). */
  closestPoint(p: Point3, maxDistance?: number | null): PointFoot | null;
  /** `Solid.curveClosestPoints`' answer at the projector's tolerance; null beyond `maxDistance` (undefined, null, NaN or Infinity: no limit). The projector's lock is held for the whole curve query. */
  curveClosestPoints(curve: NurbsCurve, maxDistance?: number | null): CurveBodyFoot | null;
}
/**
 * Parts meshed once, asked pose after pose which of them interfere. `close()` frees this handle;
 * so does leaving a `using` block or the garbage collector.
 */
export class Collider {
  /**
   * `solids` at rest, meshed at `tolerance`; `groups` one group index per solid (omitted: each
   * solid its own group -- `check` then takes one frame per solid), `allowed` pairs of part
   * indices never tested (designed contacts, flattened: `[a0, b0, a1, b1, ...]`).
   */
  constructor(solids: Solid[], tolerance?: number | null, groups?: ArrayLike<number> | null, allowed?: ArrayLike<number>);
  close(): void;
  readonly closed: boolean;
  [Symbol.dispose](): void;
  /** How many groups this collider has -- the highest group index past the constructor, plus one. */
  readonly groupCount: number;
  readonly stats: ColliderStats;
  /**
   * The pairs that interfere, or could not be decided, with each group placed at its matching
   * frame in `frames` (one per group, in group order). `share`: omitted, every pair past the box
   * filters is decided now; `[k, n]`, only those whose index is `k` modulo `n`. `[k, 0]` is the
   * same as omitted: the C ABI reads `n` 0 as every pair.
   */
  check(frames: FrameLike[], share?: [number, number] | null): CollisionHit[];
  /**
   * Every pair of parts that penetrates, touches or lies within `clearance` (0 by default; zero
   * or more) of the other, as `Clash` rows in pair order, with each group placed at its matching
   * frame in `frames` (as for `check`); `share` as for `check`. The collider keeps each measured
   * part's closest mesh for its lifetime. Throws for a negative or non-finite `clearance`, the
   * wrong number of frames or a bad `share`.
   */
  clash(frames: FrameLike[], clearance?: number, share?: [number, number] | null): Clash[];
  /**
   * Every pair of parts that penetrates, touches or comes within `clearance` (0 by default) of
   * the other anywhere on the path through `poses` -- not only at the poses -- as `SweptClash`
   * rows in pair order. `poses` is two or more poses, each the `frames` `clash` takes. Between
   * two poses each group moves rigidly about the centre of its rest box (straight line, steady
   * shorter-way rotation); time runs in pose units. `resolution` (1e-3 by default, in (0, 1]) is
   * how closely an interval's end is found; `maxSteps` (100000 by default) the pose-wise tests
   * one pair may take -- past it the pair is a `'refused'` row. `share` as for `check`, over the
   * pairs whose swept boxes meet. Throws for fewer than two poses, the wrong number of frames in
   * a pose, a bad frame, `clearance`, `resolution` or `share`, or `maxSteps` 0.
   */
  sweptClash(poses: Iterable<Iterable<FrameLike>>, clearance?: number, resolution?: number, maxSteps?: number, share?: [number, number] | null): SweptClash[];
}
/** An R-tree box: `[min, max]` (two triples), a `Box`, `{ min, max }`, or 6 numbers `[minx, miny, minz, maxx, maxy, maxz]`; a point (3 numbers) stands for a zero box. */
export type RTreeBox = [ArrayLike<number>, ArrayLike<number>] | Box | { min: ArrayLike<number>; max: ArrayLike<number> } | ArrayLike<number>;
/** One `within` / `nearest` answer: `[id, distance]`, the distance from the point to the entry's box (0 inside it). */
export type RTreeHit = [number, number];
/** One overlapping pair of entry ids, `[a, b]`. */
export type RTreePair = [number, number];
/**
 * A spatial index over boxes with ids (an R*-tree). Ids are whole numbers from 0 to 4294967295,
 * the caller's own, and may repeat. Answers come in a fixed order: `search` ids ascending,
 * `within` / `nearest` by distance then id, pairs ascending. The tree changes in place;
 * `close()` frees it; so does leaving a `using` block or the garbage collector.
 */
export class RTree {
  /** An empty tree. */
  constructor();
  /** A tree over `[id, box]` pairs at once, packed: fuller and faster to query than inserting them one by one. */
  static fromBoxes(entries: Iterable<[number, RTreeBox]>): RTree;
  /** A tree over `points`, each a zero box whose id is its index. */
  static fromPoints(points: Iterable<Point3>): RTree;
  /** A tree over a mesh's triangles (three indices into `positions` each), one entry per triangle, its id the triangle's index, its box its three corners' box. */
  static fromTriangles(positions: Iterable<Point3>, triangles: Iterable<ArrayLike<number>>): RTree;
  close(): void;
  readonly closed: boolean;
  [Symbol.dispose](): void;
  /** How many entries the tree holds. */
  readonly count: number;
  /** The union of every entry's box as `[min, max]`, or null for an empty tree. */
  readonly bounds: [number[], number[]] | null;
  /** Add the entry `[id, box]`, `box` a box or a point. */
  insert(id: number, box: RTreeBox): void;
  /** Take out one entry equal to `[id, box]` (the box it was inserted with); false when there is none. */
  remove(id: number, box: RTreeBox): boolean;
  /** The ids of every entry whose box meets `box` (touching counts), ascending. */
  search(box: RTreeBox): number[];
  /** Every entry whose box is within `r` of `point`, by distance then id. */
  within(point: Point3, r: number): RTreeHit[];
  /** The `k` (0 to 1,000,000) entries nearest `point`, by distance then id; all of them when `k` is over the count. */
  nearest(point: Point3, k: number): RTreeHit[];
  /** Every entry whose box the ray `origin + t * direction`, `0 <= t <= maxT` (Infinity by default), meets, as `[id, t]` by `t` then id, `t` where the ray enters the box (0 inside it). */
  ray(origin: Point3, direction: Point3, maxT?: number): RTreeHit[];
  /** Every pair `[a, b]`, `a` an entry of this tree and `b` one of `other`, at most `slack` (0 by default) apart, ascending. */
  overlaps(other: RTree, slack?: number): RTreePair[];
  /** Every unordered pair of distinct entries at most `slack` apart, once each as `[smaller id, larger id]`, ascending. */
  selfOverlaps(slack?: number): RTreePair[];
}
/** For each of `needles`, the indices of the `hay` points within `limit` of it, by distance then index. */
export function closestPoints(hay: Iterable<Point3>, needles: Iterable<Point3>, limit: number): number[][];
/** For each of `needles`, the indices of the `k` (0 to 1,000,000) nearest `hay` points, by distance then index. */
export function kNeighbors(hay: Iterable<Point3>, needles: Iterable<Point3>, k: number): number[][];
/**
 * Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
 * `others` -- that penetrates, touches or lies within `clearance` (0 by default) of the other,
 * as `Clash` rows, the solids as they stand, meshed at `tolerance` (0.05 by default). `allowed`
 * pairs never tested, flattened as `Collider`'s (`[a0, b0, a1, b1, ...]`; with `others` an index
 * in `parts` then one in `others`). Throws for an empty `others`, an `allowed` of odd length or
 * with an entry that is not a whole number from 0 to 4294967295 or out of range, a bad
 * `clearance` or `tolerance`, or a part that is not a closed solid.
 */
export function clash(parts: Iterable<Solid>, others?: Iterable<Solid> | null, clearance?: number, tolerance?: number | null, allowed?: ArrayLike<number>): Clash[];
/**
 * Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
 * `others` -- that penetrates, touches or comes within `clearance` (0 by default) of the other
 * anywhere on a path, as `SweptClash` rows. Each part is its own group: pose `k` of `poses` is one
 * frame per part of `parts`, pose `k` of `otherPoses` one per part of `others` (the two go
 * together, and have as many poses). The motion, `resolution` and `maxSteps` are
 * `Collider.sweptClash`'s; `tolerance` the meshing tolerance (0.05 by default); `allowed` as
 * `clash`'s. Throws as `Collider.sweptClash` does, and for `others` without `otherPoses` (or the
 * other way round), pose counts that differ, a pose with the wrong number of frames, an empty
 * `others`, an `allowed` `clash` refuses, or a part that is not a closed solid.
 */
export function sweptClash(parts: Iterable<Solid>, poses: Iterable<Iterable<FrameLike>>, others?: Iterable<Solid> | null, otherPoses?: Iterable<Iterable<FrameLike>> | null, clearance?: number, tolerance?: number | null, resolution?: number, maxSteps?: number, allowed?: ArrayLike<number>): SweptClash[];
/**
 * One wall-thickness reading on a solid (`ThicknessGauge.thickness` / `.thicknessAt`, `thickness`).
 * `point` lies on face `face` of body `body` (the body's index in the gauge): at vertex `vertex` of
 * that body's measuring mesh (`ThicknessGauge.mesh`), or `vertex` null for a reading at a point.
 * `thickness` is the nearest-opposing-wall rule on the measuring mesh, to `opposite` on face
 * `oppositeFace` of body `oppositeBody`; `knife` marks a knife edge (thickness 0, `opposite` ==
 * `point`). `exactOpposite` is `opposite` moved onto its exact face where its foot lies within the
 * tolerance and inside the face's trims, `exactThickness` the distance to it. `sphere` is the
 * diameter of the largest ball tangent at `point` that holds none of the surfaces, null where none
 * under the maximum does (0 on a knife edge).
 */
export class Thickness {
  private constructor();
  body: number;
  vertex: number | null;
  face: number;
  point: number[];
  thickness: number;
  opposite: number[];
  oppositeBody: number;
  oppositeFace: number;
  knife: boolean;
  exactThickness: number;
  exactOpposite: number[];
  sphere: number | null;
}
/** A face's thickness, found: `thickness` the median of the face's vertex readings (or the reading at `at`), `min` and `max` their extremes, `uniform` whether `max - min` is within the gauge's tolerance. */
export class FaceThickness {
  private constructor();
  thickness: number;
  min: number;
  max: number;
  uniform: boolean;
}
/** A body's measuring mesh, copied out of the gauge: `positions` and `normals` (unit, outward) one `[x, y, z]` per vertex (a reading's `vertex` indexes them), `triangles` three vertex indices each, `faces` the B-rep face of each triangle. */
export class ThicknessMesh {
  private constructor();
  positions: number[][];
  normals: number[][];
  triangles: number[][];
  faces: number[];
}
/** One reading on a plain mesh (`meshThickness`): vertex `vertex` of mesh `mesh`, at `point`, reads `thickness` to `opposite` on triangle `oppositeTriangle` of mesh `oppositeMesh`. `knife`: a knife edge, thickness 0 and `opposite` == `point`. */
export class MeshThickness {
  private constructor();
  mesh: number;
  vertex: number;
  thickness: number;
  point: number[];
  opposite: number[];
  oppositeMesh: number;
  oppositeTriangle: number;
  knife: boolean;
}
/** The options of a face-thickness call: `at` a point whose foot on the face is measured (omitted or null: over the face's vertices), `maximum` the limit (positive and finite; no default). */
export interface ThicknessAtFaceOptions { at?: Point3 | null; maximum: number }
/**
 * Wall thickness (the nearest-opposing-wall rule) over `solids`, measured against each other: each
 * solid meshed once at `tolerance` -- absolute, in model units (0.01 by default) -- then asked as
 * often as needed. A reading's `body` is the solid's index in `solids`. The gauge keeps its own
 * reference to the bodies, so it answers on after the solids are closed. `close()` frees this
 * handle; so does leaving a `using` block or the garbage collector. Throws for a `tolerance` not
 * positive and finite.
 */
export class ThicknessGauge {
  constructor(solids: Iterable<Solid>, tolerance?: number | null);
  close(): void;
  readonly closed: boolean;
  [Symbol.dispose](): void;
  /** How many bodies the gauge measures. */
  readonly bodyCount: number;
  /** The tolerance the gauge meshed its bodies at. */
  readonly tolerance: number;
  /** One reading per measuring-mesh vertex that has one within `maximum` (positive and finite), by body then vertex; vertices whose interior angle is under `sharpAngle` radians (0 by default) are knife edges. */
  thickness(maximum: number, sharpAngle?: number): Thickness[];
  /** The reading at `point`'s foot on face `face` of body `body` (its `vertex` null), or null where the foot lies off the face or the wall is thicker than `maximum`. */
  thicknessAt(body: number, face: number, point: Point3, maximum: number, sharpAngle?: number): Thickness | null;
  /** One thickness for face `face` of body `body`, at `at`'s foot or over the face's vertices; null where nothing is found. The `maximum` has no default. */
  thicknessAtFace(body: number, face: number, options: ThicknessAtFaceOptions): FaceThickness | null;
  /** Body `body`'s measuring mesh, copied out (it outlives the gauge). */
  mesh(body: number): ThicknessMesh;
}
/** `new ThicknessGauge(solids, tolerance).thickness(maximum, sharpAngle)` on a gauge used once and freed: every reading within `maximum` on the solids, measured against each other. */
export function thickness(solids: Iterable<Solid>, maximum: number, sharpAngle?: number, tolerance?: number | null): Thickness[];
/** A plain mesh for `meshThickness`: `{ positions, triangles }` or a `[positions, triangles]` pair, `[x, y, z]` points and triples of indices into its own points. */
export type ThicknessMeshInput = { positions: Iterable<ArrayLike<number>>; triangles: Iterable<ArrayLike<number>> } | [Iterable<ArrayLike<number>>, Iterable<ArrayLike<number>>];
/** The nearest-opposing-wall rule on plain meshes measured against each other: one reading per vertex that has one within `maximum`, by mesh then vertex. `sharpAngle` as for `ThicknessGauge.thickness`. */
export function meshThickness(meshes: Iterable<ThicknessMeshInput>, maximum: number, sharpAngle?: number): MeshThickness[];
/** One side of one face bounding a region: `sense` +1 where the region is the side the face's normal points to, -1 the other. */
export interface FaceSide { readonly face: number; readonly sense: 1 | -1 }
/**
 * One region of space a solid's faces bound (`Solid.regions`): its `index` (0 the infinite region,
 * whose `finite` is false), the `box` round its faces, its `sides` ascending by face then sense,
 * and its `shells` -- 1, plus one per void inside it. A plain frozen object.
 */
export interface Region {
  readonly index: number;
  readonly finite: boolean;
  readonly box: Box;
  readonly sides: readonly FaceSide[];
  readonly shells: number;
}
/** An interpolator's mode, by Python's names; `'linear'` is the default. */
export type InterpolatorMode = 'nearest' | 'linear' | 'cosine' | 'cubic' | 'catmull_rom';
/**
 * A list of samples read at a fractional index, as Rhino's `Interpolator`: `t = 2.5` is halfway
 * between samples 2 and 3. Samples are numbers (answered as numbers) or equal-length arrays of
 * numbers (answered as arrays). An open list clamps `t` to its ends; a `cyclic` one wraps it.
 * It never changes once made; `close()` frees it, so does leaving a `using` block or the garbage collector.
 */
export class Interpolator {
  constructor(samples: Iterable<number> | Iterable<ArrayLike<number>>, cyclic?: boolean);
  close(): void;
  readonly closed: boolean;
  [Symbol.dispose](): void;
  /** How many samples. */
  readonly count: number;
  /** How many numbers per sample: 1 answers numbers, more answers arrays. */
  readonly dimension: number;
  /** Whether `t` wraps round the list (else it is clamped to the ends). */
  readonly cyclic: boolean;
  /** The value at the fractional index `t` by `mode` (`'linear'` by default): a number at dimension 1, an array otherwise. */
  at(t: number, mode?: InterpolatorMode): number | number[];
  /** The values at every `t` of `ts` by `mode`, as `at` reads each, in one call. */
  sample(ts: Iterable<number>, mode?: InterpolatorMode): (number | number[])[];
  nearest(t: number): number | number[];
  linear(t: number): number | number[];
  cosine(t: number): number | number[];
  cubic(t: number): number | number[];
  catmullRom(t: number): number | number[];
}
/** A curve's bending at a parameter (`NurbsCurve.curvature`). Frozen. */
export class Curvature {
  private constructor();
  /** 1 / radius. */
  readonly kappa: number;
  readonly tangent: number[];
  /** The unit normal toward the centre; zero on a straight piece. */
  readonly normal: number[];
  /** `tangent x normal`; zero on a straight piece. */
  readonly binormal: number[];
  /** The centre of the osculating circle; null on a straight piece. */
  readonly centre: number[] | null;
}
/** A side of a sheet's face: a boundary isocurve of its NURBS surface. */
export type SheetSide = 'u0' | 'u1' | 'v0' | 'v1';
export type SweepFrame = 'rmf' | 'fixed';
export type TrimKeep = 'outside' | 'inside' | 'left' | 'right';
/** One side of an N-sided patch's hole: a curve (met at G0), `[sheet, side, level?]` or an object. */
export type PatchBoundary = NurbsCurve | [Solid, SheetSide] | [Solid, SheetSide, number]
  | { sheet: Solid; side: SheetSide; level?: number; face?: number; range?: [number, number] };
/** How well two faces meet along their sides (`Solid.continuity`). Frozen. */
export class Continuity {
  private constructor();
  readonly gap: number;
  readonly gapAt: number[];
  readonly angle: number;
  readonly angleAt: number[];
  readonly curvature: number;
  readonly curvatureAt: number[];
  readonly samples: number;
}
/** How smoothly a curve runs through its own knots (`NurbsCurve.knotContinuity`). Frozen. */
export class KnotContinuity {
  private constructor();
  readonly angle: number;
  readonly angleParameter: number;
  readonly angleAt: number[];
  readonly curvature: number;
  readonly curvatureParameter: number;
  readonly curvatureAt: number[];
}
/** A fair's span free of inflections: off (null/false), the whole curve (true), or `[from, to]` with null an open end. */
export type NoInflection = boolean | null | [number | null, number | null];
/** What `Solid.faired` keeps of each side: one level for all four, per side by name, or a 4-array `[u0, u1, v0, v1]`; null free to move, 0 position, 1 tangent plane, 2 curvature. */
export type SheetKeep = number | null | Partial<Record<SheetSide, number | null>> | [number | null, number | null, number | null, number | null];
/** Where a face's curvatures change sign (`Solid.curvatureTurns`). Frozen. */
export class CurvatureTurns {
  private constructor();
  readonly gaussianPositive: number;
  readonly gaussianNegative: number;
  /** The points between opposite Gaussian signs: `tangent` the face's unit normal, `parameter` its `u`. */
  readonly gaussianTurns: At[];
  readonly meanPositive: number;
  readonly meanNegative: number;
  /** The points between opposite mean-curvature signs. */
  readonly meanTurns: At[];
  readonly samples: number;
}
/** The worst kink of the highlight lines crossing an edge (`Solid.highlightKink`): `angle` in radians, where, and the light tube that shows it. Frozen. */
export class HighlightKink {
  private constructor();
  readonly angle: number;
  readonly at: number[];
  readonly lightPoint: number[];
  readonly lightDirection: number[];
  readonly samples: number;
}
/** How well an N-sided patch meets (`Solid.patchReport`). Frozen. */
export class PatchReport {
  private constructor();
  readonly faces: number;
  readonly boundary: Continuity;
  readonly internal: Continuity;
  readonly cornerAngle: number;
}
/** What `Solid.joinSheets` did. Frozen. */
export class JoinReport {
  private constructor();
  readonly sewn: number;
  readonly worstGap: number;
  readonly nakedBefore: number;
  readonly nakedAfter: number;
  readonly refused: number;
  readonly turned: number;
  readonly closed: boolean;
}
/** What `Solid.mirrorJoin` did. Frozen. */
export class SymmetryReport {
  private constructor();
  readonly seams: number;
  readonly squared: number;
  readonly moved: number;
  readonly gap: number;
  readonly angle: number;
  readonly curvature: number;
  readonly naked: number;
}
/** How `NurbsCurve.tween` blends: control point by control point, after making the curves compatible, or through arc-length samples. */
export type TweenMethod = 'plain' | 'matching' | 'sampling';
/**
 * A curve in space -- always a NURBS, so a line, an arc or a conic is an exact rational one.
 * Immutable; every edit returns a new curve. `close()` frees it, so does leaving a `using` block
 * or the garbage collector. A face here is its whole surface: its trims are ignored.
 */
export class NurbsCurve {
  /** Control points of `degree` (1 to 7), `weights` one per point or null, the full `knots` vector or null for clamped and uniform. */
  constructor(points: Iterable<Point3>, degree?: number, weights?: Iterable<number> | null, knots?: Iterable<number> | null);
  close(): void;
  readonly closed: boolean;
  [Symbol.dispose](): void;
  /** The largest distance from the fitted points; null unless made by `fit`, `fair`, `faired`, `projectedToFace` or `pulledToFace`. */
  readonly fitError: number | null;
  static through(points: Iterable<Point3>, degree?: number, closed?: boolean, startTangent?: Point3 | null, endTangent?: Point3 | null): NurbsCurve;
  static fit(points: Iterable<Point3>, degree?: number, tolerance?: number | null): NurbsCurve;
  /** The smoothest curve of `degree` (3 to 7) within `tolerance` of the points; `noInflection` true holds the whole curve, `[i, j]` (point indices, null an open end) a span, free of inflections. */
  static fair(points: Iterable<Point3>, degree?: number, tolerance?: number | null, noInflection?: NoInflection): NurbsCurve;
  static fromEdge(solid: Solid, edge: Edge | number): NurbsCurve;
  static isocurve(solid: Solid, face: number, alongU: boolean, at: number): NurbsCurve;
  static blend(a: NurbsCurve, aEnd: boolean, b: NurbsCurve, bEnd: boolean, continuity?: number, bulge?: number): NurbsCurve;
  static joined(curves: Iterable<NurbsCurve>, tolerance?: number): NurbsCurve;
  /** `count` curves blending from this one to `other`; `samples` is required by `'sampling'` and refused otherwise. */
  tween(other: NurbsCurve, count: number, method?: TweenMethod, samples?: number | null, align?: boolean, tolerance?: number | null): NurbsCurve[];
  projectedToPlane(origin: Point3, normal: Point3, direction?: Point3 | null): NurbsCurve;
  projectedToFace(solid: Solid, face: number, direction: Point3, tolerance?: number | null): NurbsCurve;
  pulledToFace(solid: Solid, face: number, tolerance?: number | null): NurbsCurve;
  /** This curve, lying on the sheet `solid`, offset `distance` along it (positive: left of its run seen from the outward side). */
  offsetOnSheet(solid: Solid, distance: number, tolerance?: number | null): NurbsCurve;
  reversed(): NurbsCurve;
  trimmed(t0: number, t1: number): NurbsCurve;
  extended(length: number, atStart?: boolean): NurbsCurve;
  elevated(by?: number): NurbsCurve;
  transformed(t: Transform | MatrixLike): NurbsCurve;
  clone(): NurbsCurve;
  readonly degree: number;
  readonly controlPoints: number[][];
  readonly weights: number[];
  readonly knots: number[];
  readonly domain: [number, number];
  readonly isRational: boolean;
  readonly isClosed: boolean;
  point(t: number): number[];
  /** The nearest point of the curve to `p` over its whole domain; `unique` false where another point is as near (a circle's axis). Exact. */
  closestPoint(p: Point3): CurveFoot;
  /** The same, or null where that point lies beyond `maxDistance` (undefined, null, NaN or Infinity: no limit, the same answer as with none). */
  closestPoint(p: Point3, maxDistance: number | null | undefined): CurveFoot | null;
  /** The nearest points of this curve and `other` (side `a` this curve; distance 0 where they cross), or null where they lie farther apart than `maxDistance` (undefined, null, NaN or Infinity: no limit). Exact. */
  closestPoints(other: NurbsCurve, maxDistance?: number | null): CurvePair | null;
  /** The item of `items` nearest to this curve -- each a `Solid`, a `NurbsCurve`, a `Projector` or a point -- or null where none lies within `maxDistance` (undefined, null, NaN or Infinity: no limit) or the list is empty. Equal distances go to the earlier item. `tolerance` (undefined, null, 0 or NaN: each solid's effective tolerance) sizes each solid's search; a projector keeps its own. */
  closestObject(items: Iterable<Solid | NurbsCurve | Projector | Point3>, maxDistance?: number | null, tolerance?: number | null): NearestObject | null;
  /** The point and its derivatives up to `order` (at most 8): `order + 1` points. */
  derivatives(t: number, order?: number): number[][];
  curvature(t: number): Curvature;
  length(accuracy?: number): Length;
  pointAtLength(s: number, accuracy?: number): At;
  divideByCount(n: number, accuracy?: number): At[];
  divideByLength(step: number, accuracy?: number): At[];
  planeHits(origin: Point3, normal: Point3): At[];
  faceHits(solid: Solid, face: number, tolerance?: number | null): At[];
  /** This curve faired, as `fair` makes one from points; `noInflection`'s pair is this curve's own parameters. */
  faired(degree?: number, tolerance?: number | null, noInflection?: NoInflection): NurbsCurve;
  /** Where the curvature turns from one side to the other, in parameter order (`error` zero). */
  inflections(): At[];
  /** The largest turn of the tangent and jump of the curvature at the curve's knots. */
  knotContinuity(): KnotContinuity;
  /** `n + 1` pairs `[point, point - scale * kappa * normal]` along the domain. */
  comb(n?: number, scale?: number): [number[], number[]][];
}
export class Edge {
  private constructor();
  index: number; kind: string; faces: number[]; segments: [number[], number[]][];
  /** The edge's exact curve, or null for an edge with none (kind `other`). */
  curve: Curve | null;
  readonly isLine: boolean;
  readonly direction: number[] | null;
}
/** Where a hit lands on one side: a profile's loop, segment and t (face NONE), or a solid's face at (u, v). */
export class Spot {
  private constructor();
  loopIndex: number; segment: number; t: number; face: number; u: number; v: number;
}
/** A cage edge: two vertex ids. */
export type SubdEdge = [number, number];
/** A mirror plane's axis. */
export type SubdAxis = 'x' | 'y' | 'z';
/** What an edit touched, or what `transform` moves: vertex or face ids, or edges as `[a, b]` pairs. */
export type SubdSelection = { kind: 'vertices' | 'faces'; ids: number[] } | { kind: 'edges'; ids: SubdEdge[] };
/** A mirrored half's plane: its axis and how far from it a vertex counts as on it. */
export interface SubdSymmetry { axis: SubdAxis; tolerance: number; }
/** Cage positions in: a flat run of three numbers a vertex, or `[x, y, z]` each. */
export type SubdPoints = ArrayLike<number> | ArrayLike<number>[];
/**
 * One level of a cage's smooth surface, copied out of the cage so it outlives it: `positions` and
 * `normals` 3n doubles, `indices` three vertex ids a triangle, `triangleFace` the full cage's face
 * each triangle lies on.
 */
export class SubdMesh {
  private constructor();
  positions: Float64Array;
  normals: Float64Array;
  indices: Uint32Array;
  triangleFace: Uint32Array;
}
/** What `Subd.toSolid` did and how close it came, with the world points it measured at. */
export class SubdReport {
  private constructor();
  regular: number;
  refined: number;
  steps: number;
  levels: number;
  deviation: number;
  g1AngleDeg: number;
  deviationAt: [number, number, number];
  g1At: [number, number, number];
}
/**
 * A Catmull-Clark control cage, immutable: every edit returns a new `Subd` whose `selection`
 * names what the edit touched. `close()` frees this handle; so does leaving a `using` block or
 * the garbage collector.
 */
export class Subd {
  private constructor();
  static cuboid(size?: Point3, segments?: ArrayLike<number>): Subd;
  /** `creasedRims` is true by default, which is what converts. */
  static cylinder(radius?: number, height?: number, sides?: number, rings?: number, creasedRims?: boolean): Subd;
  static sphere(radius?: number, segments?: number): Subd;
  static torus(major?: number, minor?: number, around?: number, tube?: number): Subd;
  static fromParts(positions: SubdPoints, faces: ArrayLike<number>[], creases?: SubdEdge[], pins?: ArrayLike<number>, symmetry?: SubdSymmetry | null): Subd;
  close(): void;
  readonly closed: boolean;
  [Symbol.dispose](): void;
  /** Copies, every one. */
  readonly positions: Float64Array;
  readonly faces: number[][];
  readonly creases: SubdEdge[];
  readonly pins: number[];
  readonly symmetry: SubdSymmetry | null;
  readonly selection: SubdSelection | null;
  /** `matrix`: sixteen numbers column-major, or a 4x4 of rows (row-major). */
  transform(selection: SubdSelection, matrix: ArrayLike<number> | ArrayLike<number>[]): Subd;
  crease(edges: SubdEdge[], on?: boolean): Subd;
  pin(vertices: ArrayLike<number>, on?: boolean): Subd;
  extrude(faces: ArrayLike<number>, distance: number): Subd;
  inset(faces: ArrayLike<number>, amount: number, individual?: boolean): Subd;
  /** A new cage with `faces` subdivided once by the Catmull-Clark rules (the whole cage when no faces are given): each face becomes quads round a new point, and an unpicked face beside them takes the new edge points as corners. The whole cage keeps its smooth surface exactly. The new cage selects the new faces. */
  subdivide(faces?: ArrayLike<number>): Subd;
  insertLoop(edge: SubdEdge, at?: number): Subd;
  /** Empty when `edge` is not an edge of the cage. */
  edgeLoop(edge: SubdEdge): SubdEdge[];
  mirrorOn(axis: SubdAxis): Subd;
  mirrorOff(): Subd;
  full(): Subd;
  /** `levels` 1 to 6, 3 by default. */
  smoothMesh(levels?: number): SubdMesh;
  /** Null when nothing is near (not an error); a point that is not finite throws. */
  pick(point: Point3, kind: 'vertex' | 'face'): number | null;
  pick(point: Point3, kind: 'edge'): SubdEdge | null;
  toSolid(tolerance?: number, g1Angle?: number, maxLevels?: number): { solid: Solid; report: SubdReport };
}
export type SketchEntityKind = 'point' | 'line' | 'circle' | 'arc' | 'free_curve';
export type SketchConstraintKind =
  | 'coincident' | 'point_on_line' | 'point_on_circle' | 'horizontal' | 'vertical' | 'parallel' | 'perpendicular'
  | 'collinear' | 'tangent' | 'tangent_at_end' | 'concentric' | 'equal_length' | 'equal_radius' | 'midpoint'
  | 'symmetric' | 'fix' | 'distance' | 'point_line_distance' | 'line_distance' | 'circle_line_distance'
  | 'circle_distance' | 'horizontal_distance' | 'vertical_distance' | 'length' | 'angle' | 'radius' | 'diameter';
export type SketchSense = 'auto' | 'positive' | 'negative';
export type SketchEnd = 'start' | 'end';
export type SketchStatus = 'converged' | 'conflicting' | 'diverged';
export type SketchState = 'under' | 'full' | 'over';
/** What a solve did; `ids` the constraints a conflict ran into, or the worst of a diverged solve (empty when it converged). */
export class SolveReport {
  private constructor();
  status: SketchStatus; iterations: number; maxResidual: number; ids: number[];
  readonly converged: boolean;
}
/** One independent part of a diagnosed sketch. */
export class PartDof {
  private constructor();
  params: number; free: number; state: SketchState;
  constraints: number[]; redundant: number[]; conflicting: number[]; freeEntities: number[];
}
/** A sketch's degrees of freedom (`Sketch.diagnose`), whole and per independent part. */
export class Dof {
  private constructor();
  free: number; state: SketchState;
  redundant: number[]; conflicting: number[]; freeEntities: number[]; parts: PartDof[];
}
/**
 * A 2D sketch of points, lines, circles, arcs and free curves held by geometric constraints and
 * dimensions, solved on request. Ids are numbers; a refusal throws `BuildError` whose `ids` name
 * what it ran into. `close()` frees it; so does a `using` block or the garbage collector.
 */
export class Sketch {
  constructor();
  static fromProfile(profile: Profile, infer?: boolean, tolerance?: number): Sketch;
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  addPoint(x: number, y: number): number;
  addLine(a: number, b: number): number;
  addCircle(centre: number, r: number): number;
  addArc(centre: number, start: number, end: number): number;
  addBezier(start: number, c1: Point2, c2: Point2, to: Point2): number;
  addConic(start: number, control: Point2, to: Point2, weight: number): number;
  /** `weights` null for a plain B-spline, or one per control point counting the start. */
  addNurbs(start: number, points: Iterable<Point2>, knots: ArrayLike<number>, degree?: number, weights?: ArrayLike<number> | null): number;
  /** `[corners, sides]`, four ids each. */
  addRect(a: Point2, b: Point2): [number[], number[]];
  kind(id: number): SketchEntityKind;
  entities(): number[];
  point(id: number): [number, number];
  setPoint(id: number, x: number, y: number): void;
  radius(id: number): number;
  setRadius(id: number, r: number): void;
  centre(id: number): number;
  ends(id: number): number[];
  setConstruction(id: number, on?: boolean): void;
  isConstruction(id: number): boolean;
  isReference(id: number): boolean;
  removeEntity(id: number): number[];
  reference(other: Sketch, entity: number): number;
  updateReference(id: number, other: Sketch): SolveReport;
  coincident(a: number, b: number): number;
  pointOnLine(point: number, line: number): number;
  pointOnCircle(point: number, circle: number): number;
  horizontal(a: number, b: number): number;
  vertical(a: number, b: number): number;
  parallel(a: number, b: number): number;
  perpendicular(a: number, b: number): number;
  collinear(a: number, b: number): number;
  tangent(a: number, b: number, sense?: SketchSense): number;
  tangentAtEnd(curve: number, other: number, end?: SketchEnd): number;
  concentric(a: number, b: number): number;
  equalLength(a: number, b: number): number;
  equalRadius(a: number, b: number): number;
  midpoint(point: number, line: number): number;
  symmetric(a: number, b: number, about: number): number;
  fix(entity: number): number;
  distance(a: number, b: number, value: number, driving?: boolean): number;
  pointLineDistance(point: number, line: number, value: number, driving?: boolean, sense?: SketchSense): number;
  lineDistance(a: number, b: number, value: number, driving?: boolean, sense?: SketchSense): number;
  circleLineDistance(circle: number, line: number, value: number, driving?: boolean, sense?: SketchSense): number;
  circleDistance(a: number, b: number, value: number, driving?: boolean): number;
  horizontalDistance(a: number, b: number, value: number, driving?: boolean): number;
  verticalDistance(a: number, b: number, value: number, driving?: boolean): number;
  length(line: number, value: number, driving?: boolean): number;
  /** In radians. */
  angle(a: number, b: number, value: number, driving?: boolean): number;
  /** The RADIUS dimension (kind 'radius'); `radius(id)` reads a radius. */
  radiusOf(circle: number, value: number, driving?: boolean): number;
  diameter(circle: number, value: number, driving?: boolean): number;
  constraints(): number[];
  constraintKind(id: number): SketchConstraintKind;
  constraintRefs(id: number): number[];
  /** Null for a constraint that is not a dimension. */
  constraintValue(id: number): number | null;
  constraintDriving(id: number): boolean;
  constraintSense(id: number): SketchSense;
  constraintEnd(id: number): SketchEnd;
  isJointTangent(id: number): boolean;
  remove(id: number): void;
  setValue(id: number, value: number): SolveReport;
  setDriving(id: number, driving: boolean): SolveReport;
  measure(id: number): number;
  solve(): SolveReport;
  /** `moves` a `Map` or a plain object of point id to its `[x, y]` target. */
  drag(moves: Map<number, Point2> | Record<number, Point2>): SolveReport;
  diagnose(): Dof;
  profiles(tolerance?: number): Profile[];
  openChains(tolerance?: number): Profile[];
}
/** One place two curves meet: a point (start equals end; touch where tangent) or a run from start to end. */
export class Hit {
  private constructor();
  run: boolean; touch: boolean; start: number[]; end: number[];
  aStart: Spot; aEnd: Spot; bStart: Spot; bEnd: Spot;
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

// ---- the document: a node graph of constructive verbs, with parameters and a history --------

/** What an edit changed: the ids added, changed and removed, and the parameter names touched. */
export interface ChangedSet { added: string[]; changed: string[]; removed: string[]; params: string[]; [key: string]: any }
/** One node's status after an evaluation. */
export interface NodeStatus { id: string; state: 'ok' | 'error' | 'blocked' | 'pending'; [key: string]: any }
/** A node the evaluation left in error or blocked. */
export interface NodeError { id: string; state: string; message: string; [key: string]: any }
/** One node kind: its `name`, `inputs`, `output`, `cost` and `help`. */
export interface NodeKind { name: string; [key: string]: any }
/** A node's fields for `Document.add`/`set`: numbers, `"=expressions"`, other nodes' ids, lists and records; `id`, `name` and `message` (the commit's, not a field) as the methods say. */
export type NodeFields = { [field: string]: any };
/** The synchronous body of `Document.batch`/`preview`: the ops it applies are the scope's; what it returns is returned. */
export type DocumentBody = () => any;

/** One commit of a `Document`'s history. Frozen. */
export class Commit {
  private constructor();
  /** Its id; `c0` is the root. */
  readonly id: string;
  /** The ids of the commits it follows. */
  readonly parents: readonly string[];
  /** The message it was recorded with; null when not set. */
  readonly message: string | null;
  /** Who recorded it; null when not set. */
  readonly author: string | null;
  /** When it was recorded; null when not set. */
  readonly time: string | null;
  /** The ops it applied, each as the record that was sent. */
  readonly ops: readonly { [key: string]: any }[];
}

/** `Document.params`: the parameters, name to value (a number, or an `"=expression"`), shaped like a `Map`. Each read asks the document. */
export class DocumentParams {
  private constructor();
  /** The parameter's value, or undefined when there is none of that name. */
  get(name: string): number | string | undefined;
  has(name: string): boolean;
  /** Sets (or adds) a parameter: a `param` op, one commit. Null is refused: `delete` it instead. */
  set(name: string, value: number | string): this;
  /** Removes a parameter, one commit: false when there was none; a parameter a node reads is refused. */
  delete(name: string): boolean;
  keys(): string[];
  readonly size: number;
  /** Every parameter as a plain object, name to value. */
  toObject(): { [name: string]: number | string };
}

/**
 * A model as data: a graph of nodes, each a blacksmith verb reading other nodes by id, with
 * named parameters, evaluated incrementally, and edited by ops that are undoable and branch.
 * Saves as JSON text and loads back to the same document. A refused op throws `BuildError` with
 * the reason, and the document is unchanged. `close()` frees it; so does leaving a `using` block
 * or the garbage collector. One thread at a time.
 */
export class Document {
  /** An empty document counting lengths in `units` (`mm`, `cm`, `m`, `in` or `ft`). */
  constructor(units?: string);
  /** The document `save` wrote as `text`. */
  static load(text: string): Document;
  /** The document saved in the file at `path`. */
  static open(path: string): Document;
  /** Every node kind the library knows. */
  static kinds(): NodeKind[];
  /** An empty building document: the blacksmith kinds and the `bim.*` ones, with a hidden `bim.project` node. */
  static newBim(units?: string): Document;
  /** A saved building document, opened with the `bim.*` kinds. */
  static loadBim(text: string): Document;
  /** The building document saved in the file at `path`. */
  static openBim(path: string): Document;
  /** Every node kind a building document knows. */
  static bimKinds(): NodeKind[];
  /**
   * The building as IFC text; with `path`, also written to that file. `timestamp` (Unix seconds)
   * defaults to now. A refusal throws `BuildError` (one `node: reason` a line) with `refusals`,
   * `[node | null, reason]` pairs, and writes no file.
   */
  exportIfc(path?: string | null, options?: { schema?: string; geometry?: string; timestamp?: number | null; name?: string }): string;
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  /** `Document(closed)`, or the branch and head. */
  toString(): string;
  /** The document as JSON text; with `path`, also written to that file. */
  save(path?: string | null): string;
  /** Applies one op (a record or its JSON text), one commit with `message`; the changed set. */
  apply(op: string | { [key: string]: any }, message?: string | null): ChangedSet;
  /** A new node of `kind` with `fields`, one commit; its id. */
  add(kind: string, fields?: NodeFields): string;
  /** A `solid.body` (`sheet.body` with `sheet`) node holding `solid` exactly; its id. */
  addSolid(solid: Solid, fields?: NodeFields & { sheet?: boolean }): string;
  /** A `profile.path` node holding `profile` exactly; its id. */
  addProfile(profile: Profile, fields?: NodeFields): string;
  /** Sets `fields` of node `id`, one commit (`message` is the commit's); the changed set. */
  set(id: string, fields: NodeFields): ChangedSet;
  /** Removes node `id`; refused while another node reads it, unless `cascade`. */
  remove(id: string, options?: { cascade?: boolean; message?: string | null }): ChangedSet;
  /** Gives node `id` the display name `name` (null clears it). */
  rename(id: string, name: string | null, message?: string | null): ChangedSet;
  readonly params: DocumentParams;
  /** The ops `body` applies are recorded as one commit; an error rolls them back and is thrown on. `body` is synchronous; its result is returned. */
  batch(message: string | null | undefined, body: DocumentBody): any;
  batch(body: DocumentBody): any;
  /** The ops `body` applies evaluate but are never recorded, and are taken back on leaving. */
  preview(body: DocumentBody): any;
  /** One drag frame: `op` applied unrecorded after taking back the last frame; the changed set relative to before the drag. */
  previewFrame(op: string | { [key: string]: any }): ChangedSet;
  /** Takes back an open drag (or preview); the changed set of doing so. */
  endPreview(): ChangedSet;
  /** Takes back the head commit; false when there was nothing to take back. */
  undo(): boolean;
  /** Puts back the commit `undo` took back; false when there was nothing to put back. */
  redo(): boolean;
  readonly canUndo: boolean;
  readonly canRedo: boolean;
  /** The current branch's name, or null when the head is detached. */
  readonly branch: string | null;
  /** Every branch, name to the id of its tip commit. */
  readonly branches: { [name: string]: string };
  /** A new branch; without `at` it starts at the head and the document switches onto it. */
  branchNew(name: string, at?: string | null): void;
  /** Moves the head to the branch of that name, else to the commit of that id. */
  switch(nameOrCommitId: string): void;
  branchRename(old: string, name: string): void;
  branchDelete(name: string): void;
  tips(): Commit[];
  log(branch?: string | null): Commit[];
  readonly head: Commit;
  evaluate(options?: { cheapOnly?: boolean }): NodeStatus[];
  /** `evaluate`, every kernel call's progress heard as `(node, phase, done, total)`: `node` the id of the node being built. */
  evaluateWith(progress: DocumentProgress | null, options?: { cheapOnly?: boolean }): NodeStatus[];
  errors(): NodeError[];
  /** Node `id`'s value, parsed; throws `BuildError` for a node with none. */
  value(id: string): any;
  /** What node `id` evaluated to, by its kind: a `Solid`, a `Profile`, an array of `Profile`, a `NurbsCurve`, a `Subd`, an array of these, or a value; null for no such node or one that failed. */
  result(id: string): any;
}

// ---- CAM: tools, stock and a job -------------------------------------------------------

/** A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and `fluteLength` in
 * mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts at
 * `rampAngle` degrees. Immutable; a job keeps its own copy. */
export class Tool {
  private constructor();
  /** A flat end mill. Throws for a `number` outside 1..255, a size, feed or speed not
   * positive and finite, or a `rampAngle` outside (0, 90]. */
  static flat(number: number, diameter: number, fluteLength: number, feed: number, plunge: number, rpm: number, rampAngle?: number): Tool;
  /** A ball end mill, as `flat` but its tip a half sphere of the diameter; in 2.5D it cuts
   * where a flat does, `bottom` being the tip. */
  static ball(number: number, diameter: number, fluteLength: number, feed: number, plunge: number, rpm: number, rampAngle?: number): Tool;
  /** A drill, plunging at `feed`. A job takes it for `Job.drill` or `Job.machine`'s own
   * holes. */
  static drill(number: number, diameter: number, fluteLength: number, feed: number, rpm: number): Tool;
  /** The Grbl tool number, 1 to 255 (the `T` word). */
  readonly number: number;
  /** The cutting end. */
  readonly shape: 'flat' | 'ball' | 'drill' | 'vbit' | 'bullnose';
  /** The cutting diameter, in mm. */
  readonly diameter: number;
  /** How far up the cutting edge reaches from the tip, in mm. */
  readonly fluteLength: number;
  /** A V-bit's included angle, in degrees; `null` for every other shape. */
  readonly angle: number | null;
  /** A bull-nose's corner radius, in mm; `null` for every other shape. */
  readonly cornerRadius: number | null;
}

/** The block of material a job cuts, an axis-aligned box. Immutable; a job keeps its own
 * copy. */
export class Stock {
  private constructor();
  /** The box from `min` (x, y, z) to `max`. Throws unless every min is below its max and
   * all six are finite. */
  static box(min: Point3, max: Point3): Stock;
  /** `solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at the
   * solid's lowest Z. Throws for a `margin` negative or not finite. */
  static around(solid: Solid, margin?: number): Stock;
}

/** One file a job wrote: a Grbl program (`tool` its `T` number, `name` `<job name>-T<n>`,
 * or `<job name>-<k>-T<n>` for a repeated tool) or, from `Job.writeCamotics`, a simulation
 * copy or the CAMotics project (`tool` 0). Read-only. */
export class Program {
  private constructor();
  readonly tool: number; readonly name: string; readonly text: string;
}

/** One operation of a `Job`, read back by `Job.operations()`: `kind` ("face", "contour",
 * "pocket" or "drill"), `tool` (its Grbl T number) and `params` -- a plain object, in the
 * kind-specific order the operation stores. In `params`: `side` reads as
 * `"outside"`/`"inside"`/`"on"`; `climb` and `open` as `boolean`; `points` as an integer; a
 * `NaN` `peck` as `null`; every other value stays a number. Read-only. */
export class Operation {
  private constructor();
  readonly kind: string; readonly tool: number;
  readonly params: Record<string, number | string | boolean | null>;
}

/** One thing `Job.machine()` left uncut: `kind` (`"corner"`, `"hole"`, `"slope"`,
 * `"undercut"`, `"too_deep"` or `"relief"`), `at` (`[x, y, z]`), `size` (its meaning per
 * `kind`; for a relief, how far the notch reaches into each wall, in mm), `reason` (one sentence naming the tool involved), `region` (its XY area, as a list
 * of `Profile`), and `top` and `bottom` (the highest and lowest Z it stands at, from the
 * band's top down to its floor). Read-only. */
export class ReportItem {
  private constructor();
  readonly kind: string; readonly at: number[]; readonly size: number; readonly reason: string;
  readonly region: Profile[]; readonly top: number; readonly bottom: number;
}
/** What `Job.machine()` could not make, read eagerly when it returns: a plain array of
 * `ReportItem`, in order, with a non-enumerable `text` (the kernel's own report text, one
 * line per item or "nothing left uncut") and a matching `toString()`. */
export interface Report extends ReadonlyArray<ReportItem> {
  readonly text: string;
}

/**
 * A machining job on a `Stock`: operations kept in the order they are added, written as
 * one Grbl 1.1 program per run of operations sharing a tool. Mutable -- each operation is
 * added in place, and a refused one leaves the job as it was. `safeZ` is the absolute Z of
 * rapids between operations and at a program's start and end, above the stock's top;
 * `clearance` is how far an operation enters and leaves its passes above its top;
 * `tolerance` fits free-form sides and offsets; `name` names the programs (`<name>-T<n>`);
 * every program waits `spindleDwell` seconds after starting the spindle; `resolution` is
 * the CAMotics project's voxel size in mm. Throws for a `safeZ` not above the stock, or a
 * setting the job refuses. `close()` frees this handle.
 */
export class Job {
  constructor(stock: Stock, safeZ: number, clearance?: number, tolerance?: number, name?: string, spindleDwell?: number, resolution?: number);
  readonly closed: boolean;
  close(): void;
  [Symbol.dispose](): void;
  /** The stock's box as the job holds it, `[[minX, minY, minZ], [maxX, maxY, maxZ]]`. */
  readonly stock: [[number, number, number], [number, number, number]];
  /** The tools this job was given -- by `face`, `contour`, `pocket`, `drill` and `machine`
   * (its end mill and each drill it used) -- by Grbl number. A refused call adds none; the
   * later of two tools with one number wins. A new `Map` each time. */
  readonly tools: Map<number, Tool>;
  /** Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and passes
   * at most `stepdown` deep, with `tool`. Added to the job in place. */
  face(tool: Tool, z: number, stepover: number, stepdown: number): void;
  /** Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep, with
   * `tool`: `side` "outside" the profile, "inside" it, or "on" its line; `climb` for climb
   * milling, else conventional; `open` to cut the outline as an open chain. Throws for any
   * other `side`. */
  contour(tool: Tool, profile: Profile, top: number, bottom: number, side?: 'outside' | 'inside' | 'on', stepdown?: number, climb?: boolean, open?: boolean): void;
  /** Clear `profile` -- its holes left standing as islands -- from `top` to `bottom`, in
   * rings `stepover` apart (at most the tool's radius) and passes at most `stepdown` deep,
   * with `tool`. */
  pocket(tool: Tool, profile: Profile, top: number, bottom: number, stepover: number, stepdown: number): void;
  /** Drill a hole at each (x, y) of `points` from `top` to `bottom` with `tool`, pecking
   * `peck` deep at a time (retracting between pecks), or straight to depth for `null`. */
  drill(tool: Tool, points: Iterable<Point2>, top: number, bottom: number, peck?: number | null): void;
  /**
   * Recognise `part` and append the operations that make it: faced, contoured and
   * pocketed with `endMill` -- or with several end mills, largest first, given as an
   * array: each later one cleans what the earlier ones left, and the report lists only
   * what none of them reached -- its holes drilled with whichever of `drills` fits each --
   * a tool per required diameter. `drills` may be one `Tool` as well as an array of them.
   * With `cornerRelief` true, each inside corner the smallest end mill leaves is relieved with a
   * dog-bone and reported as a `relief` item in place of the corner item.
   * Returns the machining's `Report` of what could not be cut.
   */
  machine(part: Solid, endMill: Tool | (Tool | null)[], drills?: Tool | Iterable<Tool>, stepover?: number | null, stepdown?: number | null, skin?: number, peck?: number | null, cornerRelief?: boolean): Report;
  /** Every operation added to this job so far, in order -- whether added by
   * `face`/`contour`/`pocket`/`drill` or by `machine`. */
  operations(): Operation[];
  /** The job as Grbl 1.1 programs, one per run of consecutive operations sharing a tool
   * (T1, T2, T1 gives three), each named `<name>-T<n>` (or `<name>-<k>-T<n>` for run `k`
   * of a repeated tool); an array of length 0 for a job with no operations. */
  gcode(): Program[];
  /**
   * A CAMotics project at `filePath` and its files beside it, named after the project's
   * file stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each
   * program, a simulation copy of it (`.sim.nc`, which the project lists), and the project
   * last. Creates the directory. Returns the paths written, the project last.
   */
  writeCamotics(filePath: string): string[];
}

/**
 * `schema`: null/undefined (the kernel's built-in AP203); the path of a schema file
 * (no newline in it, naming an existing file), read and sent as EXPRESS text; the bare
 * name of a built-in schema (case-insensitive, e.g.
 * `"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"` -- an unknown name throws
 * `BuildError`); or a custom schema's own EXPRESS text.
 */
export function writeStepText(solids: Iterable<Solid>, schema?: string | null, unit?: Unit): string;
export function writeStep(path: string, solids: Iterable<Solid>, schema?: string | null, unit?: Unit): void;
/** Several solids as one ACIS SAT file, each its own body. */
export function writeSatText(solids: Iterable<Solid>, unit?: Unit): string;
export function writeSat(path: string, solids: Iterable<Solid>, unit?: Unit): void;
/**
 * Several solids as one Rhino `.3dm` (version 8), one object each: its exact brep, or its
 * mesh where a body has no exact form there, with a `process.emitWarning` ("3dm: ...") saying
 * so. Named, coloured and with the solid's attributes as user text.
 */
export function rhino3dmBytes(solids: Iterable<Solid>, unit?: Unit): Buffer;
/** Several solids meshed as one file's bytes: `'stl'`, `'stl-ascii'`, `'obj'`, `'glb'` or `'gltf'`; `names` one a solid, `looks` six linear numbers a solid (`r g b a metallic roughness`, glTF only). */
export function meshFile(solids: Iterable<Solid>, format?: 'stl' | 'stl-ascii' | 'obj' | 'glb' | 'gltf', names?: Iterable<string> | null, looks?: Iterable<ArrayLike<number>> | null, tolerance?: number | null): Buffer;
export function write3dm(path: string, solids: Iterable<Solid>, unit?: Unit): void;
/** Several solids as one `.brep`, each its own solid under one compound. */
export function writeBrepText(solids: Iterable<Solid>): string;
export function writeBrep(path: string, solids: Iterable<Solid>): void;
/**
 * One B-rep edge of a `FemMesh`: `nodes` in order along the edge, `runs` saying where
 * the chain breaks (`chains()` cuts it), `faces` and `ends` (`[a, b]`, the second
 * `NONE` where there is none -- `0` is a real face and a real vertex), `closed`, `seam`,
 * and `id`, the **solid's own** edge id rather than this mesh's index or a row of
 * `Solid.edges()`.
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
 * One solid meshed for a solver: what `Solid.femMesh` returns, **owned by the caller**.
 * Every array is a fresh copy decoded at call time, as `Solid.mesh`'s typed arrays are
 * -- so one in hand survives `free()`, `Solid.close()` and the collector, and neither
 * closing the solid nor meshing it again at another tolerance touches this handle. A
 * call on a freed handle throws.
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
  /** Every crack, as `[a, b, brepEdge]`; `brepEdge` is `NONE` where the two nodes share none. Empty unless the solid's topology is closed. */
  openEdges(): [number, number, number][];
  /** Every fold, as `openEdges` reports a crack. A solid can be folded without being open. */
  foldedEdges(): [number, number, number][];
  /** Every pair of triangles that pass through each other, as `[a, b]` with `a < b`. Computed for every solid, open or closed. */
  crossings(): [number, number][];
  readonly watertight: boolean;
  /** Always false here: a `Solid` always has a B-rep, so this library has no mesh-only body. */
  readonly fromMesh: boolean;
  readonly minAngle: number;
  readonly worstTriangle: number;
  readonly longestEdge: number;
  /** Gmsh 4.1 ASCII `.msh` text. **Owned** on this side of the ABI and released by this wrapper, where the reader's is borrowed from its handle; prints the unlicensed notice. */
  mshText(): string;
  saveMsh(path: string): void;
}
/** A `Solid` or a `Profile`: what `writeSvgText`/`writeSvg` draw, split by type before the call. */
export type Drawable = Solid | Profile;
/**
 * The solids and profiles in `things` (any mix of `Solid` and `Profile`, in any order) as
 * one SVG drawing -- a `<g id="solid-<i>">` per solid then a `<g id="profile-<i>">` per
 * profile, from the camera `options` describes. A list of solids alone draws exactly as
 * it always did.
 */
export function writeSvgText(things: Iterable<Drawable>, options?: SvgOptions): string;
export function writeSvg(path: string, things: Iterable<Drawable>, options?: SvgOptions): void;
