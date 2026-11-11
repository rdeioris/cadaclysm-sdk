import type { Scene, Node } from './cadaclysm';
import type { Solid } from './cadaclysm_blacksmith';

export class ViewError extends Error {}
/** A colour: text -- '#rgb', '#rrggbb' (the '#' optional) or one of the 148 CSS colour names, any case,
 *  read by the view library's own `cadaclysm_view_parse_colour` -- or three numbers in 0..1. */
export type Colour = string | ArrayLike<number>;
/** A colour where an alpha is taken: text (alpha 1), or three or four numbers in 0..1. */
export type ColourAlpha = string | ArrayLike<number>;
export class Library {
  readonly name: string;
  readonly path: string | null;
  readonly kind: 'wgpu' | 'terminal' | 'other';
  readonly fn: Record<string, (...args: any[]) => any>;
}
export function useTerminal(): Library;
export function useWgpu(): Library;
export function use(library: string | Record<string, (...args: any[]) => any>): Library;
export function current(): Library;
export function pump(timeoutMs?: number): number;
export type TextAlign = 'top-left' | 'top' | 'top-right' | 'left' | 'centre' | 'center' | 'right' | 'bottom-left' | 'bottom' | 'bottom-right';
/** showText's options; every field optional (a white 12 px label, bottom-left on its anchor). */
/** `View.showSolid`'s options (view ABI 1.21). */
export interface SolidOptions { material?: 'default' | 'plastic' | 'metal' | 'matte' | 'paint' | 'brushed' | 'glass' | null; opacity?: number | null; faces?: ArrayLike<number> | null; }
export interface TextOptions { mode?: 'label' | 'world'; size?: number; colour?: Colour; align?: TextAlign; offset?: ArrayLike<number>; box?: ColourAlpha | null; padding?: number; onTop?: boolean; font?: number; right?: ArrayLike<number>; up?: ArrayLike<number>; }
/**
 * A TTF/OTF font for every view of the library in use (bytes or a path); its id for TextOptions.font.
 * Choose the library first (useWgpu/useTerminal/use): a font id belongs to the library that loaded it.
 */
export function loadFont(font: Uint8Array | ArrayBuffer | string): number;
export function _release(obj: unknown): void;
export function _reset(): void;
export const OPEN: 1;
export const CLOSED: 2;

export interface ViewOptions { title?: string; width?: number; height?: number; surfaces?: 'exact' | 'triangles'; up?: 'z' | 'y'; backend?: number; }
export interface NativeWindow { kind: 'win32' | 'xlib' | 'xcb' | 'wayland' | 'appkit'; window?: unknown; windowId?: number | bigint; display?: unknown; width: number; height: number; }
export type ViewName = 'front' | 'back' | 'left' | 'right' | 'top' | 'bottom' | 'iso';
export interface ShowOptions { view?: ViewName | [azimuth: number, elevation: number]; azimuth?: number; elevation?: number; zoom?: number; up?: 'z' | 'y'; edges?: boolean; width?: number; height?: number; title?: string; tolerance?: number; rgb?: Colour; }
/** A pick answer: `clicks` 2 for a double click, else 1; `point` where the ray met the model, null where no depth was read. */
export interface Pick { item: number; node: number; face: number; clicks: number; point: [number, number, number] | null; }
/** What a snap lands on (view ABI 1.22). */
export type SnapKind = 'vertex' | 'midpoint' | 'centre' | 'quadrant' | 'edge' | 'face' | 'grid' | 'plane';
/** A snap answer: the point snapped to, in the coordinates the items were shown in; `edge` null for a face, grid or plane snap; `clicks` 0 for snap() and a hover, 1 or 2 for a click's. */
export interface Snap { kind: SnapKind; point: [number, number, number]; item: number; node: number; face: number; edge: number | null; tangent: [number, number, number]; axis: [number, number, number]; radius: number; distancePx: number; clicks: number; }
export interface Camera { eye: number[]; target: number[]; up: number[]; orthographic: boolean; azimuth: number; elevation: number; pick: Pick | null; }
export interface Image { width: number; height: number; rgba: Uint8Array; }
export interface ViewEvent { type: 'pointer_down' | 'pointer_move' | 'pointer_up' | 'pointer_cancel' | 'wheel' | 'key'; x?: number; y?: number; button?: number; shift?: boolean; pointerId?: number; pointer?: 'mouse' | 'touch' | 'pen'; wheelY?: number; key?: string; keyDown?: boolean; timeMs?: number; }
export interface Viewport { rect: number[]; view: ArrayLike<number>; projection: ArrayLike<number>; eye: ArrayLike<number>; grid?: 'none' | 'top' | 'front' | 'right'; }
export interface MeshData { positions: ArrayLike<number>; indices: ArrayLike<number>; normals?: ArrayLike<number> | null; edges?: ArrayLike<number> | null; rgb?: Colour | null; }

