//! The reader: `Cadaclysm` (the library's own functions), `CadaclysmScene`, `CadaclysmNode`,
//! `CadaclysmPlacement`, `CadaclysmMesh`, `CadaclysmPolylines`, `CadaclysmBrep` and
//! `CadaclysmFemMesh`.
use std::cell::RefCell;
use std::rc::Rc;

use cadaclysm_sdk as sdk;
use godot::classes::{ArrayMesh, FileAccess, Node3D};
use godot::prelude::*;

use crate::meshes;
use crate::{clear_error, dict, fail, gs, ok, os_path};

/// A scene shared by every view of it; `None` once closed.
pub(crate) type Shared = Rc<RefCell<Option<sdk::Scene>>>;

/// Run `f` on the open scene, or fail with "closed".
pub(crate) fn with_scene<R>(shared: &Shared, f: impl FnOnce(&sdk::Scene) -> R) -> Option<R> {
    let held = shared.borrow();
    match held.as_ref() {
        Some(scene) => Some(f(scene)),
        None => fail("the scene is closed"),
    }
}

/// Run `f` on node `index` of the open scene.
pub(crate) fn with_node<R>(shared: &Shared, index: u32, f: impl FnOnce(sdk::Node<'_>) -> R) -> Option<R> {
    let held = shared.borrow();
    let Some(scene) = held.as_ref() else { return fail("the scene is closed") };
    match scene.node(index) {
        Some(node) => Some(f(node)),
        None => fail(format!("no node {index}")),
    }
}

// ---- conversions -------------------------------------------------------------------

pub(crate) fn vector3(p: [f32; 3]) -> Vector3 {
    Vector3::new(p[0], p[1], p[2])
}

#[allow(dead_code)]
pub(crate) fn vector3_64(p: [f64; 3]) -> Vector3 {
    Vector3::new(p[0] as f32, p[1] as f32, p[2] as f32)
}

/// Sixteen doubles, column-major, as a `Transform3D` (the bottom row is dropped: the
/// library's transforms are affine).
pub(crate) fn transform(m: [f64; 16]) -> Transform3D {
    let column = |c: usize| Vector3::new(m[4 * c] as f32, m[4 * c + 1] as f32, m[4 * c + 2] as f32);
    Transform3D::new(Basis::from_cols(column(0), column(1), column(2)), column(3))
}

/// A `Transform3D` as sixteen doubles, column-major: its basis columns, its origin, and
/// the affine bottom row filled in -- the inverse of `transform` above, so a transform
/// read off `CadaclysmNode.transform` goes straight back into `CadaclysmNode.fem_mesh`.
fn matrix(t: Transform3D) -> [f64; 16] {
    let mut m = [0.0; 16];
    for (c, axis) in [t.basis.col_a(), t.basis.col_b(), t.basis.col_c(), t.origin].iter().enumerate() {
        m[4 * c] = f64::from(axis.x);
        m[4 * c + 1] = f64::from(axis.y);
        m[4 * c + 2] = f64::from(axis.z);
    }
    m[15] = 1.0;
    m
}

/// A reader placement: a `Transform3D`, or sixteen numbers column-major (a
/// `PackedFloat64Array` or an array, which keep a double where a `Transform3D` holds
/// floats).
///
/// **The length is checked here** because the ABI is handed a bare pointer and cannot:
/// sixteen on this side, where the kernel's `CadaclysmSolid.fem_mesh` takes a frame's
/// **twelve**, so a caller moving between the two reformats the placement rather than
/// having it read short.
fn placement16(v: &Variant, what: &str) -> Option<[f64; 16]> {
    if v.get_type() == VariantType::TRANSFORM3D {
        return Some(matrix(v.to::<Transform3D>()));
    }
    let values: Vec<f64> = match v.get_type() {
        VariantType::PACKED_FLOAT64_ARRAY => v.to::<PackedFloat64Array>().as_slice().to_vec(),
        VariantType::PACKED_FLOAT32_ARRAY => v.to::<PackedFloat32Array>().as_slice().iter().map(|&x| f64::from(x)).collect(),
        VariantType::ARRAY => {
            let items = v.try_to::<AnyArray>().ok()?;
            let mut out = Vec::with_capacity(items.len());
            for item in items.iter_shared() {
                out.push(ok(number(&item, what))?);
            }
            out
        }
        _ => return fail(format!("{what}: expected a Transform3D or 16 numbers, not {v}")),
    };
    if values.len() != 16 {
        return fail(format!("{what}: expected 16 numbers, got {}", values.len()));
    }
    let mut m = [0.0; 16];
    m.copy_from_slice(&values);
    Some(m)
}

pub(crate) fn aabb(min: [f32; 3], max: [f32; 3]) -> Aabb {
    Aabb::new(vector3(min), vector3(max) - vector3(min))
}

fn bounds(b: sdk::Bounds) -> Aabb {
    aabb(b.min, b.max)
}

pub(crate) fn strings(items: impl IntoIterator<Item = impl AsRef<str>>) -> PackedStringArray {
    items.into_iter().map(|s| GString::from(s.as_ref())).collect()
}

fn value_kind(kind: sdk::ValueKind) -> &'static str {
    match kind {
        sdk::ValueKind::None => "none",
        sdk::ValueKind::Text => "text",
        sdk::ValueKind::Integer => "integer",
        sdk::ValueKind::Real => "real",
        sdk::ValueKind::Boolean => "boolean",
        sdk::ValueKind::List => "list",
        sdk::ValueKind::Reference => "reference",
    }
}

fn attribute(a: &sdk::Attribute) -> VarDictionary {
    let value = match &a.value {
        sdk::Value::None => Variant::nil(),
        sdk::Value::Text(text) => text.to_variant(),
        sdk::Value::Integer(v) => v.to_variant(),
        sdk::Value::Real(v) => v.to_variant(),
        sdk::Value::Boolean(v) => v.to_variant(),
    };
    dict(&[("name", a.name.as_str().to_variant()), ("kind", value_kind(a.kind).to_variant()), ("value", value.to_variant()), ("text", a.text().to_variant())])
}

fn face(f: &sdk::Face<'_>) -> VarDictionary {
    let loops: Array<PackedVector2Array> =
        f.loops.iter().map(|l| l.iter().map(|p| Vector2::new(p[0], p[1])).collect::<PackedVector2Array>()).collect();
    let quads = |rows: &[[f32; 4]]| rows.iter().map(|r| Vector4::new(r[0], r[1], r[2], r[3])).collect::<PackedVector4Array>();
    dict(&[("kind", (f.kind as i64).to_variant()), ("kind_name", f.kind_name().to_variant()), ("reversed", f.reversed.to_variant()), ("transposed", f.transposed.to_variant()), ("origin", vector3(f.origin).to_variant()), ("ax", vector3(f.ax).to_variant()), ("ay", vector3(f.ay).to_variant()), ("az", vector3(f.az).to_variant()), ("domain", Vector4::new(f.domain[0], f.domain[1], f.domain[2], f.domain[3]).to_variant()), ("scalars", Vector4::new(f.scalars[0], f.scalars[1], f.scalars[2], f.scalars[3]).to_variant()), ("loops", loops.to_variant()), ("profile", quads(f.profile).to_variant()), ("profile2", quads(f.profile2).to_variant()), ("nurbs", PackedFloat32Array::from(f.nurbs).to_variant())])
}

// ---- the FEM surface mesh's plain data ----------------------------------------------
//
// These five build what both FEM classes hand over -- this module's `CadaclysmFemMesh`
// and the kernel's `CadaclysmSolidFemMesh` -- and they take plain numbers rather than
// either library's records, so the two sides cannot drift in what they call a key or in
// which width a field comes over as. Nothing here borrows: a Godot array is always a copy.

/// Node positions as flat doubles, three a node. **Doubles, not a `PackedVector3Array`**:
/// a solver mesh is the one product here whose whole point is the f64 the library
/// computed, and Godot's `Vector3` holds floats -- the same reason the kernel's
/// `raw_points` and `CadaclysmNode.raw_transform` exist.
pub(crate) fn fem_nodes(points: &[[f64; 3]]) -> PackedFloat64Array {
    points.iter().flatten().copied().collect()
}

/// Node indices: a count or an index, never the `NONE` sentinel, so an int32 holds them
/// as `CadaclysmMesh.indices` does.
pub(crate) fn fem_indices(values: &[u32]) -> PackedInt32Array {
    values.iter().map(|&i| i as i32).collect()
}

/// Three node indices a triangle, flattened as `CadaclysmMesh.indices` is -- and **not**
/// wound round for Godot: these are the library's own triangles for a solver to read, not
/// something to draw.
pub(crate) fn fem_triangles(triangles: &[[u32; 3]]) -> PackedInt32Array {
    triangles.iter().flatten().map(|&i| i as i32).collect()
}

/// A pair that may hold the `NONE` sentinel (4294967295) -- an edge's `faces` or `ends`.
/// **Int64, not Int32**: the sentinel does not fit an int32, where it would read as -1.
fn fem_pair(pair: (u32, u32)) -> PackedInt64Array {
    PackedInt64Array::from(&[i64::from(pair.0), i64::from(pair.1)][..])
}

/// One census row, `(a, b, brep_edge)`: two node indices and the B-rep edge both lie on,
/// or `NONE`. Int64 for the sentinel, as `fem_pair` is.
pub(crate) fn fem_census(rows: &[(u32, u32, u32)]) -> Array<PackedInt64Array> {
    rows.iter().map(|&(a, b, edge)| PackedInt64Array::from(&[i64::from(a), i64::from(b), i64::from(edge)][..])).collect()
}

/// One B-rep edge of a FEM mesh, as a Dictionary: `id` (the **body's** own edge id),
/// `nodes`, `runs`, `faces`, `ends`, `closed`, `seam`.
pub(crate) fn fem_edge(id: u32, nodes: &[u32], runs: &[u32], faces: (u32, u32), ends: (u32, u32), closed: bool, seam: bool) -> VarDictionary {
    dict(&[
        ("id", i64::from(id).to_variant()),
        ("nodes", fem_indices(nodes).to_variant()),
        ("runs", fem_indices(runs).to_variant()),
        ("faces", fem_pair(faces).to_variant()),
        ("ends", fem_pair(ends).to_variant()),
        ("closed", closed.to_variant()),
        ("seam", seam.to_variant()),
    ])
}

