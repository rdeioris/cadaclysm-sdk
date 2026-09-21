//! The kernel: `CadaclysmBlacksmith` (the library's own functions), `CadaclysmFrame`, `CadaclysmProfile`,
//! `CadaclysmPath`, `CadaclysmSweepPath`, `CadaclysmSolid`, `CadaclysmEdge`, `CadaclysmHit`, `CadaclysmSpot` and
//! `CadaclysmWorkplane`.
//!
//! The kernel works in doubles, in the model's own units (millimetres, as a rule), so
//! every point it takes is a `Variant`: a `Vector2`/`Vector3` (or the `i` kinds), or an
//! `Array`/`PackedFloat64Array` of numbers -- `[1.5, 2.0, 0.0]` keeps a double's
//! precision where a `Vector3` holds floats. What it hands back to draw is Godot's own
//! (`Vector3`, `AABB`, `ArrayMesh`); where precision matters a `raw_*` accessor gives
//! the doubles.
//!
//! A frame -- where a profile is drawn and which way it is built -- is a `CadaclysmFrame`, a
//! `Transform3D` (square axes, no scale), twelve numbers (origin, x, y, z) or four
//! triples.
//!
//! Solids are immutable: every operation returns a new `CadaclysmSolid`, or `null` with the
//! reason in `Cadaclysm.last_error()`.
use cadaclysm_sdk as sdk;
use godot::classes::ArrayMesh;
use godot::obj::GdRef;
use godot::prelude::*;
use sdk::blacksmith as bs;

use crate::meshes;
use crate::reader::{self, CadaclysmMesh, CadaclysmNode, CadaclysmPolylines, CadaclysmScene};
use crate::{clear_error, dict, fail, gs, ok, os_path};

// ---- reading arguments -------------------------------------------------------------

fn number(v: &Variant) -> Option<f64> {
    match v.get_type() {
        VariantType::INT => Some(v.to::<i64>() as f64),
        VariantType::FLOAT => Some(v.to::<f64>()),
        _ => None,
    }
}

/// The numbers a vector, a packed array or an array of numbers holds; with `nested`,
/// an array's elements may themselves be vectors or arrays (four triples for a frame).
fn numbers(v: &Variant, nested: bool) -> Option<Vec<f64>> {
    let f = f64::from;
    match v.get_type() {
        VariantType::VECTOR2 => {
            let p = v.to::<Vector2>();
            Some(vec![f(p.x), f(p.y)])
        }
        VariantType::VECTOR2I => {
            let p = v.to::<Vector2i>();
            Some(vec![p.x.into(), p.y.into()])
        }
        VariantType::VECTOR3 => {
            let p = v.to::<Vector3>();
            Some(vec![f(p.x), f(p.y), f(p.z)])
        }
        VariantType::VECTOR3I => {
            let p = v.to::<Vector3i>();
            Some(vec![p.x.into(), p.y.into(), p.z.into()])
        }
        VariantType::PACKED_FLOAT64_ARRAY => Some(v.to::<PackedFloat64Array>().as_slice().to_vec()),
        VariantType::PACKED_FLOAT32_ARRAY => Some(v.to::<PackedFloat32Array>().as_slice().iter().map(|&x| f(x)).collect()),
        VariantType::PACKED_INT32_ARRAY => Some(v.to::<PackedInt32Array>().as_slice().iter().map(|&x| x.into()).collect()),
        VariantType::PACKED_INT64_ARRAY => Some(v.to::<PackedInt64Array>().as_slice().iter().map(|&x| x as f64).collect()),
        VariantType::ARRAY => {
            let array = v.try_to::<AnyArray>().ok()?;
            let mut out = Vec::with_capacity(array.len());
            for item in array.iter_shared() {
                match number(&item) {
                    Some(x) => out.push(x),
                    None if nested => out.extend(numbers(&item, false)?),
                    None => return None,
                }
            }
            Some(out)
        }
        _ => None,
    }
}

/// `N` numbers from a vector or an array, or a failure naming `what`.
fn point<const N: usize>(v: &Variant, what: &str) -> Option<[f64; N]> {
    let kind = if N == 2 { "a Vector2" } else { "a Vector3" };
    match numbers(v, false) {
        Some(values) if values.len() == N => {
            let mut out = [0.0; N];
            out.copy_from_slice(&values);
            Some(out)
        }
        Some(values) => fail(format!("{what}: expected {N} numbers, got {}", values.len())),
        None => fail(format!("{what}: expected {N} numbers ({kind} or an array), not {v}")),
    }
}

fn v2(v: &Variant, what: &str) -> Option<[f64; 2]> {
    point::<2>(v, what)
}

fn v3(v: &Variant, what: &str) -> Option<[f64; 3]> {
    point::<3>(v, what)
}

/// A list of 2D points: a `PackedVector2Array`, or an array of points.
fn points2(v: &Variant, what: &str) -> Option<Vec<[f64; 2]>> {
    match v.get_type() {
        VariantType::PACKED_VECTOR2_ARRAY => {
            Some(v.to::<PackedVector2Array>().as_slice().iter().map(|p| [f64::from(p.x), f64::from(p.y)]).collect())
        }
        VariantType::ARRAY => {
            let array = v.try_to::<AnyArray>().ok()?;
            array.iter_shared().enumerate().map(|(i, p)| v2(&p, &format!("{what}[{i}]"))).collect()
        }
        _ => fail(format!("{what}: expected a PackedVector2Array or an array of points, not {v}")),
    }
}

/// A list of numbers: an array or a packed array.
fn number_list(v: &Variant, what: &str) -> Option<Vec<f64>> {
    match numbers(v, false) {
        Some(values) => Some(values),
        None => fail(format!("{what}: expected an array of numbers, not {v}")),
    }
}

/// A count or an index from GDScript's `int`, refused where negative.
fn index(i: i64, what: &str) -> Option<u32> {
    match u32::try_from(i) {
        Ok(i) => Some(i),
        Err(_) => fail(format!("{what}: {i} is not an index")),
    }
}

fn packed_indices(list: &PackedInt32Array, what: &str) -> Option<Vec<u32>> {
    list.as_slice().iter().map(|&i| index(i.into(), what)).collect()
}

/// Edge or face indices: `CadaclysmEdge`s or ints, in an array or a packed array.
fn indices(v: &Variant, what: &str) -> Option<Vec<u32>> {
    match v.get_type() {
        VariantType::PACKED_INT32_ARRAY => packed_indices(&v.to::<PackedInt32Array>(), what),
        VariantType::PACKED_INT64_ARRAY => v.to::<PackedInt64Array>().as_slice().iter().map(|&i| index(i, what)).collect(),
        VariantType::ARRAY => {
            let array = v.try_to::<AnyArray>().ok()?;
            let mut out = Vec::with_capacity(array.len());
            for item in array.iter_shared() {
                if item.get_type() == VariantType::INT {
                    out.push(index(item.to::<i64>(), what)?);
                } else if let Ok(edge) = item.try_to::<Gd<CadaclysmEdge>>() {
                    out.push(edge.bind().edge.index);
                } else {
                    return fail(format!("{what}: expected ints or CadaclysmEdges, not {item}"));
                }
            }
            Some(out)
        }
        _ => fail(format!("{what}: expected an array of ints or CadaclysmEdges, not {v}")),
    }
}

/// A frame: a `CadaclysmFrame`, a `Transform3D`, twelve numbers or four triples.
fn frame(v: &Variant, what: &str) -> Option<bs::Frame> {
    if let Ok(frame) = v.try_to::<Gd<CadaclysmFrame>>() {
        return Some(frame.bind().frame);
    }
    if v.get_type() == VariantType::TRANSFORM3D {
        return ok(frame_of_transform(v.to::<Transform3D>()));
    }
    match numbers(v, true) {
        Some(values) if values.len() == 12 => {
            let mut raw = [0.0; 12];
            raw.copy_from_slice(&values);
            ok(bs::Frame::of(raw))
        }
        Some(values) => fail(format!("{what}: expected 12 numbers, got {}", values.len())),
        None => fail(format!("{what}: expected a CadaclysmFrame, a Transform3D or 12 numbers, not {v}")),
    }
}

/// A `Transform3D` as a frame: its basis must be square, right-handed and unscaled
/// (a frame's axes are unit, so a scale would be dropped without a word).
fn frame_of_transform(t: Transform3D) -> Result<bs::Frame, String> {
    let d = |v: Vector3| [f64::from(v.x), f64::from(v.y), f64::from(v.z)];
    let axes = [t.basis.col_a(), t.basis.col_b(), t.basis.col_c()];
    if axes.iter().any(|a| (f64::from(a.length()) - 1.0).abs() > 1e-5) {
        return Err("frame: the transform scales, which a frame cannot follow".to_string());
    }
    bs::Frame::new(d(t.origin), d(axes[0]), d(axes[1]), d(axes[2])).map_err(|e| e.to_string())
}

/// A slant: a number (a flat plane at that height), or `{at, grad}` with `grad` two
/// numbers -- what `CadaclysmBlacksmith.slant_of_plane` returns.
fn slant(v: &Variant, what: &str) -> Option<bs::Slant> {
    if let Some(at) = number(v) {
        return Some(bs::Slant::flat(at));
    }
    let Ok(d) = v.try_to::<VarDictionary>() else {
        return fail(format!("{what}: expected a number or {{at, grad}}, not {v}"));
    };
    let Some(at) = d.get("at").as_ref().and_then(number) else {
        return fail(format!("{what}: {{at, grad}} needs a number at \"at\""));
    };
    let grad = match d.get("grad") {
        Some(g) => v2(&g, &format!("{what}.grad"))?,
        None => [0.0, 0.0],
    };
    Some(bs::Slant { at, grad })
}

/// A face selector: `">Z"`/`"<X"`..., an index, or a normal.
fn selector(v: &Variant, what: &str) -> Option<bs::Selector> {
    match v.get_type() {
        VariantType::INT => Some(bs::Selector::Index(index(v.to::<i64>(), what)?)),
        VariantType::STRING | VariantType::STRING_NAME => {
            let text = v.to_string();
            let t = text.trim();
            let axis = match t.get(1..).map(str::to_ascii_lowercase).as_deref() {
                Some("x") => Some(bs::Axis::X),
                Some("y") => Some(bs::Axis::Y),
                Some("z") => Some(bs::Axis::Z),
                _ => None,
            };
            match (t.chars().next(), axis) {
                (Some('>'), Some(axis)) => Some(bs::Selector::Max(axis)),
                (Some('<'), Some(axis)) => Some(bs::Selector::Min(axis)),
                _ => fail(format!("{what}: a selector is \">X\", \"<Z\"..., a face index or a normal, not {text:?}")),
            }
        }
        _ => Some(bs::Selector::Normal(v3(v, what)?)),
    }
}

fn keep_side(text: &GString) -> Option<bs::Keep> {
    match text.to_string().as_str() {
        "outside" => Some(bs::Keep::Outside),
        "inside" => Some(bs::Keep::Inside),
        other => fail(format!("trim: keep must be 'outside' or 'inside', not '{other}'")),
    }
}

fn step_unit(text: &GString) -> Option<bs::Unit> {
    match text.to_string().as_str() {
        "m" => Some(bs::Unit::Metre),
        "mm" => Some(bs::Unit::Millimetre),
        "in" => Some(bs::Unit::Inch),
        other => fail(format!("unit must be one of m, mm, in, not {other:?}")),
    }
}

/// `""` is none: the kernel's built-in AP203. A `res://` or `user://` path is made the
/// file system's.
fn schema_arg(text: &GString) -> Option<String> {
    let s = text.to_string();
    if s.is_empty() {
        None
    } else if s.starts_with("res://") || s.starts_with("user://") {
        Some(os_path(text))
    } else {
        Some(s)
    }
}

/// A colour: a `Color`, `"#rgb"`/`"#rrggbb"`, or three numbers in 0..1.
fn colour_arg(v: &Variant) -> Option<[f64; 3]> {
    match v.get_type() {
        VariantType::COLOR => {
            let c = v.to::<Color>();
            Some([c.r, c.g, c.b].map(f64::from))
        }
        VariantType::STRING | VariantType::STRING_NAME => ok(bs::rgb(&v.to_string())),
        _ => v3(v, "coloured"),
    }
}

fn colour_out(c: Option<[f64; 3]>) -> Variant {
    match c {
        Some([r, g, b]) => Color::from_rgb(r as f32, g as f32, b as f32).to_variant(),
        None => Variant::nil(),
    }
}

fn vector3(p: [f64; 3]) -> Vector3 {
    Vector3::new(p[0] as f32, p[1] as f32, p[2] as f32)
}

fn aabb(lo: [f64; 3], hi: [f64; 3]) -> Aabb {
    Aabb::new(vector3(lo), vector3(hi) - vector3(lo))
}

/// The objects of class `T` a list holds, or a failure naming the first that is not.
fn object_list<T>(list: &AnyArray, what: &str) -> Option<Vec<Gd<T>>>
where
    T: GodotClass + Inherits<RefCounted>,
{
    list.iter_shared()
        .map(|item| match item.try_to::<Gd<T>>() {
            Ok(object) => Some(object),
            Err(_) => fail(format!("{what}: expected {}s, not {item}", T::class_id())),
        })
        .collect()
}

