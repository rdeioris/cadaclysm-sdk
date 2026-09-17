/* cadaclysm - one C ABI over the whole project. Generated; do not edit. */

#ifndef CADACLYSM_H
#define CADACLYSM_H



#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Returned where a part has no parent, and by any lookup that found nothing.
 */
#define CADACLYSM_NONE UINT32_MAX

/**
 * The face count above which a convex hull cannot be a Unity `MeshCollider`.
 *
 * Named rather than clamped to -- see [`cadaclysm_node_collision`].
 *
 * Spelled as a literal because cbindgen cannot fold a path expression into the
 * header, and a constant the header refers to but never defines is one a C caller
 * cannot use. The assertion below is what keeps the literal honest.
 */
#define CADACLYSM_UNITY_HULL_LIMIT 255

/**
 * How many coarser levels [`cadaclysm_node_mesh_lod`] can give.
 *
 * A constant of the library rather than a property of a scene, so a caller can
 * size its buffers before opening anything.
 */
#define CADACLYSM_LOD_LEVELS 3

/**
 * The host has no window, and wants an unparented dialog -- see
 * [`CadaclysmWindow`] for what that costs.
 */
#define CADACLYSM_WINDOW_NONE 0

/**
 * An X11 window id.
 */
#define CADACLYSM_WINDOW_X11 1

/**
 * A Wayland `wl_surface`.
 */
#define CADACLYSM_WINDOW_WAYLAND 2

/**
 * A Win32 `HWND`.
 */
#define CADACLYSM_WINDOW_WIN32 3

/**
 * An AppKit window -- passed as its `NSView`, not its `NSWindow`; see
 * [`CadaclysmWindow`].
 */
#define CADACLYSM_WINDOW_APPKIT 4

/**
 * One of the six directions an axis can land on, for
 * [`CadaclysmConventionSpec`]. Spelled the way the header spells its other
 * constants, for the same reason [`CadaclysmConvention`] is.
 */
typedef enum CadaclysmAxis {
  CADACLYSM_AXIS_X = 0,
  CADACLYSM_AXIS_Y = 1,
  CADACLYSM_AXIS_Z = 2,
  CADACLYSM_AXIS_NEG_X = 3,
  CADACLYSM_AXIS_NEG_Y = 4,
  CADACLYSM_AXIS_NEG_Z = 5,
} CadaclysmAxis;

/**
 * Which way round the target's renderer wants a front-facing triangle wound.
 */
typedef enum CadaclysmWinding {
  /**
   * OpenGL, Vulkan, WebGPU -- and what this library produces unchanged.
   */
  CADACLYSM_WINDING_COUNTER_CLOCKWISE = 0,
  /**
   * Direct3D, and Unreal with it.
   */
  CADACLYSM_WINDING_CLOCKWISE = 1,
} CadaclysmWinding;

/**
 * What kind of value an attribute holds.
 */
typedef enum CadaclysmValueKind {
  /**
   * The attribute was not there.
   */
  CadaclysmValueNone = 0,
  CadaclysmValueText = 1,
  CadaclysmValueInteger = 2,
  CadaclysmValueReal = 3,
  CadaclysmValueBoolean = 4,
  /**
   * A list of values. The flat C struct cannot hold the elements, so `text`
   * carries a `[a, b, c]` rendering of them.
   */
  CadaclysmValueList = 5,
  /**
   * A reference to another entity, with `text` carrying the id the file gave
   * (`#4`). Distinct from [`CadaclysmValueText`](Self::CadaclysmValueText) so a
   * consumer can follow it to the part it names rather than showing the id as
   * prose.
   */
  CadaclysmValueReference = 6,
} CadaclysmValueKind;

/**
 * A target coordinate space, named the way [`cadaclysm::Convention`]'s
 * presets are — [`cadaclysm_open`] and [`cadaclysm_open_memory`] take one of
 * these as a `uint32_t`, optionally OR'd with [`CADACLYSM_FILE_UNITS`].
 *
 * `#[allow(non_camel_case_types)]`: the variants are spelled the way the rest
 * of this header spells a constant (`CADACLYSM_NONE`, `CADACLYSM_FILE_UNITS`),
 * because that is the name a C caller writes, and cbindgen carries a Rust
 * enum's variant spelling straight into the header unchanged.
 */
typedef enum CadaclysmConvention {
  CADACLYSM_NATIVE = 0,
  CADACLYSM_UNREAL = 1,
  CADACLYSM_UNITY = 2,
  CADACLYSM_Y_UP = 3,
  CADACLYSM_BLENDER = 4,
} CadaclysmConvention;

/**
 * Whether meshes carry texture coordinates, and of what kind.
 *
 * Off by default and deliberately: a `(u, v)` is eight bytes a vertex, and on a
 * ten-million-triangle assembly that is not a cost to impose on a caller who
 * never asked. What world scale is good for, and what it is not, is on
 * [`CadaclysmMesh::uvs`].
 */
typedef enum CadaclysmMeshUvs {
  CADACLYSM_UV_NONE = 0,
  /**
   * The surface's own parameters, scaled so one unit is one world unit.
   */
  CADACLYSM_UV_WORLD_SCALE = 1,
} CadaclysmMeshUvs;

/**
 * Whether meshes carry a colour per vertex.
 *
 * Off by default for the reason [`CadaclysmMeshUvs`] is — a colour is sixteen
 * bytes a vertex — and worth turning on for one thing a node's single colour
 * cannot say. STEP paints a face at a time with `OVER_RIDING_STYLED_ITEM`:
 * `io1-ec-214.stp` bores a red hole through a yellow flange as one solid, and a
 * body drawn whole has to pick whichever colour covers most of its faces.
 *
 * See [`CadaclysmMesh::colors`] for when an array actually arrives.
 */
typedef enum CadaclysmMeshColors {
  CADACLYSM_COLORS_NONE = 0,
  CADACLYSM_COLORS_PER_FACE = 1,
} CadaclysmMeshColors;

/**
 * A mesh split into meshlets, and the coarser levels above them.
 */
typedef struct CadaclysmMeshlets CadaclysmMeshlets;

/**
 * A file, read. Opaque to C; `cadaclysm_close` frees it.
 *
 * Every accessor may be called concurrently through a `*const` — the document's
 * geometry cache fills through `&self` and is `Send + Sync`, and the string
 * cache is `OnceLock`. Only `cadaclysm_close` needs exclusive access.
 */
typedef struct CadaclysmScene CadaclysmScene;

/**
 * A target space spelled out in full, for a host none of the presets names.
 *
 * Everything [`cadaclysm::Convention`] carries, so a caller can describe a
 * renderer this library has never heard of rather than waiting for a preset.
 * Passed to [`cadaclysm_open_custom`] and
 * [`cadaclysm_open_memory_custom`]; the preset entry points are unchanged and
 * remain the shorter way to say one of the five common answers.
 *
 * `x`, `y` and `z` say where the *source's* own axes land, which is the same
 * thing the presets state, so a spec can be read off one of them and edited.
 */
typedef struct CadaclysmConventionSpec {
  enum CadaclysmAxis x;
  enum CadaclysmAxis y;
  enum CadaclysmAxis z;
  /**
   * Metres per unit in the target space: 1.0 for metres, 100.0 for Unreal's
   * centimetres. Ignored when `file_units` is true.
   */
  double units_per_metre;
  /**
   * Keep the file's own units rather than scaling to `units_per_metre` --
   * the same opt-out [`CADACLYSM_FILE_UNITS`] gives a preset.
   */
  bool file_units;
  enum CadaclysmWinding winding;
} CadaclysmConventionSpec;

/**
 * One member of a zip that this build has a reader for, as offered to a
 * [`CadaclysmPick`]. Both strings are valid only for the duration of the call.
 */
typedef struct CadaclysmCandidate {
  /**
   * As named in the archive, with forward slashes: `parts/bracket.step`.
   */
  const char *name;
  /**
   * The extension the reader is registered under: `step`.
   */
  const char *format;
  /**
   * Directories above it; 0 at the top.
   */
  size_t depth;
} CadaclysmCandidate;

/**
 * A caller's say in which member of a zip opens. Called once, with every
 * readable member in archive order; returns the index to open. **Anything
 * `>= count` declines the archive**, and the open fails with that reason.
 */
typedef size_t (*CadaclysmPick)(const struct CadaclysmCandidate *candidates,
                                size_t count,
                                void *user);

/**
 * Everything an open takes beyond where the bytes come from.
 *
 * Zero it, set `size`, then set what you care about — `cadaclysm_open_options_init`
 * does the first two. A null pointer where one of these is expected means every
 * default, so `cadaclysm_open("part.step", NULL)` is the short way in.
 *
 * **`size` is how this struct grows.** Set it to `sizeof(CadaclysmOpenOptions)`
 * as *your* header declares it. The library reads the fields that fit inside it
 * and defaults the rest, so a caller built against an older header works with a
 * newer library, and a caller built against a newer one works with an older
 * library that stops reading at the end of what it knows. The rule that makes
 * that hold, and the only one: fields are appended, never reordered and never
 * removed.
 *
 * This replaced ten entry points. They were one function per combination of
 * three independent choices — where the bytes come from, how the schema is
 * named, and how the target space is — which is an eighteen-cell grid that had
 * ten of its cells filled, and anything that fitted none of them was being
 * packed into spare bits of the convention word instead.
 */