/// One B-rep vertex of a FEM mesh, as a Dictionary: `node` (the mesh node there, or
/// `NONE`), `point` (three doubles, in the same space as the nodes) and `has_position`,
/// without which `point` is a meaningless zero rather than the origin.
pub(crate) fn fem_vertex(node: u32, point: [f64; 3], has_position: bool) -> VarDictionary {
    dict(&[
        ("node", i64::from(node).to_variant()),
        ("point", PackedFloat64Array::from(&point[..]).to_variant()),
        ("has_position", has_position.to_variant()),
    ])
}

pub(crate) fn manifold(m: sdk::Manifold) -> VarDictionary {
    dict(&[("faces", (m.faces as i64).to_variant()), ("edges", (m.edges as i64).to_variant()), ("vertices", (m.vertices as i64).to_variant()), ("boundary_edges", (m.boundary_edges as i64).to_variant()), ("non_manifold_edges", (m.non_manifold_edges as i64).to_variant()), ("non_manifold_vertices", (m.non_manifold_vertices as i64).to_variant()), ("is_manifold", m.is_manifold.to_variant()), ("is_closed", m.is_closed.to_variant())])
}

// ---- options -----------------------------------------------------------------------

/// `CadaclysmScene.open`'s options dictionary as the SDK's `OpenOptions`.
///
/// `convention` defaults to `"y-up"` -- Y up, right-handed, metres, which is Godot's
/// own space -- where every other wrapper defaults to `"native"`: here a file opened
/// with no options should simply draw.
fn open_options(options: &VarDictionary) -> Option<sdk::OpenOptions> {
    let mut known = vec!["convention", "uv_world", "colors", "schema", "source_metres_per_unit", "name"];
    known.sort_unstable();
    for key in options.keys_array().iter_shared() {
        let key = key.to_string();
        if known.binary_search(&key.as_str()).is_err() {
            return fail(format!("no open option called {key:?}: {}", known.join(", ")));
        }
    }
    let convention = match options.get("convention") {
        Some(value) if value.get_type() == VariantType::INT => value.to::<i64>() as u32,
        Some(value) => ok(sdk::Convention::parse(&value.to_string()))?,
        None => sdk::Convention::YUp as u32,
    };
    let flag = |name: &str| options.get(name).is_some_and(|v| v.booleanize());
    let convention = convention | if flag("uv_world") { sdk::UV_WORLD } else { 0 };
    let mut opened = sdk::OpenOptions::new().convention(convention).colors(flag("colors"));
    if let Some(schema) = options.get("schema") {
        opened = opened.schema(os_path(&GString::from(&schema.to_string())));
    }
    if let Some(metres) = options.get("source_metres_per_unit") {
        opened = opened.source_metres_per_unit(ok(number(&metres, "source_metres_per_unit"))?);
    }
    if let Some(name) = options.get("name") {
        opened = opened.name(name.to_string());
    }
    Some(opened)
}

/// A number an option may give: gdext's `Variant::to::<f64>()` refuses an INT Variant
/// outright (`FromGodot::from_variant() failed -- cannot convert from INT to FLOAT`), so
/// every numeric option is read through this instead of `to::<f64>()` directly.
fn number(v: &Variant, key: &str) -> Result<f64, String> {
    match v.get_type() {
        VariantType::INT => Ok(v.to::<i64>() as f64),
        VariantType::FLOAT => Ok(v.to::<f64>()),
        _ => Err(format!("{key}: expected a number, not {v}")),
    }
}

/// A colour a `svg_text`/`svg` option may give: a `Color`, `"#rgb"`/`"#rrggbb"`, or an
/// already packed `0xRRGGBB` int, as `CadaclysmSvgOptions.stroke`/`background` want it.
fn packed_colour(v: &Variant, what: &str) -> Option<u32> {
    match v.get_type() {
        VariantType::COLOR => {
            let c = v.to::<Color>();
            let byte = |x: f32| (x.clamp(0.0, 1.0) * 255.0).round() as u32;
            Some((byte(c.r) << 16) | (byte(c.g) << 8) | byte(c.b))
        }
        VariantType::INT => Some(v.to::<i64>() as u32),
        VariantType::STRING | VariantType::STRING_NAME => {
            let text = v.to_string();
            let hex = text.strip_prefix('#').unwrap_or(&text);
            let hex = if hex.len() == 3 { hex.chars().flat_map(|c| [c, c]).collect::<String>() } else { hex.to_string() };
            match (hex.len(), u32::from_str_radix(&hex, 16)) {
                (6, Ok(value)) => Some(value),
                _ => fail(format!("{what}: colour must be '#rrggbb' or a Color, not {text:?}")),
            }
        }
        _ => fail(format!("{what}: colour must be '#rrggbb' or a Color")),
    }
}

/// `svg_text`/`svg`'s options dictionary as the SDK's `SvgOptions`: `view` through the
/// viewer's own table, `az`/`el` over it, `up` left `None` to keep the scene's (or, for
/// a kernel solid, always `"z"`) own default -- `Scene::svg_text`/`Node::svg_text` and
/// `blacksmith::Solid::svg_text` apply that fallback themselves, so this never guesses
/// it. See `CadaclysmScene.svg_text_with`'s doc for every key.
pub(crate) fn svg_options(options: &VarDictionary) -> Option<sdk::SvgOptions> {
    let mut known =
        vec!["view", "az", "el", "up", "fov", "size", "margin", "tolerance", "stroke", "width", "background", "edges", "curves", "isocurves", "polylines"];
    known.sort_unstable();
    for key in options.keys_array().iter_shared() {
        let key = key.to_string();
        if known.binary_search(&key.as_str()).is_err() {
            return fail(format!("no svg option called {key:?}: {}", known.join(", ")));
        }
    }
    let mut opts = sdk::SvgOptions::default();
    if let Some(view) = options.get("view") {
        opts.view = match view.to_string().as_str() {
            "front" => sdk::SvgView::Front,
            "back" => sdk::SvgView::Back,
            "left" => sdk::SvgView::Left,
            "right" => sdk::SvgView::Right,
            "top" => sdk::SvgView::Top,
            "bottom" => sdk::SvgView::Bottom,
            "iso" => sdk::SvgView::Iso,
            other => return fail(format!("no view called {other:?}: front, back, left, right, top, bottom, iso")),
        };
    }
    if let Some(az) = options.get("az") {
        opts.azimuth = Some(ok(number(&az, "az"))?);
    }
    if let Some(el) = options.get("el") {
        opts.elevation = Some(ok(number(&el, "el"))?);
    }
    if let Some(up) = options.get("up") {
        opts.up = match up.to_string().to_lowercase().as_str() {
            "y" => Some(sdk::Up::Y),
            "z" => Some(sdk::Up::Z),
            other => return fail(format!("up must be 'y' or 'z', not {other:?}")),
        };
    }
    if let Some(fov) = options.get("fov") {
        opts.fov = ok(number(&fov, "fov"))?;
    }
    if let Some(size) = options.get("size") {
        let (width, height) = match size.get_type() {
            VariantType::VECTOR2 => {
                let v = size.to::<Vector2>();
                (v.x as f64, v.y as f64)
            }
            VariantType::VECTOR2I => {
                let v = size.to::<Vector2i>();
                (v.x as f64, v.y as f64)
            }
            VariantType::ARRAY => {
                let items: Vec<Variant> = size.try_to::<AnyArray>().ok()?.iter_shared().collect();
                if items.len() != 2 {
                    return fail("size: expected [width, height]");
                }
                (ok(number(&items[0], "size"))?, ok(number(&items[1], "size"))?)
            }
            _ => return fail("size: expected a Vector2 or [width, height]"),
        };
        opts.width = width;
        opts.height = height;
    }
    if let Some(margin) = options.get("margin") {
        opts.margin = ok(number(&margin, "margin"))?;
    }
    if let Some(tolerance) = options.get("tolerance") {
        opts.tolerance = ok(number(&tolerance, "tolerance"))?;
    }
    if let Some(stroke) = options.get("stroke") {
        opts.stroke = packed_colour(&stroke, "stroke")?;
    }
    if let Some(width) = options.get("width") {
        opts.stroke_width = ok(number(&width, "width"))?;
    }
    if let Some(background) = options.get("background") {
        opts.background = Some(packed_colour(&background, "background")?);
    }
    let flag = |name: &str, default: bool| options.get(name).map(|v| v.booleanize()).unwrap_or(default);
    opts.edges = flag("edges", true);
    opts.curves = flag("curves", false);
    opts.isocurves = flag("isocurves", false);
    opts.polylines = flag("polylines", false);
    Some(opts)
}

// ---- Cadaclysm ---------------------------------------------------------------------

/// The reader library itself: its version, its license, what it writes, and the last
/// error any cadaclysm call reported.
#[derive(GodotClass)]
#[class(no_init, base = Object)]
pub struct Cadaclysm;

#[godot_api]
impl Cadaclysm {
    /// Why the last cadaclysm call that failed failed; `""` after a call that worked.
    #[func]
    fn last_error() -> GString {
        gs(crate::last_error())
    }

    /// Load the reader from `path` before anything else uses it. Without this, it is
    /// found beside the extension, then where `CADACLYSM_LIBRARY` points.
    #[func]
    fn load(path: GString) -> bool {
        ok(sdk::load(os_path(&path))).is_some()
    }

    /// Where the reader was loaded from, or would be.
    #[func]
    fn library_path() -> GString {
        gs(ok(sdk::library_path()).map(|p| p.display().to_string()).unwrap_or_default())
    }

    #[func]
    fn version() -> GString {
        gs(ok(sdk::version()).unwrap_or_default())
    }

    #[func]
    fn build_date() -> GString {
        gs(ok(sdk::build_date()).unwrap_or_default())
    }

    /// Install a license: the license file's text, or its path.
    #[func]
    fn license(text_or_path: GString) -> bool {
        let text = text_or_path.to_string();
        let given = if text.starts_with("res://") || text.starts_with("user://") { os_path(&text_or_path) } else { text };
        ok(sdk::license(given)).is_some()
    }

    #[func]
    fn license_info() -> GString {
        gs(ok(sdk::license_info()).unwrap_or_default())
    }

    #[func]
    fn license_notice_count() -> i64 {
        ok(sdk::license_notice_count()).unwrap_or_default() as i64
    }

    /// Every format `CadaclysmNode.save_mesh` and `CadaclysmScene.save` write, as
    /// `{name, extension}` dictionaries.
    #[func]
    fn mesh_formats() -> Array<VarDictionary> {
        ok(sdk::mesh_formats())
            .unwrap_or_default()
            .iter()
            .map(|f| dict(&[("name", f.name.as_str().to_variant()), ("extension", f.extension.as_str().to_variant())]))
            .collect()
    }