fn step_text_of(solids: &[&bs::Solid], schema: &GString, unit: &GString) -> Option<String> {
    let unit = step_unit(unit)?;
    let schema = schema_arg(schema);
    ok(bs::write_step_text(solids, schema.as_deref(), unit))
}

fn sat_text_of(solids: &[&bs::Solid], unit: &GString) -> Option<String> {
    let unit = step_unit(unit)?;
    ok(bs::write_sat_text(solids, unit))
}

/// Several solids' SAT text: every one bound for the length of the call.
fn solids_sat_text(solids: &AnyArray, unit: &GString) -> Option<String> {
    let list = object_list::<CadaclysmSolid>(solids, "write_sat")?;
    let guards: Vec<GdRef<CadaclysmSolid>> = list.iter().map(|s| s.bind()).collect();
    let held: Vec<&bs::Solid> = guards.iter().map(|g| g.held()).collect::<Option<_>>()?;
    sat_text_of(&held, unit)
}

fn write_text(path: &GString, text: String) -> bool {
    let file = os_path(path);
    ok(std::fs::write(&file, text).map_err(|e| format!("{file}: {e}"))).is_some()
}

/// Several solids' STEP text: every one bound for the length of the call.
fn solids_step_text(solids: &AnyArray, schema: &GString, unit: &GString) -> Option<String> {
    let list = object_list::<CadaclysmSolid>(solids, "write_step")?;
    let guards: Vec<GdRef<CadaclysmSolid>> = list.iter().map(|s| s.bind()).collect();
    let held: Vec<&bs::Solid> = guards.iter().map(|g| g.held()).collect::<Option<_>>()?;
    step_text_of(&held, schema, unit)
}

fn solids_brep_text(solids: &AnyArray) -> Option<String> {
    let list = object_list::<CadaclysmSolid>(solids, "write_brep")?;
    let guards: Vec<GdRef<CadaclysmSolid>> = list.iter().map(|s| s.bind()).collect();
    let held: Vec<&bs::Solid> = guards.iter().map(|g| g.held()).collect::<Option<_>>()?;
    ok(bs::write_brep_text(&held))
}

fn svg_text_of(solids: &[&bs::Solid], options: &sdk::SvgOptions) -> Option<String> {
    ok(bs::write_svg_text(solids, options))
}

/// Several solids' SVG text: every one bound for the length of the call.
fn solids_svg_text(solids: &AnyArray, options: &sdk::SvgOptions) -> Option<String> {
    let list = object_list::<CadaclysmSolid>(solids, "write_svg")?;
    let guards: Vec<GdRef<CadaclysmSolid>> = list.iter().map(|s| s.bind()).collect();
    let held: Vec<&bs::Solid> = guards.iter().map(|g| g.held()).collect::<Option<_>>()?;
    svg_text_of(&held, options)
}

// ---- CadaclysmBlacksmith --------------------------------------------------------------------

/// The kernel library itself: its version, its license, and STEP for several solids at
/// once. Its errors land in `Cadaclysm.last_error()` like the reader's.
#[derive(GodotClass)]
#[class(no_init, base = Object)]
pub struct CadaclysmBlacksmith;

#[godot_api]
impl CadaclysmBlacksmith {
    /// Load the kernel from `path` before anything else uses it. Without this, it is
    /// found beside the extension, then where `CADACLYSM_BLACKSMITH_LIBRARY` points.
    #[func]
    fn load(path: GString) -> bool {
        ok(bs::load(os_path(&path))).is_some()
    }

    /// Where the kernel was loaded from, or would be.
    #[func]
    fn library_path() -> GString {
        gs(ok(bs::library_path()).map(|p| p.display().to_string()).unwrap_or_default())
    }

    #[func]
    fn version() -> GString {
        gs(ok(bs::version()).unwrap_or_default())
    }

    #[func]
    fn build_date() -> GString {
        gs(ok(bs::build_date()).unwrap_or_default())
    }

    /// Install a license in the kernel (it keeps its own, apart from the reader's): the
    /// license file's text, or its path.
    #[func]
    fn license(text_or_path: GString) -> bool {
        let text = text_or_path.to_string();
        let given = if text.starts_with("res://") || text.starts_with("user://") { os_path(&text_or_path) } else { text };
        ok(bs::license(given)).is_some()
    }

    #[func]
    fn license_info() -> GString {
        gs(ok(bs::license_info()).unwrap_or_default())
    }

    #[func]
    fn license_notice_count() -> i64 {
        ok(bs::license_notice_count()).unwrap_or_default() as i64
    }

    /// How the kernel lays a B-rep out; `CadaclysmSolid.from_node` needs it to equal
    /// `CadaclysmBrep.layout_id()` (both libraries from one release).
    #[func]
    fn brep_layout_id() -> GString {
        gs(ok(bs::brep_layout_id()).unwrap_or_default())
    }

    /// The path of `ap203.exp` where one is found; `""` otherwise. Not needed to write
    /// STEP: the kernel has AP203 built in.
    #[func]
    fn default_schema() -> GString {
        gs(ok(bs::default_schema()).map(|p| p.display().to_string()).unwrap_or_default())
    }

    /// The tolerance booleans, bounds and meshes default to: 0.05.
    #[func]
    fn default_tolerance() -> f64 {
        bs::DEFAULT_TOLERANCE
    }

    /// The tolerance `fillet`, `chamfer` and `shell` default to: 1e-6.
    #[func]
    fn fillet_tolerance() -> f64 {
        bs::FILLET_TOLERANCE
    }

    /// `"#rgb"` or `"#rrggbb"` (the `#` optional) as a `Color`; black, with the error
    /// recorded, for anything else.
    #[func]
    fn rgb(hex: GString) -> Color {
        let rgb = ok(bs::rgb(&hex.to_string()));
        rgb.map(|[r, g, b]| Color::from_rgb(r as f32, g as f32, b as f32)).unwrap_or(Color::BLACK)
    }

    /// The plane through `point` square to `normal`, read as heights over `frame`'s
    /// sketch plane: `{at, grad: [gx, gy]}`, what `CadaclysmSolid.extrude_between` takes for a
    /// sloped cap. Empty where the plane holds the sweep direction itself.
    #[func]
    fn slant_of_plane(frame: Variant, point: Variant, normal: Variant) -> VarDictionary {
        let built = (|| {
            let f = self::frame(&frame, "slant_of_plane: frame")?;
            let s = ok(bs::Slant::of_plane(&f, v3(&point, "point")?, v3(&normal, "normal")?))?;
            let grad: VarArray = varray![s.grad[0], s.grad[1]];
            Some(dict(&[("at", s.at.to_variant()), ("grad", grad.to_variant())]))
        })();
        built.unwrap_or_default()
    }

    /// Several solids as one STEP file's text, each its own body. `schema`: `""` for the
    /// kernel's built-in AP203, a built-in schema's name
    /// (`"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"`), an `.exp` path, or EXPRESS
    /// text. `unit`: `"mm"`, `"m"` or `"in"`. `""` on failure.
    #[func]
    fn write_step_text(solids: AnyArray, #[opt(default = "")] schema: GString, #[opt(default = "mm")] unit: GString) -> GString {
        gs(solids_step_text(&solids, &schema, &unit).unwrap_or_default())
    }

    /// Several solids written to one STEP file at `path`; see `write_step_text`.
    #[func]
    fn write_step(path: GString, solids: AnyArray, #[opt(default = "")] schema: GString, #[opt(default = "mm")] unit: GString) -> bool {
        match solids_step_text(&solids, &schema, &unit) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// Several solids as one ACIS SAT file's text, each its own body: the analytic
    /// surfaces as their own records, splines and swept surfaces as exact NURBS.
    /// `unit`: `"mm"`, `"m"` or `"in"`. `""` on failure.
    #[func]
    fn write_sat_text(solids: AnyArray, #[opt(default = "mm")] unit: GString) -> GString {
        gs(solids_sat_text(&solids, &unit).unwrap_or_default())
    }

    /// Several solids written to one SAT file at `path`; see `write_sat_text`.
    #[func]
    fn write_sat(path: GString, solids: AnyArray, #[opt(default = "mm")] unit: GString) -> bool {
        match solids_sat_text(&solids, &unit) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// Several solids as one OCCT `.brep` file's text, each its own solid under one
    /// compound (a single solid is the file's root): the exact surfaces and curves, with a
    /// curve in each face's own parameters for every edge. No unit is declared. `""` on failure.
    #[func]
    fn write_brep_text(solids: AnyArray) -> GString {
        gs(solids_brep_text(&solids).unwrap_or_default())
    }

    /// Several solids written to one `.brep` file at `path`; see `write_brep_text`.
    #[func]
    fn write_brep(path: GString, solids: AnyArray) -> bool {
        match solids_brep_text(&solids) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// Several solids' wireframe as one SVG's text, each its own `<g>`. `""` on a
    /// refused option.
    #[func]
    fn write_svg_text(solids: AnyArray) -> GString {
        Self::write_svg_text_with(solids, VarDictionary::new())
    }

    /// `write_svg_text`, with options: see `CadaclysmScene.svg_text_with` for every
    /// key -- `up` left out is always `"z"` here, a solid carrying no convention of
    /// its own for a scene to default it from.
    #[func]
    fn write_svg_text_with(solids: AnyArray, options: VarDictionary) -> GString {
        let Some(opts) = reader::svg_options(&options) else { return GString::new() };
        gs(solids_svg_text(&solids, &opts).unwrap_or_default())
    }

    /// Several solids written to one SVG file at `path`; see `write_svg_text`.
    #[func]
    fn write_svg(path: GString, solids: AnyArray) -> bool {
        Self::write_svg_with(path, solids, VarDictionary::new())
    }

    /// `write_svg`, with options: see `write_svg_text_with`.
    #[func]
    fn write_svg_with(path: GString, solids: AnyArray, options: VarDictionary) -> bool {
        let Some(opts) = reader::svg_options(&options) else { return false };
        match solids_svg_text(&solids, &opts) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }
}

// ---- CadaclysmFrame ----------------------------------------------------------------------

/// An origin and three unit axes, square and right-handed (z = x × y), in doubles: the
/// plane a profile is drawn on (its x and y) and the direction it is built along (its
/// z). Every constructor checks, so a `CadaclysmFrame` in hand is always a valid one.
///
/// ```gdscript
/// var lid := CadaclysmSolid.extrude(CadaclysmProfile.rect(10, 4), CadaclysmFrame.xy(Vector3(0, 0, 5)), 2)
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmFrame {
    frame: bs::Frame,
    #[var(get = get_origin, no_set)]
    origin: PhantomVar<Vector3>,
    #[var(get = get_x, no_set)]
    x: PhantomVar<Vector3>,
    #[var(get = get_y, no_set)]
    y: PhantomVar<Vector3>,
    #[var(get = get_z, no_set)]
    z: PhantomVar<Vector3>,
    #[var(get = get_raw, no_set)]
    raw: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmFrame {
    pub(crate) fn wrap(frame: bs::Frame) -> Gd<CadaclysmFrame> {
        Gd::from_object(CadaclysmFrame {
            frame,
            origin: PhantomVar::default(),
            x: PhantomVar::default(),
            y: PhantomVar::default(),
            z: PhantomVar::default(),
            raw: PhantomVar::default(),
        })
    }

    fn moved(base: bs::Frame, origin: Vector3) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(base.translate(origin.x.into(), origin.y.into(), origin.z.into()))
    }
}

#[godot_api]
impl IRefCounted for CadaclysmFrame {
    fn to_string(&self) -> GString {
        gs(self.frame.to_string())
    }
}

#[godot_api]
impl CadaclysmFrame {
    /// The world XY plane through `origin`: z up.
    #[func]
    fn xy(#[opt(default = Vector3::ZERO)] origin: Vector3) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::moved(bs::Frame::xy([0.0; 3]), origin)
    }

    /// The world XZ plane through `origin`: x along X, y along Z, so z is -Y.
    #[func]
    fn xz(#[opt(default = Vector3::ZERO)] origin: Vector3) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::moved(bs::Frame::xz([0.0; 3]), origin)
    }

    /// The world YZ plane through `origin`: x along Y, y along Z, so z is +X.
    #[func]
    fn yz(#[opt(default = Vector3::ZERO)] origin: Vector3) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::moved(bs::Frame::yz([0.0; 3]), origin)
    }

    /// The plane through `origin` square to `normal` (the frame's z). Its x axis is `x`
    /// laid onto that plane; with `x` left at `Vector3.ZERO`, world X laid onto it, or
    /// world Y when the normal is within about 25° of X -- the axes `CadaclysmSolid.face_frame`
    /// gives a face facing `normal`.
    #[func]
    fn at(origin: Variant, normal: Variant, #[opt(default = Vector3::ZERO)] x: Vector3) -> Option<Gd<CadaclysmFrame>> {
        let origin = v3(&origin, "Frame.at: origin")?;
        let normal = v3(&normal, "Frame.at: normal")?;
        let x = (x != Vector3::ZERO).then(|| [x.x, x.y, x.z].map(f64::from));
        ok(bs::Frame::at(origin, normal, x)).map(CadaclysmFrame::wrap)
    }

    /// A frame from its origin and axes, normalised; fails where the axes are not square
    /// or not right-handed. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(origin: Variant, x: Variant, y: Variant, z: Variant) -> Option<Gd<CadaclysmFrame>> {
        let (o, x, y, z) = (v3(&origin, "Frame: origin")?, v3(&x, "Frame: x")?, v3(&y, "Frame: y")?, v3(&z, "Frame: z")?);
        ok(bs::Frame::new(o, x, y, z)).map(CadaclysmFrame::wrap)
    }

    /// Twelve numbers -- origin, x, y, z -- (or four triples, or a `Transform3D`) checked
    /// as `create` checks them.
    #[func]
    fn of(raw: Variant) -> Option<Gd<CadaclysmFrame>> {
        let f = frame(&raw, "Frame.of")?;
        clear_error();
        Some(CadaclysmFrame::wrap(f))
    }

    /// A `Transform3D`'s origin and basis as a frame: the basis must be square,
    /// unscaled and right-handed.
    #[func]
    fn from_transform(transform: Transform3D) -> Option<Gd<CadaclysmFrame>> {
        ok(frame_of_transform(transform)).map(CadaclysmFrame::wrap)
    }

    #[func]
    fn get_origin(&self) -> Vector3 {
        vector3(self.frame.origin())
    }

    #[func]
    fn get_x(&self) -> Vector3 {
        vector3(self.frame.x())
    }

    #[func]
    fn get_y(&self) -> Vector3 {
        vector3(self.frame.y())
    }

    #[func]
    fn get_z(&self) -> Vector3 {
        vector3(self.frame.z())
    }

    /// The twelve doubles every call taking a frame reads: origin, x, y, z.
    #[func]
    fn get_raw(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.frame.raw()[..])
    }

    /// This frame moved by (`dx`, `dy`, `dz`) in world coordinates.
    #[func]
    fn translate(&self, dx: f64, dy: f64, dz: f64) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.frame.translate(dx, dy, dz))
    }

    /// This frame moved `distance` along its own z.
    #[func]
    fn offset(&self, distance: f64) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.frame.offset(distance))
    }

    /// The frame as a `Transform3D`: basis columns x, y, z, and the origin.
    #[func]
    fn to_transform(&self) -> Transform3D {
        let f = &self.frame;
        Transform3D::new(Basis::from_cols(vector3(f.x()), vector3(f.y()), vector3(f.z())), vector3(f.origin()))
    }

    /// Whether `other`'s twelve numbers are each within `tolerance` of this one's.
    #[func]
    fn is_equal_approx(&self, other: Gd<CadaclysmFrame>, #[opt(default = 1e-9)] tolerance: f64) -> bool {
        let theirs = other.bind().frame.raw();
        self.frame.raw().iter().zip(theirs.iter()).all(|(a, b)| (a - b).abs() <= tolerance)
    }
}