typedef struct CadaclysmOpenOptions {
  /**
   * `sizeof(CadaclysmOpenOptions)`. Zero, or anything shorter than the first
   * published struct, is refused rather than defaulted: that is uninitialised
   * memory rather than an old caller, and reading it as defaults would take a
   * garbage convention for `CADACLYSM_NATIVE`.
   */
  size_t size;
  /**
   * One of [`CadaclysmConvention`]'s values. A `u32` rather than the enum
   * itself, for the reason this header's own note on that type gives: C can
   * hand over a number no variant names, and reading that back as a Rust
   * enum would be undefined. It is range-checked instead, and an unknown
   * value is refused rather than quietly read as `CADACLYSM_NATIVE`.
   */
  uint32_t convention;
  /**
   * Not null spells the target space out in full and `convention` is ignored.
   */
  const struct CadaclysmConventionSpec *spec;
  /**
   * Keep the file's own units rather than the preset's scale.
   */
  bool file_units;
  /**
   * One of [`CadaclysmMeshUvs`]'s values, range-checked as `convention` is.
   */
  uint32_t uvs;
  /**
   * One of [`CadaclysmMeshColors`]'s values, range-checked as `convention` is.
   */
  uint32_t colors;
  /**
   * What one of the file's own units is worth in metres, for a format that
   * states none — OpenSCAD is the case, being unitless. `0` means "not said";
   * anything negative or not finite is refused rather than ignored, because a
   * caller who passed a scale meant something by it.
   */
  double source_meters_per_unit;
  /**
   * Zero or more `.exp` files or directories to read EXPRESS schemas from,
   * **on top of the built-in ones**: every schema the project ships (the IFC
   * releases, the STEP application protocols) is compiled into the library,
   * so STEP and IFC open with none given. One given here adds to that set --
   * a house schema, a newer IFC -- and replaces a built-in of the same name.
   * Null with a non-zero `schema_count` is refused.
   */
  const char *const *schemas;
  size_t schema_count;
  /**
   * EXPRESS text already in memory, for a caller with no path to give: a
   * schema downloaded, decompressed, or linked into their own binary. Must
   * be UTF-8, and is tried before `schemas`.
   */
  const uint8_t *schema_text;
  size_t schema_length;
  /**
   * Which member of a zip to open. Null means the shallowest member, ties to
   * archive order -- a top-level `main.scad` over `lib/utils.scad`. Ignored
   * for anything that is not a `.zip`.
   */
  CadaclysmPick pick;
  /**
   * Handed back to `pick` untouched.
   */
  void *pick_user;
} CadaclysmOpenOptions;

/**
 * An axis-aligned box, or all zeros where there is nothing to bound.
 */
typedef struct CadaclysmBounds {
  float min[3];
  float max[3];
} CadaclysmBounds;

/**
 * One thing a file said about a part.
 *
 * `kind` says which of the fields below it means; the rest are zero. `text`
 * borrows from the scene like every other string here.
 */
typedef struct CadaclysmAttribute {
  const char *name;
  enum CadaclysmValueKind kind;
  const char *text;
  int64_t integer;
  double real;
  bool boolean;
} CadaclysmAttribute;

/**
 * A part's triangles. All five pointers borrow from the scene.
 *
 * `positions` and `normals` each hold `vertex_count * 3` floats, `uvs` holds
 * `vertex_count * 2`, `colors` holds `vertex_count * 4`, and `indices` holds
 * `index_count` of them, three to a triangle. A part with no geometry gives
 * all-null and all-zero.
 *
 * `uvs` is present for either of two reasons, and **they do not mean the same
 * thing**:
 *
 * - **The file carried them.** A `.3dm` stores texture coordinates per vertex
 *   and this hands them straight through, whatever the scene was opened with.
 *   They mean whatever their author intended — a layout, a scale, an atlas —
 *   and nothing here normalises them.
 * - **They were generated**, because the scene was opened with
 *   `CADACLYSM_UV_WORLD` and the part's surfaces have a parameterisation to
 *   scale. Then one unit of `u` or `v` is one world unit, so a texture holds
 *   its size across faces whose parameters mean different things. Faces do not
 *   share an origin and their charts overlap, which suits a tiling material and
 *   rules out a lightmap.
 *
 * Null when none of that applies. Three ways that happens, and the third is the
 * one worth knowing:
 *
 * - No flag, and the file carried nothing.
 * - The part has no surfaces to parameterise: a constructive solid meshes
 *   straight to triangles and has none, in any format.
 * - **The reader does not honour the flag.** Only STEP generates coordinates
 *   today. IFC, IGES, BREP and OpenSCAD ignore `CADACLYSM_UV_WORLD` silently,
 *   and 3dm ignores it too — what a `.3dm` returns is its own stored
 *   coordinates, present with or without the flag.
 *
 * This ABI does not say which of the two you got. A caller who needs to know
 * knows it from the format it opened.
 */