    /// The schema a STEP or IFC file declares in its header; `""` for none.
    #[func]
    fn declared_schema(path: GString) -> GString {
        gs(ok(sdk::declared_schema(os_path(&path))).unwrap_or_default())
    }

    /// A convention's name (`"y-up"`, `"unreal+file-units"`...) as the number the
    /// library takes; -1 for a name it does not know.
    #[func]
    fn convention(name: GString) -> i64 {
        ok(sdk::Convention::parse(&name.to_string())).map_or(-1, i64::from)
    }
}

// ---- CadaclysmScene ----------------------------------------------------------------------

/// An open CAD file: its tree of nodes, and the placements that draw it.
///
/// ```gdscript
/// var scene := CadaclysmScene.open("res://part.step")
/// add_child(scene.instantiate())      # every body, as MeshInstance3D nodes
/// for node in scene.walk():
///     print("  ".repeat(node.depth), node.label)
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmScene {
    pub(crate) shared: Shared,
    path: String,
    #[var(rename = path, get = get_path, no_set)]
    path_: PhantomVar<GString>,
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
    #[var(get = get_version, no_set)]
    version: PhantomVar<GString>,
    #[var(get = get_schema, no_set)]
    schema: PhantomVar<GString>,
    #[var(get = get_schema_read, no_set)]
    schema_read: PhantomVar<GString>,
    #[var(get = get_substituted, no_set)]
    substituted: PhantomVar<bool>,
    #[var(get = get_convention, no_set)]
    convention: PhantomVar<i64>,
    #[var(get = get_metres_per_unit, no_set)]
    metres_per_unit: PhantomVar<f64>,
    #[var(get = get_bounds, no_set)]
    bounds: PhantomVar<Aabb>,
    #[var(get = get_surface_matrix, no_set)]
    surface_matrix: PhantomVar<Transform3D>,
    #[var(get = get_diagnostics, no_set)]
    diagnostics: PhantomVar<PackedStringArray>,
    #[var(get = get_source_name, no_set)]
    source_name: PhantomVar<GString>,
    #[var(get = get_node_count, no_set)]
    node_count: PhantomVar<i64>,
    #[var(get = get_nodes, no_set)]
    nodes: PhantomVar<Array<Gd<CadaclysmNode>>>,
    #[var(get = get_roots, no_set)]
    roots: PhantomVar<Array<Gd<CadaclysmNode>>>,
    #[var(get = get_placements, no_set)]
    placements: PhantomVar<Array<Gd<CadaclysmPlacement>>>,
    #[var(get = get_links, no_set)]
    links: PhantomVar<Array<Gd<CadaclysmLink>>>,
    #[var(get = get_joints, no_set)]
    joints: PhantomVar<Array<Gd<CadaclysmJoint>>>,
    #[var(get = get_realized, no_set)]
    realized: PhantomVar<i64>,
    #[var(get = get_realize_total, no_set)]
    realize_total: PhantomVar<i64>,
}

impl CadaclysmScene {
    pub(crate) fn wrap(scene: sdk::Scene) -> Gd<CadaclysmScene> {
        let path = scene.path().display().to_string();
        Gd::from_object(CadaclysmScene {
            shared: Rc::new(RefCell::new(Some(scene))),
            path,
            path_: PhantomVar::default(),
            closed: PhantomVar::default(),
            version: PhantomVar::default(),
            schema: PhantomVar::default(),
            schema_read: PhantomVar::default(),
            substituted: PhantomVar::default(),
            convention: PhantomVar::default(),
            metres_per_unit: PhantomVar::default(),
            bounds: PhantomVar::default(),
            surface_matrix: PhantomVar::default(),
            diagnostics: PhantomVar::default(),
            source_name: PhantomVar::default(),
            node_count: PhantomVar::default(),
            nodes: PhantomVar::default(),
            roots: PhantomVar::default(),
            placements: PhantomVar::default(),
            links: PhantomVar::default(),
            joints: PhantomVar::default(),
            realized: PhantomVar::default(),
            realize_total: PhantomVar::default(),
        })
    }

    fn node_gd(&self, index: u32) -> Gd<CadaclysmNode> {
        CadaclysmNode::wrap(self.shared.clone(), index)
    }

    fn node_list(&self, f: impl FnOnce(&sdk::Scene) -> Vec<u32>) -> Array<Gd<CadaclysmNode>> {
        with_scene(&self.shared, f).unwrap_or_default().into_iter().map(|i| self.node_gd(i)).collect()
    }
}

#[godot_api]
impl CadaclysmScene {
    /// Open a CAD file: STEP, IGES, IFC, Rhino 3dm, ACIS SAT, OCCT BREP, OpenSCAD, or a
    /// `.zip` holding one, read Y up in metres (Godot's own space). `res://` and
    /// `user://` paths work, in the editor and in an exported game alike.
    ///
    /// Returns `null` on failure; `Cadaclysm.last_error()` says why.
    #[func]
    fn open(path: GString) -> Option<Gd<CadaclysmScene>> {
        Self::open_with(path, VarDictionary::new())
    }

    /// `open`, with options: `convention` (`"y-up"`, the default and Godot's own space; `"native"`,
    /// `"unity"`, `"unreal"`, `"blender"`, with `"+file-units"` to keep the file's
    /// units), `uv_world` (world-scale UVs), `colors` (per-vertex colours for a body
    /// painted in more than one), `schema` (an extra EXPRESS `.exp`), and
    /// `source_metres_per_unit` for a format that states no unit.
    #[func]
    fn open_with(path: GString, options: VarDictionary) -> Option<Gd<CadaclysmScene>> {
        let opened = open_options(&options)?;
        let file = os_path(&path);
        if !std::path::Path::new(&file).exists() && FileAccess::file_exists(&path) {
            // Inside an exported game's pack: no file on disk, so read it through Godot.
            let bytes = FileAccess::get_file_as_bytes(&path);
            let text = path.to_string();
            let format = text.rsplit('.').next().unwrap_or_default().to_string();
            let name = text.rsplit('/').next().unwrap_or_default().to_string();
            let opened = if options.contains_key("name") { opened } else { opened.name(name) };
            return ok(opened.open_memory(bytes.as_slice(), &format)).map(CadaclysmScene::wrap);
        }
        ok(opened.open(file)).map(CadaclysmScene::wrap)
    }

    /// Open a CAD file already in memory. `format` names its kind as an extension
    /// would: `"step"`, `"ifc"`, `"3dm"`, `"zip"`... `options` as `open`'s, plus `name`,
    /// the path the scene reports.
    #[func]
    fn open_bytes(data: PackedByteArray, format: GString, options: VarDictionary) -> Option<Gd<CadaclysmScene>> {
        let opened = open_options(&options)?;
        ok(opened.open_memory(data.as_slice(), &format.to_string())).map(CadaclysmScene::wrap)
    }

    /// Free the scene now rather than when the last reference goes. Its nodes,
    /// placements and meshes stop working; `ArrayMesh`es built from them do not.
    #[func]
    fn close(&mut self) {
        self.shared.borrow_mut().take();
    }

    #[func]
    fn get_closed(&self) -> bool {
        self.shared.borrow().is_none()
    }

    #[func]
    fn get_path(&self) -> GString {
        gs(&self.path)
    }

    /// The library's version (the scene's reader).
    #[func]
    fn get_version(&self) -> GString {
        gs(with_scene(&self.shared, |s| s.version()).unwrap_or_default())
    }

    /// The schema the file says it speaks.
    #[func]
    fn get_schema(&self) -> GString {
        gs(with_scene(&self.shared, |s| s.schema()).unwrap_or_default())
    }

    /// The schema it was read with.
    #[func]
    fn get_schema_read(&self) -> GString {
        gs(with_scene(&self.shared, |s| s.schema_read()).unwrap_or_default())
    }

    /// Whether the file was read with a schema other than the one it names.
    #[func]
    fn get_substituted(&self) -> bool {
        with_scene(&self.shared, |s| s.substituted()).unwrap_or_default()
    }

    #[func]
    fn get_convention(&self) -> i64 {
        with_scene(&self.shared, |s| s.convention() as i64).unwrap_or_default()
    }

    /// What one of the file's own units is worth in metres.
    #[func]
    fn get_metres_per_unit(&self) -> f64 {
        with_scene(&self.shared, |s| s.metres_per_unit()).unwrap_or_default()
    }

    /// The box around every placement, in the convention's space.
    #[func]
    fn get_bounds(&self) -> Aabb {
        with_scene(&self.shared, |s| bounds(s.bounds())).unwrap_or_default()
    }

    /// What the library applied to the file's coordinates to reach the convention.
    #[func]
    fn get_surface_matrix(&self) -> Transform3D {
        with_scene(&self.shared, |s| {
            let rows = s.surface_matrix();
            let mut m = [0.0; 16];
            for (r, row) in rows.iter().enumerate() {
                for (c, v) in row.iter().enumerate() {
                    m[4 * c + r] = *v;
                }
            }
            transform(m)
        })
        .unwrap_or(Transform3D::IDENTITY)
    }

    /// What the reader noticed and worked around.
    #[func]
    fn get_diagnostics(&self) -> PackedStringArray {
        with_scene(&self.shared, |s| strings(s.diagnostics())).unwrap_or_default()
    }

    /// The member a `.zip` was opened from; `""` otherwise.
    #[func]
    fn get_source_name(&self) -> GString {
        gs(with_scene(&self.shared, |s| s.source_name().unwrap_or_default()).unwrap_or_default())
    }

    #[func]
    fn get_node_count(&self) -> i64 {
        with_scene(&self.shared, |s| s.len() as i64).unwrap_or_default()
    }

    /// Node `index` (from zero), or `null`.
    #[func]
    fn node(&self, index: i64) -> Option<Gd<CadaclysmNode>> {
        let count = self.get_node_count();
        if index < 0 || index >= count {
            return fail(format!("no node {index}: the scene has {count}"));
        }
        Some(self.node_gd(index as u32))
    }

    /// Every node, in the file's order.
    #[func]
    fn get_nodes(&self) -> Array<Gd<CadaclysmNode>> {
        self.node_list(|s| s.iter().map(|n| n.index()).collect())
    }

    /// The nodes at the top of the tree.
    #[func]
    fn get_roots(&self) -> Array<Gd<CadaclysmNode>> {
        self.node_list(|s| s.roots().iter().map(|n| n.index()).collect())
    }

