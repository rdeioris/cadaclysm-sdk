/// <reference types="node" />
/** The cadaclysm_blacksmith C ABI for Node.js. See cadaclysm_blacksmith.js for the semantics. */
import type { Node, Scene } from './cadaclysm';

export class BuildError extends Error {}
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
  /** `'#rgb'`, `'#rrggbb'` or `[r, g, b]` in 0..255. Default '#000000'. */
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

export class Profile {
  private constructor();
  static rect(w: number, h: number): Profile;
  static circle(r: number): Profile;
  static slot(centre: Point2, length: number, r: number): Profile;
  static polygon(points: Point2[]): Profile;
  static regularPolygon(centre: Point2, radius: number, sides: number, angle?: number): Profile;
  static star(centre: Point2, outer: number, inner: number, points: number, angle?: number): Profile;
  static spline(points: Point2[], degree?: number, weights?: ArrayLike<number> | null, closed?: boolean): Profile;
  static path(start: Point2): Path;
  static parabola(vertex: Point2, axis: Point2, focal: number, from: number, to: number): Path;
  static chain(pieces: Iterable<Profile>, tolerance?: number): Profile;
  static fromLoops(loops: Iterable<Profile>): Profile;
  closeLoop(): Profile;
  /** This curve cut where the cutters cross it -- the sketch trim's pieces, in order along the curve. */
  pieces(cutters: Iterable<Profile>, tolerance?: number): Profile[];
  /** This curve with piece `piece` of `pieces` taken away: what is left, as open profiles. */
  trim(cutters: Iterable<Profile>, piece: number, tolerance?: number): Profile[];
  withHole(hole: Profile): Profile;
  hits(other: Profile, tolerance?: number): Hit[];
  common(other: Profile, tolerance?: number): Profile[];
  static text(text: string, size?: number, font?: string, halign?: 'left' | 'center' | 'right', valign?: 'baseline' | 'bottom' | 'center' | 'top', spacing?: number, direction?: 'ltr' | 'rtl', fontBytes?: Uint8Array | ArrayBuffer | null): Profile[];
  translate(dx: number, dy: number): Profile;
  /** This outline coloured -- '#rgb', '#rrggbb' or [r, g, b] in 0..1: how it is drawn.
   *  The verbs that make a profile from one carry it; a solid made from it takes nothing. */
  coloured(colour: string | Iterable<number>): Profile;
  readonly colour: [number, number, number] | null;
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
/** `SolidMesh` in `double`: the same tessellation's own unnarrowed positions/normals. */
export interface SolidMesh64 { positions: Float64Array; normals: Float64Array; indices: Uint32Array; vertexCount: number; indexCount: number }

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
  /**
   * Where this solid's faces cross or coincide with `other`'s: chains along the curves the faces
   * meet on (one per face pair per branch -- join them by matching ends) and overlaps where a face
   * pair coincides. Neither solid is changed; no crossing is an empty result.
   */
  intersect(other: Solid, tolerance?: number, progress?: Progress | null): Intersection;
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
  hits(profile: Profile, frame: FrameLike, tolerance?: number, progress?: Progress | null): SolidHits;
  splitSheetAsync(tool: Solid, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  readonly faces: number;
  faceKind(face: number): string;
  readonly bounds: [number[], number[]];
  /** `bounds` in `double`: exact far from the origin. */
  readonly bounds64: [number[], number[]];
  boundsAt(tolerance: number): [number[], number[]];
  /** `boundsAt` in `double`, from the same tessellation's own unnarrowed positions. */
  boundsAt64(tolerance: number): [number[], number[]];
  leakedEdges(tolerance?: number): number;
  unpairedEdges(tolerance?: number): number;
  isWatertight(tolerance?: number): boolean;
  readonly manifold: Manifold;
  mesh(tolerance?: number): SolidMesh;
  /** `mesh` in `double`, from the same tessellation cache -- unnarrowed positions/normals. */
  mesh64(tolerance?: number): SolidMesh64;
  meshAsync(tolerance?: number): Promise<SolidMesh>;
  meshAsync64(tolerance?: number): Promise<SolidMesh64>;
  edgePolylines(tolerance?: number): Float32Array[];
  /** A colour per polyline of `edgePolylines(tolerance)`, as drawn: [r, g, b], or null for a polyline
   *  on no coloured edge; an empty array where the solid has no edge paint at all. Fills the solid's
   *  cache at `tolerance`, as `edgePolylines` does. */
  edgePolylineColours(tolerance?: number): Array<[number, number, number] | null>;
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
  selectFace(selector: Selector): number;
  faceFrame(face: number): number[];
  /** Face `face` by what it is, eight numbers (kind, point x y z, normal x y z, extent): what a feature made on the face keeps, to find the face again with `findFace` on a rebuilt solid. */
  faceRef(face: number): number[];
  /** The face `faceRef` refers to, `hint` the index it had; null where it is gone. */
  findFace(faceRef: Iterable<number>, hint?: number | null, tolerance?: number): number | null;
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
  edges(): Edge[];
  fillet(edges: Iterable<Edge | number>, radius: number, tolerance?: number, progress?: Progress | null): Solid;
  chamfer(edges: Iterable<Edge | number>, distance: number, tolerance?: number): Solid;
  pushPull(face: number | Iterable<number>, distance: number, tolerance?: number, progress?: Progress | null): Solid;
  mergeFlush(): Solid;
  refillet(face: number, radius: number, tolerance?: number): Solid;
  unfillet(face: number): Solid;
  rechamfer(face: number, distance: number, tolerance?: number): Solid;
  unchamfer(face: number): Solid;
  split(tool: Solid, tolerance?: number, progress?: Progress | null): Solid[];
  splitByPlane(plane: FrameLike, tolerance?: number, progress?: Progress | null): Solid[];
  lumps(): Solid[];
  shell(thickness: number, open?: Iterable<number>, tolerance?: number, progress?: Progress | null): Solid;
  thicken(thickness: number, tolerance?: number, progress?: Progress | null): Solid;
  filletAsync(edges: Iterable<Edge | number>, radius: number, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  chamferAsync(edges: Iterable<Edge | number>, distance: number, tolerance?: number): Promise<Solid>;
  shellAsync(thickness: number, open?: Iterable<number>, tolerance?: number, progress?: Progress | null): Promise<Solid>;
  thickenAsync(thickness: number, tolerance?: number, progress?: Progress | null): Promise<Solid>;
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
 * partial overlap whose outlines cross.
 */
export class Overlap {
  private constructor();
  faces: [number, number];
  loops: number[][][];
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
/** Several solids as one `.brep`, each its own solid under one compound. */
export function writeBrepText(solids: Iterable<Solid>): string;
export function writeBrep(path: string, solids: Iterable<Solid>): void;
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