export class Item {
  readonly id: number;
  readonly view: View;
  readonly shown: Solid | Scene | Node | null;
  remove(): void;
  nodeTransforms(transforms: ArrayLike<number>[] | null): void;
  colour(rgb: Colour): void;
  setText(text: string): void;
  placement(matrix: ArrayLike<number> | null): void;
  /** One colour a face (text, or 3 or 4 numbers), or four numbers a face, flat. */
  faceColours(faces: ArrayLike<number> | null, rgba?: ArrayLike<number> | ReadonlyArray<ColourAlpha>): void;
  frame(): void;
  xray(on: boolean): void;
  /** How its lines and points draw where a surface hides them: 'off' (an item shows with it until set), 'solid' or 'dashed'. */
  occluded(mode: 'off' | 'solid' | 'dashed'): void;
  /** Its finish under the lighting: 'gloss' (an item shows with it until set; under the showroom lighting a clear coat), 'satin' (a weaker, blurred coat) or 'matte' (no mirror). */
  finish(finish: 'gloss' | 'satin' | 'matte'): void;
  nodeVisible(node: number, on: boolean): void;
  nodeColour(node: number, rgba: ColourAlpha | null): void;
  nodeHighlight(node: number, rgba: ColourAlpha | null): void;
  frameNode(node: number): void;
}

export interface MachiningTool { number: number; shape: 'flat' | 'ball' | 'drill' | 'vbit' | 'bullnose'; diameter: number; flute_length?: number; angle?: number; corner_radius?: number; }
export type MachiningProgram = [MachiningTool, string] | { tool: MachiningTool; gcode: string };
export interface MachiningInfo { moves: number; move: number; nx: number; ny: number; cell: number; min: [number, number]; cycleTime: number; }

/** A CAM job shown in a View (`View.showMachining`): the stock is this item; the view's timeline plays it. */
export class Machining extends Item {
  /** Jump the timeline to the end of move `move` (0: the untouched stock). */
  seekMove(move: number): void;
  /** 'deviation' needs a part. */
  colourBy(mode: 'height' | 'tool' | 'deviation'): void;
  /** The toolpath and the tool, on or off. */
  overlays(path?: boolean, tool?: boolean): void;
  info(): MachiningInfo;
  /** The stock's heights now, `nx * ny` floats, row y then x; waits for the GPU. */
  heights(): Float32Array;
}