    /// Every node, depth first from the roots: a tree view's rows, in order.
    #[func]
    fn walk(&self) -> Array<Gd<CadaclysmNode>> {
        self.node_list(|s| s.walk().map(|n| n.index()).collect())
    }

    /// The nodes a filter picks: `kind = 'IfcWall' AND visible`, `name LIKE 'Bolt%'`...
    #[func]
    fn query(&self, filter: GString) -> Array<Gd<CadaclysmNode>> {
        let found = with_scene(&self.shared, |s| ok(s.query(&filter.to_string()))).flatten();
        found.unwrap_or_default().into_iter().map(|i| self.node_gd(i)).collect()
    }

    /// Every drawing of every body: iterate these to draw, the nodes to build a tree.
    #[func]
    fn get_placements(&self) -> Array<Gd<CadaclysmPlacement>> {
        let count = with_scene(&self.shared, |s| s.placements().len()).unwrap_or_default();
        (0..count as u32).map(|i| CadaclysmPlacement::wrap(self.shared.clone(), i)).collect()
    }

    /// The file's mechanism, as rigid bodies. Empty where the file names no kinematic
    /// links.
    #[func]
    fn get_links(&self) -> Array<Gd<CadaclysmLink>> {
        let count = with_scene(&self.shared, |s| s.links().len()).unwrap_or_default();
        (0..count as u32).map(|i| CadaclysmLink::wrap(self.shared.clone(), i)).collect()
    }

    /// The file's mechanism, as connections between links. Empty where the file names
    /// no kinematic joints.
    #[func]
    fn get_joints(&self) -> Array<Gd<CadaclysmJoint>> {
        let count = with_scene(&self.shared, |s| s.joints().len()).unwrap_or_default();
        (0..count as u32).map(|i| CadaclysmJoint::wrap(self.shared.clone(), i)).collect()
    }

    /// Mesh every body now (in parallel inside the library) rather than one by one on
    /// first use. Returns how many were meshed.
    #[func]
    fn realize_all(&self) -> i64 {
        with_scene(&self.shared, |s| s.realize_all() as i64).unwrap_or_default()
    }

    #[func]
    fn get_realized(&self) -> i64 {
        with_scene(&self.shared, |s| s.realized() as i64).unwrap_or_default()
    }

    #[func]
    fn get_realize_total(&self) -> i64 {
        with_scene(&self.shared, |s| s.realize_total() as i64).unwrap_or_default()
    }

    /// Stop a `realize_all` running on another thread.
    #[func]
    fn cancel(&self) {
        with_scene(&self.shared, |s| s.cancel());
    }

    /// Write the whole scene: `"glb"`, `"gltf"`, `"obj"`, `"stl"`... (see
    /// `Cadaclysm.mesh_formats()`).
    #[func]
    fn save(&self, path: GString, format: GString) -> bool {
        with_scene(&self.shared, |s| ok(s.save(os_path(&path), &format.to_string()))).flatten().is_some()
    }

    /// The scene as Godot nodes: a `Node3D` holding one `MeshInstance3D` per placement,
    /// the bodies that repeat sharing one `ArrayMesh`.
    ///
    /// Each `MeshInstance3D` carries its file node's index as metadata: `cadaclysm_node` (the
    /// node a click selects), `cadaclysm_geometry` and `cadaclysm_placement`.
    ///
    /// `instantiate_with`'s options: `edges` (true: each body's edges as a `lines` child), `edge_color`,
    /// `material` (a `Material` for every body instead of the file's colours), and
    /// `tree` (true: nest the placements under `Node3D`s following the file's tree).
    #[func]
    fn instantiate(&self) -> Option<Gd<Node3D>> {
        self.instantiate_with(VarDictionary::new())
    }

    /// `instantiate`, with options: see there.
    #[func]
    fn instantiate_with(&self, options: VarDictionary) -> Option<Gd<Node3D>> {
        let options = meshes::BuildOptions::from_dictionary(&options)?;
        let name = std::path::Path::new(&self.path).file_stem().map(|s| s.to_string_lossy().into_owned());
        with_scene(&self.shared, |s| meshes::instantiate(s, name.as_deref().unwrap_or("CadaclysmScene"), &options))
    }

    /// Every edge and free curve seen from `view` (`"front"`, `"top"`, `"left"`,
    /// `"right"`, `"back"`, `"bottom"`) and flattened onto the page, for 2D drawing:
    /// `{segments: PackedVector2Array (pairs, for draw_multiline), lo: Vector2, hi:
    /// Vector2}`, with `y` down the screen.
    #[func]
    fn drawing(&self, view: GString) -> VarDictionary {
        with_scene(&self.shared, |s| crate::drawing::drawing(s, &view.to_string())).flatten().unwrap_or_default()
    }

    /// Every visible placement's wireframe as SVG text, from the camera the viewer's
    /// `"iso"` angle describes -- the library's own camera, not `drawing`/`instantiate`.
    /// `""` on a refused option; `Cadaclysm.last_error()` says why.
    #[func]
    fn svg_text(&self) -> GString {
        self.svg_text_with(VarDictionary::new())
    }

    /// `svg_text`, with options: `view` (`"front"` `"back"` `"left"` `"right"` `"top"`
    /// `"bottom"` `"iso"`, default `"iso"`), `az`, `el` (degrees, over `view`'s), `up`
    /// (`"y"`/`"z"`, default from this scene's own convention), `fov` (degrees; `0`,
    /// the default, is orthographic), `size` (a `Vector2` or `[width, height]`, `0` is
    /// `1000`), `margin` (fraction of the content's extent left each side, default
    /// `0.05`), `tolerance` (how far a written curve may stray, in page units, default
    /// `0.1`), `stroke` (a `Color`, `"#rrggbb"` or a packed int, default black),
    /// `width` (the stroke's, in page units, default `1`), `background` (as `stroke`,
    /// left out for none), `edges`, `curves`, `isocurves`, `polylines` (which line
    /// sets are drawn; edges alone by default).
    #[func]
    fn svg_text_with(&self, options: VarDictionary) -> GString {
        let Some(opts) = svg_options(&options) else { return GString::new() };
        gs(with_scene(&self.shared, |s| ok(s.svg_text(&opts))).flatten().unwrap_or_default())
    }

    /// `svg_text` written to `path` by the library itself.
    #[func]
    fn svg(&self, path: GString) -> bool {
        self.svg_with(path, VarDictionary::new())
    }

    /// `svg`, with options: see `svg_text_with`.
    #[func]
    fn svg_with(&self, path: GString, options: VarDictionary) -> bool {
        let Some(opts) = svg_options(&options) else { return false };
        with_scene(&self.shared, |s| ok(s.svg(os_path(&path), &opts))).flatten().is_some()
    }
}

// ---- CadaclysmNode -----------------------------------------------------------------------

/// One node of a scene's tree: an assembly, a part, a body, a layer, a storey...
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmNode {
    pub(crate) shared: Shared,
    pub(crate) index: u32,
    #[var(rename = index, get = get_index, no_set)]
    index_: PhantomVar<i64>,
    #[var(get = get_name, no_set)]
    name: PhantomVar<GString>,
    #[var(get = get_id, no_set)]
    id: PhantomVar<GString>,
    #[var(get = get_kind, no_set)]
    kind: PhantomVar<GString>,
    #[var(get = get_label, no_set)]
    label: PhantomVar<GString>,
    #[var(get = get_depth, no_set)]
    depth: PhantomVar<i64>,
    #[var(get = get_visible, no_set)]
    visible: PhantomVar<bool>,
    #[var(get = get_visible_now, no_set)]
    visible_now: PhantomVar<bool>,
    #[var(get = get_locked, no_set)]
    locked: PhantomVar<bool>,
    #[var(get = get_generator, no_set)]
    generator: PhantomVar<GString>,
    #[var(get = get_parent, no_set)]
    parent: PhantomVar<Option<Gd<CadaclysmNode>>>,
    #[var(get = get_children, no_set)]
    children: PhantomVar<Array<Gd<CadaclysmNode>>>,
    #[var(get = get_instance_of, no_set)]
    instance_of: PhantomVar<Option<Gd<CadaclysmNode>>>,
    #[var(get = get_select_as, no_set)]
    select_as: PhantomVar<Option<Gd<CadaclysmNode>>>,
    #[var(get = get_attributes, no_set)]
    attributes: PhantomVar<Array<VarDictionary>>,
    #[var(get = get_can_mesh, no_set)]
    can_mesh: PhantomVar<bool>,
    #[var(get = get_colour, no_set)]
    colour: PhantomVar<Variant>,
    #[var(get = get_transform, no_set)]
    transform: PhantomVar<Transform3D>,
    #[var(get = get_raw_transform, no_set)]
    raw_transform: PhantomVar<PackedFloat64Array>,
    #[var(get = get_bounds, no_set)]
    bounds: PhantomVar<Aabb>,
    #[var(get = get_mesh, no_set)]
    mesh: PhantomVar<Option<Gd<CadaclysmMesh>>>,
    #[var(get = get_surfaces, no_set)]
    surfaces: PhantomVar<Array<VarDictionary>>,
    #[var(get = get_brep, no_set)]
    brep: PhantomVar<Option<Gd<CadaclysmBrep>>>,
    #[var(get = get_edges, no_set)]
    edges: PhantomVar<Option<Gd<CadaclysmPolylines>>>,
    #[var(get = get_edge_colours, no_set)]
    edge_colours: PhantomVar<Array<Variant>>,
    #[var(get = get_curves, no_set)]
    curves: PhantomVar<Option<Gd<CadaclysmPolylines>>>,
    #[var(get = get_isocurves, no_set)]
    isocurves: PhantomVar<Option<Gd<CadaclysmPolylines>>>,
}

impl CadaclysmNode {
    pub(crate) fn wrap(shared: Shared, index: u32) -> Gd<CadaclysmNode> {
        Gd::from_object(CadaclysmNode {
            shared,
            index,
            index_: PhantomVar::default(),
            name: PhantomVar::default(),
            id: PhantomVar::default(),
            kind: PhantomVar::default(),
            label: PhantomVar::default(),
            depth: PhantomVar::default(),
            visible: PhantomVar::default(),
            visible_now: PhantomVar::default(),
            locked: PhantomVar::default(),
            generator: PhantomVar::default(),
            parent: PhantomVar::default(),
            children: PhantomVar::default(),
            instance_of: PhantomVar::default(),
            select_as: PhantomVar::default(),
            attributes: PhantomVar::default(),
            can_mesh: PhantomVar::default(),
            colour: PhantomVar::default(),
            transform: PhantomVar::default(),
            raw_transform: PhantomVar::default(),
            bounds: PhantomVar::default(),
            mesh: PhantomVar::default(),
            surfaces: PhantomVar::default(),
            brep: PhantomVar::default(),
            edges: PhantomVar::default(),
            edge_colours: PhantomVar::default(),
            curves: PhantomVar::default(),
            isocurves: PhantomVar::default(),
        })
    }

