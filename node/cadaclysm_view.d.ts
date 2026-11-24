import type { Scene, Node } from './cadaclysm';
import type { Solid, Profile, Animation } from './cadaclysm_blacksmith';

export class ViewError extends Error {}
/** What an animation target moves (view ABI 1.27): `item` an Item or its id, `node` a Node or its index (absent: the item itself). */
export interface AnimationBinding { target: string; item: Item | number; node?: Node | number | null; }
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
export const _GLYPH_KINDS: readonly GlyphKind[];
export const OPEN: 1;
export const CLOSED: 2;
/** The number of clip-plane slots (view ABI 1.31, CADACLYSM_VIEW_CLIP_PLANES). */
export const CLIP_PLANES: 6;
/** The viewports that may have a clip set of their own (view ABI 1.32, CADACLYSM_VIEW_CLIP_VIEWPORTS). */
export const CLIP_VIEWPORTS: 8;
/** How a clip set's planes combine (view ABI 1.32): drawn where every plane keeps, or hidden only where every plane hides. */
export type ClipMode = 'intersection' | 'cutaway';

export interface ViewOptions { title?: string; width?: number; height?: number; surfaces?: 'exact' | 'triangles'; up?: 'z' | 'y'; backend?: number; }
export interface NativeWindow { kind: 'win32' | 'xlib' | 'xcb' | 'wayland' | 'appkit'; window?: unknown; windowId?: number | bigint; display?: unknown; width: number; height: number; }
export type ViewName = 'front' | 'back' | 'left' | 'right' | 'top' | 'bottom' | 'iso';
export interface ShowOptions { view?: ViewName | [azimuth: number, elevation: number]; azimuth?: number; elevation?: number; zoom?: number; up?: 'z' | 'y'; edges?: boolean; width?: number; height?: number; title?: string; tolerance?: number; rgb?: Colour; }
/** A pick answer: `clicks` 2 for a double click, else 1; `point` where the ray met the model, null where no depth was read. */
export interface Pick { item: number; node: number; face: number; clicks: number; point: [number, number, number] | null; /** 1.24: the item is an overlay, picked before anything beneath it. */ overlay: boolean; /** 1.28: the viewport whose label was under the pixel (item is 0 then), or -1 for none. */ viewportLabel: number; /** 1.30: the wire hit's segment (a lines item's segment, a curves item's Bezier, a kernel solid's edge index), null for a face, a point, a glyph or a label. */ segment: number | null; /** 1.30: from the cursor to the hit in device pixels; 0 for a face. */ distancePx: number; }
/** 1.30: what `View.pickRect` found: its item, what it is ('face' as the pick numbers it, 'node' of an item with no face ranges, 'segment' of a lines or curves item, 'edge' of a kernel solid or read scene, 'point' of a points or glyphs item) and its index. */
export interface RectHit { item: number; /** A kind a later library adds comes as its number, in text ('6'). */ kind: 'face' | 'node' | 'segment' | 'edge' | 'point' | (string & {}); index: number; }
/** Where an overlay hangs in the window (view ABI 1.24); its offset is measured inward from it. */
export type PointShape = 'disc' | 'ring' | 'square' | 'diamond';
export type PointState = 'normal' | 'hover' | 'selected' | 'first';
/** 1.29: a glyph's kind (`View.showGlyphs`), numbered 0..11 as the header's CADACLYSM_VIEW_GLYPH_*. */
export type GlyphKind = 'arrow' | 'tick' | 'cross' | 'square' | 'triangle' | 'parallel' | 'perpendicular' | 'coincident' | 'tangent' | 'fixed' | 'horizontal' | 'vertical';
export type Anchor = 'top-left' | 'top' | 'top-right' | 'left' | 'centre' | 'center' | 'right' | 'bottom-left' | 'bottom' | 'bottom-right';
/** `View.showOverlay`'s style: an outline by default -- `stroke` a colour or 'none' (unset: the profile's own colour, else white); `fill` only where given, a colour or 'none'. Neither is refused. */
export interface OverlayStyle { fill?: ColourAlpha | 'none' | null; stroke?: ColourAlpha | 'none' | null; strokeWidth?: number; order?: number; }
/** `View.showOverlayText`'s options: showText's, in pixels, plus the overlay order. */
export interface OverlayTextOptions { size?: number; colour?: Colour; box?: ColourAlpha | null; padding?: number; font?: number; order?: number; }
/** `View.showOverlayImage`'s options: the size drawn (0: its own), the opacity, the overlay order. */
export interface OverlayImageOptions { drawWidth?: number; drawHeight?: number; opacity?: number; order?: number; }
/** What a snap lands on (view ABI 1.22; 1.30 added 'end', 'intersection', 'point' and 'alignment'). */
export type SnapKind = 'vertex' | 'midpoint' | 'centre' | 'quadrant' | 'edge' | 'face' | 'grid' | 'plane' | 'end' | 'intersection' | 'point' | 'alignment';
/** A snap answer: the point snapped to, in the coordinates the items were shown in; `edge` null for a face, grid or plane snap; `clicks` 0 for snap() and a hover, 1 or 2 for a click's. */
export interface Snap { kind: SnapKind; point: [number, number, number]; item: number; node: number; face: number; edge: number | null; tangent: [number, number, number]; axis: [number, number, number]; radius: number; distancePx: number; clicks: number; /** 1.30: a 'point' snap's label, else the kind's name. */ label: string; /** 1.30: the lock's angle in degrees (0..360) where `setSnapBase` turned the point, else null. */ lockedAngle: number | null; /** 1.30: 0 to 2 guides, each `[from, to]` in world coordinates: alignment guides or the lock's ray. */ guides: Array<[[number, number, number], [number, number, number]]>; }
export interface Camera { eye: number[]; target: number[]; up: number[]; orthographic: boolean; azimuth: number; elevation: number; pick: Pick | null; }
/** What every input event carries (view ABI 1.26): the library's own clock (only differences mean anything), and how many events a full queue (1024) dropped just before this one. */
interface InputEventBase { timeMs: number; dropped: number; }
/** The modifiers held during a pointer, wheel or key event. */
interface Modifiers { shift: boolean; ctrl: boolean; alt: boolean; meta: boolean; }
/** A button went down, the pointer moved or a button went up: x, y in physical pixels; button 0 left, 1 middle, 2 right (0 for a move); the touch's pointerId. */
export interface PointerInputEvent extends InputEventBase, Modifiers { type: 'pointer_down' | 'pointer_move' | 'pointer_up'; x: number; y: number; button: number; pointer: 'mouse' | 'touch' | 'pen'; pointerId: number; }
/** The wheel turned at x, y: wheelY a DOM deltaY, negative forward (about 100 a notch). */
export interface WheelInputEvent extends InputEventBase, Modifiers { type: 'wheel'; x: number; y: number; wheelY: number; }
/** A key went down or up: key is its DOM code ('KeyR', 'Digit1', 'Space', 'Escape', 'ArrowUp', 'ShiftLeft', 'F5'), every key; repeat for the system's auto-repeat. */
export interface KeyInputEvent extends InputEventBase, Modifiers { type: 'key_down' | 'key_up'; key: string; repeat: boolean; }
/** The window's drawing area is now width x height physical pixels. */
export interface ResizeInputEvent extends InputEventBase { type: 'resize'; width: number; height: number; }
/** A click's pick has landed: what it hit, or null for nothing; `lastPick` gets the same answer. */
export interface PickInputEvent extends InputEventBase { type: 'pick'; pick: Pick | null; }
/** With snapping on, a hover's or click's snap has landed (clicks 0 for a hover), or null for none; `lastSnap` gets the same answer. */
export interface SnapInputEvent extends InputEventBase { type: 'snap'; snap: Snap | null; }
/** The window closed (Escape, its close button, `closeWindow`): the last event, with the camera it closed on (its pick null). */
export interface CloseInputEvent extends InputEventBase { type: 'close'; camera: Camera; }
/** The clock moved (view ABI 1.27): a draw after the timeline played, or after a seek, play or pause; no fields beyond the stamp, read `View.time`. */
export interface TimelineInputEvent extends InputEventBase { type: 'timeline'; }
/** One input event a view's own window handled (`View.nextEvent`, `View.run(onEvent)`, view ABI 1.26), told apart by `type`. */
export type InputEvent = PointerInputEvent | WheelInputEvent | KeyInputEvent | ResizeInputEvent | PickInputEvent | SnapInputEvent | CloseInputEvent | TimelineInputEvent;
export interface Image { width: number; height: number; rgba: Uint8Array; }
export interface ViewEvent { type: 'pointer_down' | 'pointer_move' | 'pointer_up' | 'pointer_cancel' | 'wheel' | 'key'; x?: number; y?: number; button?: number; shift?: boolean; pointerId?: number; pointer?: 'mouse' | 'touch' | 'pen'; wheelY?: number; key?: string; keyDown?: boolean; timeMs?: number; }
/** `layerMask`: the user layers drawn here, bit n for layer n (`Item.setUserLayer`); every layer when absent. */
export interface Viewport { rect: number[]; view: ArrayLike<number>; projection: ArrayLike<number>; eye: ArrayLike<number>; grid?: 'none' | 'top' | 'front' | 'right'; layerMask?: number; }
export interface MeshData { positions: ArrayLike<number>; indices: ArrayLike<number>; normals?: ArrayLike<number> | null; edges?: ArrayLike<number> | null; rgb?: Colour | null; }