export interface OccludedStyle { dash: number; gap: number; dim: number; colour: [number, number, number] | null; }
export class View {
  constructor(options?: ViewOptions);
  static inWindow(window: NativeWindow, options?: ViewOptions): View;
  static offscreen(width: number, height: number, options?: ViewOptions): View;
  readonly closed: boolean;
  readonly needsDraw: boolean;
  readonly size: [number, number];
  readonly wakeMs: number | null;
  surfaces: 'exact' | 'triangles';
  /** How plain parts are lit (view ABI 1.9): 'headlight' (the default) or 'studio'. */
  lighting: 'headlight' | 'studio';
  /** How every 'dashed' item's hidden lines and points look, view-wide (view ABI 1.20): dash and gap in points (6, 4), dim the coverage kept (0.5), one colour or null. Set a partial style (unset keys take the default) or null for the defaults. */
  get occludedStyle(): OccludedStyle;
  set occludedStyle(style: Partial<Omit<OccludedStyle, 'colour'>> & { colour?: Colour | null } | null);
  lod(motion?: 'detailed' | 'smooth' | null, minTriangles?: number): void;
  show(obj: Solid | Scene | Node, rgb?: Colour | null, tolerance?: number): Item;
  /** A kernel solid, read in place; `options` (view ABI 1.21) a material, an opacity 0..1 (1 opaque) and the solid's face numbers to show alone, with no edges (null: every face). */
  showSolid(solid: Solid, tolerance?: number, rgb?: Colour | null, options?: SolidOptions): Item;
  showScene(scene: Scene): Item;
  showNode(node: Node): Item;
  showMesh(mesh: MeshData): Item;
  showText(text: string, at: ArrayLike<number>, options?: TextOptions): Item;
  showLines(segments: ArrayLike<number>, rgb?: Colour | null): Item;
  /** Points, three numbers each (a flat run, or `[x, y, z]` a point): a disc `sizePx` device pixels across (1 to 64, 8 by default) at each, in `colour` (null: the edge colour), as one item. */
  showPoints(positions: ArrayLike<number> | ArrayLike<number>[], colour?: Colour | null, sizePx?: number): Item;
  /** A CAM job on a stock, paused at its start; play it with `play()`. `stock` is `[[minX, minY, minZ], [maxX, maxY, maxZ]]`. */
  showMachining(programs: MachiningProgram[], stock: [ArrayLike<number>, ArrayLike<number>], part?: { positions: ArrayLike<number>; indices: ArrayLike<number> } | null, options?: { cell?: number; tolerance?: number; skin?: number; rapidRate?: number }): Machining;
  /** Play the timeline at `speed` times real time. */
  play(speed?: number): void;
  pause(): void;
  /** Set the clock, clamped to [0, duration]. */
  seek(seconds: number): void;
  loop(on?: boolean): void;
  readonly time: number;
  readonly duration: number;
  readonly playing: boolean;
  /** One line per track at the clock's time. */
  status(): string[];
  showCurves(beziers: ArrayLike<number>, rgb?: Colour | null): Item;
  showImage(corners: ArrayLike<number>, rgba: Uint8Array, width: number, height: number, opacity?: number): Item;
  orbit(dx: number, dy: number): void;
  pan(dx: number, dy: number): void;
  zoom(steps: number): void;
  look(dx: number, dy: number): void;
  dolly(ratio: number): void;
  standard(name: 'top' | 'front' | 'right' | 'iso'): void;
  frame(): void;
  orthographic(on: boolean): void;
  /** Whether a double click frames what it hit (off by default: a pick answered with clicks 2). */
  setDoubleClickFrames(on: boolean): void;
  /** Moves the orbit point to `point` (a pick's point): the eye keeps its direction and distance; leaves fly mode. */
  focus(point: ArrayLike<number>): void;
  /** How a left drag moves the camera: 'orbit' or 'fly' (after a fly key; Tab toggles it). */
  readonly navigation: 'orbit' | 'fly';
  viewports(list: Viewport[]): void;
  layer(name: 'surfaces' | 'edges' | 'curves' | 'isocurves' | 'grid' | 'text', on: boolean): void;
  background(rgb: Colour): void;
  pick(x: number, y: number, viewport?: number): Pick | null;
  /** The newest pick answer that landed (a click, a double click), without waiting: undefined while none has, null for a click on nothing; each read once. */
  lastPick(): Pick | null | undefined;
  /** What a snap may land on (view ABI 1.22): 'all' (the default), one kind, several, or null to switch snapping off. A view starts with snapping off. */
  setSnap(kinds?: 'all' | SnapKind | SnapKind[] | null, options?: { aperturePx?: number; marker?: boolean }): void;
  /** The snap under pixel (x, y) of `viewport`, drawing until it lands; null where nothing snaps (always, while snapping is off). */
  snap(x: number, y: number, viewport?: number): Snap | null;
  /** The newest snap that landed (a hover, a click), without waiting: undefined while none has, null for one that found nothing; each read once. */
  lastSnap(): Snap | null | undefined;
  /** Hides the snap marker and drops any snap asked or answered and not yet read. */
  clearSnap(): void;
  /** The plane 'grid' and 'plane' snaps land on, in place of the ground grid; null puts the ground grid back. */
  setWorkPlane(origin: ArrayLike<number> | null, xAxis?: ArrayLike<number>, normal?: ArrayLike<number>, step?: number): void;
  draw(): void;
  run(): Camera;
  image(): Image;
  save(path: string): void;
  input(event: ViewEvent): number;
  resize(width: number, height: number): void;
  close(): void;
}