typedef struct CadaclysmMesh {
  const float *positions;
  const float *normals;
  const float *uvs;
  /**
   * Four floats a vertex, RGBA in 0..1 — or null, which is the common case.
   *
   * Non-null only where all three hold: `CADACLYSM_COLORS_PER_FACE` was
   * asked for, a STEP reader read the body, and that body's faces carry more
   * than one colour between them. A body painted a single colour reports it
   * through [`cadaclysm_node_color`] and spends nothing here, and a body
   * painted none reports nothing either way.
   *
   * Borrowed from the document exactly as `positions` is, and valid for as
   * long.
   */
  const float *colors;
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmMesh;

/**
 * What a node turned out to be, and the body an engine can simulate for it.
 *
 * `half_extent` and `frame` are **always** the true oriented box and are always
 * usable, whatever `shape` says, so a consumer that only wants boxes can ignore
 * `shape` entirely. The fields a given `shape` does not use are written zero
 * rather than left as the caller had them.
 */
typedef struct CadaclysmCollision {
  /**
   * `sizeof(CadaclysmCollision)` as the **caller** compiled it. Set this before
   * calling; nothing is written past it. It is what lets this struct gain a
   * field without breaking a binary compiled against an older header.
   */
  uint32_t size;
  /**
   * 0 none, 1 box, 2 sphere, 3 capsule, 4 cylinder, 5 hull.
   */
  uint32_t shape;
  /**
   * 0 fitted to the triangles, 1 read from the geometry itself.
   */
  uint32_t confidence;
  /**
   * Which of the frame's three axes the primitive runs along.
   */
  uint32_t axis;
  /**
   * Rotation and centre in the node's own local space, 16 doubles column-major
   * -- deliberately the same convention as [`cadaclysm_node_transform`], so a
   * consumer that parses one parses the other.
   */
  double frame[16];
  double half_extent[3];
  double radius;
  /**
   * For a capsule the **cylindrical span, excluding the two caps** -- Unreal's
   * `FKSphylElem::Length` means the same, and Unity's `CapsuleCollider.height`
   * includes them, so a Unity consumer adds `2 * radius`. For a cylinder, the
   * full height.
   */
  double height;
  /**
   * How far the real geometry deviates from the shape, relative to the node's
   * own size. Zero where the shape was read from the geometry rather than fitted.
   */
  double error;
  uint32_t hull_vertex_count;
  uint32_t hull_index_count;
} CadaclysmCollision;

/**
 * A node's convex hull, borrowed from the scene.
 */
typedef struct CadaclysmCollisionHull {
  /**
   * Three `f32` to a vertex, in the node's own local space, or null.
   */
  const float *positions;
  /**
   * Three to a triangle, outward-wound, or null.
   */
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmCollisionHull;

/**
 * A set of polylines. Both pointers borrow from the scene.
 *
 * `positions` holds `vertex_count * 3` floats, run together end to end;
 * `counts` holds `polyline_count` vertex counts saying where each run stops.
 * A part with none gives all-null and all-zero.
 */
typedef struct CadaclysmPolylines {
  const float *positions;
  const uint32_t *counts;
  uint32_t polyline_count;
  uint32_t vertex_count;
} CadaclysmPolylines;

typedef struct CadaclysmBeziers {
  const float *points;
  const float *weights;
  uint32_t count;
} CadaclysmBeziers;

/**
 * A set of rational cubic Bézier segments. Both pointers borrow from the scene.
 *
 * `points` holds `count * 4 * 3` floats — four control points to a segment,
 * three floats to a point — and `weights` holds `count * 4` beside them. A
 * part with no curves of this kind gives all-null and zero.
 *
 * **This is the curve itself, not a drawing of it.** The polyline entry points
 * beside these flatten at the tolerance the *mesh* was built at, which is the
 * right tolerance for an overlay that must sit on the triangles and the wrong
 * one for a curve a viewer will zoom into: a circle flattened for a mesh looks
 * like a polygon from close up, and no amount of zooming recovers it, because
 * the points it might have had were discarded at load. Given the segments, a
 * caller flattens at whatever tolerance it currently needs, as often as it
 * likes.
 *
 * A rational cubic: `point(t)` is the de Casteljau interpolation of the four
 * weighted control points, divided back by the interpolated weight. That is
 * what makes a circle exact rather than approximated -- the weights are not
 * decoration and a caller that ignores them draws the wrong curve for every
 * conic in the file.
 * One trimmed face as the surface it actually is, for a caller that evaluates surfaces
 * rather than triangles.
 *
 * **A cylinder stays a cylinder:** a frame, a radius, and a `(u, v)` window. That costs
 * the caller an evaluator with a branch per `kind`, and buys the trims — because the
 * loops are in the surface's own `(u, v)`, which is the space they were computed in, so
 * testing a point against them is a point-in-polygon at coordinates the evaluator
 * already has.
 *
 * `kind` numbers the surface: 0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus,
 * 5 revolution, 6 extrusion, 7 NURBS, 8 sum. They are the same numbers this project's
 * own GPU viewer uses, deliberately, so a shader written against one works against the
 * other.
 *
 * `origin`, `ax`, `ay`, `az` are the surface's frame (`xyz` used, `w` spare) and carry
 * the quadrics entirely. `scalars` is kind-dependent: radius for a cylinder or sphere;
 * radius and half-angle for a cone; major and minor for a torus; a revolution's
 * `(spin_param.0, spin_param.1, spin_radians.0, spin_radians.1)`; an extrusion's
 * direction. A NURBS surface keeps its control net in `nurbs` instead, at `nurbs_start`.
 *
 * `domain` is `(u_min, v_min, u_max, v_max)` — the window the trims occupy, not the
 * surface's whole parameter range, so a small window cut from a large surface grids only
 * the window.
 */
typedef struct CadaclysmFace {
  uint32_t kind;
  /**
   * The face sense: non-zero where the surface normal points into the solid, so a
   * caller flips it. The CPU mesher already applied this to the triangles it built.
   */
  uint32_t reversed;
  /**
   * A revolution whose `u` is the profile and `v` the spin, rather than the other way.
   */
  uint32_t transposed;
  uint32_t reserved;
  float origin[4];
  float ax[4];
  float ay[4];
  float az[4];
  float domain[4];
  float scalars[4];
  /**
   * This face's slice of [`CadaclysmSurfaces::loops`]. The first is the outer loop and
   * the rest are holes, though the even-odd test does not care which is which.
   */
  uint32_t loop_start;
  uint32_t loop_count;
  /**
   * A swept surface's profile samples, as a slice of [`CadaclysmSurfaces::profiles`].
   * Empty for a quadric, which needs none.
   */
  uint32_t profile_start;
  uint32_t profile_count;
  /**
   * A sum surface's *second* curve, in the same buffer. A sum is one curve slid along
   * another and is the only kind with two, because a surface has two parameters and a
   * third curve would want a third. Empty for every other kind.
   */
  uint32_t profile2_start;
  uint32_t profile2_count;
  /**
   * A NURBS surface's packed net, as a slice of [`CadaclysmSurfaces::nurbs`]. Empty
   * for every other kind.
   */
  uint32_t nurbs_start;
  uint32_t nurbs_count;
} CadaclysmFace;

/**
 * Every face of one part as surfaces and trims — see [`CadaclysmFace`].
 *
 * Five borrowed arrays the faces share: a face names a slice of each rather than
 * carrying its own copy, which keeps a part with two hundred faces to one allocation
 * apiece.
 *
 * **In the file's own frame and units, not the convention the document was opened
 * with.** This is the one product that is: meshes and polylines arrive already
 * converted. [`cadaclysm_surface_matrix`] is what puts these in step with them, and a
 * caller that ignores it draws its surfaces in a different space from its meshes.
 *
 * Empty where the part has none this path can express. That is
 * all-or-nothing per part: one face it cannot express and the whole part falls back to
 * triangles, so a part is drawn one way or the other and never half.
 */
typedef struct CadaclysmSurfaces {
  const struct CadaclysmFace *faces;
  uint32_t face_count;
  /**
   * Two `u32` a loop: the start and length of its run in `points`.
   */
  const uint32_t *loops;
  uint32_t loop_count;
  /**
   * Two floats a point: `(u, v)` on the face, the polygon of the even-odd test. Each
   * loop closes implicitly, its last point joining its first.
   */
  const float *points;
  uint32_t point_count;
  /**
   * Four floats a sample: `(x, y, z, parameter)` along a swept surface's profile, for
   * a caller to interpolate at a given distance along. **Sampled, not exact** — the
   * one place this product is, and the same sampling this project's viewer uses.
   */
  const float *profiles;
  uint32_t profile_count;
  /**
   * A NURBS surface's net and knots, flat: `[degree_u, degree_v, n_u, n_v, knots_u...,
   * knots_v..., net as (x·w, y·w, z·w, w)...]`, the counts riding as floats because
   * they are small integers and exact. Premultiplied, so a de Boor lerps and divides.
   */
  const float *nurbs;
  uint32_t nurbs_count;
} CadaclysmSurfaces;

/**
 * The host window a dialog should belong to. `kind` is one of the
 * `CADACLYSM_WINDOW_*` constants, saying which of `handle`/`display`'s
 * platform types apply.
 *
 * Those constants are part of the ABI: hosts compile the numbers in, so they
 * must never be renumbered.
 *
 * Pass `NULL`, or `kind = CADACLYSM_WINDOW_NONE`, for no parent -- but expect
 * what that means: a dialog that can open behind the application, that is not
 * modal to it, and that on Wayland cannot be positioned at all.
 *
 * A `kind` this build does not recognise, or that names a windowing system
 * foreign to it (a Wayland handle reaching a Windows build, say), fails the
 * pick with an error rather than silently falling back to unparented: that
 * combination is a host integration bug, and hiding it behind a dialog that
 * merely looks a little wrong would make it harder to find, not easier.
 *
 * `display` is needed on X11 (optional) and Wayland (required) and ignored on
 * Windows and macOS. For `CADACLYSM_WINDOW_APPKIT`, `handle` is the **`NSView`**,
 * not the `NSWindow`.
 */
typedef struct CadaclysmWindow {
  uint32_t kind;
  void *handle;
  void *display;
} CadaclysmWindow;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Why the last call failed, or null if none has.
 *
 * Borrowed, and good until the next call on this thread.
 *
 * # Safety
 * The returned pointer must not be freed or kept past the next call.
 */
const char *cadaclysm_last_error(void);

/**
 * The library's version, as `"0.1.0"`. Static; never freed.
 */
const char *cadaclysm_version(void);

/**
 * Open a CAD file, or a `.zip` holding one.
 *
 * `path` names the model. `schema` names the EXPRESS schema (`.exp`) it
 * conforms to, which only STEP and IFC need — they name one and cannot be
 * read without it. An IGES file, a `.brep` and a `.3dm` all say what they mean
 * in themselves, so pass null for those.
 *
 * **A `.zip` opens its shallowest readable member**, or the one
 * `options->pick` names, with the rest of the archive standing in for the
 * file's own directory — an `include <lib/box.scad>` inside the archive
 * finds the archive's own `lib/box.scad`. [`cadaclysm_source_name`] says
 * which member was chosen.
 *
 * **An OpenSCAD program's `include <…>` and `use <…>` are resolved beside
 * it**: the reader is handed the file's own directory, so a library next to
 * the program is found the way OpenSCAD itself finds it (`OPENSCADPATH` is
 * searched after). A name nothing answers to is not fatal -- the rest of the
 * program still runs, as in the real tool -- but it is no longer silent
 * either: it appears at [`cadaclysm_diagnostic`] as `include not found: …`.
 * [`cadaclysm_open_memory`] has no directory to offer and resolves nothing,
 * reporting the same way.
 *
 * `options` says everything else — the coordinate space, the schemas, the
 * texture coordinates and colours. Pass null for every default, which keeps the
 * file's own axes and units and asks for nothing extra.
 *
 * Returns null on failure, with the reason at [`cadaclysm_last_error`].
 *
 * # Safety
 * `path` must be null or a valid null-terminated string, and `options` null or
 * a [`CadaclysmOpenOptions`] whose `size` it fills honestly. The returned handle
 * must be given back to [`cadaclysm_close`] exactly once.
 */
struct CadaclysmScene *cadaclysm_open(const char *path, const struct CadaclysmOpenOptions *options);

/**
 * Open a CAD file already in memory, or a `.zip` holding one.
 *
 * `format` names the kind as an extension would — `"step"`, `"ifc"`, `"igs"`,
 * `"brep"`, `"3dm"`, `"scad"`, `"sat"`, `"zip"` — since there is no file name
 * to take it from. A leading dot is allowed and ignored.
 *
 * Those are examples rather than the whole list, which depends on the readers
 * this build was compiled with: [`cadaclysm_format_extensions`] is what it
 * actually reads, and the error returned when `format` is missing names every
 * one of them. Prefer either to a list written out by hand — this doc comment
 * carried one for a while that had gone stale.
 *
 * **`"zip"` opens its shallowest readable member**, or the one
 * `options->pick` names, with the rest of the archive standing in for the
 * missing directory a plain buffer would have none of.
 * [`cadaclysm_source_name`] says which member was chosen.
 *
 * `options` is as [`cadaclysm_open`] takes it, null included.
 *
 * # Safety
 * `bytes` must point to at least `length` readable bytes, `format` must be null
 * or a valid null-terminated string, and `options` null or a
 * [`CadaclysmOpenOptions`] whose `size` it fills honestly. The returned handle
 * must be given back to [`cadaclysm_close`] exactly once.
 */
struct CadaclysmScene *cadaclysm_open_memory(const uint8_t *bytes,
                                             size_t length,
                                             const char *format,
                                             const struct CadaclysmOpenOptions *options);

/**
 * Fill `options` with its `size` and every default.
 *
 * The alternative is a caller zeroing the struct themselves and setting `size`
 * by hand, which works and is one more thing to get wrong.
 *
 * **This is the one call the size rule does not protect.** [`cadaclysm_open`]
 * and [`cadaclysm_open_memory`] read only the fields `size` says are there, so
 * a caller built against an older header is safe against a newer library. This
 * function has no such input to read: it writes `sizeof(CadaclysmOpenOptions)`
 * bytes as *this library* knows that type, and a caller compiled against an
 * older, shorter header has only that many bytes of stack local to receive
 * them into. Its header must be at least as new as the library it links --
 * never call it after linking a newer library without rebuilding against its
 * header first. `unreal/Cadaclysm/build-rust.ps1` is what keeps the vendored
 * Unreal copy of the header in step with this crate's, for exactly this reason.
 *
 * # Safety
 * `options` must point at writable storage of at least
 * `sizeof(CadaclysmOpenOptions)` bytes, `sizeof` taken from a header at least
 * as new as this library -- see above.
 */
void cadaclysm_open_options_init(struct CadaclysmOpenOptions *options);

/**
 * Give a scene back. Null is accepted and does nothing.
 *
 * Everything borrowed from it — names, meshes, attribute text — is invalid
 * afterwards.
 *
 * # Safety
 * The handle must have come from [`cadaclysm_open`] or
 * [`cadaclysm_open_memory`] and not been closed already, and no accessor may
 * still be running on another thread.
 */
void cadaclysm_close(struct CadaclysmScene *scene);

/**
 * The archive member a scene was read from, or null for a plain file.
 *
 * What a viewer titles its window with: `cadaclysm_open` on a zip chose one
 * member, and this is the only way to learn which. Borrowed from the scene,
 * valid until [`cadaclysm_close`].
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`] or
 * [`cadaclysm_open_memory`].
 */
const char *cadaclysm_source_name(const struct CadaclysmScene *scene);

/**
 * How many parts it has, geometry or not.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_node_count(const struct CadaclysmScene *scene);

/**
 * How many parts nothing else contains.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_root_count(const struct CadaclysmScene *scene);

/**
 * One of them, or [`CADACLYSM_NONE`] past the end.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_root(const struct CadaclysmScene *scene, uint32_t index);

/**
 * The schema the file named, or `""` for a format that names none.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; the result borrows
 * from it.
 */
const char *cadaclysm_schema(const struct CadaclysmScene *scene);

/**
 * What one length in the file is worth in metres, or 1 where it did not say.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 * The schema the file was actually read with, which is not always the one it named.
 *
 * A file declaring `IFC4X3_RC2` reads under `IFC4X3_ADD2` where that is what is
 * registered: a release candidate and the finished schema of the same version are the
 * same schema, and refusing the file over the suffix would lose a readable model. A
 * file whose declared schema nobody registered reads under whichever registered one
 * defines the entity types it actually contains, and only when it defines nearly all
 * of them.
 *
 * [`cadaclysm_schema`] keeps saying what the file said. The two differ exactly when a
 * substitution happened, so comparing them is how a caller finds out — and a caller
 * that wants to refuse substituted files has what it needs to.
 *
 * Null where the reader recorded none, which is every format that names no schema.
 * The pointer lives as long as the scene.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
const char *cadaclysm_schema_read(const struct CadaclysmScene *scene);

double cadaclysm_metres_per_unit(const struct CadaclysmScene *scene);

/**
 * Everything the model covers, **in world coordinates**.
 *
 * The one figure here that is not in a part's own frame, because a bounding box
 * over the whole model has no other frame to be in. It is the union of exactly
 * what iterating the parts would draw: every part [`cadaclysm_node_can_mesh`]
 * answers true for, its extent carried through its own transform — the eight
 * corners, since a rotated box's corners are what reach furthest.
 *
 * **This meshes all of it**, being the only way to know how far it reaches.
 * A caller that has not the time should frame from the parts it has built.
 *
 * It meshes them the same way [`cadaclysm_realize_all`] does — across every
 * core — rather than one after another as reading the loop below would. The
 * loop is what asks for each node's bounds, and asking is what meshes it, so
 * left to itself it is a single-threaded realize wearing a different name: on
 * a 7,900-body assembly that was 50 seconds against the 5 the same work takes
 * threaded. Realizing up front costs nothing where a caller has already done
 * it, every node's mesh being cached behind a `OnceLock`.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmBounds cadaclysm_bounds(const struct CadaclysmScene *scene);

/**
 * The part containing this one, or [`CADACLYSM_NONE`] for a root.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_node_parent(const struct CadaclysmScene *scene, uint32_t node);

/**
 * How many parts this one contains directly.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_node_child_count(const struct CadaclysmScene *scene, uint32_t node);

/**
 * One of them, or [`CADACLYSM_NONE`] past the end.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_node_child(const struct CadaclysmScene *scene, uint32_t node, uint32_t index);

/**
 * How far down the tree it sits, a root being zero. For indenting.
 *
 * Walked from the parent chain rather than stored — `CadDocument` keeps the
 * links and not the depth, and the answer is the same. The step count is
 * bounded by the node count, so a malformed cycle cannot spin here.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_node_depth(const struct CadaclysmScene *scene, uint32_t node);

/**
 * Its name, or null past the end.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; the result borrows
 * from it.
 */
const char *cadaclysm_node_name(const struct CadaclysmScene *scene, uint32_t node);

/**
 * What the file calls it — an IFC type, an openNURBS class, a shape kind. Null
 * past the end.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; the result borrows
 * from it.
 */
const char *cadaclysm_node_kind(const struct CadaclysmScene *scene, uint32_t node);

/**
 * What the file calls it — a STEP `#N`, an IFC GlobalId, a Rhino UUID — or its
 * position for a format with no such notion. Null past the end.
 *
 * A string rather than a number, because that is what the formats carry: a
 * `.3dm` object is named by a UUID and an IFC product by a 22-character
 * GlobalId, neither of which fits in a `uint64_t`. A caller matching ids
 * compares the text.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; the result borrows
 * from it.
 */
const char *cadaclysm_node_id(const struct CadaclysmScene *scene, uint32_t node);

/**
 * Its colour into `rgba`, returning whether the file gave one.
 *
 * Where it did not, `rgba` is left alone and the caller should use its own —
 * which is the honest answer, most STEP files carrying no colour at all.
 *
 * Its own colour where it has one, and the colour of the shape it draws
 * otherwise. Both halves matter: an occurrence that overrides its shape's
 * colour — the same window type in white on one storey and grey on the next —
 * must keep the override, while one that says nothing about colour should be
 * drawn in the colour of the geometry it actually puts on screen rather than
 * falling back to the caller's default beside identical parts that are
 * coloured. This is the same [`CadaclysmScene::shape_of`] hop
 * [`cadaclysm_node_mesh`] follows.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`], and `rgba` must be
 * null or point to four writable floats.
 */
bool cadaclysm_node_color(const struct CadaclysmScene *scene, uint32_t node, float *rgba);

/**
 * Where this part's geometry sits, as a 4x4 column-major matrix.
 *
 * A mesh is in its part's own frame; this carries it to world. Doubles, while
 * the mesh is floats, on purpose: a building at UTM coordinates baked into f32
 * world positions loses millimetres, where an f32 mesh about its own origin
 * under an f64 transform does not. It is also what lets one mesh be drawn at
 * many placements instead of being copied per placement.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; `out` must have
 * room for sixteen doubles. Writes the identity for a bad index.
 */
void cadaclysm_node_transform(const struct CadaclysmScene *scene, uint32_t node, double *out);

/**
 * How many drawings this document asks for.
 *
 * **Not the part count, and the difference is the point.** Most parts are structure and
 * draw nothing; a part that places a block draws everything inside that block; and a
 * block's members draw once per placement of it rather than once on their own account.
 * A caller that walks parts and asks each for a mesh draws a Rhino block's contents once,
 * at the definition's frame, and every placement of it not at all -- which is what
 * `instances.3dm` looked like: one tube where the file has six.
 *
 * So a renderer walks these, and asks [`cadaclysm_placement_geometry`] which part's mesh
 * each one draws and [`cadaclysm_placement_transform`] where to put it. Parts remain what
 * a *tree* is built from -- names, properties, hierarchy, selection.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_placement_count(const struct CadaclysmScene *scene);

/**
 * Which part's geometry this drawing draws.
 *
 * Ask that part for its mesh, edges or curves as usual. Two drawings of one shape name
 * the same part and so hand back the same pointers, which is what lets a caller upload it
 * once and draw it at both transforms.
 *
 * `CADACLYSM_NONE` for an index past [`cadaclysm_placement_count`].
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_placement_geometry(const struct CadaclysmScene *scene, uint32_t placement);

/**
 * What a click on this drawing should select.
 *
 * The placement rather than the shape it draws: the shape is somewhere else and is shared
 * with every sibling copy, so selecting it would light them all up.
 *
 * `CADACLYSM_NONE` for an index past [`cadaclysm_placement_count`].
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_placement_select(const struct CadaclysmScene *scene, uint32_t placement);

/**
 * Where this drawing sits, as a 4x4 column-major matrix.
 *
 * Already composed through every frame between the document's root and the drawing, so a
 * caller multiplies nothing itself. Doubles for the reason
 * [`cadaclysm_node_transform`] gives.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; `out` must have room for
 * sixteen doubles. Writes the identity for a bad index.
 */
void cadaclysm_placement_transform(const struct CadaclysmScene *scene,
                                   uint32_t placement,
                                   double *out);

/**
 * How many things the file said about this part.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_node_attribute_count(const struct CadaclysmScene *scene, uint32_t node);

/**
 * One of them, or an all-zero one past the end.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; the strings in the
 * result borrow from it.
 */
struct CadaclysmAttribute cadaclysm_node_attribute(const struct CadaclysmScene *scene,
                                                   uint32_t node,
                                                   uint32_t index);

/**
 * The nodes matching `filter`, as indices into the scene's node list.
 *
 * The filter is a boolean expression over one node — `class == ON_Brep and
 * within(class == ON_Layer and name == Walls)`. Nine reserved words name the
 * node itself (`class`, `name`, `id`, `visible`, `geometry`, `index`, `depth`,
 * `children`, `instanced`); any other bare word is a property. Compare with
 * `== != < <= > >=`, `in (a, b, c)` or a case-insensitive regex with `~=`;
 * combine with `and`, `or`, `not` and parentheses; test the tree with
 * `within(e)`, `child_of(e)`, `has(e)`, `has_child(e)`, `instance_of(e)` and
 * `instanced_by(e)`, each taking a full expression of its own. Text comparison
 * folds case throughout. The full grammar and worked examples live in the
 * `query` module of the `cadaclysm-utils` Rust crate this links against.
 *
 * Returns the **total** number of matches and writes up to `capacity` of them
 * into `out`. Call once with `capacity = 0` and a null `out` to learn the size,
 * then again to fill a buffer. A filter that will not parse returns `0` with the
 * reason at [`cadaclysm_last_error`].
 *
 * **A `0` is ambiguous unless you check the error, errno-style.** Zero matches is
 * the common, legitimate outcome of a search — a typo'd filter must not look the
 * same as a filter that correctly found nothing, which is the one failure mode
 * this function exists to avoid. So this call — and only this one, not every
 * entry point in this library — clears [`cadaclysm_last_error`] to null before it
 * does anything else. With a valid `scene`, a `0` return paired with a null error
 * is a real empty result, and a `0` paired with a non-null error is a parse
 * failure. A null `scene` is the one case that does not fit this: like every
 * other accessor here, it is silently neutral rather than an error, so it too
 * returns `0` with a null error — that reflects a null handle, not a filter that
 * matched nothing, and is the caller's own bug to find rather than this
 * function's to report.
 *
 * The filter is compiled on every call. Parsing a short string is nothing beside
 * walking the tree, and a cache would need a lock, which the rule that every
 * accessor takes a `const` handle does not allow.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; `filter` must be a
 * NUL-terminated UTF-8 string; `out` must be null or point to `capacity`
 * writable `u32`s.
 */
uint32_t cadaclysm_query(const struct CadaclysmScene *scene,
                         const char *filter,
                         uint32_t *out,
                         uint32_t capacity);

/**
 * Whether this part is drawn — whether it has geometry of its own to show.
 *
 * Asks for nothing to be built, and says nothing about whether it has been.
 * Most parts of a model are structure — an assembly, a storey, a layer — and
 * answer false.
 *
 * Geometry, not triangles: a part drawn as a *curve* — a `.3dm` curve object, a
 * STEP geometrically-bounded curve — answers true and gives an empty
 * [`cadaclysm_node_mesh`], having no surface to triangulate. A caller drawing
 * solids alone can pass over an empty mesh; one that wants the wireframe reads
 * `cadaclysm_node_curves`.
 *
 * True for a part that carries geometry of its own **and** for one that
 * instances a part that does: a shared shape is drawn at each of its
 * occurrences, and each occurrence is a part here. False for the shared shape
 * itself, which is drawn wherever its occurrences put it rather than at its own
 * frame. A caller that would rather upload each shape once and draw it at many
 * transforms asks `cadaclysm_node_instance_of` which parts share one.
 *
 * **A Rhino block instance is not currently drawn at its placements.** A
 * `.3dm` instance reference points at an `ON_InstanceDefinition`, which holds
 * its geometry in member nodes rather than carrying any of its own, and the
 * resolution here is a single hop — so it lands on the definition, finds no
 * geometry, and answers false. The block's members are still parts and are
 * still drawn, but once each and at the definition's own frame rather than at
 * every place the block was put. In `cube.3dm` that is seven placements drawn
 * nowhere. Every other instancing this ABI meets — an IFC occurrence of a
 * shared representation, a STEP component — resolves in that one hop and is
 * drawn at each placement.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
bool cadaclysm_node_can_mesh(const struct CadaclysmScene *scene, uint32_t node);

/**
 * Whether the file says this node should be shown when it is opened.
 *
 * **The file's opening state, not a live switch.** A caller that wants to open
 * a document the way its author left it hides what this reports false for; from
 * then on, what is shown is the caller's business. Nothing here changes, and
 * nothing else in this ABI consults it -- a hidden node still meshes, still has
 * bounds, and is still drawn by anything that ignores this.
 *
 * True where the format says nothing, which is most of them. Today only IGES
 * (an entity's blank status) and Rhino `.3dm` (an object or a layer switched
 * off) report otherwise; STEP's `invisibility` and IFC's
 * `IfcPresentationLayerWithStyle.LayerOn` are not read yet, so their documents
 * answer true throughout.
 *
 * **Not inherited.** A layer and its members each carry their own state, so a
 * caller hiding a subtree hides its root the way a scene graph already does.
 * Turning a layer back on then restores exactly the members the file had left
 * visible, which a flag folded together could not.
 *
 * True for a node index that does not exist, since a caller iterating past the
 * end should not be told the document is hiding things from it.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
bool cadaclysm_node_visible(const struct CadaclysmScene *scene, uint32_t node);

/**
 * Its triangles, **in their own frame** and **built now if they have not been**.
 *
 * [`cadaclysm_node_transform`] says where that frame sits in the world, and it
 * is always *this* part's transform — the one that places the triangles below.
 *
 * Where the part instances another, these are the instanced part's triangles,
 * in the instanced part's frame. Two occurrences of one shape therefore hand
 * back the **same pointers** and two different transforms, which is what lets a
 * caller upload the mesh once. Asking the shared shape itself for its mesh
 * gives the same answer again.
 *
 * The pointers borrow from the scene and are good until it is closed; asking
 * twice costs nothing the second time.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]. The pointers in
 * the result must not be freed, nor read past the counts beside them, nor used
 * after [`cadaclysm_close`].
 */
struct CadaclysmMesh cadaclysm_node_mesh(const struct CadaclysmScene *scene, uint32_t node);

/**
 * About how many triangles [`cadaclysm_node_mesh`] would give for this part,
 * **without building it** -- for a caller sizing a budget before it meshes:
 * what to skip, what to take at a coarser level, how much memory a scene
 * will want. Follows the same [`CadaclysmScene::shape_of`] hop the mesh
 * does, so an instance answers for what it draws.
 *
 * **An estimate, from the reader's own knowledge of the part.** A b-rep
 * (STEP, ACIS, OpenCASCADE `.brep`, an IGES trimmed surface, a Rhino brep
 * without a render mesh) is counted the way its mesher will count it -- the
 * same trims, the same grid stations -- and lands within a few tens of
 * percent of the mesh; an untrimmed IGES patch is its grid, exact; a stored
 * or already-evaluated mesh (a `.brep` file's triangulation, a Rhino mesh or
 * render mesh, an OpenSCAD model, a mesh built by an earlier call) is exact;
 * an IFC product is exact for its extrusions and within a weld for its
 * faceted parts. `-1` where the reader cannot say without doing the work --
 * a Rhino extrusion or SubD -- and for a node that draws nothing. A caller
 * summing a document treats `-1` as unknown, not as zero.
 *
 * Cheap next to meshing but not free: a STEP body is built as a b-rep to be
 * counted, a tenth or so of meshing it.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
int64_t cadaclysm_node_triangle_estimate(const struct CadaclysmScene *scene, uint32_t node);

/**
 * A coarse mesh over this part's surfaces, for the things that need triangles and not a
 * picture. All five pointers borrow from the scene.
 *
 * **What it is for.** A part drawn from its surfaces -- see [`cadaclysm_realize_meshes`]
 * -- has no triangles, and under ray tracing it is simply absent: it casts no traced
 * shadow, does not occlude or bounce Lumen's light, and has no distance field. Everything
 * that traces wants triangles, and nothing that traces wants *good* ones. This grids each
 * face `cells` by `cells` over its trim window, keeps a cell whose centre lies inside the
 * trims, and lays two triangles across it -- no welding, no chord error, a hole smaller
 * than a cell vanishes. Never drawn; a consumer feeds it to its acceleration structure and
 * its distance field and leaves the picture to [`cadaclysm_node_surfaces`].
 *
 * In the space everything else is in, like [`cadaclysm_node_mesh`] -- a mesh converts like
 * any other, where the surfaces it came from do not.
 *
 * **Built once per part, at the first `cells` asked for.** A later call with another
 * `cells` hands back what was built; a consumer that wants two densities wants two scenes.
 * Empty for a part with no surfaces, or for `cells` of zero.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmMesh cadaclysm_node_surface_proxy_mesh(const struct CadaclysmScene *scene,
                                                       uint32_t node,
                                                       uint32_t cells);

/**
 * The extent of the geometry this part draws, **in that geometry's own
 * frame**, building it if it has not been built. Carry it through
 * [`cadaclysm_node_transform`] for world coordinates, exactly as with the mesh
 * it bounds — and through the same indirection, so a part that instances
 * another is bounded by what it actually draws.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmBounds cadaclysm_node_bounds(const struct CadaclysmScene *scene, uint32_t node);

/**
 * The extent of what this part draws **under a placement**, for a part drawn from
 * its surfaces: every sample the bounds are taken from is carried through the
 * document's convention and then `placement` -- sixteen doubles, column-major, as
 * [`cadaclysm_placement_transform`] writes them -- before it is boxed. The box of the
 * placed surfaces, in the placement's target frame: the same space the placed mesh
 * would be in, the convention included, since the surfaces alone are handed over
 * unconverted (see [`cadaclysm_surface_matrix`]) and a placement acts on converted
 * points.
 *
 * **Not the placed box of the surfaces.** A caller with only [`cadaclysm_node_bounds`]
 * carries its eight corners through the placement, and the box of a rotated box is
 * bigger than the box of the rotated points: by 8% on an assembly of rotated parts,
 * with the centre off by 4% of the diagonal, against the box the mesh path finds
 * from its placed vertices. This closes that gap for the surface path.
 *
 * Builds the surfaces if they are not built, which a part drawn from them already
 * has. All zeros for a part with no surfaces -- a caller then places the corners of
 * [`cadaclysm_node_bounds`] as before.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; `placement` must be null
 * (the identity) or point at sixteen doubles.
 */
struct CadaclysmBounds cadaclysm_node_bounds_placed(const struct CadaclysmScene *scene,
                                                    uint32_t node,
                                                    const double *placement);

/**
 * The collision body for what this node draws, **building its mesh if it has not
 * been built** -- the same cost [`cadaclysm_node_bounds`] already carries.
 *
 * `hull_budget` is the most triangles a hull may have; zero asks for
 * `CADACLYSM_UNITY_HULL_LIMIT`. It is **not** clamped to it: how closely a hull
 * should follow its part is a trade against simulation cost and belongs to
 * whoever is building the game -- Unreal's `FKConvexElem` has no cap at all. A
 * hull above the limit cannot be used as a Unity convex `MeshCollider`, which
 * hard-fails there.
 *
 * Set `out->size` to `sizeof(CadaclysmCollision)` before calling. Returns false,
 * writing nothing, for a null scene, an unknown node, one that draws nothing, or
 * an `out` too small to hold the fields this build writes.
 *
 * The body is cached per node and per budget, so asking twice costs one fit.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; `out` must be null or
 * point to at least `out->size` writable bytes.
 */
bool cadaclysm_node_collision(const struct CadaclysmScene *scene,
                              uint32_t node,
                              uint32_t hull_budget,
                              struct CadaclysmCollision *out);

/**
 * The convex hull for what this node draws, or all nulls where its shape is not
 * a hull. Builds the node's mesh if it has not been built.
 *
 * The pointers borrow from the scene and are good until it is closed **or until
 * this node is asked for a different `hull_budget`**, which refits it and frees
 * what the previous call returned. A caller that holds hulls should hold one
 * budget.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]. The pointers must not
 * be freed, nor read past the counts beside them, nor used after
 * [`cadaclysm_close`].
 */
struct CadaclysmCollisionHull cadaclysm_node_collision_hull(const struct CadaclysmScene *scene,
                                                            uint32_t node,
                                                            uint32_t hull_budget);

/**
 * The part whose geometry this one is a placement of, or `CADACLYSM_NONE`.
 *
 * The point of handing meshes over in their own frame: a shell placed seventy-
 * four times is one mesh and seventy-four transforms, and this is how a caller
 * knows to upload the buffer once.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_node_instance_of(const struct CadaclysmScene *scene, uint32_t node);

/**
 * What a click on this part's geometry should select — itself, usually.
 *
 * A format that hangs geometry on a child of the object it belongs to (IFC: a
 * representation item under its product) points the child back at the object,
 * so picking the shape selects the thing while the shape stays a part of its
 * own to inspect.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_node_select_as(const struct CadaclysmScene *scene, uint32_t node);

/**
 * What this part's geometry was before it was triangles — `"brep"`, `"mesh"`,
 * `"csg"`. A `.3dm` holds several kinds side by side and a native mesh calling
 * itself a brep is a plain lie, so this is per part rather than per file.
 *
 * Follows the same [`CadaclysmScene::shape_of`] hop [`cadaclysm_node_mesh`]
 * does, and describes the geometry actually handed back: an occurrence carries
 * none of its own, so asking it directly gets the document-wide default rather
 * than the truth. On `LargeBuilding.ifc` that was wrong for 58 of the 85
 * occurrences — one said `"brep"` over an `"extrusion"`.
 *
 * Null for a part that draws nothing, since there is then no geometry to have
 * come from anything, exactly as [`cadaclysm_node_mesh`] is empty there.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; the string borrows
 * from it.
 */
const char *cadaclysm_node_generator(const struct CadaclysmScene *scene, uint32_t node);

/**
 * The same, as a function, for a caller that binds to symbols rather than to a
 * header.
 */
uint32_t cadaclysm_lod_levels(void);

/**
 * A part's triangles at a coarser level of detail.
 *
 * `level` 0 is the mesh itself and gives exactly what [`cadaclysm_node_mesh`]
 * does; 1 up to [`CADACLYSM_LOD_LEVELS`] are progressively coarser, each about
 * a quarter of the triangles of the one before. Past that is an empty mesh.
 *
 * **Every level shares the level-0 vertices.** `positions`, `normals` and
 * `uvs` are the same pointers and the same `vertex_count` at every level --
 * only `indices` and `index_count` differ. A caller uploads the vertices once
 * and switches level by drawing a different range, which is what the levels
 * are built the way they are to allow: see `cadaclysm-lod`, which collapses
 * each edge onto an endpoint it already had rather than to a new point.
 *
 * `vertex_count` is therefore *not* how many vertices this level uses. It is
 * how many the buffer holds. A coarse level uses a subset and names them by
 * their original index.
 *
 * Simplifying a body costs about what meshing it did, and happens on the first
 * ask for that part. A caller wanting the whole document coarsened should ask
 * across threads, as it would mesh it.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmMesh cadaclysm_node_mesh_lod(const struct CadaclysmScene *scene,
                                             uint32_t node,
                                             uint32_t level);

/**
 * How far a level moved the surface, in the scene's own units — 0 at level 0,
 * and 0 for a level that does not exist.
 *
 * **This is what a renderer should choose levels by**, rather than by how large
 * a part is on screen. Size says nothing about whether coarsening would show: a
 * smooth cylinder loses three quarters of its triangles without moving its
 * surface a thousandth of its radius, and a part covered in small features
 * cannot lose one without it being visible. Projected through the view, this
 * number is how many pixels wrong the level would look — which is the question
 * actually being asked.
 *
 * Measured on a radius-10 sphere: 0.027 at the first level, 0.203 at the
 * second, 1.606 at the third.
 *
 * Building the levels is what measures this, so the first call for a part pays
 * for them exactly as [`cadaclysm_node_mesh_lod`] does.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
float cadaclysm_node_lod_error(const struct CadaclysmScene *scene, uint32_t node, uint32_t level);

/**
 * How many things this file held that the reader could not build.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_diagnostic_count(const struct CadaclysmScene *scene);

/**
 * One of them, or null past the end. Borrows from the scene.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
const char *cadaclysm_diagnostic(const struct CadaclysmScene *scene, uint32_t index);

/**
 * How many things **meshing** has complained about so far.
 *
 * [`cadaclysm_diagnostic`] answers for the *parse*: a fixed list, settled the
 * moment the file was read, of what the reader could not build. This answers
 * for the tessellation, which is a different question asked of a different
 * stage — a face whose boundary encloses no region is perfectly well parsed
 * and simply cannot be meshed.
 *
 * **It reports on what has been meshed, and meshing is lazy**, so this is
 * empty until something has asked for geometry and grows as more is asked
 * for. Call it after [`cadaclysm_realize_all`], or after meshing whatever
 * parts matter; calling it straight after [`cadaclysm_open`] is asking what
 * meshing found before any has happened, and the honest answer to that is
 * none.
 *
 * Each call takes a fresh reading. **That invalidates every pointer the last
 * one handed out** through [`cadaclysm_geometry_diagnostic`] — the only place
 * in this ABI where a borrow ends before the scene does, and it is why the
 * count is what refreshes rather than some separate call a caller could
 * forget stands between them. Read the count, then read the strings, then
 * stop using them before asking again.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_geometry_diagnostic_count(const struct CadaclysmScene *scene);

/**
 * One of them, or null past the end.
 *
 * Borrows from the scene, and only until the next
 * [`cadaclysm_geometry_diagnostic_count`] — see there.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
const char *cadaclysm_geometry_diagnostic(const struct CadaclysmScene *scene, uint32_t index);

/**
 * This part's feature edges, as polylines to draw an overlay from.
 *
 * Flattened by the document at the part's own scale — capi does not choose a
 * tolerance, here or anywhere. Built on first ask and kept; both pointers
 * borrow from the scene.
 *
 * Where the part instances another, these are the instanced part's edges, the
 * same indirection [`cadaclysm_node_mesh`] follows — an occurrence carries no
 * geometry of its own, so its edges are the shape's it instances.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmPolylines cadaclysm_node_edges(const struct CadaclysmScene *scene, uint32_t node);

/**
 * This part's face boundaries, taken from its trimmed surfaces. Both pointers borrow from
 * the scene.
 *
 * **The outline that costs no tessellation, and the reason it exists.** Both other edge
 * products mesh the part: [`cadaclysm_node_edges`] hands back the chords the mesher walked,
 * and [`cadaclysm_node_edge_beziers`] resolves the mesh too, because a B-rep reader gives
 * one builder that produces triangles and edges together. So a caller that carefully
 * skipped meshing a body -- see [`cadaclysm_realize_meshes`] -- gets every triangle back
 * the moment it draws an outline, and the memory with them.
 *
 * These are the same trim loops [`cadaclysm_node_surfaces`] hands to a shader, evaluated
 * through their surfaces, so the outline sits on the surface actually being drawn. Against
 * triangles it is the wrong product and [`cadaclysm_node_edges`] is the right one: the
 * surface is not where the triangles are, and an outline drawn on it z-fights them. That
 * is the choice, and it belongs to whoever knows which of the two is on screen.
 *
 * In the surfaces' own frame, like [`cadaclysm_node_surfaces`] -- see
 * [`cadaclysm_surface_matrix`].
 *
 * Empty for a part with no surfaces. A shared edge appears twice, once from each face that
 * meets there: a face's boundary is what a trim loop is, and matching curves between faces
 * is the topology this product exists to do without.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmPolylines cadaclysm_node_surface_edges(const struct CadaclysmScene *scene,
                                                       uint32_t node);

/**
 * This part's isocurves, taken from its trimmed surfaces and clipped to the trims. Both
 * pointers borrow from the scene.
 *
 * **The companion to [`cadaclysm_node_surface_edges`], and the other half of drawing a
 * part's wireframe without meshing it.** [`cadaclysm_node_isocurves`] slices the mesh along
 * its axes, so drawing those tessellates the body -- which on `ufi.stp` was the single
 * remaining hold on the mesher once the outline came from the trims.
 *
 * These are the surface's own isoparametric curves: lines at its bend lines where it has
 * them -- a NURBS's interior knots, a swept profile's breakpoints -- and an even spread
 * where it has none, so a cylinder is not left blank. A **flat face gets none**: an
 * isocurve across a plane says nothing its boundary has not.
 *
 * Each line is broken wherever it leaves the trims, so a line crossing a hole comes back
 * as two runs rather than one line straight over it.
 *
 * In the surfaces' own frame, like [`cadaclysm_node_surfaces`] -- see
 * [`cadaclysm_surface_matrix`]. Empty for a part with no surfaces.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmPolylines cadaclysm_node_surface_isocurves(const struct CadaclysmScene *scene,
                                                           uint32_t node);

/**
 * This part's feature edges as Bézier segments — the exact curves the polylines
 * from [`cadaclysm_node_edges`] were flattened from.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmBeziers cadaclysm_node_edge_beziers(const struct CadaclysmScene *scene,
                                                    uint32_t node);

/**
 * This part's faces as surfaces and trims — see [`CadaclysmSurfaces`].
 *
 * **The parametric product, and the trimmed one.** A face carries the surface it sits
 * on and the loops that cut it, both in that surface's own `(u, v)`, so a caller
 * evaluates the surface at whatever density its view needs and tests the point it
 * already has against the loops. Nothing here was flattened to triangles.
 *
 * In the file's own frame — see [`cadaclysm_surface_matrix`].
 *
 * Empty for a part with no surfaces, which is every mesh-only format, and for a part
 * holding one face this path cannot express, which sends the whole part down the
 * mesh path instead. Where the part instances another these are the instanced part's
 * faces, the same indirection [`cadaclysm_node_mesh`] follows.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmSurfaces cadaclysm_node_surfaces(const struct CadaclysmScene *scene, uint32_t node);

/**
 * Where a segment first meets one part's surfaces, written to `out_point` as three
 * doubles. False, writing nothing, where it meets none — or for a null scene, an unknown
 * node, or a part with no surfaces.
 *
 * **Why a caller wants this at all.** A part drawn from its surfaces has no triangles to
 * trace against, because [`cadaclysm_realize_meshes`] never built them. And a part that
 * does have them is traced only as accurately as it was meshed, so the rim of a hole picks
 * to the mesher's chord error. This answers from the surface itself and tests the trims at
 * the answer's own `(u, v)`, which is exact.
 *
 * **In the surfaces' own frame**, like [`cadaclysm_node_surfaces`] and for the same reason
 * — see [`cadaclysm_surface_matrix`]. A caller holding a ray in the space everything else
 * is in carries it through that matrix's inverse first. That is deliberately its job
 * rather than this function's: a renderer drawing these already built the matrix to draw
 * them with, and a pick that agrees with the picture must use the very same one rather
 * than a second copy composed here.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]. `from` and `to` must each
 * point to three readable doubles, and `out_point` to three writable ones.
 */
bool cadaclysm_node_surface_pick(const struct CadaclysmScene *scene,
                                 uint32_t node,
                                 const double *from,
                                 const double *to,
                                 double *out_point);

/**
 * The matrix that takes [`cadaclysm_node_surfaces`] into the space everything else is
 * already in, written to `out` as sixteen floats, column-major.
 *
 * **Only the surfaces need it.** Meshes, polylines and Bézier curves arrive in the
 * convention the document was opened with; the surfaces do not, because converting a
 * surface means converting its parameter space too — a cylinder's `v` is a length and
 * scales, a sphere's is an angle and does not — and getting that wrong moves the trim
 * loops off the face they trim. Handing over the matrix leaves the one product that is
 * unconverted plainly unconverted, rather than converted in a way that is wrong for two
 * of the eight kinds.
 *
 * Compose it on the left of a node's placement. For a document opened `NATIVE` at the
 * file's own units this is the identity, and a caller may skip it.
 *
 * Writes nothing where `scene` or `out` is null.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; `out` must be null or point
 * to space for sixteen floats.
 */
void cadaclysm_surface_matrix(const struct CadaclysmScene *scene, float *out);

/**
 * This part's free curves as Bézier segments — see
 * [`cadaclysm_node_edge_beziers`].
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmBeziers cadaclysm_node_curve_beziers(const struct CadaclysmScene *scene,
                                                     uint32_t node);

/**
 * This part's isocurves as Bézier segments — see
 * [`cadaclysm_node_edge_beziers`], and [`cadaclysm_node_isocurves`] for what an
 * isocurve is.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmBeziers cadaclysm_node_isocurve_beziers(const struct CadaclysmScene *scene,
                                                        uint32_t node);

/**
 * This part's free curves, as polylines — see [`cadaclysm_node_edges`], which
 * this differs from only in which document method it asks.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmPolylines cadaclysm_node_curves(const struct CadaclysmScene *scene, uint32_t node);

/**
 * This part's isocurves, as polylines — see [`cadaclysm_node_edges`], which
 * this differs from only in which document method it asks.
 *
 * An isocurve is one of the interior isoparametric lines across a curved
 * face — a cylinder's mid-height ring, a sphere's meridian — not its
 * boundary. A flat face has none of its own, but where the source format
 * gives no isocurves directly, the document falls back to slicing them from
 * the mesh, and that fallback draws a flat face's own outline rather than
 * nothing — so an empty result here is not guaranteed just because a face
 * is planar.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
struct CadaclysmPolylines cadaclysm_node_isocurves(const struct CadaclysmScene *scene,
                                                   uint32_t node);

/**
 * Drop every mesh built so far, keeping the document and its node tree.
 *
 * **For a caller that is done with the geometry but not with the file.** Names,
 * properties, the shape of the assembly and [`cadaclysm_query`] all keep working
 * afterwards; what goes is the built geometry this library was holding beside the
 * copy the caller has already taken. A viewer that has uploaded its meshes to the
 * GPU, or an engine plugin that has copied them into its own buffers, is otherwise
 * paying for two of everything for as long as it keeps the scene open to ask
 * questions of it.
 *
 * **Nothing breaks.** A node asked for again simply meshes again -- the cache is an
 * optimisation, and this trades time later for memory now. Bounds are kept, being a
 * box per node against a mesh of millions of triangles, and re-deriving one would
 * mean building that mesh again just to cull it.
 *
 * **It frees the cache, which on some formats is not all of it.** A reader whose
 * builder captured a finished mesh still holds that mesh; one whose builder keeps a
 * handle to the source and meshes on demand does not. The large assemblies where
 * this matters -- STEP, IFC, 3dm -- are the second kind.
 *
 * Takes the handle **mutably**, unlike every accessor here, because it is not one:
 * it changes what the scene holds. That is also why it cannot be called while
 * another thread is reading the same scene, which the `const` accessors otherwise
 * allow.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`], and no other thread may
 * be using it for the duration of this call.
 */
void cadaclysm_forget_meshes(struct CadaclysmScene *scene);

/**
 * Build every mesh in the document now, rather than as each is asked for.
 *
 * Reading is lazy so a caller can put the tree on screen while the shapes are
 * still to come. A caller that would rather pay it all up front — one honest
 * progress bar, or an exporter that needs the lot anyway — calls this. Returns
 * how many parts were realized.
 *
 * Threaded inside. Call it on one thread and watch it with
 * [`cadaclysm_realized`] from another, or stop it with [`cadaclysm_cancel`].
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_realize_all(const struct CadaclysmScene *scene);

/**
 * As [`cadaclysm_realize_all`], leaving alone every node that carries surfaces where
 * `skip_surfaced` is non-zero.
 *
 * **What makes surfaces cheaper rather than dearer.** A body's mesh is built on demand and
 * cached, so a caller who never asks for it never pays -- but `cadaclysm_realize_all` asks
 * for every node, which is right when triangles are what will be drawn and exactly wrong
 * when they are not. A renderer drawing a part from its surfaces passes a one here, takes
 * that part's bounds from `cadaclysm_node_bounds` (which falls back to the surfaces), and
 * never asks for its mesh at all.
 *
 * Nodes without surfaces are realized as usual: a part the reader could not express is
 * drawn from triangles and still needs them.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_realize_meshes(const struct CadaclysmScene *scene, uint32_t skip_surfaced);

/**
 * Whether this part's mesh has been built and is held, by [`cadaclysm_realize_all`],
 * by an ask for it, or by anything else that needed it -- the edge overlay, say. A
 * consumer drawing the part from its surfaces, and meaning never to pay for its
 * triangles, checks it did not. False for a null scene or an unknown part; through the
 * same indirection as the mesh, so a part that instances another answers for what it
 * draws.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
bool cadaclysm_node_is_meshed(const struct CadaclysmScene *scene, uint32_t node);

/**
 * How many parts [`cadaclysm_realize_all`] has finished with. Safe to read
 * from another thread while it runs.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_realized(const struct CadaclysmScene *scene);

/**
 * How many there will be in all — zero until [`cadaclysm_realize_all`] starts.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
uint32_t cadaclysm_realize_total(const struct CadaclysmScene *scene);

/**
 * Ask a running [`cadaclysm_realize_all`] to stop.
 *
 * It stops between parts, so this is prompt without abandoning half a mesh.
 * What was already built is kept, and the scene still answers one part at a
 * time afterwards — cancelling gives up on the batch, not on the document.
 *
 * **One-way, and for the life of the scene.** Nothing clears the flag, so
 * every later [`cadaclysm_realize_all`] on this scene returns 0 at once. A UI
 * that offers "Cancel" and then "Load anyway" cannot do the second on the same
 * handle: it must close the scene and open the file again. (Clearing the flag
 * when `realize_all` starts is not the fix — it would race a cancel arriving
 * from another thread just as the batch begins, and swallow it.) Meshes stay
 * available one part at a time either way, so a caller that only wants the
 * model on screen need not reopen.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`].
 */
void cadaclysm_cancel(const struct CadaclysmScene *scene);

/**
 * Write the whole scene -- every placement of every shape, named and placed
 * as the document's tree is, with a material per colour -- to `path` as glTF
 * or OBJ. False on failure, with [`cadaclysm_last_error`] saying why.
 *
 * `format` is `"glb"` (binary, one file), `"gltf"` (JSON with the vertex
 * buffer embedded, also one file) or `"obj"` (Wavefront text, every placement
 * baked to its own named object, with a `.mtl` written beside it under the
 * same stem when anything has a colour). These hold a scene where the
 * [`cadaclysm_mesh_format`] rows write one node's mesh; the same names there
 * are the one-mesh forms. Any other name is refused.
 *
 * Coordinates are the scene's own, in the space it was opened into: a scene
 * opened as `CADACLYSM_Y_UP` writes the Y-up metres glTF specifies, and one
 * opened `CADACLYSM_NATIVE` writes the file's own axes and units. Winding is
 * turned for a clockwise convention, as [`cadaclysm_node_save_mesh`] turns
 * it, and for the same reason: a file is not a frame.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; `path` and
 * `format` must be null or valid C strings.
 */
bool cadaclysm_scene_save(const struct CadaclysmScene *scene, const char *path, const char *format);

/**
 * How many formats [`cadaclysm_node_save_mesh`] accepts.
 *
 * A caller builds its export menu from this and its neighbours --
 * [`cadaclysm_mesh_format_label`] for what to show, [`cadaclysm_mesh_format`]
 * for what to pass back -- rather than from a list of its own, so a format
 * added to the library appears in every client that already asks.
 */
uint32_t cadaclysm_mesh_format_count(void);

/**
 * The name of one format, or null past the end.
 *
 * **An identifier, not display text**: this is the exact string
 * [`cadaclysm_node_save_mesh`]'s `format` parameter accepts back (`"stl"`,
 * `"stl-ascii"`, `"msh"`) -- it would read poorly in a menu, which is what
 * [`cadaclysm_mesh_format_label`] is for. The pointer is static and stays
 * valid for the life of the process.
 */
const char *cadaclysm_mesh_format(uint32_t index);

/**
 * The file extension one format should be written with, without the dot, or
 * null past the end.
 *
 * Not the format name: `stl-ascii` writes a `.stl`. A client naming an output
 * file asks for this rather than deriving it, which is the difference between
 * a format whose name and extension differ working everywhere and working
 * nowhere.
 *
 * The pointer is static and stays valid for the life of the process.
 */
const char *cadaclysm_mesh_format_extension(uint32_t index);

/**
 * The name a person should see for one format in a save dialog or export
 * menu -- `"STL (binary)"`, `"STL (ASCII)"`, `"Gmsh"` -- or null past the end.
 *
 * **Display text, not an identifier**: unlike [`cadaclysm_mesh_format`], the
 * string this returns cannot be passed back into
 * [`cadaclysm_node_save_mesh`]'s `format` parameter -- pass the value from
 * [`cadaclysm_mesh_format`] at the same `index` for that. The two exist
 * side by side because they answer different questions ("what do I show?"
 * vs. "what do I pass back?"), the same split [`cadaclysm_format_name`] and
 * [`cadaclysm_format_extensions`] have on the read side.
 *
 * The pointer is static and stays valid for the life of the process.
 */
const char *cadaclysm_mesh_format_label(uint32_t index);

/**
 * How many input formats this build can read.
 *
 * The counterpart to [`cadaclysm_mesh_format_count`], which answers for writing.
 * A host builds a file dialog, an import menu or a drag-and-drop test from these
 * rather than hardcoding extensions, so adding a reader updates it for free.
 *
 * This is what the build can read, and with the schemas built in it is also
 * what opens: a STEP or IFC file needs an extra schema only where it names
 * one the project does not ship.
 */
uint32_t cadaclysm_format_count(void);

/**
 * The name of one input format -- `"STEP"`, `"Rhino 3DM"`. Static; never freed.
 * Null if `index` is past the end.
 *
 * **Display text, not an identifier**: this is for showing to a person, the
 * same kind of string [`cadaclysm_mesh_format_label`] returns on the write
 * side -- unlike [`cadaclysm_mesh_format`], nothing accepts this string back
 * as input. A reader is chosen by file extension, not by this name, which is
 * why there is no read-side counterpart to `format` in
 * [`cadaclysm_node_save_mesh`].
 */
const char *cadaclysm_format_name(uint32_t index);

/**
 * That format's extensions, semicolon-separated and without dots -- `"step;stp"`.
 *
 * Semicolons because that is the separator every platform dialog wants, and
 * because a caller who needs them apart can split more easily than one holding
 * an array can join.
 *
 * These are exactly the strings [`cadaclysm_open_memory`]'s `format` argument
 * accepts, split on `;` -- a host that recognises `.step` from this list
 * already knows the value to pass there.
 */
const char *cadaclysm_format_extensions(uint32_t index);

/**
 * Write one node's mesh to `path` in the named format. False on failure, with
 * [`cadaclysm_last_error`] saying why.
 *
 * `format` is one of the names [`cadaclysm_mesh_format`] reports. A node that
 * draws nothing -- an assembly, a layer, an empty definition -- is a failure
 * rather than an empty file, since a caller asking to export it has almost
 * certainly clicked the wrong row.
 *
 * The mesh is the node's own, in the space the scene was opened into, and
 * carries no placement: a node instanced six times exports once, where it is
 * defined. Exporting where a *drawing* sits is a different question and this
 * is not it.
 *
 * # Safety
 * `scene` must be null or a handle from [`cadaclysm_open`]; `path` and
 * `format` must be null or valid C strings.
 */
bool cadaclysm_node_save_mesh(const struct CadaclysmScene *scene,
                              uint32_t node,
                              const char *path,
                              const char *format);

/**
 * Ask the user for a file to open, filtered to what this build can read.
 *
 * **Blocks** the calling thread until the user picks or cancels -- what a
 * modal dialog is. On macOS, call it from the **main thread**: a non-windowed
 * process cannot open a dialog off it at all, and the symptom is a hang, not
 * an error.
 *
 * Returns a UTF-8 path that must not be freed and must not be kept past the
 * next picker call on this thread -- the same rule as [`cadaclysm_last_error`].
 * Copy it if it needs to outlive that. `NULL` means the user cancelled, no
 * dialog was available, or this build has no picker; the reason is at
 * [`cadaclysm_last_error`] for the last two, and nothing for the first.
 *
 * # Safety
 * `parent` must be null, or point to a valid [`CadaclysmWindow`] whose
 * `handle` (and `display`, where the kind needs one) are live pointers to a
 * window of the kind its `kind` names, valid for the whole call. Ignored
 * entirely -- any value is accepted -- when this build has no picker.
 *
 * One function item, not two behind opposite `#[cfg]`s: cbindgen parses this
 * file's syntax without evaluating `--cfg` itself, so two same-named
 * `#[no_mangle]` items gated on opposite features would both survive into
 * the generated header as a duplicate declaration. Gating only the *body*
 * keeps the signature -- and so the header -- identical whichever way this
 * crate was built, which is the actual requirement: the C ABI does not vary
 * by build flag.
 */
const char *cadaclysm_pick_file(const struct CadaclysmWindow *parent);

/**
 * Ask the user where to save, offering the formats this build can write.
 *
 * Same blocking, threading and lifetime rules as [`cadaclysm_pick_file`].
 *
 * # Safety
 * As [`cadaclysm_pick_file`]; `suggested_name` must be null or a valid,
 * null-terminated C string. Neither is read when this build has no picker.
 */
const char *cadaclysm_pick_save(const struct CadaclysmWindow *parent, const char *suggested_name);

/**
 * Load a license from `text_or_path`: the certificate text itself, or the
 * path of a file holding it. Replaces the one in use. Null forgets the one in
 * use, so the next call resolves from the environment and the search paths
 * again. Returns false without changing anything when the text does not
 * verify, with the reason at [`cadaclysm_last_error`].
 *
 * # Safety
 * `text_or_path` must be null or a valid null-terminated string.
 */
bool cadaclysm_license_set(const char *text_or_path);

/**
 * The license in use, as one line -- `customer=Acme Ltd expiry=2027-09-15
 * entitlements=import,kernel seats=20` -- or, without one, `unlicensed`
 * (`unlicensed -- <reason>` when a license was found but did not verify).
 * Never null. Borrowed, and good until the next call on this thread.
 */
const char *cadaclysm_license_info(void);

/**
 * How many unlicensed notices this library has printed in this process; an
 * application can show its own banner instead of the stderr line.
 */
uint64_t cadaclysm_license_notice_count(void);

/**
 * The date this library was built, `"YYYY-MM-DD"`. A paid license is good for
 * every build dated on or before the day its updates end. Static; never freed.
 */
const char *cadaclysm_build_date(void);

/**
 * Split a mesh into meshlets, optionally with the coarser levels above them.
 *
 * `positions` and `normals` are three floats a vertex; `normals` may be null. `indices` is
 * three per triangle.
 *
 * `max_triangles` and `max_vertices` are **the consumer's own limits, and there is no
 * default**, because a meshlet built for one consumer cannot be handed to another: Nanite
 * packs a triangle count in 7 bits and a vertex count in 8, so its limits are 128 and 256,
 * while a mesh-shader pipeline caps at 124 and 64. The vertex cap is the one that bites,
 * since vertices are shared and a meshlet can sit well under its triangle limit while
 * walking past its vertex limit.
 *
 * With `levels` zero the result is one level of meshlets. With it non-zero, each level is
 * grouped, simplified with its outer boundary held, and split again, until one meshlet is
 * left; `cadaclysm_meshlet_level` and `cadaclysm_meshlet_children` say which is which.
 *
 * Null on failure, with `cadaclysm_last_error` saying why. Free with
 * [`cadaclysm_meshlets_free`].
 *
 * # Safety
 *
 * The three arrays must hold what their counts say.
 */
struct CadaclysmMeshlets *cadaclysm_meshlets_build(const float *positions,
                                                   const float *normals,
                                                   size_t vertex_count,
                                                   const uint32_t *indices,
                                                   size_t index_count,
                                                   uint32_t max_triangles,
                                                   uint32_t max_vertices,
                                                   int32_t levels);

/**
 * How many meshlets a build came to, over every level.
 *
 * # Safety
 *
 * The handle must be one [`cadaclysm_meshlets_build`] returned, or null.
 */
uint32_t cadaclysm_meshlets_count(const struct CadaclysmMeshlets *handle);

/**
 * How many triangles one meshlet holds.
 *
 * # Safety
 *
 * As [`cadaclysm_meshlets_count`].
 */
uint32_t cadaclysm_meshlet_triangle_count(const struct CadaclysmMeshlets *handle, uint32_t index);

/**
 * How many vertices one meshlet holds.
 *
 * # Safety
 *
 * As [`cadaclysm_meshlets_count`].
 */
uint32_t cadaclysm_meshlet_vertex_count(const struct CadaclysmMeshlets *handle, uint32_t index);

/**
 * Which level a meshlet belongs to; 0 is full detail.
 *
 * # Safety
 *
 * As [`cadaclysm_meshlets_count`].
 */
uint32_t cadaclysm_meshlet_level(const struct CadaclysmMeshlets *handle, uint32_t index);

/**
 * Which group of its level a meshlet belongs to.
 *
 * Groups are simplified together, and the boundary between them is what must not move.
 *
 * # Safety
 *
 * As [`cadaclysm_meshlets_count`].
 */
uint32_t cadaclysm_meshlet_group(const struct CadaclysmMeshlets *handle, uint32_t index);

/**
 * How far a meshlet's geometry may sit from the original, in the mesh's own units.
 *
 * # Safety
 *
 * As [`cadaclysm_meshlets_count`].
 */
float cadaclysm_meshlet_error(const struct CadaclysmMeshlets *handle, uint32_t index);

/**
 * How many meshlets one stands in for. Zero at level 0.
 *
 * # Safety
 *
 * As [`cadaclysm_meshlets_count`].
 */
uint32_t cadaclysm_meshlet_child_count(const struct CadaclysmMeshlets *handle, uint32_t index);

/**
 * Three floats a vertex.
 *
 * # Safety
 *
 * `out` must have room for `3 * cadaclysm_meshlet_vertex_count` floats.
 */
void cadaclysm_meshlet_positions(const struct CadaclysmMeshlets *handle,
                                 uint32_t index,
                                 float *out);

/**
 * Three floats a vertex, or nothing where the mesh carried no normals.
 *
 * # Safety
 *
 * `out` must have room for `3 * cadaclysm_meshlet_vertex_count` floats.
 */
void cadaclysm_meshlet_normals(const struct CadaclysmMeshlets *handle, uint32_t index, float *out);

/**
 * Three indices a triangle, into this meshlet's own vertices.
 *
 * # Safety
 *
 * `out` must have room for `3 * cadaclysm_meshlet_triangle_count` indices.
 */
void cadaclysm_meshlet_indices(const struct CadaclysmMeshlets *handle,
                               uint32_t index,
                               uint32_t *out);

/**
 * The meshlets this one stands in for, as indices into the same build.
 *
 * # Safety
 *
 * `out` must have room for `cadaclysm_meshlet_child_count` indices.
 */
void cadaclysm_meshlet_children(const struct CadaclysmMeshlets *handle,
                                uint32_t index,
                                uint32_t *out);

/**
 * Release a build.
 *
 * # Safety
 *
 * The handle must have come from [`cadaclysm_meshlets_build`] and not been freed.
 */
void cadaclysm_meshlets_free(struct CadaclysmMeshlets *handle);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* CADACLYSM_H */