    fn with<R>(&self, f: impl FnOnce(sdk::Node<'_>) -> R) -> Option<R> {
        with_node(&self.shared, self.index, f)
    }

    fn text(&self, f: impl FnOnce(sdk::Node<'_>) -> String) -> GString {
        gs(self.with(f).unwrap_or_default())
    }

    fn other(&self, f: impl FnOnce(sdk::Node<'_>) -> Option<u32>) -> Option<Gd<CadaclysmNode>> {
        self.with(f).flatten().map(|i| CadaclysmNode::wrap(self.shared.clone(), i))
    }

    fn polylines(&self, f: impl FnOnce(sdk::Node<'_>) -> sdk::Polylines<'_>) -> Option<Gd<CadaclysmPolylines>> {
        self.with(|n| CadaclysmPolylines::copy(&f(n)))
    }

    /// `fem_mesh` and `fem_mesh_placed`, which differ only in the placement: neither
    /// `tolerance` nor `max_size` is checked here -- see `fem_mesh`'s own doc.
    fn built_fem_mesh(&self, tolerance: f64, max_size: f64, placement: Option<[f64; 16]>) -> Option<Gd<CadaclysmFemMesh>> {
        let built = self.with(|n| ok(n.fem_mesh(tolerance, max_size, placement.as_ref()))).flatten()?;
        Some(CadaclysmFemMesh::wrap(built))
    }
}

#[godot_api]
impl CadaclysmNode {
    /// Its index in the scene, from zero.
    #[func]
    fn get_index(&self) -> i64 {
        self.index as i64
    }

    #[func]
    fn get_name(&self) -> GString {
        self.text(|n| n.name())
    }

    /// The id the file gave it (`#42`, a GUID...).
    #[func]
    fn get_id(&self) -> GString {
        self.text(|n| n.id())
    }

    /// What it is, in the file's own words: `IfcWall`, `PRODUCT`, `Brep`...
    #[func]
    fn get_kind(&self) -> GString {
        self.text(|n| n.kind())
    }

    /// What to call it in a tree view: its name, or its kind where it has none.
    #[func]
    fn get_label(&self) -> GString {
        self.text(|n| n.label())
    }

    #[func]
    fn get_depth(&self) -> i64 {
        self.with(|n| n.depth() as i64).unwrap_or_default()
    }

    #[func]
    fn get_visible(&self) -> bool {
        self.with(|n| n.visible()).unwrap_or_default()
    }

    /// Visible, and every ancestor visible too.
    #[func]
    fn get_visible_now(&self) -> bool {
        self.with(|n| n.visible_now()).unwrap_or_default()
    }

    #[func]
    fn get_locked(&self) -> bool {
        self.with(|n| n.locked()).unwrap_or_default()
    }

    /// The program that wrote the part, where the file says.
    #[func]
    fn get_generator(&self) -> GString {
        self.text(|n| n.generator())
    }

    #[func]
    fn get_parent(&self) -> Option<Gd<CadaclysmNode>> {
        self.other(|n| n.parent().map(|p| p.index()))
    }

    #[func]
    fn get_children(&self) -> Array<Gd<CadaclysmNode>> {
        let indices = self.with(|n| n.children().iter().map(|c| c.index()).collect::<Vec<_>>()).unwrap_or_default();
        indices.into_iter().map(|i| CadaclysmNode::wrap(self.shared.clone(), i)).collect()
    }

    /// The definition this node draws a copy of, where it is an instance.
    #[func]
    fn get_instance_of(&self) -> Option<Gd<CadaclysmNode>> {
        self.other(|n| n.instance_of().map(|p| p.index()))
    }

    /// The node a click on this one should select.
    #[func]
    fn get_select_as(&self) -> Option<Gd<CadaclysmNode>> {
        self.other(|n| Some(n.select_as().index()))
    }

    /// What the file says about it, as `{name, kind, value, text}` dictionaries.
    #[func]
    fn get_attributes(&self) -> Array<VarDictionary> {
        self.with(|n| n.attributes().iter().map(attribute).collect()).unwrap_or_default()
    }

    /// Whether it has geometry to mesh.
    #[func]
    fn get_can_mesh(&self) -> bool {
        self.with(|n| n.can_mesh()).unwrap_or_default()
    }

    /// Its colour, or `null` where the file paints it none.
    #[func]
    fn get_colour(&self) -> Variant {
        match self.with(|n| n.colour()).flatten() {
            Some(c) => Color::from_rgba(c[0], c[1], c[2], c[3]).to_variant(),
            None => Variant::nil(),
        }
    }

    /// Where it sits in the scene.
    #[func]
    fn get_transform(&self) -> Transform3D {
        self.with(|n| transform(n.raw_transform())).unwrap_or(Transform3D::IDENTITY)
    }

    /// The same, as sixteen doubles, column-major.
    #[func]
    fn get_raw_transform(&self) -> PackedFloat64Array {
        self.with(|n| PackedFloat64Array::from(&n.raw_transform()[..])).unwrap_or_default()
    }

    /// Its box, in the scene's space.
    #[func]
    fn get_bounds(&self) -> Aabb {
        self.with(|n| bounds(n.bounds())).unwrap_or_default()
    }

    /// Its triangles, copied out (the first call meshes it). `array_mesh()` builds
    /// Godot's mesh without the intermediate copy.
    #[func]
    fn get_mesh(&self) -> Option<Gd<CadaclysmMesh>> {
        self.with(|n| CadaclysmMesh::wrap(n.mesh().copy()))
    }

    /// Its faces as surfaces and trim loops, as dictionaries: `kind`, `kind_name`,
    /// `origin`, `ax`, `ay`, `az`, `domain`, `scalars`, `loops`, `profile`, `nurbs`...
    #[func]
    fn get_surfaces(&self) -> Array<VarDictionary> {
        self.with(|n| n.surfaces().iter().map(face).collect()).unwrap_or_default()
    }

    /// Its exact B-rep, or `null` where it has none; `CadaclysmSolid.from_node` takes it into
    /// the kernel.
    #[func]
    fn get_brep(&self) -> Option<Gd<CadaclysmBrep>> {
        let brep = self.with(|n| n.brep()).flatten()?;
        Some(Gd::from_object(CadaclysmBrep { brep: RefCell::new(Some(brep)) }))
    }

    /// Its feature edges, as polylines.
    #[func]
    fn get_edges(&self) -> Option<Gd<CadaclysmPolylines>> {
        self.polylines(|n| n.edges())
    }

    /// One `Color` per polyline of `edges`, `null` for an edge the file does not style;
    /// empty when nothing is styled.
    #[func]
    fn get_edge_colours(&self) -> Array<Variant> {
        self.with(|n| n.edge_colours())
            .unwrap_or_default()
            .into_iter()
            .map(|c| match c {
                Some([r, g, b, a]) => Color::from_rgba(r, g, b, a).to_variant(),
                None => Variant::nil(),
            })
            .collect()
    }

    /// Its free curves (sketches, wires, axes), as polylines.
    #[func]
    fn get_curves(&self) -> Option<Gd<CadaclysmPolylines>> {
        self.polylines(|n| n.curves())
    }

    /// Its faces' isocurves, as polylines.
    #[func]
    fn get_isocurves(&self) -> Option<Gd<CadaclysmPolylines>> {
        self.polylines(|n| n.isocurves())
    }

    /// This node's own wireframe as SVG text, in its own frame -- `CadaclysmScene.svg_text`'s
    /// options, one `<g id="node-<index>">`, no placement. `""` on a refused option;
    /// `Cadaclysm.last_error()` says why.
    #[func]
    fn svg_text(&self) -> GString {
        self.svg_text_with(VarDictionary::new())
    }

    /// `svg_text`, with options: see `CadaclysmScene.svg_text_with`.
    #[func]
    fn svg_text_with(&self, options: VarDictionary) -> GString {
        let Some(opts) = svg_options(&options) else { return GString::new() };
        gs(self.with(|n| ok(n.svg_text(&opts))).flatten().unwrap_or_default())
    }

    /// `svg_text` written to `path` by the library itself.
    #[func]
    fn svg(&self, path: GString) -> bool {
        self.svg_with(path, VarDictionary::new())
    }

    /// `svg`, with options: see `CadaclysmScene.svg_text_with`.
    #[func]
    fn svg_with(&self, path: GString, options: VarDictionary) -> bool {
        let Some(opts) = svg_options(&options) else { return false };
        self.with(|n| ok(n.svg(os_path(&path), &opts))).flatten().is_some()
    }

    /// This node and every node under it, depth first.
    #[func]
    fn walk(&self) -> Array<Gd<CadaclysmNode>> {
        let indices = self.with(|n| n.walk().map(|c| c.index()).collect::<Vec<_>>()).unwrap_or_default();
        indices.into_iter().map(|i| CadaclysmNode::wrap(self.shared.clone(), i)).collect()
    }

    /// Write its triangles: `"stl"`, `"obj"`, `"glb"`... (`Cadaclysm.mesh_formats()`).
    #[func]
    fn save_mesh(&self, path: GString, format: GString) -> bool {
        self.with(|n| ok(n.save_mesh(os_path(&path), &format.to_string()))).flatten().is_some()
    }

    /// Its triangles as an `ArrayMesh`, in its own frame, wound for Godot, painted its
    /// own colour (or grey). `null` where it has none.
    #[func]
    fn array_mesh(&self) -> Option<Gd<ArrayMesh>> {
        let built = self.with(|n| {
            let mesh = n.mesh();
            meshes::triangles(&mesh).map(|m| (m, n.colour(), mesh.colors.is_some()))
        })?;
        let (mut mesh, colour, vertex) = built?;
        mesh.surface_set_material(0, &meshes::material_for(colour, vertex));
        clear_error();
        Some(mesh)
    }

    /// This node's body meshed for a solver, as a `CadaclysmFemMesh`: nodes welded by
    /// bits, triangles wound outward, every node tagged with the lowest-dimension B-rep
    /// entity it lies on, and every crack reported rather than closed. `null` for a node
    /// with neither a B-rep nor a mesh, or a body the mesher refuses;
    /// `Cadaclysm.last_error()` says which.
    ///
    /// `tolerance` is how far the mesh may stray from the exact surface, in the body's
    /// own units, and `max_size` an upper bound on element size (`0` for none). **Both
    /// default to `FemOptions::default()`'s own figures, `0.01` and `0`** -- not to the
    /// `0.05` that `CadaclysmSolid.mesh` and `edge_polylines` take. Neither is checked
    /// here: a body with no B-rep goes down a path that reads no options at all, where
    /// even a tolerance of `0` returns a mesh, so both go through as given and the
    /// library refuses what it will not take, in its own words.
    /// `CadaclysmFemMesh.longest_edge` is what the mesh actually came to.
    ///
    /// `fem_mesh_placed` is the same call with a placement, which `fem_mesh` leaves out:
    /// a `Transform3D`, or **sixteen** numbers column-major (a `PackedFloat64Array` or an
    /// array, which keep a double where a `Transform3D` holds floats). It is a second
    /// entry point rather than a third argument because Godot has no null default for
    /// one. The kernel's `CadaclysmSolid.fem_mesh_placed` takes a frame's **twelve**
    /// instead, so a caller moving between the two reformats it; the length is checked
    /// here, the ABI being handed only a pointer.
    ///
    /// **Which space the mesh is in depends on where it came from**, which
    /// `CadaclysmFemMesh.from_mesh` is the flag for: a B-rep body's mesh is in the file's
    /// own units and axes whatever convention the scene was opened with, while a node with
    /// no B-rep falls back to the scene's own triangles, which **are** converted. Under
    /// Godot's default y-up those are two different spaces.
    ///
    /// **A cracked body is not a failure**: it comes back with
    /// `CadaclysmFemMesh.watertight` false and its cracks in
    /// `CadaclysmFemMesh.open_edges` and `folded_edges`, and nothing is welded shut to
    /// make it look sound.
    ///
    /// **The unlicensed notice is printed here**, once, and on neither of the two `.msh`
    /// calls -- where the kernel library is the other way round.
    #[func]
    fn fem_mesh(&self, #[opt(default = 0.01)] tolerance: f64, #[opt(default = 0.0)] max_size: f64) -> Option<Gd<CadaclysmFemMesh>> {
        self.built_fem_mesh(tolerance, max_size, None)
    }

    /// `fem_mesh`, placed: a `Transform3D`, or sixteen numbers column-major. See there.
    #[func]
    fn fem_mesh_placed(&self, tolerance: f64, max_size: f64, placement: Variant) -> Option<Gd<CadaclysmFemMesh>> {
        let matrix = placement16(&placement, "fem_mesh_placed: placement")?;
        self.built_fem_mesh(tolerance, max_size, Some(matrix))
    }

    /// Its edges (and free curves) as a `lines` `ArrayMesh`, in its own frame; `null`
    /// where it has none.
    #[func]
    fn edge_mesh(&self, #[opt(default = Color::from_rgb(0.07, 0.07, 0.08))] colour: Color) -> Option<Gd<ArrayMesh>> {
        let built = self.with(|n| meshes::lines(&[n.edges(), n.curves()], None))?;
        let mut mesh = built?;
        mesh.surface_set_material(0, &meshes::edge_material(colour));
        Some(mesh)
    }
}

// ---- CadaclysmPlacement ------------------------------------------------------------------

/// One drawing of one node's geometry, at one place. A node is not a drawing: a
/// block's members draw once per placement of the block.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmPlacement {
    shared: Shared,
    index: u32,
    #[var(rename = index, get = get_index, no_set)]
    index_: PhantomVar<i64>,
    #[var(get = get_geometry, no_set)]
    geometry: PhantomVar<Option<Gd<CadaclysmNode>>>,
    #[var(get = get_select, no_set)]
    select: PhantomVar<Option<Gd<CadaclysmNode>>>,
    #[var(get = get_transform, no_set)]
    transform: PhantomVar<Transform3D>,
    #[var(get = get_raw_transform, no_set)]
    raw_transform: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmPlacement {
    fn wrap(shared: Shared, index: u32) -> Gd<CadaclysmPlacement> {
        Gd::from_object(CadaclysmPlacement {
            shared,
            index,
            index_: PhantomVar::default(),
            geometry: PhantomVar::default(),
            select: PhantomVar::default(),
            transform: PhantomVar::default(),
            raw_transform: PhantomVar::default(),
        })
    }

    fn with<R>(&self, f: impl FnOnce(&sdk::Placement<'_>) -> R) -> Option<R> {
        with_scene(&self.shared, |s| s.placements().get(self.index as usize).map(f)).flatten()
    }
}

#[godot_api]
impl CadaclysmPlacement {
    #[func]
    fn get_index(&self) -> i64 {
        self.index as i64
    }

    /// The node whose geometry this draws.
    #[func]
    fn get_geometry(&self) -> Option<Gd<CadaclysmNode>> {
        self.with(|p| p.geometry().index()).map(|i| CadaclysmNode::wrap(self.shared.clone(), i))
    }

    /// The node a click on this drawing selects.
    #[func]
    fn get_select(&self) -> Option<Gd<CadaclysmNode>> {
        self.with(|p| p.select().index()).map(|i| CadaclysmNode::wrap(self.shared.clone(), i))
    }

    /// Where the geometry is drawn: a `MeshInstance3D`'s `transform`.
    #[func]
    fn get_transform(&self) -> Transform3D {
        self.with(|p| transform(p.raw_transform())).unwrap_or(Transform3D::IDENTITY)
    }

    #[func]
    fn get_raw_transform(&self) -> PackedFloat64Array {
        self.with(|p| PackedFloat64Array::from(&p.raw_transform()[..])).unwrap_or_default()
    }
}

// ---- CadaclysmLink -----------------------------------------------------------------------

/// A rigid body of the file's mechanism: the nodes that move together when a joint
/// moves it. From `CadaclysmScene.links`.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmLink {
    shared: Shared,
    index: u32,
    #[var(rename = index, get = get_index, no_set)]
    index_: PhantomVar<i64>,
    #[var(get = get_name, no_set)]
    name: PhantomVar<GString>,
    #[var(get = get_nodes, no_set)]
    nodes: PhantomVar<Array<Gd<CadaclysmNode>>>,
}

impl CadaclysmLink {
    fn wrap(shared: Shared, index: u32) -> Gd<CadaclysmLink> {
        Gd::from_object(CadaclysmLink {
            shared,
            index,
            index_: PhantomVar::default(),
            name: PhantomVar::default(),
            nodes: PhantomVar::default(),
        })
    }

    fn with<R>(&self, f: impl FnOnce(&sdk::Link<'_>) -> R) -> Option<R> {
        with_scene(&self.shared, |s| s.links().get(self.index as usize).map(f)).flatten()
    }
}

#[godot_api]
impl CadaclysmLink {
    #[func]
    fn get_index(&self) -> i64 {
        self.index as i64
    }

    /// The link's name as the file gives it.
    #[func]
    fn get_name(&self) -> GString {
        gs(self.with(|l| l.name()).unwrap_or_default())
    }

    /// The topmost node of each subtree this link moves, in node order: moving these
    /// moves everything under them.
    #[func]
    fn get_nodes(&self) -> Array<Gd<CadaclysmNode>> {
        self.with(|l| l.nodes().iter().map(|n| n.index()).collect::<Vec<u32>>())
            .unwrap_or_default()
            .into_iter()
            .map(|i| CadaclysmNode::wrap(self.shared.clone(), i))
            .collect()
    }
}

// ---- CadaclysmJoint ----------------------------------------------------------------------

/// A connection between two links of the file's mechanism. Topology only: how it
/// moves is not read yet. From `CadaclysmScene.joints`.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmJoint {
    shared: Shared,
    index: u32,
    #[var(rename = index, get = get_index, no_set)]
    index_: PhantomVar<i64>,
    #[var(get = get_name, no_set)]
    name: PhantomVar<GString>,
    #[var(get = get_start, no_set)]
    start: PhantomVar<Option<Gd<CadaclysmLink>>>,
    #[var(get = get_end, no_set)]
    end: PhantomVar<Option<Gd<CadaclysmLink>>>,
}

impl CadaclysmJoint {
    fn wrap(shared: Shared, index: u32) -> Gd<CadaclysmJoint> {
        Gd::from_object(CadaclysmJoint {
            shared,
            index,
            index_: PhantomVar::default(),
            name: PhantomVar::default(),
            start: PhantomVar::default(),
            end: PhantomVar::default(),
        })
    }

    fn with<R>(&self, f: impl FnOnce(&sdk::Joint<'_>) -> R) -> Option<R> {
        with_scene(&self.shared, |s| s.joints().get(self.index as usize).map(f)).flatten()
    }
}

#[godot_api]
impl CadaclysmJoint {
    #[func]
    fn get_index(&self) -> i64 {
        self.index as i64
    }

    /// The joint's name as the file gives it.
    #[func]
    fn get_name(&self) -> GString {
        gs(self.with(|j| j.name()).unwrap_or_default())
    }

    /// The link this joint starts at, in the file's order -- not a parent: a
    /// mechanism may be a network with loops.
    #[func]
    fn get_start(&self) -> Option<Gd<CadaclysmLink>> {
        self.with(|j| j.start().index()).map(|i| CadaclysmLink::wrap(self.shared.clone(), i))
    }

    /// The link this joint ends at, in the file's order.
    #[func]
    fn get_end(&self) -> Option<Gd<CadaclysmLink>> {
        self.with(|j| j.end().index()).map(|i| CadaclysmLink::wrap(self.shared.clone(), i))
    }
}

// ---- CadaclysmMesh -----------------------------------------------------------------------

/// A node's triangles, copied out of the scene: they outlive it.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmMesh {
    data: sdk::MeshData,
    #[var(get = get_positions, no_set)]
    positions: PhantomVar<PackedVector3Array>,
    #[var(get = get_normals, no_set)]
    normals: PhantomVar<PackedVector3Array>,
    #[var(get = get_uvs, no_set)]
    uvs: PhantomVar<PackedVector2Array>,
    #[var(get = get_colors, no_set)]
    colors: PhantomVar<PackedColorArray>,
    #[var(get = get_indices, no_set)]
    indices: PhantomVar<PackedInt32Array>,
    #[var(get = get_vertex_count, no_set)]
    vertex_count: PhantomVar<i64>,
    #[var(get = get_index_count, no_set)]
    index_count: PhantomVar<i64>,
    #[var(get = get_triangle_count, no_set)]
    triangle_count: PhantomVar<i64>,
    #[var(get = get_is_empty, no_set)]
    is_empty: PhantomVar<bool>,
}

impl CadaclysmMesh {
    pub(crate) fn wrap(data: sdk::MeshData) -> Gd<CadaclysmMesh> {
        Gd::from_object(CadaclysmMesh {
            data,
            positions: PhantomVar::default(),
            normals: PhantomVar::default(),
            uvs: PhantomVar::default(),
            colors: PhantomVar::default(),
            indices: PhantomVar::default(),
            vertex_count: PhantomVar::default(),
            index_count: PhantomVar::default(),
            triangle_count: PhantomVar::default(),
            is_empty: PhantomVar::default(),
        })
    }

    fn view(&self) -> sdk::Mesh<'_> {
        sdk::Mesh {
            positions: &self.data.positions,
            normals: self.data.normals.as_deref(),
            uvs: self.data.uvs.as_deref(),
            colors: self.data.colors.as_deref(),
            indices: &self.data.indices,
        }
    }
}

#[godot_api]
impl CadaclysmMesh {
    #[func]
    fn get_positions(&self) -> PackedVector3Array {
        meshes::points(&self.data.positions)
    }

    /// Empty where the mesh has none.
    #[func]
    fn get_normals(&self) -> PackedVector3Array {
        self.data.normals.as_deref().map(meshes::points).unwrap_or_default()
    }

    /// Empty where the mesh has none (open with `uv_world`).
    #[func]
    fn get_uvs(&self) -> PackedVector2Array {
        self.data.uvs.as_deref().map(meshes::uvs).unwrap_or_default()
    }

    /// Empty where the mesh has none (open with `colors`).
    #[func]
    fn get_colors(&self) -> PackedColorArray {
        self.data.colors.as_deref().map(meshes::colors).unwrap_or_default()
    }

    /// Three to a triangle, wound counter-clockwise as the library produces them;
    /// `to_array_mesh` turns them round for Godot.
    #[func]
    fn get_indices(&self) -> PackedInt32Array {
        self.data.indices.iter().map(|&i| i as i32).collect()
    }

    #[func]
    fn get_vertex_count(&self) -> i64 {
        self.data.positions.len() as i64
    }

    #[func]
    fn get_index_count(&self) -> i64 {
        self.data.indices.len() as i64
    }

    #[func]
    fn get_triangle_count(&self) -> i64 {
        self.data.indices.len() as i64 / 3
    }

    #[func]
    fn get_is_empty(&self) -> bool {
        self.view().is_empty()
    }

    /// These triangles as an `ArrayMesh` wound for Godot; `null` when there are none.
    #[func]
    fn to_array_mesh(&self) -> Option<Gd<ArrayMesh>> {
        let mut mesh = meshes::triangles(&self.view())?;
        mesh.surface_set_material(0, &meshes::material_for(None, self.data.colors.is_some()));
        Some(mesh)
    }
}

// ---- CadaclysmPolylines ------------------------------------------------------------------

/// Edges or curves flattened to points: `positions` holds the runs end to end and
/// `counts` says how long each is. Copied out of the scene.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmPolylines {
    positions: Vec<[f32; 3]>,
    counts: Vec<u32>,
    #[var(rename = positions, get = get_positions, no_set)]
    positions_: PhantomVar<PackedVector3Array>,
    #[var(rename = counts, get = get_counts, no_set)]
    counts_: PhantomVar<PackedInt32Array>,
    #[var(get = get_polyline_count, no_set)]
    polyline_count: PhantomVar<i64>,
    #[var(get = get_vertex_count, no_set)]
    vertex_count: PhantomVar<i64>,
    #[var(get = get_is_empty, no_set)]
    is_empty: PhantomVar<bool>,
}

impl CadaclysmPolylines {
    pub(crate) fn from_runs(positions: Vec<[f32; 3]>, counts: Vec<u32>) -> Gd<CadaclysmPolylines> {
        Gd::from_object(CadaclysmPolylines {
            positions,
            counts,
            positions_: PhantomVar::default(),
            counts_: PhantomVar::default(),
            polyline_count: PhantomVar::default(),
            vertex_count: PhantomVar::default(),
            is_empty: PhantomVar::default(),
        })
    }

    fn copy(lines: &sdk::Polylines<'_>) -> Gd<CadaclysmPolylines> {
        CadaclysmPolylines::from_runs(lines.positions.to_vec(), lines.counts.to_vec())
    }

    fn view(&self) -> sdk::Polylines<'_> {
        sdk::Polylines { positions: &self.positions, counts: &self.counts }
    }
}

#[godot_api]
impl CadaclysmPolylines {
    #[func]
    fn get_positions(&self) -> PackedVector3Array {
        meshes::points(&self.positions)
    }