// ---- CadaclysmProfile --------------------------------------------------------------------

/// A closed outline with holes (or an open chain, from `CadaclysmPath.end_open`), in its own
/// x/y. Immutable: every method returns a new one.
///
/// ```gdscript
/// var outline := CadaclysmProfile.rect(80, 40).with_hole(CadaclysmProfile.circle(4))
/// var plate := CadaclysmSolid.extrude(outline, CadaclysmFrame.xy(), 6)
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmProfile {
    profile: bs::Profile,
}

impl CadaclysmProfile {
    fn made(result: sdk::Result<bs::Profile>) -> Option<Gd<CadaclysmProfile>> {
        ok(result).map(|profile| Gd::from_object(CadaclysmProfile { profile }))
    }

    fn joined(list: &AnyArray, what: &str, f: impl FnOnce(&[&bs::Profile]) -> sdk::Result<bs::Profile>) -> Option<Gd<CadaclysmProfile>> {
        let list = object_list::<CadaclysmProfile>(list, what)?;
        let guards: Vec<GdRef<CadaclysmProfile>> = list.iter().map(|p| p.bind()).collect();
        let refs: Vec<&bs::Profile> = guards.iter().map(|g| &g.profile).collect();
        Self::made(f(&refs))
    }

    /// Several profiles out of a list of them in (the trim's pieces and chains): an
    /// empty array, with the reason logged, where the kernel refuses.
    fn several(list: &AnyArray, what: &str, f: impl FnOnce(&[&bs::Profile]) -> sdk::Result<Vec<bs::Profile>>) -> Array<Gd<CadaclysmProfile>> {
        let Some(list) = object_list::<CadaclysmProfile>(list, what) else { return Array::new() };
        let guards: Vec<GdRef<CadaclysmProfile>> = list.iter().map(|p| p.bind()).collect();
        let refs: Vec<&bs::Profile> = guards.iter().map(|g| &g.profile).collect();
        ok(f(&refs)).unwrap_or_default().into_iter().map(|profile| Gd::from_object(CadaclysmProfile { profile })).collect()
    }
}

#[godot_api]
impl CadaclysmProfile {
    /// A `w` by `h` rectangle about the origin.
    #[func]
    fn rect(w: f64, h: f64) -> Option<Gd<CadaclysmProfile>> {
        Self::made(bs::Profile::rect(w, h))
    }

    /// A circle of radius `r` about the origin.
    #[func]
    fn circle(r: f64) -> Option<Gd<CadaclysmProfile>> {
        Self::made(bs::Profile::circle(r))
    }

    /// A slot: two half-circles of radius `r` whose centres are `length` apart along x,
    /// about `centre`.
    #[func]
    fn slot(centre: Variant, length: f64, r: f64) -> Option<Gd<CadaclysmProfile>> {
        Self::made(bs::Profile::slot(v2(&centre, "slot: centre")?, length, r))
    }

    /// The polygon through `points` (a `PackedVector2Array` or an array of points).
    #[func]
    fn polygon(points: Variant) -> Option<Gd<CadaclysmProfile>> {
        Self::made(bs::Profile::polygon(&points2(&points, "polygon")?))
    }

    /// A regular polygon of `sides` sides on the circle of `radius` about `centre`, its
    /// first corner at `angle` radians from the sketch's x axis.
    #[func]
    fn regular_polygon(centre: Variant, radius: f64, sides: i64, #[opt(default = 0.0)] angle: f64) -> Option<Gd<CadaclysmProfile>> {
        let sides = u32::try_from(sides).unwrap_or(0);
        Self::made(bs::Profile::regular_polygon(v2(&centre, "regular_polygon: centre")?, radius, sides, angle))
    }

    /// A spline of `degree` through the control polygon `points`, with `weights` one per
    /// point (empty: none). Open, it starts on the first point and ends on the last;
    /// `closed`, it is periodic -- a closed profile.
    #[func]
    fn spline(
        points: Variant,
        #[opt(default = 3)] degree: i64,
        #[opt(default = &PackedFloat64Array::new())] weights: PackedFloat64Array,
        #[opt(default = false)] closed: bool,
    ) -> Option<Gd<CadaclysmProfile>> {
        let points = points2(&points, "spline")?;
        let weights = (!weights.is_empty()).then(|| weights.as_slice().to_vec());
        Self::made(bs::Profile::spline(&points, index(degree, "spline: degree")?, weights.as_deref(), closed))
    }

    /// An outline drawn a segment at a time from `start`: a `CadaclysmPath`.
    #[func]
    fn path(start: Variant) -> Option<Gd<CadaclysmPath>> {
        CadaclysmPath::start(start)
    }

    /// Open profiles joined end to end into one, in any order and either way round, each
    /// next one meeting the chain so far within `tolerance`; closed where the chain's
    /// two ends meet.
    #[func]
    fn chain(pieces: AnyArray, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmProfile>> {
        Self::joined(&pieces, "chain", |refs| bs::Profile::chain(refs, tolerance))
    }

    /// Closed loops, in any order, as one profile: the loop enclosing the most area is
    /// the boundary and every other a hole in it.
    #[func]
    fn from_loops(loops: AnyArray) -> Option<Gd<CadaclysmProfile>> {
        Self::joined(&loops, "from_loops", bs::Profile::from_loops)
    }

    /// This profile closed: a straight segment back to the start where it stops short.
    #[func]
    fn close_loop(&self) -> Option<Gd<CadaclysmProfile>> {
        Self::made(self.profile.close_loop())
    }

    /// This curve cut where the `cutters` cross, touch or run along it -- the sketch
    /// trim's pieces, in order along the curve: portions of its own segments, exactly.
    #[func]
    fn pieces(&self, cutters: AnyArray, #[opt(default = 1e-6)] tolerance: f64) -> Array<Gd<CadaclysmProfile>> {
        Self::several(&cutters, "pieces", |refs| self.profile.pieces(refs, tolerance))
    }

    /// This curve with piece `piece` of `pieces` taken away -- the sketch trim: what is
    /// left as open chains (one for a closed curve, up to two for an open one).
    #[func]
    fn trim(&self, cutters: AnyArray, piece: u32, #[opt(default = 1e-6)] tolerance: f64) -> Array<Gd<CadaclysmProfile>> {
        Self::several(&cutters, "trim", |refs| self.profile.trim(refs, piece, tolerance))
    }

    /// This profile with `hole` cut out of it.
    #[func]
    fn with_hole(&self, hole: Gd<CadaclysmProfile>) -> Option<Gd<CadaclysmProfile>> {
        Self::made(self.profile.with_hole(&hole.bind().profile))
    }

    #[func]
    fn translate(&self, dx: f64, dy: f64) -> Option<Gd<CadaclysmProfile>> {
        Self::made(self.profile.translate(dx, dy))
    }

    /// Where this profile's curves cross, touch or run along `other`'s, both read in one
    /// plane, as `CadaclysmHit`s ordered along this profile. Points closer than
    /// `tolerance` merge; two curves within `tolerance` of each other for longer than
    /// it are one run when they part only where one ends or the stretch is flat -- one
    /// curve following the other, offset within `tolerance` or tilted by under about
    /// half of it, even where it leaves mid-both; a tangency or a shallow crossing is
    /// one point. Empty on failure.
    #[func]
    fn hits(&self, other: Gd<CadaclysmProfile>, #[opt(default = 1e-6)] tolerance: f64) -> Array<Gd<CadaclysmHit>> {
        let hits = ok(self.profile.hits(&other.bind().profile, tolerance));
        hits.unwrap_or_default().into_iter().map(CadaclysmHit::wrap).collect()
    }

    /// The region this profile and `other` share, both read in one plane, as zero or
    /// more profiles -- each boundary counter-clockwise, each hole clockwise, arcs and
    /// splines kept exact. Both must be closed and simple. No shared area is an empty
    /// array; so is a failure (a `tolerance` not positive and finite, a profile open or
    /// crossing itself), with `Cadaclysm.last_error()` set.
    #[func]
    fn common(&self, other: Gd<CadaclysmProfile>, #[opt(default = 1e-6)] tolerance: f64) -> Array<Gd<CadaclysmProfile>> {
        let shared = ok(self.profile.common(&other.bind().profile, tolerance));
        shared.unwrap_or_default().into_iter().map(|profile| Gd::from_object(CadaclysmProfile { profile })).collect()
    }

    /// This profile with its corners rounded by `radius` where two straight segments
    /// meet. `corners` empty rounds every such corner, the holes' too; a list picks
    /// corners of the boundary alone (corner `k` is where segment `k` ends). `open`
    /// reads it as an open chain, whose two ends stay square.
    #[func]
    fn round(
        &self,
        radius: f64,
        #[opt(default = &PackedInt32Array::new())] corners: PackedInt32Array,
        #[opt(default = false)] open: bool,
    ) -> Option<Gd<CadaclysmProfile>> {
        let picked = if corners.is_empty() { None } else { Some(packed_indices(&corners, "round: corner")?) };
        Self::made(self.profile.round(radius, picked.as_deref(), open))
    }
}

// ---- CadaclysmPath -----------------------------------------------------------------------

/// An outline drawn a segment at a time; each step returns the path itself, so steps
/// chain, and `end()` closes it into a `CadaclysmProfile` (`end_open()` leaves it open). A
/// step that fails returns `null` and spends the path.
///
/// ```gdscript
/// var rounded := CadaclysmProfile.path([0, 0]).line_to(10, 0).line_to(10, 8) \
///     .arc_to(8, 10, [8, 8]).line_to(0, 10).end()
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmPath {
    base: Base<RefCounted>,
    path: Option<bs::Path>,
}

impl CadaclysmPath {
    fn start(start: Variant) -> Option<Gd<CadaclysmPath>> {
        let path = ok(bs::Path::begin(v2(&start, "path: start")?))?;
        Some(Gd::from_init_fn(|base| CadaclysmPath { base, path: Some(path) }))
    }

    fn step(&mut self, f: impl FnOnce(bs::Path) -> sdk::Result<bs::Path>) -> Option<Gd<CadaclysmPath>> {
        let Some(path) = self.path.take() else { return fail("path: already ended") };
        self.path = Some(ok(f(path))?);
        Some(self.to_gd())
    }

