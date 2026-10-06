import type { Scene, Node } from './cadaclysm';
import type { Solid } from './cadaclysm_blacksmith';

export class ViewError extends Error {}
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
export function _release(obj: unknown): void;
export function _reset(): void;
export const OPEN: 1;
export const CLOSED: 2;

export interface ViewOptions { title?: string; width?: number; height?: number; surfaces?: 'exact' | 'triangles'; up?: 'z' | 'y'; backend?: number; }
export interface NativeWindow { kind: 'win32' | 'xlib' | 'xcb' | 'wayland' | 'appkit'; window?: unknown; windowId?: number | bigint; display?: unknown; width: number; height: number; }
export type ViewName = 'front' | 'back' | 'left' | 'right' | 'top' | 'bottom' | 'iso';
export interface ShowOptions { view?: ViewName | [azimuth: number, elevation: number]; azimuth?: number; elevation?: number; zoom?: number; up?: 'z' | 'y'; edges?: boolean; width?: number; height?: number; title?: string; tolerance?: number; rgb?: number[]; }
export interface Pick { item: number; node: number; face: number; }
export interface Camera { eye: number[]; target: number[]; up: number[]; orthographic: boolean; azimuth: number; elevation: number; pick: Pick | null; }
export interface Image { width: number; height: number; rgba: Uint8Array; }
export interface ViewEvent { type: 'pointer_down' | 'pointer_move' | 'pointer_up' | 'pointer_cancel' | 'wheel' | 'key'; x?: number; y?: number; button?: number; shift?: boolean; pointerId?: number; pointer?: 'mouse' | 'touch' | 'pen'; wheelY?: number; key?: string; keyDown?: boolean; timeMs?: number; }
export interface Viewport { rect: number[]; view: ArrayLike<number>; projection: ArrayLike<number>; eye: ArrayLike<number>; grid?: 'none' | 'top' | 'front' | 'right'; }
export interface MeshData { positions: ArrayLike<number>; indices: ArrayLike<number>; normals?: ArrayLike<number> | null; edges?: ArrayLike<number> | null; rgb?: number[] | null; }

export class Item {
  readonly id: number;
  readonly view: View;
  readonly shown: Solid | Scene | Node | null;
  remove(): void;
  nodeTransforms(transforms: ArrayLike<number>[] | null): void;
  colour(rgb: number[]): void;
  placement(matrix: ArrayLike<number> | null): void;
  faceColours(faces: ArrayLike<number> | null, rgba?: ArrayLike<number>): void;
  frame(): void;
  xray(on: boolean): void;
  nodeVisible(node: number, on: boolean): void;
  nodeColour(node: number, rgba: number[] | null): void;
  nodeHighlight(node: number, rgba: number[] | null): void;
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
  lod(motion?: 'detailed' | 'smooth' | null, minTriangles?: number): void;
  show(obj: Solid | Scene | Node, rgb?: number[] | null, tolerance?: number): Item;
  showSolid(solid: Solid, tolerance?: number, rgb?: number[] | null): Item;
  showScene(scene: Scene): Item;
  showNode(node: Node): Item;
  showMesh(mesh: MeshData): Item;
  showLines(segments: ArrayLike<number>, rgb?: number[] | null): Item;
  showCurves(beziers: ArrayLike<number>, rgb?: number[] | null): Item;
  showImage(corners: ArrayLike<number>, rgba: Uint8Array, width: number, height: number, opacity?: number): Item;
  orbit(dx: number, dy: number): void;
  pan(dx: number, dy: number): void;
  zoom(steps: number): void;
  look(dx: number, dy: number): void;
  dolly(ratio: number): void;
  standard(name: 'top' | 'front' | 'right' | 'iso'): void;
  frame(): void;
  orthographic(on: boolean): void;
  viewports(list: Viewport[]): void;
  layer(name: 'surfaces' | 'edges' | 'curves' | 'isocurves' | 'grid', on: boolean): void;
  background(rgb: number[]): void;
  pick(x: number, y: number, viewport?: number): Pick | null;
  draw(): void;
  run(): Camera;
  image(): Image;
  save(path: string): void;
  input(event: ViewEvent): number;
  resize(width: number, height: number): void;
  close(): void;
}