    #[func]
    fn get_counts(&self) -> PackedInt32Array {
        self.counts.iter().map(|&c| c as i32).collect()
    }

    #[func]
    fn get_polyline_count(&self) -> i64 {
        self.counts.len() as i64
    }

    #[func]
    fn get_vertex_count(&self) -> i64 {
        self.positions.len() as i64
    }

    #[func]
    fn get_is_empty(&self) -> bool {
        self.view().is_empty()
    }

    /// Each run as its own array of points.
    #[func]
    fn runs(&self) -> Array<PackedVector3Array> {
        self.view().iter().map(meshes::points).collect()
    }

    /// Every segment as a pair of points, end to end: `ImmediateMesh` or
    /// `draw_multiline` food.
    #[func]
    fn segments(&self) -> PackedVector3Array {
        meshes::points(&self.view().segments())
    }

    /// The same segments as index pairs into `positions`.
    #[func]
    fn segment_indices(&self) -> PackedInt32Array {
        self.view().segment_indices().iter().map(|&i| i as i32).collect()
    }

    /// These lines as a `lines` `ArrayMesh`, unshaded in `colour`; `null` when empty.
    #[func]
    fn to_array_mesh(&self, #[opt(default = Color::from_rgb(0.07, 0.07, 0.08))] colour: Color) -> Option<Gd<ArrayMesh>> {
        let mut mesh = meshes::lines(&[self.view()], None)?;
        mesh.surface_set_material(0, &meshes::edge_material(colour));
        Some(mesh)
    }
}

// ---- CadaclysmBrep -----------------------------------------------------------------------

/// A node's exact B-rep, shared with its scene rather than copied, and kept alive by
/// this object even after the scene closes. `CadaclysmSolid.from_node` takes a node's into
/// the kernel.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmBrep {
    brep: RefCell<Option<sdk::Brep>>,
}