    fn finish(&mut self, open: bool) -> Option<Gd<CadaclysmProfile>> {
        let Some(path) = self.path.take() else { return fail("path: already ended") };
        CadaclysmProfile::made(if open { path.end_open() } else { path.end() })
    }
}

#[godot_api]
impl CadaclysmPath {
    /// A path starting at `start`; the same as `CadaclysmProfile.path(start)`.
    #[func]
    fn begin(start: Variant) -> Option<Gd<CadaclysmPath>> {
        CadaclysmPath::start(start)
    }

    #[func]
    fn line_to(&mut self, x: f64, y: f64) -> Option<Gd<CadaclysmPath>> {
        self.step(|p| p.line_to(x, y))
    }

    /// An arc to (`x`, `y`) about `centre`, counter-clockwise unless `ccw` is false.
    #[func]
    fn arc_to(&mut self, x: f64, y: f64, centre: Variant, #[opt(default = true)] ccw: bool) -> Option<Gd<CadaclysmPath>> {
        let centre = v2(&centre, "arc_to: centre")?;
        self.step(|p| p.arc_to(x, y, centre, ccw))
    }

    /// A cubic Bézier to `to`, pulled by the control points `c1` and `c2`.
    #[func]
    fn bezier_to(&mut self, c1: Variant, c2: Variant, to: Variant) -> Option<Gd<CadaclysmPath>> {
        let (c1, c2, to) = (v2(&c1, "bezier_to: c1")?, v2(&c2, "bezier_to: c2")?, v2(&to, "bezier_to: to")?);
        self.step(|p| p.bezier_to(c1, c2, to))
    }

    /// A NURBS piece: `control` every control point after the current one, the endpoint
    /// last; `knots` the full repeated knot vector; `weights` one per control point
    /// *including* the current one (empty: none).
    #[func]
    fn nurbs_to(
        &mut self,
        control: Variant,
        knots: Variant,
        degree: i64,
        #[opt(default = &PackedFloat64Array::new())] weights: PackedFloat64Array,
    ) -> Option<Gd<CadaclysmPath>> {
        let control = points2(&control, "nurbs_to: control")?;
        let knots = number_list(&knots, "nurbs_to: knots")?;
        let degree = index(degree, "nurbs_to: degree")?;
        let weights = (!weights.is_empty()).then(|| weights.as_slice().to_vec());
        self.step(|p| p.nurbs_to(&control, &knots, degree, weights.as_deref()))
    }

    /// Close the outline into a `CadaclysmProfile`. The path is spent either way.
    #[func]
    fn end(&mut self) -> Option<Gd<CadaclysmProfile>> {
        self.finish(false)
    }

    /// The path as it stands, without closing it: an open chain for `extrude_open`,
    /// `sweep_open`, `loft_open` or `CadaclysmSweepPath.along`.
    #[func]
    fn end_open(&mut self) -> Option<Gd<CadaclysmProfile>> {
        self.finish(true)
    }
}

// ---- CadaclysmSweepPath ------------------------------------------------------------------

/// A 3D path a profile is carried along -- lines and arcs -- for `CadaclysmSolid.sweep`,
/// `sweep_open` and `pipe`, which only borrow it: sweep it as often as needed. Each
/// step returns the path itself; a step that fails returns `null` and spends it.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSweepPath {
    base: Base<RefCounted>,
    path: Option<bs::SweepPath>,
}

impl CadaclysmSweepPath {
    fn made(result: sdk::Result<bs::SweepPath>) -> Option<Gd<CadaclysmSweepPath>> {
        let path = ok(result)?;
        Some(Gd::from_init_fn(|base| CadaclysmSweepPath { base, path: Some(path) }))
    }

    fn held(&self) -> Option<&bs::SweepPath> {
        match &self.path {
            Some(path) => Some(path),
            None => fail("sweep_path: closed"),
        }
    }

    fn step(&mut self, f: impl FnOnce(bs::SweepPath) -> sdk::Result<bs::SweepPath>) -> Option<Gd<CadaclysmSweepPath>> {
        let Some(path) = self.path.take() else { return fail("sweep_path: closed") };
        self.path = Some(ok(f(path))?);
        Some(self.to_gd())
    }
}

#[godot_api]
impl CadaclysmSweepPath {
    /// A path starting at `point`.
    #[func]
    fn at(point: Variant) -> Option<Gd<CadaclysmSweepPath>> {
        Self::made(bs::SweepPath::at(v3(&point, "sweep_path: point")?))
    }

    /// The path the 2D chain `curve` draws on `frame`: lines and arcs as they are, a
    /// Bézier or spline fitted with tangent biarcs to within `tolerance`. `open` false
    /// closes it back to its start.
    #[func]
    fn along(
        curve: Gd<CadaclysmProfile>,
        frame: Variant,
        #[opt(default = 0.05)] tolerance: f64,
        #[opt(default = true)] open: bool,
    ) -> Option<Gd<CadaclysmSweepPath>> {
        let f = self::frame(&frame, "along: frame")?;
        Self::made(bs::SweepPath::along(&curve.bind().profile, &f, tolerance, open))
    }

    #[func]
    fn line_to(&mut self, point: Variant) -> Option<Gd<CadaclysmSweepPath>> {
        let point = v3(&point, "line_to: point")?;
        self.step(|p| p.line_to(point))
    }

    /// Turn `angle` radians (in (0, 2π]) about the axis through `centre` along `axis`.
    #[func]
    fn arc(&mut self, centre: Variant, axis: Variant, angle: f64) -> Option<Gd<CadaclysmSweepPath>> {
        let (centre, axis) = (v3(&centre, "arc: centre")?, v3(&axis, "arc: axis")?);
        self.step(|p| p.arc(centre, axis, angle))
    }

    /// Free it now; later calls fail with "closed".
    #[func]
    fn close(&mut self) {
        self.path = None;
    }
}

// ---- CadaclysmEdge -----------------------------------------------------------------------

/// One edge of a solid, as plain data: its index (what `CadaclysmSolid.fillet` takes), its
/// curve kind, the faces meeting on it, its segments' ends, and its exact `CadaclysmCurve`
/// (`null` for an edge with no exact curve, kind `"other"`).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmEdge {
    edge: bs::Edge,
    #[var(get = get_curve, no_set)]
    curve: PhantomVar<Variant>,
    #[var(rename = index, get = get_index, no_set)]
    index_: PhantomVar<i64>,
    #[var(get = get_kind, no_set)]
    kind: PhantomVar<GString>,
    #[var(get = get_faces, no_set)]
    faces: PhantomVar<PackedInt32Array>,
    #[var(get = get_segments, no_set)]
    segments: PhantomVar<PackedVector3Array>,
    #[var(get = get_raw_segments, no_set)]
    raw_segments: PhantomVar<PackedFloat64Array>,
    #[var(get = get_is_line, no_set)]
    is_line: PhantomVar<bool>,
    #[var(get = get_direction, no_set)]
    direction: PhantomVar<Variant>,
}