export class Item {
  readonly id: number;
  readonly view: View;
  readonly shown: Solid | Scene | Node | null;
  remove(): void;
  setNodeTransforms(transforms: ArrayLike<number>[] | null): void;
  setColour(rgb: Colour): void;
  setText(text: string): void;
  setPlacement(matrix: ArrayLike<number> | null): void;
  /** One colour a face (text, or 3 or 4 numbers), or four numbers a face, flat. */
  setFaceColours(faces: ArrayLike<number> | null, rgba?: ArrayLike<number> | ReadonlyArray<ColourAlpha>): void;
  frame(): void;
  setXray(on: boolean): void;
  /** 1.28: draws the item's lines in its own dash and gap, in points; null (or a dash of 0) is solid. A gap of 0 with a dash is refused. */
  setLineStyle(style: { dash: number; gap: number } | null): void;
  /** 1.28: a points item's marker. */
  setPointStyle(style?: { shape?: PointShape; hollow?: boolean }): void;
  /** 1.28: one state a point, by name or by number 0..3; one entry per point. */
  setPointStates(states: Iterable<PointState | number>): void;
  /** 1.29: replaces a lines item's segments (six numbers each) in place; an empty list empties it. */
  setLines(segments: ArrayLike<number>): void;
  /** 1.29: replaces a curves item's Beziers (sixteen numbers each) in place. */
  setCurves(beziers: ArrayLike<number>): void;
  /** 1.29: replaces a points item's positions (three numbers each); the point states stay by index. */
  setPoints(positions: ArrayLike<number>): void;
  /** 1.29: moves a mesh item's vertices in place (same count); null normals are recomputed. */
  setMeshPositions(positions: ArrayLike<number>, normals?: ArrayLike<number> | null): void;
  /** 1.30: points a 'point' snap lands on (`[[x, y, z], ...]` or flat), each answering `label` (at most 31 bytes; null or '': 'point'); none clears them. */
  setSnapPoints(points: ArrayLike<number> | ReadonlyArray<ArrayLike<number>>, label?: string | null): void;
  /** 1.28: draws the item after every other with depth testing off, picked ahead of what is under it (refused for overlays, text, images, exact-surface and curve items). */
  setOnTop(on?: boolean): void;
  /** How its lines and points draw where a surface hides them: 'off' (an item shows with it until set), 'solid' or 'dashed'. */
  setOccluded(mode: 'off' | 'solid' | 'dashed'): void;
  /** Its finish under the lighting: 'gloss' (an item shows with it until set; under the showroom lighting a clear coat), 'satin' (a weaker, blurred coat) or 'matte' (no mirror). */
  setFinish(finish: 'gloss' | 'satin' | 'matte'): void;
  /** Its edges in `rgb` (view ABI 1.23), over the view's `setEdgeColour`, its colour and a solid's own edge paint; null takes the view's colour again. */
  setEdgeColour(rgb: Colour | null): void;
  /** Its curves in `rgb` (view ABI 1.23), over the view's `setCurveColour` and its colour; null takes the view's colour again. */
  setCurveColour(rgb: Colour | null): void;
  /** Its isocurves in `rgb` (view ABI 1.23), over the view's `setIsocurveColour` and its colour; null takes the view's colour again. */
  setIsocurveColour(rgb: Colour | null): void;
  /** The user layer it is on, 0..31 (every item starts on 0): drawn while the layer is on (`View.setUserLayer`) and in viewports whose `layerMask` has its bit. */
  setUserLayer(layer: number): void;
  /** Shown or hidden (view ABI 1.27): a hidden item draws nothing, is never picked or snapped and is left out of `frame`; it shows only while its layer is on too. */
  setVisible(visible: boolean): void;
  /** The nodes drawn as ghosts (x-ray), each an index or a Node (view ABI 1.27); the set replaces the previous ghosts, null or an empty list clears them. */
  setNodeGhosts(nodes: Iterable<number | Node> | null): void;
  setNodeVisible(node: number, on: boolean): void;
  setNodeColour(node: number, rgba: ColourAlpha | null): void;
  setNodeHighlight(node: number, rgba: ColourAlpha | null): void;
  frameNode(node: number): void;
}