impl CadaclysmBrep {
    fn with<R>(&self, f: impl FnOnce(&sdk::Brep) -> R) -> Option<R> {
        match self.brep.borrow().as_ref() {
            Some(brep) => Some(f(brep)),
            None => fail("the B-rep was released"),
        }
    }
}

#[godot_api]
impl CadaclysmBrep {
    /// The layout the reader's B-reps are in; the kernel refuses a different one.
    #[func]
    fn layout_id() -> GString {
        gs(ok(sdk::Brep::layout_id()).unwrap_or_default())
    }

    /// The raw `const CadaclysmBrep *`, for another native library.
    #[func]
    fn pointer(&self) -> i64 {
        self.with(|b| b.pointer() as i64).unwrap_or_default()
    }

    /// Whether its faces make a manifold: `{faces, edges, vertices, boundary_edges,
    /// non_manifold_edges, non_manifold_vertices, is_manifold, is_closed}`.
    #[func]
    fn manifold(&self) -> VarDictionary {
        self.with(|b| ok(b.manifold()).map(manifold)).flatten().unwrap_or_default()
    }

    /// Hand the B-rep back now.
    #[func]
    fn release(&self) {
        self.brep.borrow_mut().take();
    }
}

// ---- CadaclysmFemMesh --------------------------------------------------------------------

/// One body meshed for a solver: nodes welded by bits, triangles wound outward, every
/// node tagged with the lowest-dimension B-rep entity it lies on, and every crack
/// reported rather than closed. What `CadaclysmNode.fem_mesh` returns.
///
/// **A handle of its own, and it owns the library memory it reads from.** A
/// `CadaclysmScene.close` neither frees it nor stales it, so it outlives the scene it was
/// built through -- the one thing in this extension that does. `release()` hands it back
/// early; letting the last reference go does the same.
///
/// **Every array here is a copy**, as `CadaclysmMesh`'s and `CadaclysmPolylines`' are:
/// Godot's packed arrays have nowhere to point into the library's memory, so one already
/// in hand cannot go stale and needs no `copy()`. The price runs the other way -- each ask
/// copies again -- so hold the array rather than reading `nodes` inside a loop.
///
/// `nodes` and a vertex's `point` come over as **doubles**, not `Vector3`s: what a solver
/// wants is the f64 the library computed, and Godot's `Vector3` holds floats.
///
/// ```gdscript
/// var mesh := node.fem_mesh(0.01)
/// print(mesh.nodes.size() / 3, " nodes, watertight: ", mesh.watertight)
/// mesh.save_msh("user://part.msh")
/// mesh.release()
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmFemMesh {
    mesh: RefCell<Option<sdk::FemMesh>>,
    #[var(get = get_nodes, no_set)]
    nodes: PhantomVar<PackedFloat64Array>,
    #[var(get = get_triangles, no_set)]
    triangles: PhantomVar<PackedInt32Array>,
    #[var(get = get_triangle_face, no_set)]
    triangle_face: PhantomVar<PackedInt32Array>,
    #[var(get = get_node_kind, no_set)]
    node_kind: PhantomVar<PackedInt32Array>,
    #[var(get = get_node_entity, no_set)]
    node_entity: PhantomVar<PackedInt32Array>,
    #[var(get = get_face_count, no_set)]
    face_count: PhantomVar<i64>,
    #[var(get = get_edges, no_set)]
    edges: PhantomVar<Array<VarDictionary>>,
    #[var(get = get_vertices, no_set)]
    vertices: PhantomVar<Array<VarDictionary>>,
    #[var(get = get_open_edges, no_set)]
    open_edges: PhantomVar<Array<PackedInt64Array>>,
    #[var(get = get_folded_edges, no_set)]
    folded_edges: PhantomVar<Array<PackedInt64Array>>,
    #[var(get = get_watertight, no_set)]
    watertight: PhantomVar<bool>,
    #[var(get = get_from_mesh, no_set)]
    from_mesh: PhantomVar<bool>,
    #[var(get = get_min_angle, no_set)]
    min_angle: PhantomVar<f64>,
    #[var(get = get_worst_triangle, no_set)]
    worst_triangle: PhantomVar<i64>,
    #[var(get = get_longest_edge, no_set)]
    longest_edge: PhantomVar<f64>,
    #[var(get = get_released, no_set)]
    released: PhantomVar<bool>,
}