impl CadaclysmEdge {
    fn wrap(edge: bs::Edge) -> Gd<CadaclysmEdge> {
        Gd::from_object(CadaclysmEdge {
            edge,
            curve: PhantomVar::default(),
            index_: PhantomVar::default(),
            kind: PhantomVar::default(),
            faces: PhantomVar::default(),
            segments: PhantomVar::default(),
            raw_segments: PhantomVar::default(),
            is_line: PhantomVar::default(),
            direction: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmEdge {
    fn to_string(&self) -> GString {
        let faces: Vec<String> = self.edge.faces.iter().map(u32::to_string).collect();
        gs(format!("Edge({}, '{}', faces=({}))", self.edge.index, self.edge.kind, faces.join(", ")))
    }
}

#[godot_api]
impl CadaclysmEdge {
    #[func]
    fn get_index(&self) -> i64 {
        self.edge.index.into()
    }

    /// The curve it lies on: `"line"`, `"circle"`, ...
    #[func]
    fn get_kind(&self) -> GString {
        gs(&self.edge.kind)
    }

    /// The faces meeting on it.
    #[func]
    fn get_faces(&self) -> PackedInt32Array {
        self.edge.faces.iter().map(|&f| f as i32).collect()
    }

    /// Its segments' ends, two points a segment.
    #[func]
    fn get_segments(&self) -> PackedVector3Array {
        self.edge.segments.iter().flat_map(|[a, b]| [vector3(*a), vector3(*b)]).collect()
    }

    /// The same, as doubles: six a segment.
    #[func]
    fn get_raw_segments(&self) -> PackedFloat64Array {
        self.edge.segments.iter().flat_map(|[a, b]| a.iter().chain(b.iter()).copied().collect::<Vec<_>>()).collect()
    }

    #[func]
    fn get_is_line(&self) -> bool {
        self.edge.is_line()
    }

    /// The unit direction of a line edge, or `null` for any other.
    #[func]
    fn get_direction(&self) -> Variant {
        self.edge.direction().map_or(Variant::nil(), |d| vector3(d).to_variant())
    }

    /// The edge's exact curve as a `CadaclysmCurve`, or `null` for an edge with none.
    #[func]
    fn get_curve(&self) -> Variant {
        self.edge.curve.clone().map_or(Variant::nil(), |c| CadaclysmCurve::wrap(c).to_variant())
    }
}

// ---- CadaclysmCurve ----------------------------------------------------------------------

/// One edge's exact curve, as plain data copied out (`CadaclysmEdge.curve`): `kind` is
/// `"line"`, `"circle"`, `"ellipse"` or `"nurbs"`.
///
/// `t0..t1` is the edge's parameter range on its own curve: a line's fraction (0..1 over
/// `origin -> origin + x`, where `x` is the full `to - from`, NOT unit -- so
/// `point(t) = origin + x*t`); a circle's or ellipse's angle in radians about `origin` in
/// the `x, y` plane (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`,
/// `radius2 = radius` for a circle); a NURBS's knot parameter
/// (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are unit for conics;
/// for a line `x` is the direction with length = the line's length and `y, z` are zero.
///
/// `origin`, `x`, `y`, `z` are `Vector3`s of floats; `raw_frame` keeps the twelve doubles.
/// For a NURBS the frame is zero and so are the radii; for a conic or a line `degree` is 0
/// and `knots`, `poles` are empty. `poles` is three doubles a control point
/// (`knots.size() == poles.size() / 3 + degree + 1`); `weights` is one per pole, or empty
/// for a non-rational (plain B-spline) curve, a conic or a line (`is_rational` tells).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCurve {
    curve: bs::Curve,
    #[var(get = get_kind, no_set)]
    kind: PhantomVar<GString>,
    #[var(get = get_origin, no_set)]
    origin: PhantomVar<Vector3>,
    #[var(get = get_x, no_set)]
    x: PhantomVar<Vector3>,
    #[var(get = get_y, no_set)]
    y: PhantomVar<Vector3>,
    #[var(get = get_z, no_set)]
    z: PhantomVar<Vector3>,
    #[var(get = get_raw_frame, no_set)]
    raw_frame: PhantomVar<PackedFloat64Array>,
    #[var(get = get_radius, no_set)]
    radius: PhantomVar<f64>,
    #[var(get = get_radius2, no_set)]
    radius2: PhantomVar<f64>,
    #[var(get = get_t0, no_set)]
    t0: PhantomVar<f64>,
    #[var(get = get_t1, no_set)]
    t1: PhantomVar<f64>,
    #[var(get = get_degree, no_set)]
    degree: PhantomVar<i64>,
    #[var(get = get_knots, no_set)]
    knots: PhantomVar<PackedFloat64Array>,
    #[var(get = get_poles, no_set)]
    poles: PhantomVar<PackedFloat64Array>,
    #[var(get = get_weights, no_set)]
    weights: PhantomVar<PackedFloat64Array>,
    #[var(get = get_is_rational, no_set)]
    is_rational: PhantomVar<bool>,
}

impl CadaclysmCurve {
    fn wrap(curve: bs::Curve) -> Gd<CadaclysmCurve> {
        Gd::from_object(CadaclysmCurve {
            curve,
            kind: PhantomVar::default(),
            origin: PhantomVar::default(),
            x: PhantomVar::default(),
            y: PhantomVar::default(),
            z: PhantomVar::default(),
            raw_frame: PhantomVar::default(),
            radius: PhantomVar::default(),
            radius2: PhantomVar::default(),
            t0: PhantomVar::default(),
            t1: PhantomVar::default(),
            degree: PhantomVar::default(),
            knots: PhantomVar::default(),
            poles: PhantomVar::default(),
            weights: PhantomVar::default(),
            is_rational: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCurve {
    fn to_string(&self) -> GString {
        let c = &self.curve;
        gs(if c.kind == "nurbs" {
            format!("Curve('nurbs', degree={}, poles={}, rational={}, t0={}, t1={})", c.degree, c.poles.len(), c.weights.is_some(), c.t0, c.t1)
        } else {
            format!("Curve('{}', origin={:?}, radius={}, t0={}, t1={})", c.kind, c.origin, c.radius, c.t0, c.t1)
        })
    }
}

#[godot_api]
impl CadaclysmCurve {
    #[func]
    fn get_kind(&self) -> GString {
        gs(&self.curve.kind)
    }

    #[func]
    fn get_origin(&self) -> Vector3 {
        vector3(self.curve.origin)
    }

    #[func]
    fn get_x(&self) -> Vector3 {
        vector3(self.curve.x)
    }

    #[func]
    fn get_y(&self) -> Vector3 {
        vector3(self.curve.y)
    }

    #[func]
    fn get_z(&self) -> Vector3 {
        vector3(self.curve.z)
    }

    /// The frame as twelve doubles -- origin, x, y, z -- where the `Vector3`s hold floats.
    #[func]
    fn get_raw_frame(&self) -> PackedFloat64Array {
        let c = &self.curve;
        c.origin.iter().chain(c.x.iter()).chain(c.y.iter()).chain(c.z.iter()).copied().collect()
    }

    #[func]
    fn get_radius(&self) -> f64 {
        self.curve.radius
    }

    #[func]
    fn get_radius2(&self) -> f64 {
        self.curve.radius2
    }

    #[func]
    fn get_t0(&self) -> f64 {
        self.curve.t0
    }

    #[func]
    fn get_t1(&self) -> f64 {
        self.curve.t1
    }

    #[func]
    fn get_degree(&self) -> i64 {
        self.curve.degree.into()
    }

    /// The knot vector; empty for a conic or a line.
    #[func]
    fn get_knots(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.curve.knots[..])
    }

    /// The control points, three doubles each; empty for a conic or a line.
    #[func]
    fn get_poles(&self) -> PackedFloat64Array {
        self.curve.poles.iter().flatten().copied().collect()
    }

    /// One weight per pole, or empty for a non-rational curve, a conic or a line.
    #[func]
    fn get_weights(&self) -> PackedFloat64Array {
        self.curve.weights.as_deref().map_or_else(PackedFloat64Array::new, |w| PackedFloat64Array::from(w))
    }

    /// Whether `weights` are there: a rational NURBS.
    #[func]
    fn get_is_rational(&self) -> bool {
        self.curve.weights.is_some()
    }
}

// ---- CadaclysmSpot and CadaclysmHit ------------------------------------------------------

/// Where a `CadaclysmHit` lands on one side: a profile's `loop_index` (0 the boundary or
/// the open chain, then the holes in the order they were added), `segment` and `t` from 0
/// to 1 along it, with `face` `NONE` (4294967295) -- or a solid's `face` at (`u`, `v`).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSpot {
    spot: bs::Spot,
    #[var(get = get_loop_index, no_set)]
    loop_index: PhantomVar<i64>,
    #[var(get = get_segment, no_set)]
    segment: PhantomVar<i64>,
    #[var(get = get_t, no_set)]
    t: PhantomVar<f64>,
    #[var(get = get_face, no_set)]
    face: PhantomVar<i64>,
    #[var(get = get_u, no_set)]
    u: PhantomVar<f64>,
    #[var(get = get_v, no_set)]
    v: PhantomVar<f64>,
}

impl CadaclysmSpot {
    fn wrap(spot: bs::Spot) -> Gd<CadaclysmSpot> {
        Gd::from_object(CadaclysmSpot {
            spot,
            loop_index: PhantomVar::default(),
            segment: PhantomVar::default(),
            t: PhantomVar::default(),
            face: PhantomVar::default(),
            u: PhantomVar::default(),
            v: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmSpot {
    fn to_string(&self) -> GString {
        let s = &self.spot;
        gs(format!("Spot(loop_index={}, segment={}, t={}, face={}, u={}, v={})", s.loop_index, s.segment, s.t, s.face, s.u, s.v))
    }
}

#[godot_api]
impl CadaclysmSpot {
    #[func]
    fn get_loop_index(&self) -> i64 {
        self.spot.loop_index.into()
    }

    #[func]
    fn get_segment(&self) -> i64 {
        self.spot.segment.into()
    }

    #[func]
    fn get_t(&self) -> f64 {
        self.spot.t
    }

    #[func]
    fn get_face(&self) -> i64 {
        self.spot.face.into()
    }

    #[func]
    fn get_u(&self) -> f64 {
        self.spot.u
    }

    #[func]
    fn get_v(&self) -> f64 {
        self.spot.v
    }
}

/// One place two curves meet, as plain data, copied out: what `CadaclysmProfile.hits`
/// lists. A point has `run` false and `start` equal to `end`; a run has the two curves
/// coinciding from `start` to `end`.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmHit {
    hit: bs::Hit,
    #[var(get = get_run, no_set)]
    run: PhantomVar<bool>,
    #[var(get = get_touch, no_set)]
    touch: PhantomVar<bool>,
    #[var(get = get_start, no_set)]
    start: PhantomVar<Vector3>,
    #[var(get = get_end, no_set)]
    end: PhantomVar<Vector3>,
    #[var(get = get_raw_start, no_set)]
    raw_start: PhantomVar<PackedFloat64Array>,
    #[var(get = get_raw_end, no_set)]
    raw_end: PhantomVar<PackedFloat64Array>,
    #[var(get = get_a_start, no_set)]
    a_start: PhantomVar<Gd<CadaclysmSpot>>,
    #[var(get = get_a_end, no_set)]
    a_end: PhantomVar<Gd<CadaclysmSpot>>,
    #[var(get = get_b_start, no_set)]
    b_start: PhantomVar<Gd<CadaclysmSpot>>,
    #[var(get = get_b_end, no_set)]
    b_end: PhantomVar<Gd<CadaclysmSpot>>,
}

impl CadaclysmHit {
    fn wrap(hit: bs::Hit) -> Gd<CadaclysmHit> {
        Gd::from_object(CadaclysmHit {
            hit,
            run: PhantomVar::default(),
            touch: PhantomVar::default(),
            start: PhantomVar::default(),
            end: PhantomVar::default(),
            raw_start: PhantomVar::default(),
            raw_end: PhantomVar::default(),
            a_start: PhantomVar::default(),
            a_end: PhantomVar::default(),
            b_start: PhantomVar::default(),
            b_end: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmHit {
    fn to_string(&self) -> GString {
        let h = &self.hit;
        gs(format!("Hit(run={}, touch={}, start={:?}, end={:?})", h.run, h.touch, h.start, h.end))
    }
}

#[godot_api]
impl CadaclysmHit {
    #[func]
    fn get_run(&self) -> bool {
        self.hit.run
    }

    #[func]
    fn get_touch(&self) -> bool {
        self.hit.touch
    }

    #[func]
    fn get_start(&self) -> Vector3 {
        vector3(self.hit.start)
    }

    #[func]
    fn get_end(&self) -> Vector3 {
        vector3(self.hit.end)
    }

    /// `start` as three doubles, where a `Vector3` holds floats.
    #[func]
    fn get_raw_start(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.hit.start[..])
    }

    /// `end` as three doubles.
    #[func]
    fn get_raw_end(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.hit.end[..])
    }

    #[func]
    fn get_a_start(&self) -> Gd<CadaclysmSpot> {
        CadaclysmSpot::wrap(self.hit.a_start)
    }

    #[func]
    fn get_a_end(&self) -> Gd<CadaclysmSpot> {
        CadaclysmSpot::wrap(self.hit.a_end)
    }

    #[func]
    fn get_b_start(&self) -> Gd<CadaclysmSpot> {
        CadaclysmSpot::wrap(self.hit.b_start)
    }

    #[func]
    fn get_b_end(&self) -> Gd<CadaclysmSpot> {
        CadaclysmSpot::wrap(self.hit.b_end)
    }
}

// ---- CadaclysmSolid ----------------------------------------------------------------------

/// An exact B-rep solid (or open sheet). Immutable: every operation returns a new one,
/// or `null` with the reason in `Cadaclysm.last_error()`. Sizes are the model's own
/// units (millimetres, as a rule): scale the node that draws it into Godot's metres.
///
/// ```gdscript
/// var plate := CadaclysmSolid.extrude(CadaclysmProfile.rect(80, 40), CadaclysmFrame.xy(), 6)
/// var part := plate.cut(CadaclysmSolid.cylinder(4, 20).translate(0, 0, -5))
/// var node := MeshInstance3D.new()
/// node.mesh = part.array_mesh()
/// node.scale = Vector3.ONE * 0.001
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSolid {
    solid: Option<bs::Solid>,
    #[var(get = get_faces, no_set)]
    faces: PhantomVar<i64>,
    #[var(get = get_edges, no_set)]
    edges: PhantomVar<Array<Gd<CadaclysmEdge>>>,
    #[var(get = get_bounds, no_set)]
    bounds: PhantomVar<Aabb>,
    #[var(get = get_colour, no_set)]
    colour: PhantomVar<Variant>,
    #[var(get = get_manifold, no_set)]
    manifold: PhantomVar<VarDictionary>,
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
}

type Made = sdk::Result<bs::Solid>;

impl CadaclysmSolid {
    pub(crate) fn wrap(solid: bs::Solid) -> Gd<CadaclysmSolid> {
        Gd::from_object(CadaclysmSolid {
            solid: Some(solid),
            faces: PhantomVar::default(),
            edges: PhantomVar::default(),
            bounds: PhantomVar::default(),
            colour: PhantomVar::default(),
            manifold: PhantomVar::default(),
            closed: PhantomVar::default(),
        })
    }

    fn made(result: Made) -> Option<Gd<CadaclysmSolid>> {
        ok(result).map(CadaclysmSolid::wrap)
    }

    /// `loft_through` and `loft_through_open`: `[profile, frame]` pairs, in order.
    fn lofted_through(sections: &VarArray, solid: bool) -> Option<Gd<CadaclysmSolid>> {
        let what = if solid { "loft_through" } else { "loft_through_open" };
        let mut pairs = Vec::with_capacity(sections.len());
        for (i, item) in sections.iter_shared().enumerate() {
            let pair = match item.try_to::<VarArray>() {
                Ok(pair) if pair.len() == 2 => pair,
                _ => return fail(format!("{what}: section {i} is not a [profile, frame] pair")),
            };
            let Ok(profile) = pair.at(0).try_to::<Gd<CadaclysmProfile>>() else {
                return fail(format!("{what}: section {i}'s first item is not a CadaclysmProfile"));
            };
            pairs.push((profile, frame(&pair.at(1), &format!("{what}: section {i}'s frame"))?));
        }
        let guards: Vec<GdRef<CadaclysmProfile>> = pairs.iter().map(|(p, _)| p.bind()).collect();
        let refs: Vec<(&bs::Profile, &bs::Frame)> = guards.iter().zip(&pairs).map(|(g, (_, f))| (&g.profile, f)).collect();
        Self::made(if solid { bs::Solid::loft_through(&refs) } else { bs::Solid::loft_through_open(&refs) })
    }

    fn many(result: sdk::Result<Vec<bs::Solid>>) -> Array<Gd<CadaclysmSolid>> {
        ok(result).unwrap_or_default().into_iter().map(CadaclysmSolid::wrap).collect()
    }

    fn held(&self) -> Option<&bs::Solid> {
        match &self.solid {
            Some(solid) => Some(solid),
            None => fail("the solid is closed"),
        }
    }

    fn held_mut(&mut self) -> Option<&mut bs::Solid> {
        match &mut self.solid {
            Some(solid) => Some(solid),
            None => fail("the solid is closed"),
        }
    }

    /// `f` on this solid, its result wrapped.
    fn then(&self, f: impl FnOnce(&bs::Solid) -> Made) -> Option<Gd<CadaclysmSolid>> {
        Self::made(f(self.held()?))
    }

    /// `f` on this solid and `other` (which may be this one).
    fn with<R>(&self, other: &Gd<CadaclysmSolid>, f: impl FnOnce(&bs::Solid, &bs::Solid) -> sdk::Result<R>) -> Option<R> {
        let mine = self.held()?;
        let theirs = other.bind();
        ok(f(mine, theirs.held()?))
    }

    fn face_index(face: i64, what: &str) -> Option<u32> {
        match u32::try_from(face) {
            Ok(f) => Some(f),
            Err(_) => fail(format!("{what}: no face {face}")),
        }
    }

    /// A boolean's result, its flush faces merged where `merge` asks.
    fn combined(result: Option<bs::Solid>, merge: bool) -> Option<Gd<CadaclysmSolid>> {
        let solid = result?;
        if merge {
            return Self::made(solid.merge_flush());
        }
        Some(CadaclysmSolid::wrap(solid))
    }

    /// The feature edges at `tolerance`, copied out as runs end to end and their lengths.
    fn edge_runs(&mut self, tolerance: f64) -> Option<(Vec<[f32; 3]>, Vec<u32>)> {
        let runs = ok(self.held_mut()?.edge_polylines(tolerance))?;
        let positions = runs.iter().flat_map(|r| r.iter().copied()).collect();
        let counts = runs.iter().map(|r| r.len() as u32).collect();
        Some((positions, counts))
    }

    /// This solid's STEP text.
    fn own_step_text(&self, schema: &GString, unit: &GString) -> Option<String> {
        step_text_of(&[self.held()?], schema, unit)
    }
}

#[godot_api]
impl CadaclysmSolid {
    // -- building

    /// A box `x` by `y` by `z`.
    #[func]
    fn cuboid(x: f64, y: f64, z: f64) -> Option<Gd<CadaclysmSolid>> {
        Self::made(bs::Solid::cuboid(x, y, z))
    }

    /// A cylinder of radius `r`, `h` high along z.
    #[func]
    fn cylinder(r: f64, h: f64) -> Option<Gd<CadaclysmSolid>> {
        Self::made(bs::Solid::cylinder(r, h))
    }

    /// A cone of base radius `r`, `h` high along z.
    #[func]
    fn cone(r: f64, h: f64) -> Option<Gd<CadaclysmSolid>> {
        Self::made(bs::Solid::cone(r, h))
    }

    #[func]
    fn sphere(r: f64) -> Option<Gd<CadaclysmSolid>> {
        Self::made(bs::Solid::sphere(r))
    }

    /// A torus about z: `major` from the axis to the tube's centre, `minor` the tube's
    /// radius.
    #[func]
    fn torus(major: f64, minor: f64) -> Option<Gd<CadaclysmSolid>> {
        Self::made(bs::Solid::torus(major, minor))
    }

    /// A wedge: an `x` by `y` by `z` block whose top is `top_x` long in x.
    #[func]
    fn wedge(x: f64, y: f64, z: f64, top_x: f64) -> Option<Gd<CadaclysmSolid>> {
        Self::made(bs::Solid::wedge(x, y, z, top_x))
    }

    /// `profile`, drawn on `frame`, raised `height` along the frame's z.
    #[func]
    fn extrude(profile: Gd<CadaclysmProfile>, frame: Variant, height: f64) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "extrude: frame")?;
        Self::made(bs::Solid::extrude(&profile.bind().profile, &f, height))
    }

    /// `extrude` without the caps: an open sheet of walls.
    #[func]
    fn extrude_open(profile: Gd<CadaclysmProfile>, frame: Variant, height: f64) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "extrude_open: frame")?;
        Self::made(bs::Solid::extrude_open(&profile.bind().profile, &f, height))
    }

    /// `extrude` with a draft: the walls lean out by `taper` radians as they rise (in,
    /// when negative), every wall exact.
    #[func]
    fn extrude_tapered(profile: Gd<CadaclysmProfile>, frame: Variant, height: f64, taper: f64) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "extrude_tapered: frame")?;
        Self::made(bs::Solid::extrude_tapered(&profile.bind().profile, &f, height, taper))
    }

    /// `extrude_tapered` without the caps.
    #[func]
    fn extrude_open_tapered(profile: Gd<CadaclysmProfile>, frame: Variant, height: f64, taper: f64) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "extrude_open_tapered: frame")?;
        Self::made(bs::Solid::extrude_open_tapered(&profile.bind().profile, &f, height, taper))
    }

    /// `extrude` between two planes, each a number (flat at that height) or a slant
    /// `{at, grad: [gx, gy]}` -- the height `at + grad · p` over each sketch point (see
    /// `CadaclysmBlacksmith.slant_of_plane`). With both flat this is `extrude`.
    #[func]
    fn extrude_between(profile: Gd<CadaclysmProfile>, frame: Variant, bottom: Variant, top: Variant) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "extrude_between: frame")?;
        let (bottom, top) = (slant(&bottom, "extrude_between: bottom")?, slant(&top, "extrude_between: top")?);
        Self::made(bs::Solid::extrude_between(&profile.bind().profile, &f, bottom, top))
    }