export interface MachiningTool { number: number; shape: 'flat' | 'ball' | 'drill' | 'vbit' | 'bullnose'; diameter: number; flute_length?: number; angle?: number; corner_radius?: number; }
export type MachiningProgram = [MachiningTool, string] | { tool: MachiningTool; gcode: string };
/** What a view has drawn (View.stats, view ABI 1.25). */
export interface ViewStats {
  /** Frames drawn: every frame drawn to the window and every image() rendered; a pump or draw that owes nothing adds none. */
  framesDrawn: number;
  /** The last frame's CPU time, ms. */
  lastFrameMs: number;
  /** The last frame's GPU time, ms; -1 where it cannot be measured. */
  lastGpuMs: number;
  /** Triangles the last frame drew. */
  triangles: number;
  /** Draw calls the last frame recorded. */
  drawCalls: number;
}
export interface MachiningInfo { moves: number; move: number; nx: number; ny: number; cell: number; min: [number, number]; cycleTime: number; }

/** A CAM job shown in a View (`View.showMachining`): the stock is this item; the view's timeline plays it. */
/** An overlay shown (view ABI 1.24): a shape, text or an image hung from an anchor of the window. */
export class Overlay extends Item {
  /** The anchor it hangs from now. */
  readonly anchor: Anchor;
  /** Moved to `x`, `y` pixels inward from its anchor, or hung from `anchor` instead. */
  moveTo(x: number, y: number, anchor?: Anchor): void;
}
export class Machining extends Item {
  /** Jump the timeline to the end of move `move` (0: the untouched stock). */
  seekMove(move: number): void;
  /** 'deviation' needs a part. */
  setColourBy(mode: 'height' | 'tool' | 'deviation'): void;
  /** The toolpath and the tool, on or off. */
  setOverlays(path?: boolean, tool?: boolean): void;
  info(): MachiningInfo;
  /** The stock's heights now, `nx * ny` floats, row y then x; waits for the GPU. */
  heights(): Float32Array;
}