impl CadaclysmFemMesh {
    fn wrap(mesh: sdk::FemMesh) -> Gd<CadaclysmFemMesh> {
        Gd::from_object(CadaclysmFemMesh {
            mesh: RefCell::new(Some(mesh)),
            nodes: PhantomVar::default(),
            triangles: PhantomVar::default(),
            triangle_face: PhantomVar::default(),
            node_kind: PhantomVar::default(),
            node_entity: PhantomVar::default(),
            face_count: PhantomVar::default(),
            edges: PhantomVar::default(),
            vertices: PhantomVar::default(),
            open_edges: PhantomVar::default(),
            folded_edges: PhantomVar::default(),
            watertight: PhantomVar::default(),
            from_mesh: PhantomVar::default(),
            min_angle: PhantomVar::default(),
            worst_triangle: PhantomVar::default(),
            longest_edge: PhantomVar::default(),
            released: PhantomVar::default(),
        })
    }

    /// `f` on the mesh, its answer **by value**: the SDK lends its arrays from the handle,
    /// so a getter copies inside the closure and the borrow ends with it -- which is what
    /// lets every accessor here hand back a Godot array of its own. `CadaclysmBrep::with`
    /// is the same shape over the same kind of handle.
    fn with<R>(&self, f: impl FnOnce(&sdk::FemMesh) -> R) -> Option<R> {
        match self.mesh.borrow().as_ref() {
            Some(mesh) => Some(f(mesh)),
            None => fail("the FEM mesh was released"),
        }
    }
}

#[godot_api]
impl IRefCounted for CadaclysmFemMesh {
    fn to_string(&self) -> GString {
        let text = self.with(|m| {
            format!("FemMesh(nodes={}, triangles={}, watertight={}, from_mesh={})", m.nodes().len(), m.triangles().len(), m.watertight(), m.from_mesh())
        });
        // The only `to_string` in this module that clears the error, and deliberately:
        // `with` on a released handle reports "released" through `fail`, so `print(mesh)`
        // would leave an error no call of the caller's own made. The cost is that
        // `print(mesh)` also clears an error left by an earlier call, which the module's
        // other `to_string`s do not -- read `Cadaclysm.last_error()` before printing.
        clear_error();
        gs(text.unwrap_or_else(|| "FemMesh(released)".to_string()))
    }
}

#[godot_api]
impl CadaclysmFemMesh {
    /// Every node's position, three doubles a node, placed by `CadaclysmNode.fem_mesh`'s
    /// placement and in the space `from_mesh` names. Every node is used by at least one
    /// triangle.
    #[func]
    fn get_nodes(&self) -> PackedFloat64Array {
        self.with(|m| fem_nodes(m.nodes())).unwrap_or_default()
    }

    /// Three node indices a triangle, wound outward -- a mirroring placement is wound
    /// back. Not turned round for Godot: these are a solver's triangles, not a mesh to
    /// draw.
    #[func]
    fn get_triangles(&self) -> PackedInt32Array {
        self.with(|m| fem_triangles(m.triangles())).unwrap_or_default()
    }

    /// Which B-rep face each triangle lies on, one per triangle, into the body's
    /// `face_count` faces.
    #[func]
    fn get_triangle_face(&self) -> PackedInt32Array {
        self.with(|m| fem_indices(m.triangle_face())).unwrap_or_default()
    }

    /// What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per
    /// node: the lowest-dimension entity it lies on, which is the `.msh` format's own
    /// classification rule. `node_entity` says which entity of that kind.
    #[func]
    fn get_node_kind(&self) -> PackedInt32Array {
        self.with(|m| fem_indices(m.node_kind())).unwrap_or_default()
    }

    /// Which vertex, edge or face each node lies on, read by the matching `node_kind`: an
    /// index into `vertices`, into `edges`, or into the body's faces.
    #[func]
    fn get_node_entity(&self) -> PackedInt32Array {
        self.with(|m| fem_indices(m.node_entity())).unwrap_or_default()
    }

    /// The body's faces; `triangle_face` and a `node_kind` of `2` index them. **The same
    /// faces `CadaclysmNode.surfaces` hands over**, in the same order.
    #[func]
    fn get_face_count(&self) -> i64 {
        self.with(|m| i64::from(m.face_count())).unwrap_or_default()
    }

    /// One Dictionary per B-rep edge -- `id`, `nodes`, `runs`, `faces`, `ends`, `closed`,
    /// `seam` -- in the order a `node_kind` of `1` indexes them. Empty for a `from_mesh`
    /// body, which has no B-rep edges at all. One call to the library per edge, so read it
    /// once into a variable.
    #[func]
    fn get_edges(&self) -> Array<VarDictionary> {
        let rows = self.with(|m| {
            ok(m.edges()).map(|edges| edges.iter().map(|e| fem_edge(e.id, e.nodes, e.runs, e.faces, e.ends, e.closed, e.seam)).collect())
        });
        rows.flatten().unwrap_or_default()
    }

    /// One Dictionary per B-rep vertex -- `node`, `point`, `has_position` -- in the order
    /// a `node_kind` of `0` indexes them. Empty for a `from_mesh` body.
    #[func]
    fn get_vertices(&self) -> Array<VarDictionary> {
        let rows = self.with(|m| ok(m.vertices()).map(|found| found.iter().map(|v| fem_vertex(v.node, v.point, v.has_position)).collect()));
        rows.flatten().unwrap_or_default()
    }

    /// Every crack, as `[a, b, brep_edge]`: a directed mesh edge `(a, b)` with no
    /// `(b, a)`, and the B-rep edge both nodes lie on or `NONE` (4294967295) where they
    /// share none. **Empty unless the body's topology is closed -- for a B-rep body**,
    /// whose mesh is otherwise not asked about at all: such a body reports `watertight`
    /// false with this and `folded_edges` both empty, and that trio together says "not
    /// asked", not "nothing found". A `from_mesh` body is the other case: its census
    /// always runs over the welded triangles, so an empty one there really does mean
    /// nothing found.
    #[func]
    fn get_open_edges(&self) -> Array<PackedInt64Array> {
        self.with(|m| ok(m.open_edges()).map(|rows| fem_census(&rows))).flatten().unwrap_or_default()
    }

    /// Every fold, as `open_edges` reports a crack: a directed mesh edge used by more than
    /// one triangle. **A body can be folded without being open** -- a solid no thicker
    /// than a line leaves no hole for an open edge to find -- so a caller that checks
    /// `open_edges` alone calls such a body sound. Empty under the same rule.
    #[func]
    fn get_folded_edges(&self) -> Array<PackedInt64Array> {
        self.with(|m| ok(m.folded_edges()).map(|rows| fem_census(&rows))).flatten().unwrap_or_default()
    }

    /// The welded mesh closes -- every directed mesh edge paired with its reverse and none
    /// used twice -- and, for a B-rep body, so does the topology behind it. **False for
    /// every B-rep body whose topology is not closed**, whose mesh is then not asked
    /// about; read `open_edges` for what an empty census beside a false here does and does
    /// not mean.
    #[func]
    fn get_watertight(&self) -> bool {
        self.with(|m| m.watertight()).unwrap_or_default()
    }

    /// This came from the scene's own mesh rather than from a B-rep: one face, every node
    /// on face `0`, no edges and no vertices. **It is also which space the mesh is in**,
    /// and which contract the census is reporting under -- see `CadaclysmNode.fem_mesh`.
    #[func]
    fn get_from_mesh(&self) -> bool {
        self.with(|m| m.from_mesh()).unwrap_or_default()
    }

    /// The smallest interior angle of any triangle, in degrees. There is always one: a
    /// body that meshed to no triangles is a refusal, not a mesh.
    #[func]
    fn get_min_angle(&self) -> f64 {
        self.with(|m| m.min_angle()).unwrap_or_default()
    }

    /// The triangle with that angle, as an index into `triangles`.
    #[func]
    fn get_worst_triangle(&self) -> i64 {
        self.with(|m| i64::from(m.worst_triangle())).unwrap_or_default()
    }

    /// The longest triangle edge, placed. **The figure to check against
    /// `CadaclysmNode.fem_mesh`'s `max_size`, and the only one that says what the mesh
    /// actually is**: `max_size` bounds the boundary segments and merely targets the
    /// interior -- measured at 1.03x on a face whose parameters run unevenly -- and one
    /// small enough beside the body to reach the mesher's own ceilings is not honoured at
    /// all.
    #[func]
    fn get_longest_edge(&self) -> f64 {
        self.with(|m| m.longest_edge()).unwrap_or_default()
    }

    /// Whether `release` has run.
    #[func]
    fn get_released(&self) -> bool {
        self.mesh.borrow().is_none()
    }

    /// The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face,
    /// a volume where the body closes, and a physical group naming each. `""` for a mesh
    /// the writer refuses, naming the field it cannot honour, and for a released handle.
    ///
    /// **On this side of the ABI the library's text is borrowed** -- a slot on the handle,
    /// replaced by the next call on it -- and copied out here, so what comes back is
    /// Godot's own. The kernel library's `CadaclysmSolidFemMesh.msh_text` is the other way
    /// round, an owned string its own wrapper releases; a reader porting one side's
    /// reasoning onto the other leaks or double-frees. No unlicensed notice is printed
    /// here or by `save_msh`: `CadaclysmNode.fem_mesh` gave it when the mesh was built.
    #[func]
    fn msh_text(&self) -> GString {
        gs(self.with(|m| ok(m.msh_text())).flatten().unwrap_or_default())
    }

    /// `msh_text` written to `path` by the library itself: the same bytes from the same
    /// writer, straight to the file rather than through the borrowed slot. A `user://` path
    /// works, and `res://` in the editor -- an exported game's `res://` lives inside its
    /// pack, which nothing can write to. False for a mesh the writer refuses or a file it
    /// cannot write.
    #[func]
    fn save_msh(&self, path: GString) -> bool {
        self.with(|m| ok(m.save_msh(os_path(&path)))).flatten().is_some()
    }

    /// Hand the mesh back now rather than when the last reference goes, as
    /// `CadaclysmBrep.release` does. Idempotent; every accessor then fails with
    /// "released". Nothing taken from it goes stale -- every array was a copy.
    #[func]
    fn release(&self) {
        if let Some(mesh) = self.mesh.borrow_mut().take() {
            // By value, as the SDK's `free` takes it: dropping the handle is the free.
            mesh.free();
        }
    }
}