    /// `extrude_between` without the caps.
    #[func]
    fn extrude_open_between(profile: Gd<CadaclysmProfile>, frame: Variant, bottom: Variant, top: Variant) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "extrude_open_between: frame")?;
        let (bottom, top) = (slant(&bottom, "extrude_open_between: bottom")?, slant(&top, "extrude_open_between: top")?);
        Self::made(bs::Solid::extrude_open_between(&profile.bind().profile, &f, bottom, top))
    }

    /// The solid between `a` on `frame_a` and `b` on `frame_b`: ruled walls between
    /// matching sides (the same number of sides, no holes), capped by the two.
    #[func]
    fn loft(a: Gd<CadaclysmProfile>, frame_a: Variant, b: Gd<CadaclysmProfile>, frame_b: Variant) -> Option<Gd<CadaclysmSolid>> {
        let (fa, fb) = (frame(&frame_a, "loft: frame_a")?, frame(&frame_b, "loft: frame_b")?);
        Self::made(bs::Solid::loft(&a.bind().profile, &fa, &b.bind().profile, &fb))
    }

    /// `loft` without the caps.
    #[func]
    fn loft_open(a: Gd<CadaclysmProfile>, frame_a: Variant, b: Gd<CadaclysmProfile>, frame_b: Variant) -> Option<Gd<CadaclysmSolid>> {
        let (fa, fb) = (frame(&frame_a, "loft_open: frame_a")?, frame(&frame_b, "loft_open: frame_b")?);
        Self::made(bs::Solid::loft_open(&a.bind().profile, &fa, &b.bind().profile, &fb))
    }

    /// The solid smooth through every section, in order -- each an `[profile, frame]`
    /// pair: each wall interpolates its side across all the profiles (cubic through four
    /// or more, quadratic through three, `loft` through two), capped by the first and the
    /// last. The profiles must have the same number of sides and no holes.
    #[func]
    fn loft_through(sections: VarArray) -> Option<Gd<CadaclysmSolid>> {
        Self::lofted_through(&sections, true)
    }

    /// `loft_through` without the caps: the sheet through the curves.
    #[func]
    fn loft_through_open(sections: VarArray) -> Option<Gd<CadaclysmSolid>> {
        Self::lofted_through(&sections, false)
    }

    /// `profile`, read as (distance from the axis, height along it), swung `angle`
    /// radians about the axis through `axis_point` along `axis_direction`.
    #[func]
    fn revolve(profile: Gd<CadaclysmProfile>, axis_point: Variant, axis_direction: Variant, angle: f64) -> Option<Gd<CadaclysmSolid>> {
        let axis = [v3(&axis_point, "revolve: axis_point")?, v3(&axis_direction, "revolve: axis_direction")?];
        Self::made(bs::Solid::revolve(&profile.bind().profile, &axis, angle))
    }

    /// `revolve` without the caps: an open profile turned into a sheet.
    #[func]
    fn revolve_open(profile: Gd<CadaclysmProfile>, axis_point: Variant, axis_direction: Variant, angle: f64) -> Option<Gd<CadaclysmSolid>> {
        let axis = [v3(&axis_point, "revolve_open: axis_point")?, v3(&axis_direction, "revolve_open: axis_direction")?];
        Self::made(bs::Solid::revolve_open(&profile.bind().profile, &axis, angle))
    }

    /// `profile`, drawn on `frame`, swung `angle` radians about the axis through the
    /// sketch points `a` and `b` -- the profile and its axis drawn together.
    #[func]
    fn revolve_in_plane(profile: Gd<CadaclysmProfile>, frame: Variant, a: Variant, b: Variant, angle: f64) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "revolve_in_plane: frame")?;
        let (a, b) = (v2(&a, "revolve_in_plane: a")?, v2(&b, "revolve_in_plane: b")?);
        Self::made(bs::Solid::revolve_in_plane(&profile.bind().profile, &f, a, b, angle))
    }

    /// `revolve_in_plane` without the caps.
    #[func]
    fn revolve_open_in_plane(profile: Gd<CadaclysmProfile>, frame: Variant, a: Variant, b: Variant, angle: f64) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "revolve_open_in_plane: frame")?;
        let (a, b) = (v2(&a, "revolve_open_in_plane: a")?, v2(&b, "revolve_open_in_plane: b")?);
        Self::made(bs::Solid::revolve_open_in_plane(&profile.bind().profile, &f, a, b, angle))
    }

    /// `profile` coiled about the axis through `axis_point` along `axis_direction`, read
    /// as `revolve` reads it, turned `turns` times while climbing `pitch` each turn: a
    /// spring, a thread.
    #[func]
    fn coil(profile: Gd<CadaclysmProfile>, axis_point: Variant, axis_direction: Variant, pitch: f64, turns: f64) -> Option<Gd<CadaclysmSolid>> {
        let axis = [v3(&axis_point, "coil: axis_point")?, v3(&axis_direction, "coil: axis_direction")?];
        Self::made(bs::Solid::coil(&profile.bind().profile, &axis, pitch, turns))
    }

    /// `profile`, drawn on `frame`, carried along `path` into a closed solid: a straight
    /// piece is an extrusion, a circular one a revolution, nothing approximated.
    #[func]
    fn sweep(profile: Gd<CadaclysmProfile>, frame: Variant, path: Gd<CadaclysmSweepPath>) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "sweep: frame")?;
        let path = path.bind();
        Self::made(bs::Solid::sweep(&profile.bind().profile, &f, path.held()?))
    }

    /// `sweep` for a curve: one wall per segment per piece, no caps.
    #[func]
    fn sweep_open(profile: Gd<CadaclysmProfile>, frame: Variant, path: Gd<CadaclysmSweepPath>) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "sweep_open: frame")?;
        let path = path.bind();
        Self::made(bs::Solid::sweep_open(&profile.bind().profile, &f, path.held()?))
    }

    /// A circle of `radius` swept along `path`: a rod, or with a positive `thickness` a
    /// tube whose walls are that thick.
    #[func]
    fn pipe(path: Gd<CadaclysmSweepPath>, radius: f64, #[opt(default = 0.0)] thickness: f64) -> Option<Gd<CadaclysmSolid>> {
        let path = path.bind();
        Self::made(bs::Solid::pipe(path.held()?, radius, thickness))
    }

    /// The flat sheet `profile` bounds on `frame`: one planar face, each hole a hole
    /// through it -- raise it with `extrude_faces`, cut it with `trim`.
    #[func]
    fn face(profile: Gd<CadaclysmProfile>, frame: Variant) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "face: frame")?;
        Self::made(bs::Solid::face(&profile.bind().profile, &f))
    }

    // -- from files

    /// The body `node` draws, as a solid, sharing the reader's B-rep rather than copying
    /// it: the scene can be closed first. `placed` puts it where the node's transform
    /// does, which needs the scene opened `{"convention": "native"}`; false keeps the
    /// node's own frame. In the file's own units and axes either way.
    #[func]
    fn from_node(node: Gd<CadaclysmNode>, #[opt(default = true)] placed: bool) -> Option<Gd<CadaclysmSolid>> {
        let node = node.bind();
        Self::made(reader::with_node(&node.shared, node.index, |n| bs::Solid::from_node(&n, placed))?)
    }

    /// The body a CAD file holds (STEP, ACIS, Rhino, OCCT `.brep`, IGES or IFC), read
    /// where it draws, in the file's own units and axes. A file of several bodies needs
    /// `body` (from 0, in drawing order), or `open_all`.
    #[func]
    fn open(path: GString, #[opt(default = -1)] body: i64) -> Option<Gd<CadaclysmSolid>> {
        let body = usize::try_from(body).ok();
        Self::made(bs::Solid::open(os_path(&path), body))
    }

    /// Every body a CAD file draws, as solids placed where it draws them: one per
    /// placement, so a part placed twice is two solids. Empty on failure.
    #[func]
    fn open_all(path: GString) -> Array<Gd<CadaclysmSolid>> {
        Self::many(bs::Solid::open_all(os_path(&path)))
    }

    /// Free it now rather than when the last reference goes; later calls fail with
    /// "closed". `ArrayMesh`es and `CadaclysmMesh`es made from it live on.
    #[func]
    fn close(&mut self) {
        self.solid = None;
    }

    #[func]
    fn get_closed(&self) -> bool {
        self.solid.is_none()
    }

    // -- one solid to another

    /// Face `face` alone, as an open sheet: what extruding a solid's face starts from.
    #[func]
    fn face_sheet(&self, face: i64) -> Option<Gd<CadaclysmSolid>> {
        let face = Self::face_index(face, "face_sheet")?;
        self.then(|s| s.face_sheet(face))
    }

    /// This solid without the faces at `faces`: the rest keep their order.
    #[func]
    fn drop_faces(&self, faces: PackedInt32Array) -> Option<Gd<CadaclysmSolid>> {
        let faces = packed_indices(&faces, "drop_faces: face")?;
        self.then(|s| s.drop_faces(&faces))
    }

    /// A sheet raised `height` along its faces' normals into a solid.
    #[func]
    fn extrude_faces(&self, height: f64) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.extrude_faces(height))
    }

    /// This solid moved so that its own XY frame lands on `frame`.
    #[func]
    fn place(&self, frame: Variant) -> Option<Gd<CadaclysmSolid>> {
        let f = self::frame(&frame, "place: frame")?;
        self.then(|s| s.place(&f))
    }

    #[func]
    fn translate(&self, dx: f64, dy: f64, dz: f64) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.translate(dx, dy, dz))
    }

    /// This solid turned `radians` about the axis through `axis_point` along
    /// `axis_direction`.
    #[func]
    fn rotate(&self, axis_point: Variant, axis_direction: Variant, radians: f64) -> Option<Gd<CadaclysmSolid>> {
        let axis = [v3(&axis_point, "rotate: axis_point")?, v3(&axis_direction, "rotate: axis_direction")?];
        self.then(|s| s.rotate(&axis, radians))
    }

    /// This solid mirrored in the plane through `plane`'s origin, square to its z.
    #[func]
    fn mirror(&self, plane: Variant) -> Option<Gd<CadaclysmSolid>> {
        let f = frame(&plane, "mirror: plane")?;
        self.then(|s| s.mirror(&f))
    }

    // -- combining

    /// This solid and `other` as one. `merge` then merges the flush faces the join
    /// leaves (`merge_flush`), as Fusion does.
    #[func]
    fn join(&self, other: Gd<CadaclysmSolid>, #[opt(default = 0.05)] tolerance: f64, #[opt(default = false)] merge: bool) -> Option<Gd<CadaclysmSolid>> {
        Self::combined(self.with(&other, |a, b| a.join(b, tolerance)), merge)
    }

    /// This solid with `other` removed.
    #[func]
    fn cut(&self, other: Gd<CadaclysmSolid>, #[opt(default = 0.05)] tolerance: f64, #[opt(default = false)] merge: bool) -> Option<Gd<CadaclysmSolid>> {
        Self::combined(self.with(&other, |a, b| a.cut(b, tolerance)), merge)
    }

    /// What this solid and `other` share.
    #[func]
    fn common(&self, other: Gd<CadaclysmSolid>, #[opt(default = 0.05)] tolerance: f64, #[opt(default = false)] merge: bool) -> Option<Gd<CadaclysmSolid>> {
        Self::combined(self.with(&other, |a, b| a.common(b, tolerance)), merge)
    }

    /// This sheet or solid cut along the closed `tool`'s boundary, the pieces on one
    /// side thrown away: `keep` `"outside"` (a hole punched through) or `"inside"` (cut
    /// to the tool's outline). The kept pieces come in this solid's face order.
    #[func]
    fn trim(&self, tool: Gd<CadaclysmSolid>, #[opt(default = "outside")] keep: GString, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        let keep = keep_side(&keep)?;
        self.with(&tool, |a, b| a.trim(b, keep, tolerance)).map(CadaclysmSolid::wrap)
    }

    /// This solid cut along `tool`'s boundary, nothing removed: each face's pieces
    /// outside `tool`, then its pieces inside.
    #[func]
    fn split_sheet(&self, tool: Gd<CadaclysmSolid>, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        self.with(&tool, |a, b| a.split_sheet(b, tolerance)).map(CadaclysmSolid::wrap)
    }

    /// Round `edges` (`CadaclysmEdge`s or their indices) to `radius`.
    #[func]
    fn fillet(&self, edges: Variant, radius: f64, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        let edges = indices(&edges, "fillet: edges")?;
        self.then(|s| s.fillet(&edges, radius, tolerance))
    }

    /// `fillet` with a flat bevel: each edge cut back `distance` along both its faces.
    #[func]
    fn chamfer(&self, edges: Variant, distance: f64, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        let edges = indices(&edges, "chamfer: edges")?;
        self.then(|s| s.chamfer(&edges, distance, tolerance))
    }

    /// Face `face` pushed out by `distance` along its outward normal (in, negative) and
    /// the flush faces merged, as Fusion and Rhino extrude a face. A face on a cylinder,
    /// a cone, a sphere or a torus moves out along its normal instead, the flat faces
    /// beside it carried along.
    ///
    /// `face` may be a list of faces (ints or a `PackedInt32Array`), pushed together as
    /// Fusion's press-pull on a selection: a box's top and a side pushed 5 is the box 5
    /// taller and 5 wider.
    #[func]
    fn push_pull(&self, face: Variant, distance: f64, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        if face.get_type() == VariantType::INT {
            let face = Self::face_index(face.to::<i64>(), "push_pull")?;
            return self.then(|s| s.push_pull(face, distance, tolerance));
        }
        let faces = indices(&face, "push_pull: faces")?;
        self.then(|s| s.push_pull_faces(&faces, distance, tolerance))
    }

    /// This solid split by `tool` into bodies: a closed tool gives the parts outside it,
    /// then the parts inside; a flat sheet splits by its whole plane. Empty on failure.
    #[func]
    fn split(&self, tool: Gd<CadaclysmSolid>, #[opt(default = 0.05)] tolerance: f64) -> Array<Gd<CadaclysmSolid>> {
        let parts = self.with(&tool, |a, b| a.split(b, tolerance));
        parts.unwrap_or_default().into_iter().map(CadaclysmSolid::wrap).collect()
    }

    /// This solid split by the plane through `plane`'s origin, square to its z: the
    /// bodies in front of it first, then those behind. Empty on failure.
    #[func]
    fn split_by_plane(&self, plane: Variant, #[opt(default = 0.05)] tolerance: f64) -> Array<Gd<CadaclysmSolid>> {
        let (Some(f), Some(s)) = (frame(&plane, "split_by_plane: plane"), self.held()) else { return Array::new() };
        Self::many(s.split_by_plane(&f, tolerance))
    }

    /// This solid's connected bodies, each a solid of its own, in the order of their
    /// first faces.
    #[func]
    fn lumps(&self) -> Array<Gd<CadaclysmSolid>> {
        self.held().map(|s| Self::many(s.lumps())).unwrap_or_default()
    }

    /// This solid with its flush faces merged: the seams a `join` leaves where two
    /// parts are flush.
    #[func]
    fn merge_flush(&self) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.merge_flush())
    }

    /// The round `face` belongs to, made again at `radius` (Fusion's press-pull on a
    /// fillet face).
    #[func]
    fn refillet(&self, face: i64, radius: f64, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        let face = Self::face_index(face, "refillet")?;
        self.then(|s| s.refillet(face, radius, tolerance))
    }

    /// The round `face` belongs to taken off, the faces beside it sharp again.
    #[func]
    fn unfillet(&self, face: i64) -> Option<Gd<CadaclysmSolid>> {
        let face = Self::face_index(face, "unfillet")?;
        self.then(|s| s.unfillet(face))
    }

    /// The chamfer `face` belongs to, cut again at `distance`.
    #[func]
    fn rechamfer(&self, face: i64, distance: f64, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        let face = Self::face_index(face, "rechamfer")?;
        self.then(|s| s.rechamfer(face, distance, tolerance))
    }

    /// The chamfer `face` belongs to taken off, the faces beside it sharp again.
    #[func]
    fn unchamfer(&self, face: i64) -> Option<Gd<CadaclysmSolid>> {
        let face = Self::face_index(face, "unchamfer")?;
        self.then(|s| s.unchamfer(face))
    }

    /// This solid hollowed to walls `thickness` thick, the faces at `open` removed so
    /// the hollow is reachable.
    #[func]
    fn shell(
        &self,
        thickness: f64,
        #[opt(default = &PackedInt32Array::new())] open: PackedInt32Array,
        #[opt(default = 1e-6)] tolerance: f64,
    ) -> Option<Gd<CadaclysmSolid>> {
        let open = packed_indices(&open, "shell: face")?;
        self.then(|s| s.shell(thickness, &open, tolerance))
    }

    /// This sheet made a solid `thickness` thick (Fusion's Thicken): its faces, their
    /// twins moved along the faces' normals, and a wall round every open edge.
    #[func]
    fn thicken(&self, thickness: f64, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.thicken(thickness, tolerance))
    }

    // -- colour

    /// This solid coloured `colour` (a `Color`, `"#rrggbb"`, or three numbers in 0..1),
    /// or with `face` just that face, whose colour then wins over the solid's. What is
    /// made from a coloured solid inherits its colours.
    #[func]
    fn coloured(&self, colour: Variant, #[opt(default = -1)] face: i64) -> Option<Gd<CadaclysmSolid>> {
        let solid = self.held()?;
        let rgb = colour_arg(&colour)?;
        let face = match face {
            -1 => None,
            f => match u32::try_from(f) {
                Ok(f) if f != bs::NONE => Some(f),
                _ => {
                    let count = solid.faces().unwrap_or_default();
                    return fail(format!("coloured: face {f} is not one of the solid's {count}"));
                }
            },
        };
        Self::made(solid.coloured(rgb, face))
    }

    /// Its colour, or `null` where it has none.
    #[func]
    fn get_colour(&self) -> Variant {
        self.held().and_then(|s| ok(s.colour())).map_or(Variant::nil(), colour_out)
    }

    /// Face `face`'s colour as drawn -- its own, else the solid's -- or `null`.
    #[func]
    fn face_colour(&self, face: i64) -> Variant {
        let Some(solid) = self.held() else { return Variant::nil() };
        let colour = match u32::try_from(face) {
            Ok(f) => ok(solid.face_colour(f)),
            Err(_) => {
                let count = solid.faces().unwrap_or_default();
                fail(format!("colour: face {face} is not one of the solid's {count}"))
            }
        };
        colour.map_or(Variant::nil(), colour_out)
    }

    // -- asking

    /// How many faces it has.
    #[func]
    fn get_faces(&self) -> i64 {
        self.held().and_then(|s| ok(s.faces())).unwrap_or_default().into()
    }

    /// What surface `face` lies on: `"plane"`, `"cylinder"`, `"cone"`, `"sphere"`...;
    /// `""` for no such face.
    #[func]
    fn face_kind(&self, face: i64) -> GString {
        let kind = Self::face_index(face, "face_kind").and_then(|f| ok(self.held()?.face_kind(f)));
        gs(kind.unwrap_or_default())
    }

    /// The face a selector picks, or -1: `">Z"` (furthest along +Z), `"<X"` (furthest
    /// along -X)..., a normal (a `Vector3` or three numbers: the face facing it), or an
    /// index.
    #[func]
    fn select_face(&self, selector: Variant) -> i64 {
        let Some(selector) = self::selector(&selector, "select_face") else { return -1 };
        self.held().and_then(|s| ok(s.select_face(&selector))).map_or(-1, i64::from)
    }

    /// The workplane on `face`: its centre, world X laid onto it and its outward normal,
    /// as `CadaclysmFrame.at` lays them.
    #[func]
    fn face_frame(&self, face: i64) -> Option<Gd<CadaclysmFrame>> {
        let face = Self::face_index(face, "face_frame")?;
        ok(self.held()?.face_frame(face)).map(CadaclysmFrame::wrap)
    }

    /// Face `face` by what it is, eight doubles: the surface's kind (plane 0, cylinder 1,
    /// cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8), a point on
    /// the surface at the face's middle (x y z), the outward normal there (x y z), and the
    /// face's extent -- what a feature made on the face keeps, to find the face again with
    /// `find_face` when the solid has been rebuilt with its faces moved, split or
    /// renumbered. Take it before any move you apply to the solid, and look it up on the
    /// unmoved one. Empty on failure.
    #[func]
    fn face_ref(&self, face: i64) -> PackedFloat64Array {
        let Some(face) = Self::face_index(face, "face_ref") else { return PackedFloat64Array::new() };
        self.held().and_then(|s| ok(s.face_ref(face))).map(|r| PackedFloat64Array::from(&r[..])).unwrap_or_default()
    }

    /// The face `face_ref` (from `face_ref`) refers to: among the faces of that kind whose
    /// surface passes through the point, facing the same way, the one the point lies in --
    /// or, where it lies in none, the one whose boundary comes nearest. `hint` is the index
    /// the face had, preferred among faces that fit equally well (negative for none);
    /// `tolerance` how far the point may sit off a surface to still be on it. -1 where the
    /// face is gone or on failure.
    #[func]
    fn find_face(&self, face_ref: PackedFloat64Array, #[opt(default = -1)] hint: i64, #[opt(default = 1e-3)] tolerance: f64) -> i64 {
        let Ok(r) = <[f64; 8]>::try_from(face_ref.as_slice()) else {
            return fail::<()>("find_face: a face reference is eight numbers").map_or(-1, |()| -1);
        };
        let hint = u32::try_from(hint).ok();
        self.held().and_then(|s| ok(s.find_face(&r, hint, tolerance))).flatten().map_or(-1, i64::from)
    }

    /// The axis-aligned box around its mesh at the default tolerance.
    #[func]
    fn get_bounds(&self) -> Aabb {
        self.bounds_at(bs::DEFAULT_TOLERANCE)
    }

    /// The axis-aligned box around its mesh at `tolerance` (the same cache `mesh`
    /// fills).
    #[func]
    fn bounds_at(&self, tolerance: f64) -> Aabb {
        self.held().and_then(|s| ok(s.bounds_at(tolerance))).map(|(lo, hi)| aabb(lo, hi)).unwrap_or_default()
    }

    /// The same box as six doubles: min x, y, z, then max x, y, z. Empty on failure.
    #[func]
    fn raw_bounds(&self, #[opt(default = 0.05)] tolerance: f64) -> PackedFloat64Array {
        let bounds = self.held().and_then(|s| ok(s.bounds_at(tolerance)));
        bounds.map(|(lo, hi)| PackedFloat64Array::from(&[lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]][..])).unwrap_or_default()
    }

    /// How many edges of the mesh at `tolerance` are bound by anything other than
    /// exactly two triangles -- zero for a closed solid; -1 on failure.
    #[func]
    fn leaked_edges(&self, #[opt(default = 0.05)] tolerance: f64) -> i64 {
        self.held().and_then(|s| ok(s.leaked_edges(tolerance))).map_or(-1, i64::from)
    }

    /// How many edges of the mesh at `tolerance` have triangle uses that do not cancel
    /// -- zero for a closed, consistently oriented solid; -1 on failure.
    #[func]
    fn unpaired_edges(&self, #[opt(default = 0.05)] tolerance: f64) -> i64 {
        self.held().and_then(|s| ok(s.unpaired_edges(tolerance))).map_or(-1, i64::from)
    }

    /// Whether its mesh at `tolerance` leaks nowhere (`leaked_edges` is zero).
    #[func]
    fn is_watertight(&self, #[opt(default = 0.05)] tolerance: f64) -> bool {
        self.held().and_then(|s| ok(s.is_watertight(tolerance))).unwrap_or(false)
    }

    /// Whether its faces make a manifold, read off the topology: `{faces, edges,
    /// vertices, boundary_edges, non_manifold_edges, non_manifold_vertices, is_manifold,
    /// is_closed}`.
    #[func]
    fn get_manifold(&self) -> VarDictionary {
        self.held().and_then(|s| ok(s.manifold())).map(reader::manifold).unwrap_or_default()
    }

    /// Its edges, whose indices `fillet` and `chamfer` take.
    #[func]
    fn get_edges(&self) -> Array<Gd<CadaclysmEdge>> {
        self.held().and_then(|s| ok(s.edges())).unwrap_or_default().into_iter().map(CadaclysmEdge::wrap).collect()
    }

    // -- out

    /// Its triangles at `tolerance`, copied out: positions, normals, three indices a
    /// triangle (wound counter-clockwise; `array_mesh` winds them for Godot).
    #[func]
    fn mesh(&mut self, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmMesh>> {
        let mesh = ok(self.held_mut()?.mesh(tolerance))?;
        Some(CadaclysmMesh::wrap(mesh.copy()))
    }

    /// Its feature edges at `tolerance`, as polylines.
    #[func]
    fn edge_polylines(&mut self, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmPolylines>> {
        let (positions, counts) = self.edge_runs(tolerance)?;
        Some(CadaclysmPolylines::from_runs(positions, counts))
    }

    /// Its triangles at `tolerance` as an `ArrayMesh`, wound for Godot, painted its
    /// colour (or grey), both sides drawn where it is an open sheet.
    #[func]
    fn array_mesh(&mut self, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<ArrayMesh>> {
        let solid = self.held()?;
        let colour = ok(solid.colour())?.map(|[r, g, b]| [r as f32, g as f32, b as f32, 1.0]);
        let closed = solid.manifold().map(|m| m.is_closed).unwrap_or(true);
        let mesh = ok(self.held_mut()?.mesh(tolerance))?;
        let Some(mut out) = meshes::triangles(&mesh) else { return fail("array_mesh: the solid meshes to no triangles") };
        let material = meshes::material_for(colour, false);
        out.surface_set_material(0, &if closed { material } else { meshes::double_sided(&material) });
        Some(out)
    }

    /// Its feature edges at `tolerance` as a `lines` `ArrayMesh`, unshaded in `colour`.
    #[func]
    fn edge_mesh(
        &mut self,
        #[opt(default = 0.05)] tolerance: f64,
        #[opt(default = Color::from_rgb(0.07, 0.07, 0.08))] colour: Color,
    ) -> Option<Gd<ArrayMesh>> {
        let (positions, counts) = self.edge_runs(tolerance)?;
        let lines = sdk::Polylines { positions: &positions, counts: &counts };
        let Some(mut out) = meshes::lines(&[lines], None) else { return fail("edge_mesh: the solid has no edges") };
        out.surface_set_material(0, &meshes::edge_material(colour));
        Some(out)
    }

    /// This solid as STEP text; `schema` and `unit` as `CadaclysmBlacksmith.write_step_text`
    /// takes them. `""` on failure.
    #[func]
    fn step_text(&self, #[opt(default = "")] schema: GString, #[opt(default = "mm")] unit: GString) -> GString {
        gs(self.own_step_text(&schema, &unit).unwrap_or_default())
    }

    /// This solid written to a STEP file at `path`.
    #[func]
    fn step(&self, path: GString, #[opt(default = "")] schema: GString, #[opt(default = "mm")] unit: GString) -> bool {
        match self.own_step_text(&schema, &unit) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// This solid as ACIS SAT text; `unit` as `CadaclysmBlacksmith.write_sat_text` takes it.
    /// `""` on failure.
    #[func]
    fn sat_text(&self, #[opt(default = "mm")] unit: GString) -> GString {
        gs(self.held().and_then(|s| sat_text_of(&[s], &unit)).unwrap_or_default())
    }

    /// This solid written to an ACIS SAT file at `path`.
    #[func]
    fn sat(&self, path: GString, #[opt(default = "mm")] unit: GString) -> bool {
        match self.held().and_then(|s| sat_text_of(&[s], &unit)) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// This solid as OCCT `.brep` text; see `CadaclysmBlacksmith.write_brep_text`. `""` on failure.
    #[func]
    fn brep_text(&self) -> GString {
        gs(self.held().and_then(|s| ok(bs::write_brep_text(&[s]))).unwrap_or_default())
    }

    /// This solid written to a `.brep` file at `path`.
    #[func]
    fn brep(&self, path: GString) -> bool {
        match self.held().and_then(|s| ok(bs::write_brep_text(&[s]))) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// This solid's wireframe as SVG text, from the camera the viewer's `"iso"` angle
    /// describes -- the library's own camera, not a viewer. `""` on a refused option.
    #[func]
    fn svg_text(&self) -> GString {
        self.svg_text_with(VarDictionary::new())
    }

    /// `svg_text`, with options: see `CadaclysmScene.svg_text_with` for every key --
    /// `up` left out is always `"z"` here, this solid carrying no convention of its
    /// own for a scene to default it from.
    #[func]
    fn svg_text_with(&self, options: VarDictionary) -> GString {
        let Some(opts) = reader::svg_options(&options) else { return GString::new() };
        gs(self.held().and_then(|s| svg_text_of(&[s], &opts)).unwrap_or_default())
    }

    /// This solid written to an SVG file at `path`, by the library itself.
    #[func]
    fn svg(&self, path: GString) -> bool {
        self.svg_with(path, VarDictionary::new())
    }

    /// `svg`, with options: see `svg_text_with`.
    #[func]
    fn svg_with(&self, path: GString, options: VarDictionary) -> bool {
        let Some(opts) = reader::svg_options(&options) else { return false };
        match self.held().and_then(|s| svg_text_of(&[s], &opts)) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// This solid as a reader `CadaclysmScene`, through STEP text: the door to the tree walk
    /// and everything the reader draws, in the kernel's own axes and units.
    #[func]
    fn to_scene(&self, #[opt(default = "")] schema: GString) -> Option<Gd<CadaclysmScene>> {
        let schema = schema_arg(&schema);
        ok(self.held()?.to_scene(schema.as_deref())).map(CadaclysmScene::wrap)
    }
}

// ---- CadaclysmWorkplane ------------------------------------------------------------------

/// The fluent chain: a frame, the solid built so far, and the face last picked. A
/// build call *replaces* the solid; combine solids with `CadaclysmSolid.join`. Each step
/// returns the chain itself, or `null` where it fails.
///
/// ```gdscript
/// var plate := CadaclysmWorkplane.xy().extrude(outline, 6).solid()
/// var pin := CadaclysmWorkplane.from_solid(plate).faces(">Z").workplane().cylinder(4, 10).solid()
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmWorkplane {
    base: Base<RefCounted>,
    frame: bs::Frame,
    solid: Option<Gd<CadaclysmSolid>>,
    selected: Option<u32>,
    #[var(rename = frame, get = get_frame, no_set)]
    frame_: PhantomVar<Gd<CadaclysmFrame>>,
}

impl CadaclysmWorkplane {
    fn start(frame: bs::Frame, solid: Option<Gd<CadaclysmSolid>>) -> Gd<CadaclysmWorkplane> {
        Gd::from_init_fn(|base| CadaclysmWorkplane { base, frame, solid, selected: None, frame_: PhantomVar::default() })
    }

    /// Hold `made` as the solid built so far, the face selection cleared.
    fn set(&mut self, made: Option<Gd<CadaclysmSolid>>) -> Option<Gd<CadaclysmWorkplane>> {
        self.solid = Some(made?);
        self.selected = None;
        Some(self.to_gd())
    }

    fn held(&self, what: &str) -> Option<Gd<CadaclysmSolid>> {
        match &self.solid {
            Some(solid) => Some(solid.clone()),
            None => fail(format!("{what}: the workplane holds no solid (BuildError::Empty)")),
        }
    }
}

#[godot_api]
impl CadaclysmWorkplane {
    #[func]
    fn xy() -> Gd<CadaclysmWorkplane> {
        CadaclysmWorkplane::start(bs::Frame::xy([0.0; 3]), None)
    }

    #[func]
    fn xz() -> Gd<CadaclysmWorkplane> {
        CadaclysmWorkplane::start(bs::Frame::xz([0.0; 3]), None)
    }

    #[func]
    fn yz() -> Gd<CadaclysmWorkplane> {
        CadaclysmWorkplane::start(bs::Frame::yz([0.0; 3]), None)
    }

    /// A chain on `frame` (a `CadaclysmFrame`, a `Transform3D` or twelve numbers).
    #[func]
    fn on(frame: Variant) -> Option<Gd<CadaclysmWorkplane>> {
        let f = self::frame(&frame, "Workplane.on: frame")?;
        clear_error();
        Some(CadaclysmWorkplane::start(f, None))
    }

    /// A chain on the XY plane holding `solid`, so faces of it can be picked.
    #[func]
    fn from_solid(solid: Gd<CadaclysmSolid>) -> Gd<CadaclysmWorkplane> {
        CadaclysmWorkplane::start(bs::Frame::xy([0.0; 3]), Some(solid))
    }

    /// The frame the next build call draws on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.frame)
    }

    /// A box placed on the frame.
    #[func]
    fn cuboid(&mut self, x: f64, y: f64, z: f64) -> Option<Gd<CadaclysmWorkplane>> {
        let frame = self.frame;
        self.set(CadaclysmSolid::made(bs::Solid::cuboid(x, y, z).and_then(|s| s.place(&frame))))
    }

    /// A cylinder placed on the frame.
    #[func]
    fn cylinder(&mut self, r: f64, h: f64) -> Option<Gd<CadaclysmWorkplane>> {
        let frame = self.frame;
        self.set(CadaclysmSolid::made(bs::Solid::cylinder(r, h).and_then(|s| s.place(&frame))))
    }

    /// `profile` extruded `height` from the frame.
    #[func]
    fn extrude(&mut self, profile: Gd<CadaclysmProfile>, height: f64) -> Option<Gd<CadaclysmWorkplane>> {
        let made = CadaclysmSolid::made(bs::Solid::extrude(&profile.bind().profile, &self.frame, height));
        self.set(made)
    }

    /// The flat sheet `profile` bounds on the frame.
    #[func]
    fn face(&mut self, profile: Gd<CadaclysmProfile>) -> Option<Gd<CadaclysmWorkplane>> {
        let made = CadaclysmSolid::made(bs::Solid::face(&profile.bind().profile, &self.frame));
        self.set(made)
    }

    /// `profile` revolved `angle` radians about the frame's own y axis through its
    /// origin.
    #[func]
    fn revolve(&mut self, profile: Gd<CadaclysmProfile>, angle: f64) -> Option<Gd<CadaclysmWorkplane>> {
        let axis = [self.frame.origin(), self.frame.y()];
        let made = CadaclysmSolid::made(bs::Solid::revolve(&profile.bind().profile, &axis, angle));
        self.set(made)
    }

    /// Slide the current solid, keeping the face picked: a translation carries every
    /// face along at the same index.
    #[func]
    fn translate(&mut self, dx: f64, dy: f64, dz: f64) -> Option<Gd<CadaclysmWorkplane>> {
        let held = self.held("translate")?;
        let moved = held.bind().translate(dx, dy, dz)?;
        self.solid = Some(moved);
        Some(self.to_gd())
    }

    /// Pick a face of the current solid: a selector as `CadaclysmSolid.select_face` takes.
    #[func]
    fn faces(&mut self, selector: Variant) -> Option<Gd<CadaclysmWorkplane>> {
        let held = self.held("faces")?;
        let selector = self::selector(&selector, "faces")?;
        let face = held.bind().held().and_then(|s| ok(s.select_face(&selector)))?;
        self.selected = Some(face);
        Some(self.to_gd())
    }

    /// Adopt the frame on the face last picked; a no-op if none is.
    #[func]
    fn workplane(&mut self) -> Option<Gd<CadaclysmWorkplane>> {
        if let (Some(solid), Some(face)) = (&self.solid, self.selected) {
            let frame = solid.bind().held().and_then(|s| ok(s.face_frame(face)))?;
            self.frame = frame;
        }
        Some(self.to_gd())
    }

    /// The solid built, or `null` where nothing was.
    #[func]
    fn solid(&self) -> Option<Gd<CadaclysmSolid>> {
        match &self.solid {
            Some(solid) => Some(solid.clone()),
            None => fail("solid: nothing was built (BuildError::Empty)"),
        }
    }
}