export interface OccludedStyle { dash: number; gap: number; dim: number; colour: [number, number, number] | null; }
/** A clip plane as `View.setClipPlane` takes it (view ABI 1.31): absent keys take their defaults (no cap, no hatch, angle 45, spacing 0 = automatic, width 1). */
export interface ClipPlaneOptions {
  point: ArrayLike<number>;
  normal: ArrayLike<number>;
  cap?: Colour | null;
  hatch?: Colour | null;
  hatchAngle?: number;
  hatchSpacing?: number;
  hatchWidth?: number;
  /** 1.32: a colour drawing the cut as a line, capped or not (none by default). */
  outline?: Colour | null;
  /** 1.32: the outline's width in points (1; 0 reads back 1; at most 100). */
  outlineWidth?: number;
}
/** A clip plane as `View.clipPlane` reads it back: the normal of unit length, a zero width resolved to 1; with no hatch the angle, spacing and width are the defaults; with no outline its width is 1. */
export interface ClipPlane {
  point: [number, number, number];
  normal: [number, number, number];
  cap: [number, number, number] | null;
  hatch: [number, number, number] | null;
  hatchAngle: number;
  hatchSpacing: number;
  hatchWidth: number;
  outline: [number, number, number] | null;
  outlineWidth: number;
}
/** The colour every edge, curve or isocurve draws in: one colour, or each part's own where `fromPart`. */
export interface LineColour { colour: [number, number, number]; fromPart: boolean; }
export class View {
  constructor(options?: ViewOptions);
  static inWindow(window: NativeWindow, options?: ViewOptions): View;
  static offscreen(width: number, height: number, options?: ViewOptions): View;
  readonly closed: boolean;
  readonly needsDraw: boolean;
  /** What the view has drawn (view ABI 1.25): an FPS counter read from it stays right while the scene is still. */
  stats(): ViewStats;
  readonly size: [number, number];
  readonly wakeMs: number | null;
  surfaces: 'exact' | 'triangles';
  /** How plain parts are lit (view ABI 1.9): 'headlight' (the default) or 'studio'. */
  lighting: 'headlight' | 'studio';
  /** Whether parts whose material has a base-colour texture (a glTF's) draw it -- true, the default -- or their colour (view ABI 1.33). */
  textures: boolean;
  /** How every 'dashed' item's hidden lines and points look, view-wide (view ABI 1.20): dash and gap in points (6, 4), dim the coverage kept (0.5), one colour or null. Set a partial style (unset keys take the default) or null for the defaults. */
  get occludedStyle(): OccludedStyle;
  set occludedStyle(style: Partial<Omit<OccludedStyle, 'colour'>> & { colour?: Colour | null } | null);
  /** The colour every edge draws in (view ABI 1.23): `rgb`, or with `fromPart` each part's own colour, brightened. An item's `setEdgeColour` draws over it. */
  setEdgeColour(rgb: Colour, fromPart?: boolean): void;
  /** The edges' colour in use. */
  edgeColour(): LineColour;
  /** The colour every curve draws in (view ABI 1.23): `rgb`, or with `fromPart` each part's own colour (the default). */
  setCurveColour(rgb: Colour, fromPart?: boolean): void;
  /** The curves' colour in use. */
  curveColour(): LineColour;
  /** The colour every isocurve draws in (view ABI 1.23): `rgb`, or with `fromPart` each part's own colour. */
  setIsocurveColour(rgb: Colour, fromPart?: boolean): void;
  /** The isocurves' colour in use. */
  isocurveColour(): LineColour;
  setLod(motion?: 'detailed' | 'smooth' | null, minTriangles?: number): void;
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
  setLoop(on?: boolean): void;
  /**
   * Plays the kernel `animation` on the timeline (view ABI 1.27); the track's id (1 or more). Each binding is
   * `{ target, item, node? }` or `[target, item, node?]`. The view plays its own copy: the animation may be closed at once.
   */
  playAnimation(animation: Animation, bindings: Iterable<AnimationBinding | [string, Item | number] | [string, Item | number, Node | number | null | undefined]>): number;
  /** Removes the track `playAnimation` returned and restores what it moved (view ABI 1.27). */
  removeTrack(track: number): void;
  readonly time: number;
  readonly duration: number;
  readonly playing: boolean;
  /** One line per track at the clock's time. */
  status(): string[];
  showCurves(beziers: ArrayLike<number>, rgb?: Colour | null): Item;
  /** 1.29: drafting glyphs of one `kind` at each of `at` (three numbers each), `sizePt` points across (1 to 128, default 12), in `colour` (null: the edge colour), turned to `dir` (three numbers a glyph as projected on the screen; null: unturned). Glyph i picks as node i. */
  showGlyphs(at: ArrayLike<number>, options: { kind: GlyphKind; sizePt?: number; colour?: Colour | null; dir?: ArrayLike<number> | null }): Item;
  /** A 2D shape over the window (view ABI 1.24): a profile, profiles, or Beziers (16 numbers each), in pixels, hung `x`, `y` pixels inward from `anchor`. */
  showOverlay(shape: Profile | Profile[] | ArrayLike<number>, anchor: Anchor, x: number, y: number, style?: OverlayStyle): Overlay;
  /** Text over the window (view ABI 1.24): its box hangs from `anchor` by the same point, `x`, `y` pixels inward. */
  showOverlayText(text: string, anchor: Anchor, x: number, y: number, options?: OverlayTextOptions): Overlay;
  /** An image over the window (view ABI 1.24): `rgba` rows from the top, its box hanging from `anchor`, `x`, `y` pixels inward. */
  showOverlayImage(rgba: Uint8Array, width: number, height: number, anchor: Anchor, x: number, y: number, options?: OverlayImageOptions): Overlay;
  showImage(corners: ArrayLike<number>, rgba: Uint8Array, width: number, height: number, opacity?: number): Item;
  orbit(dx: number, dy: number): void;
  pan(dx: number, dy: number): void;
  zoom(steps: number): void;
  look(dx: number, dy: number): void;
  dolly(ratio: number): void;
  standard(name: 'top' | 'front' | 'right' | 'iso'): void;
  frame(): void;
  setOrthographic(on: boolean): void;
  /** Whether a double click frames what it hit (off by default: a pick answered with clicks 2). */
  setDoubleClickFrames(on: boolean): void;
  /** Moves the orbit point to `point` (a pick's point): the eye keeps its direction and distance; leaves fly mode. */
  focus(point: ArrayLike<number>): void;
  /** How a left drag moves the camera: 'orbit' or 'fly' (after a fly key; Tab toggles it). */
  readonly navigation: 'orbit' | 'fly';
  setViewports(list: Viewport[]): void;
  /** 1.28: the colours hover, selected and first points draw in; a missing one restores its default. */
  setPointStateColours(colours?: { hover?: Colour | null; selected?: Colour | null; first?: Colour | null }): void;
  /** 1.28: names viewport `i` top left inside it; null clears it. */
  setViewportLabel(i: number, text: string | null, options?: { colour?: Colour | null }): void;
  /** 1.28: frames viewport `i` one point inside its edge; null clears it. */
  setViewportBorder(i: number, colour: Colour | null): void;
  setLayer(name: 'surfaces' | 'edges' | 'curves' | 'isocurves' | 'grid' | 'text', on: boolean): void;
  /** User layer `layer`, 0..31, on or off in every viewport (all start on). */
  setUserLayer(layer: number, on: boolean): void;
  setBackground(rgb: Colour): void;
  pick(x: number, y: number, viewport?: number): Pick | null;
  /** The newest pick answer that landed (a click, a double click), without waiting: undefined while none has, null for a click on nothing; each read once. */
  lastPick(): Pick | null | undefined;
  /** What a snap may land on (view ABI 1.22): 'default' (the default: the first eight and 'point'), 'all', one kind, several, or null to switch snapping off. A view starts with snapping off. */
  setSnap(kinds?: 'default' | 'all' | SnapKind | SnapKind[] | null, options?: { aperturePx?: number; marker?: boolean }): void;
  /** The snap under pixel (x, y) of `viewport`, drawing until it lands; null where nothing snaps (always, while snapping is off). */
  snap(x: number, y: number, viewport?: number): Snap | null;
  /** The newest snap that landed (a hover, a click), without waiting: undefined while none has, null for one that found nothing; each read once. */
  lastSnap(): Snap | null | undefined;
  /** Hides the snap marker and drops any snap asked or answered and not yet read. */
  clearSnap(): void;
  /** The plane 'grid' and 'plane' snaps land on, in place of the ground grid; null puts the ground grid back. */
  setWorkPlane(origin: ArrayLike<number> | null, xAxis?: ArrayLike<number>, normal?: ArrayLike<number>, step?: number): void;
  /** 1.30: the angle lock: snaps on no point kind turn about `point` onto multiples of `stepDeg` (default 15); null clears it. */
  setSnapBase(point: ArrayLike<number> | null, stepDeg?: number): void;
  /** 1.30: how far a pick reaches for lines, curves, points and glyphs, in points; 0 restores the default, 4. */
  setPickAperture(points: number): void;
  /** 1.30: what lies in a rectangle of `viewport` (device pixels), crossing by default; every hit, sorted by item, kind and index. */
  pickRect(x: number, y: number, w: number, h: number, options?: { crossing?: boolean; viewport?: number }): RectHit[];
  /** 1.31: sets clip-plane slot `slot` (0..5), view-wide: the side `normal` points to is hidden; an optional cap fills the cut, hatched where `hatch`. null clears. */
  setClipPlane(slot: number, plane: ClipPlaneOptions | null): void;
  /** 1.31: clears clip-plane slot `slot`. */
  clearClipPlane(slot: number): void;
  /** 1.31: clip-plane slot `slot` as set, or null for an empty slot. */
  clipPlane(slot: number): ClipPlane | null;
  /** 1.32: how the view-wide planes combine; 'intersection' by default. */
  clipMode: ClipMode;
  /** 1.32: sets slot `slot` of viewport `viewport`'s own clip set (the first plane gives it a set of its own). null clears the slot. */
  setViewportClipPlane(viewport: number, slot: number, plane: ClipPlaneOptions | null): void;
  /** 1.32: clears slot `slot` of viewport `viewport`'s own clip set; the set stays its own. */
  clearViewportClipPlane(viewport: number, slot: number): void;
  /** 1.32: slot `slot` of viewport `viewport`'s own clip set, or null for an empty slot or a viewport with no set of its own. */
  viewportClipPlane(viewport: number, slot: number): ClipPlane | null;
  /** 1.32: viewport `viewport`'s own set's mode; null (or 'inherit') drops its set, back to the view-wide one. */
  setViewportClipMode(viewport: number, mode: ClipMode | 'inherit' | null): void;
  /** 1.32: viewport `viewport`'s own set's mode, or null where it inherits the view-wide set. */
  viewportClipMode(viewport: number): ClipMode | null;
  draw(): void;
  /** Blocks until the window is closed; the camera it ended on and the last pick. */
  run(): Camera;
  /**
   * The window run on this thread, each input event handed to `onEvent` between pumps as the window handles it
   * (view ABI 1.26): returning `false` closes the window and ends the run; the 'close' event is handed over last
   * when the window closes by itself. The camera it closed on and the last pick.
   */
  run(onEvent: (event: InputEvent) => boolean | void): Camera;
  /** The oldest input event the own window handled and has not handed out yet, without waiting; null while none waits (view ABI 1.26). A view in a host's window, or offscreen, queues nothing. */
  nextEvent(): InputEvent | null;
  /** Closes the own window as its close button does (view ABI 1.26): `closed` turns true and a 'close' event is queued; `close()` still owes the destroy. Refused for a view in a host's window or offscreen. */
  closeWindow(): void;
  image(): Image;
  save(path: string): void;
  input(event: ViewEvent): number;
  resize(width: number, height: number): void;
  close(): void;
}
