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
  nodeVisible(node: number, on: boolean): void;
  nodeColour(node: number, rgba: ColourAlpha | null): void;
  nodeHighlight(node: number, rgba: ColourAlpha | null): void;
  frameNode(node: number): void;
}

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
  lod(motion?: 'detailed' | 'smooth' | null, minTriangles?: number): void;
  show(obj: Solid | Scene | Node, rgb?: Colour | null, tolerance?: number): Item;
  showSolid(solid: Solid, tolerance?: number, rgb?: Colour | null): Item;
  showScene(scene: Scene): Item;
  showNode(node: Node): Item;
  showMesh(mesh: MeshData): Item;
  showText(text: string, at: ArrayLike<number>, options?: TextOptions): Item;
  showLines(segments: ArrayLike<number>, rgb?: Colour | null): Item;
  /** Points, three numbers each (a flat run, or `[x, y, z]` a point): a disc `sizePx` device pixels across (1 to 64, 8 by default) at each, in `colour` (null: the edge colour), as one item. */
  showPoints(positions: ArrayLike<number> | ArrayLike<number>[], colour?: Colour | null, sizePx?: number): Item;
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
  draw(): void;
  run(): Camera;
  image(): Image;
  save(path: string): void;
  input(event: ViewEvent): number;
  resize(width: number, height: number): void;
  close(): void;
}
