//! The kernel: `CadaclysmBlacksmith` (the library's own functions), `CadaclysmFrame`, `CadaclysmProfile`,
//! `CadaclysmPath`, `CadaclysmSweepPath`, `CadaclysmSolid`, `CadaclysmAssembly`, `CadaclysmEdge`, `CadaclysmHit`,
//! the curves in space (`CadaclysmNurbsCurve`, `CadaclysmCurvature`) and the records of the sheets
//! made from them (`CadaclysmContinuity`, `CadaclysmPatchReport`, `CadaclysmJoinReport`),
//! `CadaclysmSpot`, `CadaclysmWorkplane`, `CadaclysmSolidFemMesh`, the 2D sketcher (`CadaclysmSketch`,
//! `CadaclysmSolveReport`, `CadaclysmDof`, `CadaclysmPartDof`), the R-tree (`CadaclysmRTree`,
//! `CadaclysmRTreeHit`, `CadaclysmRTreePair`), `CadaclysmInterpolator`, the regions of a merge
//! (`CadaclysmRegion`, `CadaclysmFaceSide`), `CadaclysmHistory` and the CAM surface --
//! `CadaclysmTool`, `CadaclysmStock`, `CadaclysmJob`, `CadaclysmProgram`, `CadaclysmOperation`,
//! `CadaclysmReport` and `CadaclysmReportItem`.
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
use std::cell::RefCell;

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

/// One entry of `CadaclysmAssembly.pair`'s `ranges`: `[lower, upper]`, each side `null`
/// for unbounded (`PairOptions`'s own per-side `None`) or a number for a bound.
fn range_item(v: &Variant, what: &str) -> Option<(Option<f64>, Option<f64>)> {
    let Ok(pair) = v.try_to::<AnyArray>() else {
        return fail(format!("{what}: expected [lower, upper], not {v}"));
    };
    if pair.len() != 2 {
        return fail(format!("{what}: expected [lower, upper], got {} items", pair.len()));
    }
    let side = |side: Variant, which: &str| -> Option<Option<f64>> {
        if side.is_nil() {
            Some(None)
        } else {
            match number(&side) {
                Some(n) => Some(Some(n)),
                None => fail(format!("{what}: {which} must be a number or null, not {side}")),
            }
        }
    };
    let lower = side(pair.at(0), "lower")?;
    let upper = side(pair.at(1), "upper")?;
    Some((lower, upper))
}

/// `CadaclysmAssembly.pair`'s `ranges`: an array of `[lower, upper]` pairs. Empty reads
/// as `PairOptions::ranges` `None` ("no ranges given") -- this is Godot's own idiom, not
/// the C ABI's: the C ABI distinguishes "no ranges" (all four pointers null) from "zero
/// ranges given" (non-null pointers, count 0), and a `kind` with freedoms refuses the
/// latter. Godot has no null-vs-empty-array distinction worth a separate `Variant` here
/// (unlike `end_frame`), so an empty GDScript array always means "no ranges" by this
/// wrapper's own choice (controller ruling), not a pass-through of the kernel's distinction.
fn ranges_arg(v: &AnyArray, what: &str) -> Option<Option<Vec<(Option<f64>, Option<f64>)>>> {
    if v.len() == 0 {
        return Some(None);
    }
    let mut out = Vec::with_capacity(v.len());
    for (i, item) in v.iter_shared().enumerate() {
        out.push(range_item(&item, &format!("{what}[{i}]"))?);
    }
    Some(Some(out))
}

/// One row of `CadaclysmAssembly.state`'s `rows`: `[joint, values]`, `joint` a `String`
/// and `values` a `PackedFloat64Array` (or any array of numbers).
fn state_row(v: &Variant, what: &str) -> Option<(String, Vec<f64>)> {
    let Ok(row) = v.try_to::<AnyArray>() else {
        return fail(format!("{what}: expected [joint, values], not {v}"));
    };
    if row.len() != 2 {
        return fail(format!("{what}: expected [joint, values], got {} items", row.len()));
    }
    let joint = row.at(0).to_string();
    let values = number_list(&row.at(1), &format!("{what}.values"))?;
    Some((joint, values))
}

/// `CadaclysmAssembly.state`'s `rows`: an array of `[joint, values]` rows, in the
/// caller's order -- Godot's spelling of the SDK's `&[(&str, &[f64])]`.
fn state_rows_arg(v: &AnyArray, what: &str) -> Option<Vec<(String, Vec<f64>)>> {
    let mut out = Vec::with_capacity(v.len());
    for (i, item) in v.iter_shared().enumerate() {
        out.push(state_row(&item, &format!("{what}[{i}]"))?);
    }
    Some(out)
}

/// A joint key for `CadaclysmAssembly.posed`: a `String` already a path (placement names
/// then the joint's name joined by "/", a "/" or "\" inside a name escaped with "\"), or an
/// array of the names, which this escapes and joins like Python's `_joint_path`.
fn joint_path(v: &Variant, what: &str) -> Option<String> {
    match v.get_type() {
        VariantType::STRING | VariantType::STRING_NAME => Some(v.to_string()),
        VariantType::ARRAY | VariantType::PACKED_STRING_ARRAY => {
            let names: Vec<String> = match v.get_type() {
                VariantType::ARRAY => v.try_to::<AnyArray>().ok()?.iter_shared().map(|n| n.to_string()).collect(),
                _ => v.to::<PackedStringArray>().as_slice().iter().map(|n| n.to_string()).collect(),
            };
            if names.is_empty() {
                return fail(format!("{what}: a joint path needs at least the joint's name"));
            }
            let escaped: Vec<String> = names.iter().map(|n| n.replace('\\', "\\\\").replace('/', "\\/")).collect();
            Some(escaped.join("/"))
        }
        _ => fail(format!("{what}: expected a joint path (a String or an array of names), not {v}")),
    }
}

/// `CadaclysmAssembly.posed`'s `values`: a `Dictionary` of joint key to value, an array
/// of `[key, value]` rows, or nil for none; a value is one number (a one-freedom joint)
/// or a list of numbers in the pair's freedom order.
fn posed_rows_arg(v: &Variant, what: &str) -> Option<Vec<(String, Vec<f64>)>> {
    let mut pairs: Vec<(Variant, Variant)> = Vec::new();
    match v.get_type() {
        VariantType::NIL => {}
        VariantType::DICTIONARY => pairs.extend(v.to::<VarDictionary>().iter_shared()),
        VariantType::ARRAY => {
            for (i, item) in v.to::<AnyArray>().iter_shared().enumerate() {
                let Ok(row) = item.try_to::<AnyArray>() else {
                    return fail(format!("{what}[{i}]: expected [joint, values], not {item}"));
                };
                if row.len() != 2 {
                    return fail(format!("{what}[{i}]: expected [joint, values], got {} items", row.len()));
                }
                pairs.push((row.at(0), row.at(1)));
            }
        }
        _ => return fail(format!("{what}: expected a Dictionary or an array of [joint, values] rows, not {v}")),
    }
    let mut out = Vec::with_capacity(pairs.len());
    for (i, (key, value)) in pairs.iter().enumerate() {
        let path = joint_path(key, &format!("{what}[{i}]"))?;
        let values = match number(value) {
            Some(x) => vec![x],
            None => number_list(value, &format!("{what}[{i}].values"))?,
        };
        out.push((path, values));
    }
    Some(out)
}

/// `[[state, t, interpolation], ...]` as `Assembly::sequence` takes it.
fn sequence_rows_arg(v: &AnyArray, what: &str) -> Option<Vec<(String, f64, String)>> {
    let mut out = Vec::with_capacity(v.len());
    for (i, item) in v.iter_shared().enumerate() {
        let what = format!("{what}[{i}]");
        let Ok(row) = item.try_to::<AnyArray>() else { return fail(format!("{what}: expected [state, t, interpolation]")) };
        if row.len() != 3 {
            return fail(format!("{what}: expected [state, t, interpolation]"));
        }
        let Ok(state) = row.at(0).try_to::<GString>() else { return fail(format!("{what}: state must be a String")) };
        let Ok(t) = row.at(1).try_to::<f64>() else { return fail(format!("{what}: t must be a number")) };
        let Ok(word) = row.at(2).try_to::<GString>() else { return fail(format!("{what}: interpolation must be a String")) };
        out.push((state.to_string(), t, word.to_string()));
    }
    Some(out)
}

/// A Grbl tool number from GDScript's `int`: a negative one clamped to 0, as every other
/// wrapper does, so the library refuses it in its own words ("tool: number must be at least
/// 1") rather than this one in a message of its own.
fn tool_number(number: i64) -> u32 {
    u32::try_from(number).unwrap_or(if number < 0 { 0 } else { u32::MAX })
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

/// A frame: a `CadaclysmFrame`, a `Transform3D`, twelve numbers or four triples. As
/// Python's `_frame` -- twelve raw numbers go through **unchecked**
/// (`bs::Frame::raw_unchecked`), the kernel's own call left to refuse them: only
/// `CadaclysmFrame.create` (and `.at`) checks square, unit, right-handed axes at
/// construction. `CadaclysmFrame.of` re-checks a raw array itself, on top of this
/// helper, since it -- unlike every other frame-taking call -- **is** the checked
/// constructor for one; see its own doc. This is what lets spec §5 fact 7 (a mirrored
/// raw frame refused "right-handed and orthonormal", in the library's own words) reach
/// `CadaclysmAssembly.place` at all -- a checked path would catch it first, as
/// `CadaclysmFrame.create` does, in this crate's own "left-handed" wording, and the
/// library's message would never be seen.
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
            Some(bs::Frame::raw_unchecked(raw))
        }
        Some(values) => fail(format!("{what}: expected 12 numbers, got {}", values.len())),
        None => fail(format!("{what}: expected a CadaclysmFrame, a Transform3D or 12 numbers, not {v}")),
    }
}

/// A `Transform3D` as a frame: its basis must be square, right-handed and unscaled
/// (a frame's axes are unit, so a scale would be dropped without a word) -- each to
/// 1e-5, a float's own slack. Within that the basis is squared up in doubles
/// (Gram-Schmidt: x normalised, y made square to x and normalised, z = x × y), so a
/// float32 transform gives an exactly rigid frame.
fn frame_of_transform(t: Transform3D) -> Result<bs::Frame, String> {
    const SLACK: f64 = 1e-5;
    let d = |v: Vector3| [f64::from(v.x), f64::from(v.y), f64::from(v.z)];
    let dot = |a: [f64; 3], b: [f64; 3]| a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    let cross = |a: [f64; 3], b: [f64; 3]| [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    let scaled = |a: [f64; 3], s: f64| [a[0] * s, a[1] * s, a[2] * s];
    let [x, y, z] = [t.basis.col_a(), t.basis.col_b(), t.basis.col_c()].map(d);
    if [x, y, z].iter().any(|&a| (dot(a, a).sqrt() - 1.0).abs() > SLACK) {
        return Err("frame: the transform scales, which a frame cannot follow".to_string());
    }
    if dot(x, y).abs().max(dot(y, z).abs()).max(dot(z, x).abs()) > SLACK {
        return Err("frame: the transform shears, which a frame cannot follow".to_string());
    }
    if dot(cross(x, y), z) <= 0.0 {
        // Mirrored: the frame's own refusal says so.
        return bs::Frame::new(d(t.origin), x, y, z).map_err(|e| e.to_string());
    }
    let x = scaled(x, 1.0 / dot(x, x).sqrt());
    let y0 = [y[0] - x[0] * dot(x, y), y[1] - x[1] * dot(x, y), y[2] - x[2] * dot(x, y)];
    let y = scaled(y0, 1.0 / dot(y0, y0).sqrt());
    bs::Frame::new(d(t.origin), x, y, cross(x, y)).map_err(|e| e.to_string())
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

/// A colour: a `Color`, `"#rgb"`/`"#rrggbb"`/a CSS colour name, or three numbers in 0..1.
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

/// A flat `allowed` (`[a0, b0, a1, b1, ...]`) as part-index pairs, refused under `call`'s
/// name for an odd length or a negative index, in Python's words.
fn allowed_pairs(allowed: &PackedInt32Array, call: &str) -> Option<Vec<(u32, u32)>> {
    if allowed.len() % 2 != 0 {
        return fail(format!("{call}: allowed is {} numbers, not pairs", allowed.len()));
    }
    allowed
        .as_slice()
        .chunks_exact(2)
        .map(|c| match (u32::try_from(c[0]), u32::try_from(c[1])) {
            (Ok(x), Ok(y)) => Some((x, y)),
            _ => fail(format!("{call}: allowed pair ({}, {}) is not two indices", c[0], c[1])),
        })
        .collect()
}

/// The poses a swept clash call takes: an array of poses, each an array of frames (any of
/// the shapes `frame` reads). A pose that is not an array, or a frame that is not a frame,
/// is refused under `call`'s name; `set` names the poses' set in the message (`""` or
/// `" of set a"`).
fn swept_poses(poses: &AnyArray, call: &str, set: &str) -> Option<Vec<Vec<bs::Frame>>> {
    poses
        .iter_shared()
        .enumerate()
        .map(|(k, pose)| {
            let Ok(frames) = pose.try_to::<AnyArray>() else {
                return fail(format!("{call}: pose {k}{set} is an array of frames, not {pose}"));
            };
            frames.iter_shared().enumerate().map(|(i, item)| frame(&item, &format!("{call}: frame {i} of pose {k}{set}"))).collect()
        })
        .collect()
}

/// A swept clash call's `max_steps` as the `u32` the library takes; a negative one, or one
/// past a `u32`, refused under `call`'s name (0 goes on, for the kernel to refuse).
fn swept_max_steps(max_steps: i64, call: &str) -> Option<u32> {
    match u32::try_from(max_steps) {
        Ok(n) => Some(n),
        Err(_) => fail(format!("{call}: max_steps {max_steps} is not a count")),
    }
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

/// Several solids and profiles' SVG text, any mix -- the SDK's own `svg_text_of`,
/// which calls the kernel's widened drawing pair (never the solids-only one, so a
/// mixed drawing and a solids-only one drawn this way refuse in the same words).
fn drawing_svg_text_of(solids: &[&bs::Solid], profiles: &[&bs::Profile], options: &sdk::SvgOptions) -> Option<String> {
    ok(bs::svg_text_of(solids, profiles, options))
}

/// Several solids and profiles' SVG text, any mix: every solid bound for the length of
/// the call, a profile carrying no such lock. The widened pair beside `solids_svg_text`.
fn drawables_svg_text(solids: &AnyArray, profiles: &AnyArray, options: &sdk::SvgOptions) -> Option<String> {
    let solid_list = object_list::<CadaclysmSolid>(solids, "write_svg")?;
    let solid_guards: Vec<GdRef<CadaclysmSolid>> = solid_list.iter().map(|s| s.bind()).collect();
    let solid_held: Vec<&bs::Solid> = solid_guards.iter().map(|g| g.held()).collect::<Option<_>>()?;
    let profile_list = object_list::<CadaclysmProfile>(profiles, "write_svg")?;
    let profile_guards: Vec<GdRef<CadaclysmProfile>> = profile_list.iter().map(|p| p.bind()).collect();
    let profile_refs: Vec<&bs::Profile> = profile_guards.iter().map(|g| &g.profile).collect();
    drawing_svg_text_of(&solid_held, &profile_refs, options)
}

/// `options`, with `view` defaulted to `"top"` where the caller left it out -- a
/// profile lies in `z = 0`, so its own plane already is the page, unlike a solid's,
/// which has no plane of its own to prefer and keeps `reader::svg_options`'s own
/// `"iso"`. A shallow copy: the caller's own dictionary (GDScript's) is never mutated,
/// and a `"view"` the caller did set (even `"iso"`) is kept as given.
fn profile_svg_options(options: &VarDictionary) -> VarDictionary {
    let mut merged = options.duplicate_shallow();
    if !merged.contains_key("view") {
        merged.set("view", "top");
    }
    merged
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

    /// Set a kernel option, by its name, for the whole process from the next call on:
    /// `"boolean.mesh_budget"`, `"boolean.finest_tolerance"`,
    /// `"profile_boolean.point_budget"`, `"measure.default_accuracy"`,
    /// `"step.validation_properties"`, `"step.validation_accuracy"`,
    /// `"tolerance.relative"` or `"tolerance.angular"`. False -- and
    /// nothing changed -- for a name that is not an option or a value it does not take,
    /// the reason in `Cadaclysm.last_error()`. The last two stamp a written STEP part
    /// file with each body's measured area, volume and centroid, there for the kernel
    /// that reads the file to check the transfer against; off by default, since it
    /// measures every body in the file at `"step.validation_accuracy"` (1e-5).
    #[func]
    fn set_option(name: GString, value: f64) -> bool {
        ok(bs::set_option(&name.to_string(), value)).is_some()
    }

    /// A kernel option's value, by its name: what `set_option` last set, else its default.
    /// NaN for a name that is not an option, the reason (listing the ones there are) in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn option(name: GString) -> f64 {
        ok(bs::option(&name.to_string())).unwrap_or(f64::NAN)
    }

    /// The tolerance a verb given a tolerance of 0 (or `NAN`) works at over `solids` (an
    /// `Array` of `CadaclysmSolid`s): the larger of the loosest absolute tolerance they declare
    /// (`CadaclysmSolid.tolerances()`) and `option("tolerance.relative")` times the largest of
    /// their sizes, never finer than their coordinates can represent. 0 for no solids, or solids
    /// with nothing to size by -- which a verb refuses. Every default here stays what it is
    /// (`join` still means 0.05); passing 0 as a verb's `tolerance` opts into this one. `NAN` on
    /// failure (an item that is not an open solid), with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn effective_tolerance(solids: AnyArray) -> f64 {
        let Some(owners) = object_list::<CadaclysmSolid>(&solids, "effective_tolerance: solids") else { return f64::NAN };
        let guards: Vec<GdRef<CadaclysmSolid>> = owners.iter().map(Gd::bind).collect();
        let Some(held) = guards.iter().map(|g| g.held()).collect::<Option<Vec<&bs::Solid>>>() else { return f64::NAN };
        ok(bs::effective_tolerance(&held)).unwrap_or(f64::NAN)
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

    /// How many freedoms a pair kind has, so a caller can size
    /// `CadaclysmAssembly.pair`'s `ranges`: one entry per freedom of `kind`. 0 for an
    /// unknown name, for `"fully_constrained"` (which has none), and if the kernel
    /// library cannot be loaded.
    #[func]
    fn pair_freedom_count(kind: GString) -> i64 {
        bs::pair_freedom_count(&kind.to_string()).into()
    }

    /// `"#rgb"`, `"#rrggbb"` (the `#` optional) or a CSS colour name as a `Color`; black,
    /// with the error recorded, for anything else.
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

    /// Several solids and profiles' wireframes, any mix, as one SVG's text, each its
    /// own `<g>` -- the pair beside `write_svg_text` a drawing takes both kinds
    /// through. `""` on a refused option.
    #[func]
    fn write_drawing_svg_text(solids: AnyArray, profiles: AnyArray) -> GString {
        Self::write_drawing_svg_text_with(solids, profiles, VarDictionary::new())
    }

    /// `write_drawing_svg_text`, with options: see `CadaclysmScene.svg_text_with` for
    /// every key -- `up` left out is always `"z"` here, as `write_svg_text_with`.
    #[func]
    fn write_drawing_svg_text_with(solids: AnyArray, profiles: AnyArray, options: VarDictionary) -> GString {
        let Some(opts) = reader::svg_options(&options) else { return GString::new() };
        gs(drawables_svg_text(&solids, &profiles, &opts).unwrap_or_default())
    }

    /// Several solids and profiles, any mix, written to one SVG file at `path`; see
    /// `write_drawing_svg_text`.
    #[func]
    fn write_drawing_svg(path: GString, solids: AnyArray, profiles: AnyArray) -> bool {
        Self::write_drawing_svg_with(path, solids, profiles, VarDictionary::new())
    }

    /// `write_drawing_svg`, with options: see `write_drawing_svg_text_with`.
    #[func]
    fn write_drawing_svg_with(path: GString, solids: AnyArray, profiles: AnyArray, options: VarDictionary) -> bool {
        let Some(opts) = reader::svg_options(&options) else { return false };
        match drawables_svg_text(&solids, &profiles, &opts) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// Every pair of `parts` -- or, with `others`, every part of `parts` against every part
    /// of `others` -- that penetrates, touches or lies within `clearance` of the other, as
    /// `CadaclysmClash` rows in pair order, the solids as they stand. `others` is `null` for
    /// one set (then `a < b` in a row) or an array of solids (`a` indexes `parts`, `b`
    /// indexes `others`). A row's `kind` is decided in this order: `"penetrating"`,
    /// `"touching"` (within `tolerance`), `"too_close"` (within `clearance`), `"refused"`.
    /// `tolerance` is the meshing tolerance, absolute. `allowed` pairs of part indices are
    /// never tested (designed contacts), flat: `[a0, b0, a1, b1, ...]`; with `others` a pair
    /// is (index in `parts`, index in `others`). For the same parts moved pose after pose,
    /// build a `CadaclysmCollider` and ask `CadaclysmCollider.clash`.
    ///
    /// Returns an `Array` of `CadaclysmClash` -- empty when no pair is in trouble -- or
    /// `null` with the reason in `Cadaclysm.last_error()`: an empty `others`
    /// (`clash: an empty set`), an odd-length `allowed` (`clash: allowed is N numbers, not
    /// pairs`) or a negative index in it (`clash: allowed pair (x, y) is not two indices`),
    /// and in the kernel's words (`clash: ...`) a `clearance` negative or not finite, a
    /// `tolerance` not positive and finite, an `allowed` index out of range or a part that
    /// is not a closed solid.
    #[func]
    fn clash(
        parts: AnyArray,
        others: Variant,
        #[opt(default = 0.0)] clearance: f64,
        #[opt(default = 0.05)] tolerance: f64,
        #[opt(default = &PackedInt32Array::new())] allowed: PackedInt32Array,
    ) -> Variant {
        let Some(first) = object_list::<CadaclysmSolid>(&parts, "clash: parts") else { return Variant::nil() };
        let second = if others.is_nil() {
            None
        } else {
            let Ok(list) = others.try_to::<AnyArray>() else {
                fail::<()>(format!("clash: others is null or an array of CadaclysmSolids, not {others}"));
                return Variant::nil();
            };
            let Some(list) = object_list::<CadaclysmSolid>(&list, "clash: others") else { return Variant::nil() };
            Some(list)
        };
        let Some(pairs) = allowed_pairs(&allowed, "clash") else { return Variant::nil() };
        let first_guards: Vec<GdRef<CadaclysmSolid>> = first.iter().map(Gd::bind).collect();
        let Some(first_held) = first_guards.iter().map(|g| g.held()).collect::<Option<Vec<&bs::Solid>>>() else {
            return Variant::nil();
        };
        let second_guards: Option<Vec<GdRef<CadaclysmSolid>>> = second.as_ref().map(|s| s.iter().map(Gd::bind).collect());
        let second_held = match &second_guards {
            Some(guards) => match guards.iter().map(|g| g.held()).collect::<Option<Vec<&bs::Solid>>>() {
                Some(held) => Some(held),
                None => return Variant::nil(),
            },
            None => None,
        };
        // An empty `others` goes on to the SDK, which refuses it (`clash: an empty set`):
        // never read as one set.
        CadaclysmClash::rows(bs::clash(&first_held, second_held.as_deref(), clearance, tolerance, &pairs))
    }

    /// Every pair of `parts` -- or, with `others`, every part of `parts` against every part
    /// of `others` -- that penetrates, touches or comes within `clearance` of the other
    /// anywhere on a path, as `CadaclysmSweptClash` rows in pair order: `clash`'s question
    /// asked of the motion, not only of the poses. Each part is its own group: pose `k` of
    /// `poses` is an array of one frame (a `CadaclysmFrame`, a `Transform3D`, twelve numbers
    /// or four triples) per part of `parts`, and pose `k` of `other_poses` one per part of
    /// `others`. `others` and `other_poses` go together: both `null` for one set (then
    /// `a < b` in a row), or an array of solids and as many poses as `poses` (then `a`
    /// indexes `parts` and `b` indexes `others`). The motion between poses, the guarantee,
    /// `resolution` and `max_steps` are `CadaclysmCollider.swept_clash`'s; `clearance`,
    /// `tolerance` (the meshing tolerance, absolute) and `allowed` (flat:
    /// `[a0, b0, a1, b1, ...]`) are `clash`'s.
    ///
    /// Returns an `Array` of `CadaclysmSweptClash` -- empty when no pair is in trouble on the
    /// way -- or `null` with the reason in `Cadaclysm.last_error()`, every one prefixed
    /// `swept_clash:`: `others` without `other_poses` or the other way round (`others and
    /// other_poses go together`), a pose that is not an array or a frame that is not a frame,
    /// an odd-length `allowed` (`allowed is N numbers, not pairs`) or a negative index in it
    /// (`allowed pair (x, y) is not two indices`), a `max_steps` negative or past a `u32`;
    /// a different number of poses in the two sets (`P poses for set a, Q for set b`), a pose
    /// with the wrong number of frames (`pose K of set a has N frames for M parts`, set a
    /// first), an empty `others` (`an empty set`); and in the kernel's words fewer than two
    /// poses, a bad frame, `tolerance`, `clearance` or `resolution`, `max_steps` 0, an
    /// `allowed` index out of range or a part that is not a closed solid.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn swept_clash(
        parts: AnyArray,
        poses: AnyArray,
        others: Variant,
        other_poses: Variant,
        #[opt(default = 0.0)] clearance: f64,
        #[opt(default = 0.05)] tolerance: f64,
        #[opt(default = 1e-3)] resolution: f64,
        #[opt(default = 100000)] max_steps: i64,
        #[opt(default = &PackedInt32Array::new())] allowed: PackedInt32Array,
    ) -> Variant {
        let Some(first) = object_list::<CadaclysmSolid>(&parts, "swept_clash: parts") else { return Variant::nil() };
        let second = if others.is_nil() {
            None
        } else {
            let Ok(list) = others.try_to::<AnyArray>() else {
                fail::<()>(format!("swept_clash: others is null or an array of CadaclysmSolids, not {others}"));
                return Variant::nil();
            };
            let Some(list) = object_list::<CadaclysmSolid>(&list, "swept_clash: others") else { return Variant::nil() };
            Some(list)
        };
        let second_poses = if other_poses.is_nil() {
            None
        } else {
            let Ok(list) = other_poses.try_to::<AnyArray>() else {
                fail::<()>(format!("swept_clash: other_poses is null or an array of poses, not {other_poses}"));
                return Variant::nil();
            };
            let Some(set) = swept_poses(&list, "swept_clash", " of set b") else { return Variant::nil() };
            Some(set)
        };
        // The SDK pairs the other set with its poses, so one without the other is ours to
        // refuse.
        if second.is_some() != second_poses.is_some() {
            fail::<()>("swept_clash: others and other_poses go together");
            return Variant::nil();
        }
        let Some(first_poses) = swept_poses(&poses, "swept_clash", " of set a") else { return Variant::nil() };
        let Some(steps) = swept_max_steps(max_steps, "swept_clash") else { return Variant::nil() };
        let Some(pairs) = allowed_pairs(&allowed, "swept_clash") else { return Variant::nil() };
        let first_guards: Vec<GdRef<CadaclysmSolid>> = first.iter().map(Gd::bind).collect();
        let Some(first_held) = first_guards.iter().map(|g| g.held()).collect::<Option<Vec<&bs::Solid>>>() else {
            return Variant::nil();
        };
        let second_guards: Option<Vec<GdRef<CadaclysmSolid>>> = second.as_ref().map(|s| s.iter().map(Gd::bind).collect());
        let second_held = match &second_guards {
            Some(guards) => match guards.iter().map(|g| g.held()).collect::<Option<Vec<&bs::Solid>>>() {
                Some(held) => Some(held),
                None => return Variant::nil(),
            },
            None => None,
        };
        let first_refs: Vec<&[bs::Frame]> = first_poses.iter().map(Vec::as_slice).collect();
        let second_refs: Option<Vec<&[bs::Frame]>> = second_poses.as_ref().map(|set| set.iter().map(Vec::as_slice).collect());
        // Pose counts, frame counts and an empty `others` go on to the SDK, which refuses
        // them in Python's words (`swept_clash: ...`), as `clash` leaves it an empty set.
        let other = match (&second_held, &second_refs) {
            (Some(solids), Some(set)) => Some((solids.as_slice(), set.as_slice())),
            _ => None,
        };
        CadaclysmSweptClash::rows(bs::swept_clash(&first_held, &first_refs, other, clearance, tolerance, resolution, steps, &pairs))
    }

    /// Every wall-thickness reading within `maximum` on `solids`, measured against each other,
    /// as `CadaclysmThickness` rows by body then vertex: a `CadaclysmThicknessGauge` built at
    /// `tolerance` (0.01 by default), asked `thickness` once and freed. Build the gauge
    /// yourself to ask more than once.
    ///
    /// Returns an `Array` of `CadaclysmThickness` -- empty when nothing reads -- or `null` with
    /// the reason in `Cadaclysm.last_error()`, in the gauge call's own words
    /// (`thickness_gauge_new: ...`, `thickness_gauge_measure: ...`): a `maximum` not positive
    /// and finite, a `sharp_angle` negative or not finite, a `tolerance` not positive and
    /// finite.
    #[func]
    fn thickness(
        solids: AnyArray,
        maximum: f64,
        #[opt(default = 0.0)] sharp_angle: f64,
        #[opt(default = 0.01)] tolerance: f64,
    ) -> Variant {
        let Some(owners) = object_list::<CadaclysmSolid>(&solids, "thickness: solids") else { return Variant::nil() };
        let guards: Vec<GdRef<CadaclysmSolid>> = owners.iter().map(Gd::bind).collect();
        let Some(held) = guards.iter().map(|g| g.held()).collect::<Option<Vec<&bs::Solid>>>() else { return Variant::nil() };
        CadaclysmThickness::rows(bs::thickness(&held, maximum, sharp_angle, tolerance))
    }

    /// The wall-thickness rule on plain meshes, measured against each other, as
    /// `CadaclysmMeshThickness` rows by mesh then vertex. Each of `meshes` is a pair
    /// `[positions, triangles]`: its points (a `PackedVector3Array`, or an array of
    /// `Vector3`s or triples of numbers -- the array keeps a double's precision) and its
    /// triangles (a flat `PackedInt32Array` of three indices each, or an array of triples),
    /// indices into its own points. A vertex with no opposing triangle, or one further than
    /// `maximum`, gives no row.
    ///
    /// Returns an `Array` of `CadaclysmMeshThickness` -- empty when nothing reads -- or `null`
    /// with the reason in `Cadaclysm.last_error()`: a mesh that is not such a pair
    /// (`mesh_thickness: mesh M is not a [positions, triangles] pair`), a position that is not
    /// three numbers (`mesh M position P is not three numbers`), a triangle that is not three
    /// indices (`mesh M triangle T is not three indices`, a negative or past-`u32` index
    /// included), and in the kernel's words (`mesh_thickness: ...`) a triangle past its mesh,
    /// a position not finite, a `maximum` not positive and finite, or a `sharp_angle` negative
    /// or not finite.
    #[func]
    fn mesh_thickness(meshes: AnyArray, maximum: f64, #[opt(default = 0.0)] sharp_angle: f64) -> Variant {
        let Some(parsed) = thickness_meshes(&meshes) else { return Variant::nil() };
        let views: Vec<(&[[f64; 3]], &[[u32; 3]])> = parsed.iter().map(|(p, t)| (&p[..], &t[..])).collect();
        match ok(bs::mesh_thickness(&views, maximum, sharp_angle)) {
            Some(rows) => rows.into_iter().map(CadaclysmMeshThickness::wrap).collect::<Array<Gd<CadaclysmMeshThickness>>>().to_variant(),
            None => Variant::nil(),
        }
    }

    /// For each of `needles`, the indices of the `hay` points within `limit` of it, nearest
    /// first and equal distances by index, as one `PackedInt64Array` a needle -- one
    /// `CadaclysmRTree` over `hay` answers every needle. `hay` and `needles` are each a
    /// `PackedVector3Array` or an array of points. Empty for a `limit` negative or NaN, then
    /// the first hay point and the first needle not finite, by index, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn closest_points(hay: Variant, needles: Variant, limit: f64) -> Array<PackedInt64Array> {
        rtree_closest_points(&hay, &needles, limit).unwrap_or_default()
    }

    /// For each of `needles`, the indices of the `k` nearest `hay` points, nearest first and
    /// equal distances by index (the smaller indices win a tie at the `k`-th place), as one
    /// `PackedInt64Array` a needle; every hay point when `k` is over their count. Empty for
    /// the first hay point and the first needle not finite, by index, then a `k` negative or
    /// above 1,000,000, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn k_neighbors(hay: Variant, needles: Variant, k: i64) -> Array<PackedInt64Array> {
        rtree_k_neighbors(&hay, &needles, k).unwrap_or_default()
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
    /// as `create` checks them. `frame()` itself reads a raw array **unchecked**
    /// (`bs::Frame::raw_unchecked`, so a kernel call taking a frame is refused in the
    /// kernel's own words, spec §5 fact 7) -- `of` re-validates through the checked
    /// `bs::Frame::of` before wrapping, since unlike every other frame-taking call this
    /// one **is** the checked constructor for a raw array, as Python's `Frame.of` is
    /// (it builds through the checked `Frame(...)`).
    #[func]
    fn of(raw: Variant) -> Option<Gd<CadaclysmFrame>> {
        let f = frame(&raw, "Frame.of")?;
        ok(bs::Frame::of(f.raw()))?;
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

    /// The same plane facing the other way: x and y swapped, z reversed.
    #[func]
    fn flipped(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.frame.flipped())
    }

    /// This frame turned `radians` about `axis` (a direction: a `Vector3` or three numbers)
    /// through its origin, right-handed; `null` for a zero axis.
    #[func]
    fn rotated(&self, radians: f64, axis: Variant) -> Option<Gd<CadaclysmFrame>> {
        ok(self.frame.rotated(radians, at(&axis, "rotated: axis")?)).map(CadaclysmFrame::wrap)
    }

    /// The point `p` (a `Vector3` or three numbers) in this frame's coordinates. `NAN`s for a
    /// `p` that is not a point.
    #[func]
    fn to_local(&self, p: Variant) -> Vector3 {
        at(&p, "to_local").map_or(NAN3, |p| vector3(self.frame.to_local(p)))
    }

    /// The point `p` dropped onto the frame's plane along its z. `NAN`s for a `p` that is not
    /// a point.
    #[func]
    fn closest_point(&self, p: Variant) -> Vector3 {
        at(&p, "closest_point").map_or(NAN3, |p| vector3(self.frame.closest_point(p)))
    }

    /// How far `p` lies above the frame's plane, along its z: negative below. `NAN` for a `p`
    /// that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "distance_to").map_or(f64::NAN, |p| self.frame.distance_to(p))
    }

    /// The least-squares plane through `points` (a `PackedVector3Array` or an array of points,
    /// three or more, not all on one line) as `{frame, deviation}`: the `CadaclysmFrame` and
    /// the largest distance any point lies off it. `null` for fewer points or points on one
    /// line, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn fit(points: Variant) -> Variant {
        let Some(points) = point_list(&points, "frame_fit") else {
            return Variant::nil();
        };
        match ok(bs::Frame::fit(&points)) {
            Some((frame, deviation)) => {
                dict(&[("frame", CadaclysmFrame::wrap(frame).to_variant()), ("deviation", deviation.to_variant())]).to_variant()
            }
            None => Variant::nil(),
        }
    }
}

// ---- CadaclysmTransform, CadaclysmQuaternion -------------------------------------------

/// A transform argument: a `CadaclysmTransform`, or 16 numbers row-major (four rows of
/// four too), checked as `CadaclysmTransform.from_rows` checks them.
fn transform_arg(v: &Variant, what: &str) -> Option<bs::Transform> {
    if let Ok(t) = v.try_to::<Gd<CadaclysmTransform>>() {
        return Some(t.bind().transform);
    }
    match numbers(v, true) {
        Some(values) => ok(bs::Transform::from_rows(&values)),
        None => fail(format!("{what}: expected a CadaclysmTransform or 16 numbers, not {v}")),
    }
}

fn doubles(values: &[f64]) -> PackedFloat64Array {
    PackedFloat64Array::from(values)
}

/// An affine map of space in doubles: a 4×4 matrix, row-major, its bottom row `0 0 0 1`.
/// Immutable, with nothing to free; `a.compose(b)` is `a` after `b`. Not Godot's own
/// `Transform3D`, which holds floats in a default build: the constructors and the
/// decompositions are the kernel's, in doubles, so every language computes them alike.
/// A frame argument is a `CadaclysmFrame`, a `Transform3D` or 12 numbers; a point is a
/// `Vector3` or three numbers (an array keeps a double's precision).
///
/// ```gdscript
/// var t := CadaclysmTransform.translation([1, 2, 3]).compose(CadaclysmTransform.scale([0, 0, 0], 2))
/// var p := t.point([1, 1, 1])   # [3, 4, 5]
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmTransform {
    transform: bs::Transform,
    #[var(get = get_rows, no_set)]
    rows: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmTransform {
    fn wrap(transform: bs::Transform) -> Gd<CadaclysmTransform> {
        Gd::from_object(CadaclysmTransform { transform, rows: PhantomVar::default() })
    }

    fn made(result: sdk::Result<bs::Transform>) -> Option<Gd<CadaclysmTransform>> {
        ok(result).map(CadaclysmTransform::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmTransform {
    fn to_string(&self) -> GString {
        gs(format!("CadaclysmTransform{:?}", self.transform.rows()))
    }
}

#[godot_api]
impl CadaclysmTransform {
    /// The map 16 numbers state, row-major -- an array, a `PackedFloat64Array`, or four
    /// rows of four. `null` for another count (`Transform: a matrix is 16 numbers, got
    /// N`), a number not finite, or a bottom row not `0 0 0 1`, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn from_rows(rows: Variant) -> Option<Gd<CadaclysmTransform>> {
        match numbers(&rows, true) {
            Some(values) => Self::made(bs::Transform::from_rows(&values)),
            None => fail(format!("Transform: expected 16 numbers or four rows of four, not {rows}")),
        }
    }

    /// The map that moves nothing.
    #[func]
    fn identity() -> Gd<CadaclysmTransform> {
        CadaclysmTransform::wrap(bs::Transform::identity())
    }

    /// `p + v`.
    #[func]
    fn translation(v: Variant) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::translation(v3(&v, "translation: v")?))
    }

    /// A turn of `radians` about the line through `point` along `direction`, right-handed.
    #[func]
    fn rotation(point: Variant, direction: Variant, radians: f64) -> Option<Gd<CadaclysmTransform>> {
        let axis = [v3(&point, "rotation: point")?, v3(&direction, "rotation: direction")?];
        Self::made(bs::Transform::rotation(&axis, radians))
    }

    /// The reflection across `plane`, its z the normal.
    #[func]
    fn mirror(plane: Variant) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::mirror(&frame(&plane, "mirror: plane")?))
    }

    /// A uniform scale by `k` about `centre`.
    #[func]
    fn scale(centre: Variant, k: f64) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::scale(v3(&centre, "scale: centre")?, k))
    }

    /// A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin.
    #[func]
    fn scale_xyz(frame: Variant, sx: f64, sy: f64, sz: f64) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::scale_xyz(&self::frame(&frame, "scale_xyz: frame")?, sx, sy, sz))
    }

    /// Every point slid along `direction` by `factor` times its height above `plane`.
    /// `direction` is normalised, so `factor` alone sets the slide; one off the plane is
    /// refused.
    #[func]
    fn shear(plane: Variant, direction: Variant, factor: f64) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::shear(&frame(&plane, "shear: plane")?, v3(&direction, "shear: direction")?, factor))
    }

    /// The rigid map sending frame `a` onto frame `b`.
    #[func]
    fn plane_to_plane(a: Variant, b: Variant) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::plane_to_plane(&frame(&a, "plane_to_plane: a")?, &frame(&b, "plane_to_plane: b")?))
    }

    /// Coordinates in frame `from` to coordinates in frame `to`: a change of basis.
    #[func]
    fn change_basis(from: Variant, to: Variant) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::change_basis(&frame(&from, "change_basis: from")?, &frame(&to, "change_basis: to")?))
    }

    /// The orthogonal projection onto `plane` -- singular by design.
    #[func]
    fn planar_projection(plane: Variant) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::planar_projection(&frame(&plane, "planar_projection: plane")?))
    }

    /// The parallel projection onto `plane` along `direction`; a direction in the plane is
    /// refused.
    #[func]
    fn project_along(plane: Variant, direction: Variant) -> Option<Gd<CadaclysmTransform>> {
        Self::made(bs::Transform::project_along(&frame(&plane, "project_along: plane")?, v3(&direction, "project_along: direction")?))
    }

    /// The 16 numbers, row-major.
    #[func]
    fn get_rows(&self) -> PackedFloat64Array {
        doubles(&self.transform.rows())
    }

    /// Where the map takes the point `p`, three doubles; empty for a `p` that is not three
    /// numbers, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn point(&self, p: Variant) -> PackedFloat64Array {
        v3(&p, "point").map(|p| doubles(&self.transform.point(p))).unwrap_or_default()
    }

    /// This map after `other`: `a.compose(b).point(p)` is `a.point(b.point(p))`.
    #[func]
    fn compose(&self, other: Gd<CadaclysmTransform>) -> Option<Gd<CadaclysmTransform>> {
        Self::made(self.transform.compose(&other.bind().transform))
    }

    /// The map undoing this one; `null` for a singular map, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn inverse(&self) -> Option<Gd<CadaclysmTransform>> {
        Self::made(self.transform.inverse())
    }

    /// Whether the linear part is orthogonal (`AᵀA = I` to `tolerance`): a rotation or a
    /// mirror. False for a tolerance negative or not finite too, the reason then in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn is_rigid(&self, #[opt(default = bs::MAP_TOLERANCE)] tolerance: f64) -> bool {
        ok(self.transform.is_rigid(tolerance)).unwrap_or(false)
    }

    /// The scale `k` where the linear part is `k` times an orthogonal one (to `tolerance`,
    /// relative to `k²`), else `null`. `null` for a tolerance negative or not finite too,
    /// the reason then in `Cadaclysm.last_error()`.
    #[func]
    fn is_similarity(&self, #[opt(default = bs::MAP_TOLERANCE)] tolerance: f64) -> Variant {
        ok(self.transform.is_similarity(tolerance)).flatten().map_or(Variant::nil(), |k| k.to_variant())
    }

    /// A rigid map's parts, `{translation, orthogonal}` -- the map is
    /// `p -> orthogonal · p + translation`, `translation` three doubles and `orthogonal` a
    /// `CadaclysmTransform` (a rotation, or a rotation and a mirror) -- else `null`. `null`
    /// for a tolerance negative or not finite too, the reason then in `Cadaclysm.last_error()`.
    #[func]
    fn decompose_rigid(&self, #[opt(default = bs::MAP_TOLERANCE)] tolerance: f64) -> Variant {
        match ok(self.transform.decompose_rigid(tolerance)).flatten() {
            Some(p) => dict(&[
                ("translation", doubles(&p.translation).to_variant()),
                ("orthogonal", CadaclysmTransform::wrap(p.orthogonal).to_variant()),
            ])
            .to_variant(),
            None => Variant::nil(),
        }
    }

    /// A similarity's parts, `{translation, orthogonal, k}` -- the map is
    /// `p -> k · orthogonal · p + translation`, `k` positive -- else `null`. `null` for a
    /// tolerance negative or not finite too, the reason then in `Cadaclysm.last_error()`.
    #[func]
    fn decompose_similarity(&self, #[opt(default = bs::MAP_TOLERANCE)] tolerance: f64) -> Variant {
        match ok(self.transform.decompose_similarity(tolerance)).flatten() {
            Some(p) => dict(&[
                ("translation", doubles(&p.translation).to_variant()),
                ("orthogonal", CadaclysmTransform::wrap(p.orthogonal).to_variant()),
                ("k", p.k.to_variant()),
            ])
            .to_variant(),
            None => Variant::nil(),
        }
    }

    /// The polar split, `{translation, rotation, axes, stretch}`: the linear part is
    /// `rotation · axes · diag(stretch) · axesᵀ`, `rotation` (a `CadaclysmTransform`)
    /// carrying the mirror, `axes` a proper rotation whose columns are the stretch
    /// directions, `stretch` three doubles, largest first. `null` for a singular map, or one
    /// stretched past 1e7:1.
    #[func]
    fn decompose_affine(&self) -> Variant {
        match ok(self.transform.decompose_affine()).flatten() {
            Some(p) => dict(&[
                ("translation", doubles(&p.translation).to_variant()),
                ("rotation", CadaclysmTransform::wrap(p.rotation).to_variant()),
                ("axes", CadaclysmTransform::wrap(p.axes).to_variant()),
                ("stretch", doubles(&p.stretch).to_variant()),
            ])
            .to_variant(),
            None => Variant::nil(),
        }
    }
}

/// A rotation as `w + xi + yj + zk`, in doubles. Immutable. `q` and `-q` are the same
/// rotation; a non-unit one is normalised where it becomes a rotation, and a zero one is
/// refused there. `a.multiply(b)` turns by `b`, then by `a`. Not Godot's own `Quaternion`,
/// which holds floats in a default build.
///
/// ```gdscript
/// var q := CadaclysmQuaternion.from_axis_angle([0, 0, 1], PI / 2)
/// var p := q.to_transform().point([1, 0, 0])   # [0, 1, 0]
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmQuaternion {
    quaternion: bs::Quaternion,
    #[var(get = get_w, no_set)]
    w: PhantomVar<f64>,
    #[var(get = get_x, no_set)]
    x: PhantomVar<f64>,
    #[var(get = get_y, no_set)]
    y: PhantomVar<f64>,
    #[var(get = get_z, no_set)]
    z: PhantomVar<f64>,
    #[var(get = get_components, no_set)]
    components: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmQuaternion {
    fn wrap(quaternion: bs::Quaternion) -> Gd<CadaclysmQuaternion> {
        Gd::from_object(CadaclysmQuaternion {
            quaternion,
            w: PhantomVar::default(),
            x: PhantomVar::default(),
            y: PhantomVar::default(),
            z: PhantomVar::default(),
            components: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Quaternion>) -> Option<Gd<CadaclysmQuaternion>> {
        ok(result).map(CadaclysmQuaternion::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmQuaternion {
    fn to_string(&self) -> GString {
        gs(format!("CadaclysmQuaternion{:?}", self.quaternion.components()))
    }
}

#[godot_api]
impl CadaclysmQuaternion {
    /// `w + xi + yj + zk`; `null` for a component not finite (`Quaternion: not finite`).
    /// (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(w: f64, x: f64, y: f64, z: f64) -> Option<Gd<CadaclysmQuaternion>> {
        Self::made(bs::Quaternion::new(w, x, y, z))
    }

    /// The turn that turns nothing, `1 + 0i + 0j + 0k`.
    #[func]
    fn identity() -> Gd<CadaclysmQuaternion> {
        CadaclysmQuaternion::wrap(bs::Quaternion::identity())
    }

    /// The turn of `radians` about `direction`, right-handed.
    #[func]
    fn from_axis_angle(direction: Variant, radians: f64) -> Option<Gd<CadaclysmQuaternion>> {
        Self::made(bs::Quaternion::from_axis_angle(v3(&direction, "from_axis_angle: direction")?, radians))
    }

    /// The rotation in `t`'s linear part (its translation ignored); `null` unless that is a
    /// proper rotation, orthogonal to 1e-9, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn from_transform(t: Gd<CadaclysmTransform>) -> Option<Gd<CadaclysmQuaternion>> {
        Self::made(bs::Quaternion::from_transform(&t.bind().transform))
    }

    /// From `a` (`s = 0`) to `b` (`s = 1`) along the shorter arc.
    #[func]
    fn slerp(a: Gd<CadaclysmQuaternion>, b: Gd<CadaclysmQuaternion>, s: f64) -> Option<Gd<CadaclysmQuaternion>> {
        Self::made(bs::Quaternion::slerp(&a.bind().quaternion, &b.bind().quaternion, s))
    }

    /// This rotation as a `CadaclysmTransform` fixing `centre`, three numbers (empty, the
    /// default, for the origin); `null` for a zero quaternion, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn to_transform(&self, #[opt(default = &PackedFloat64Array::new())] centre: PackedFloat64Array) -> Option<Gd<CadaclysmTransform>> {
        let centre = if centre.is_empty() { [0.0; 3] } else { v3(&centre.to_variant(), "to_transform: centre")? };
        CadaclysmTransform::made(self.quaternion.to_transform(centre))
    }

    #[func]
    fn get_w(&self) -> f64 {
        self.quaternion.w()
    }

    #[func]
    fn get_x(&self) -> f64 {
        self.quaternion.x()
    }

    #[func]
    fn get_y(&self) -> f64 {
        self.quaternion.y()
    }

    #[func]
    fn get_z(&self) -> f64 {
        self.quaternion.z()
    }

    /// `[w, x, y, z]`, doubles.
    #[func]
    fn get_components(&self) -> PackedFloat64Array {
        doubles(&self.quaternion.components())
    }

    /// Its length; 1 for a rotation as the library makes one.
    #[func]
    fn length(&self) -> f64 {
        self.quaternion.length()
    }

    /// The turn, in `[0, 2π]`.
    #[func]
    fn angle(&self) -> f64 {
        self.quaternion.angle()
    }

    /// The turn's axis, unit, three doubles; `null` for the identity.
    #[func]
    fn axis(&self) -> Variant {
        self.quaternion.axis().map_or(Variant::nil(), |a| doubles(&a).to_variant())
    }

    /// The opposite turn.
    #[func]
    fn conjugate(&self) -> Gd<CadaclysmQuaternion> {
        CadaclysmQuaternion::wrap(self.quaternion.conjugate())
    }

    /// The same rotation at length 1, scaled by its largest component first, so 1e200 and
    /// 1e-170 normalise; `null` for a zero quaternion (`Quaternion.normalized: the
    /// quaternion is zero`).
    #[func]
    fn normalized(&self) -> Option<Gd<CadaclysmQuaternion>> {
        Self::made(self.quaternion.normalized())
    }

    /// The Hamilton product, this one times `other`: it turns by `other`, then by this one.
    /// `null` where huge components overflow, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn multiply(&self, other: Gd<CadaclysmQuaternion>) -> Option<Gd<CadaclysmQuaternion>> {
        Self::made(self.quaternion * other.bind().quaternion)
    }
}

// ---- value geometry: CadaclysmInterval, the feet, CadaclysmLine ... CadaclysmCuboid ----------

/// A point for a value call: a `Vector3` or three numbers (an array keeps a double's
/// precision), refused in Python's words, `"{call}: a point is 3 numbers, got N"`.
fn at(v: &Variant, call: &str) -> Option<[f64; 3]> {
    match numbers(v, false) {
        Some(values) if values.len() == 3 => Some([values[0], values[1], values[2]]),
        Some(values) => fail(format!("{call}: a point is 3 numbers, got {}", values.len())),
        None => fail(format!("{call}: a point is 3 numbers, not {v}")),
    }
}

/// Points for a value call: a `PackedVector3Array`, or an array of points.
fn point_list(v: &Variant, call: &str) -> Option<Vec<[f64; 3]>> {
    match v.get_type() {
        VariantType::PACKED_VECTOR3_ARRAY => {
            Some(v.to::<PackedVector3Array>().as_slice().iter().map(|p| [p.x, p.y, p.z].map(f64::from)).collect())
        }
        VariantType::ARRAY => {
            let array = v.try_to::<AnyArray>().ok()?;
            array.iter_shared().map(|p| at(&p, call)).collect()
        }
        _ => fail(format!("{call}: expected a PackedVector3Array or an array of points, not {v}")),
    }
}

/// A range for a value call: a `CadaclysmInterval`, or two numbers.
fn interval_arg(v: &Variant, what: &str) -> Option<bs::Interval> {
    if let Ok(i) = v.try_to::<Gd<CadaclysmInterval>>() {
        return Some(i.bind().interval);
    }
    match numbers(v, false) {
        Some(values) if values.len() == 2 => ok(bs::Interval::new(values[0], values[1])),
        Some(values) => fail(format!("{what}: an interval is 2 numbers, got {}", values.len())),
        None => fail(format!("{what}: expected a CadaclysmInterval or two numbers, not {v}")),
    }
}

/// Every component `NAN`: what a value call answering a point gives on a refusal.
const NAN3: Vector3 = Vector3::new(f32::NAN, f32::NAN, f32::NAN);

/// A point a value call answers, or `NAN`s with the reason in `Cadaclysm.last_error()`.
fn point_out(result: sdk::Result<[f64; 3]>) -> Vector3 {
    ok(result).map_or(NAN3, vector3)
}

/// A number a value call answers, or `NAN` with the reason in `Cadaclysm.last_error()`.
fn number_out(result: sdk::Result<f64>) -> f64 {
    ok(result).unwrap_or(f64::NAN)
}

/// The kind and the array of any value object, for `equals`.
fn value_parts(v: &Variant) -> Option<(u32, Vec<f64>)> {
    if let Ok(x) = v.try_to::<Gd<CadaclysmLine>>() {
        return Some((bs::Line::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmCircle>>() {
        return Some((bs::Circle::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmArc>>() {
        return Some((bs::Arc::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmEllipse>>() {
        return Some((bs::Ellipse::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmSphere>>() {
        return Some((bs::Sphere::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmCylinder>>() {
        return Some((bs::Cylinder::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmCone>>() {
        return Some((bs::Cone::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmTorus>>() {
        return Some((bs::Torus::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmCuboid>>() {
        return Some((bs::Cuboid::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmRectangle>>() {
        return Some((bs::Rectangle::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmTriangle>>() {
        return Some((bs::Triangle::KIND, x.bind().value.values().to_vec()));
    }
    if let Ok(x) = v.try_to::<Gd<CadaclysmRay>>() {
        return Some((bs::Ray::KIND, x.bind().value.values().to_vec()));
    }
    None
}

/// Value equality: the same kind and the same array (`-0.0` equal to `0.0`).
fn same_value(kind: u32, values: &[f64], other: &Variant) -> bool {
    value_parts(other).is_some_and(|(k, v)| k == kind && v == values)
}

/// A parameter range `t0..t1`, in either order, in doubles: `length` and `swapped` keep the
/// order, the set operations (`grown`, `union`, `intersect`) answer increasing. Immutable,
/// with nothing to free; both ends finite. `equals` compares the two numbers.
///
/// ```gdscript
/// var up := CadaclysmInterval.create(2, 6)
/// var both := up.union([8, 7])   # 2..8
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmInterval {
    interval: bs::Interval,
    /// The start, as given.
    #[var(get = get_t0, no_set)]
    t0: PhantomVar<f64>,
    /// The end, as given.
    #[var(get = get_t1, no_set)]
    t1: PhantomVar<f64>,
    /// `[t0, t1]`, doubles.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmInterval {
    fn wrap(interval: bs::Interval) -> Gd<CadaclysmInterval> {
        Gd::from_object(CadaclysmInterval {
            interval,
            t0: PhantomVar::default(),
            t1: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Interval>) -> Option<Gd<CadaclysmInterval>> {
        ok(result).map(CadaclysmInterval::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmInterval {
    fn to_string(&self) -> GString {
        gs(format!("Interval({:?}, {:?})", self.interval.t0(), self.interval.t1()))
    }
}

#[godot_api]
impl CadaclysmInterval {
    /// `t0..t1`, in either order; `null` where either end is not finite (`Interval: not
    /// finite`). (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(t0: f64, t1: f64) -> Option<Gd<CadaclysmInterval>> {
        Self::made(bs::Interval::new(t0, t1))
    }

    /// A `CadaclysmInterval`, or two numbers (an Array, a `PackedFloat64Array` or a
    /// `Vector2`), as a `CadaclysmInterval`; `null` for any other count.
    #[func]
    fn of(value: Variant) -> Option<Gd<CadaclysmInterval>> {
        interval_arg(&value, "Interval").map(CadaclysmInterval::wrap)
    }

    /// The start, as given.
    #[func]
    fn get_t0(&self) -> f64 {
        self.interval.t0()
    }

    /// The end, as given.
    #[func]
    fn get_t1(&self) -> f64 {
        self.interval.t1()
    }

    /// `[t0, t1]`, doubles.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.interval.values())
    }

    /// `t1 - t0`: negative for a decreasing interval.
    #[func]
    fn length(&self) -> f64 {
        self.interval.length()
    }

    /// The middle, `(t0 + t1) / 2`.
    #[func]
    fn mid(&self) -> f64 {
        self.interval.mid()
    }

    /// The smaller end.
    #[func]
    fn min(&self) -> f64 {
        self.interval.min()
    }

    /// The larger end.
    #[func]
    fn max(&self) -> f64 {
        self.interval.max()
    }

    /// Whether `t0 < t1`.
    #[func]
    fn is_increasing(&self) -> bool {
        self.interval.is_increasing()
    }

    /// Whether `t0 == t1`.
    #[func]
    fn is_singleton(&self) -> bool {
        self.interval.is_singleton()
    }

    /// The interval `t1..t0`.
    #[func]
    fn swapped(&self) -> Gd<CadaclysmInterval> {
        CadaclysmInterval::wrap(self.interval.swapped())
    }

    /// The increasing interval holding this one and `t`; `null` for a `t` not finite.
    #[func]
    fn grown(&self, t: f64) -> Option<Gd<CadaclysmInterval>> {
        Self::made(self.interval.grown(t))
    }

    /// The increasing interval holding this one and `other` (a `CadaclysmInterval` or two
    /// numbers).
    #[func]
    fn union(&self, other: Variant) -> Option<Gd<CadaclysmInterval>> {
        let other = interval_arg(&other, "Interval.union")?;
        clear_error();
        Some(CadaclysmInterval::wrap(self.interval.union(other)))
    }

    /// The increasing overlap with `other` (a `CadaclysmInterval` or two numbers); `null` where
    /// the two are apart. Two that touch give a singleton.
    #[func]
    fn intersect(&self, other: Variant) -> Option<Gd<CadaclysmInterval>> {
        let other = interval_arg(&other, "Interval.intersect")?;
        clear_error();
        self.interval.intersect(other).map(CadaclysmInterval::wrap)
    }

    /// Whether `t` lies in the closed range, in either order.
    #[func]
    fn contains(&self, t: f64) -> bool {
        self.interval.contains(t)
    }

    /// `t0 + s (t1 - t0)`: the fraction `s` of the way from `t0`; outside 0..1 extrapolates.
    #[func]
    fn parameter_at(&self, s: f64) -> f64 {
        self.interval.parameter_at(s)
    }

    /// The fraction of the way `t` lies from `t0` toward `t1`, a float; `null` for a
    /// singleton.
    #[func]
    fn normalized_parameter_at(&self, t: f64) -> Variant {
        self.interval.normalized_parameter_at(t).map_or(Variant::nil(), |s| s.to_variant())
    }

    /// Whether `other` is a `CadaclysmInterval` with the same two numbers, in the same order.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        other.try_to::<Gd<CadaclysmInterval>>().is_ok_and(|o| o.bind().interval == self.interval)
    }
}

/// The closest point of a curve value (`CadaclysmCircle.closest_point` and the others): its
/// parameter `t`, the `point`, and `unique` -- `false` where several points lie equally near
/// and `point` is a fixed pick among them (a point on a circle's axis, one equidistant from an
/// arc's ends). `point` is a `Vector3`, so floats; `raw_point` gives the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCurveFoot {
    foot: bs::CurveFoot,
    /// The curve's parameter at the foot.
    #[var(get = get_t, no_set)]
    t: PhantomVar<f64>,
    /// The foot itself.
    #[var(get = get_point, no_set)]
    point: PhantomVar<Vector3>,
    /// `point` as three doubles.
    #[var(get = get_raw_point, no_set)]
    raw_point: PhantomVar<PackedFloat64Array>,
    /// Whether the foot is the only nearest point.
    #[var(get = get_unique, no_set)]
    unique: PhantomVar<bool>,
}

impl CadaclysmCurveFoot {
    fn wrap(foot: bs::CurveFoot) -> Gd<CadaclysmCurveFoot> {
        Gd::from_object(CadaclysmCurveFoot {
            foot,
            t: PhantomVar::default(),
            point: PhantomVar::default(),
            raw_point: PhantomVar::default(),
            unique: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCurveFoot {
    fn to_string(&self) -> GString {
        let f = &self.foot;
        gs(format!("CurveFoot(t={:?}, point={:?}, unique={})", f.t, f.point, f.unique))
    }
}

#[godot_api]
impl CadaclysmCurveFoot {
    /// The curve's parameter at the foot.
    #[func]
    fn get_t(&self) -> f64 {
        self.foot.t
    }

    /// The foot itself.
    #[func]
    fn get_point(&self) -> Vector3 {
        vector3(self.foot.point)
    }

    /// `point` as three doubles.
    #[func]
    fn get_raw_point(&self) -> PackedFloat64Array {
        doubles(&self.foot.point)
    }

    /// Whether the foot is the only nearest point.
    #[func]
    fn get_unique(&self) -> bool {
        self.foot.unique
    }
}

/// The closest point of a surface value (`CadaclysmSphere.closest_point` and the others): its
/// parameters `u`, `v`, the `point`, and `unique` -- `false` where several points lie equally
/// near and `point` is a fixed pick among them (a sphere's centre, a point on an axis).
/// `point` is a `Vector3`, so floats; `raw_point` gives the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSurfaceFoot {
    foot: bs::SurfaceFoot,
    /// The surface's first parameter at the foot.
    #[var(get = get_u, no_set)]
    u: PhantomVar<f64>,
    /// The surface's second parameter at the foot.
    #[var(get = get_v, no_set)]
    v: PhantomVar<f64>,
    /// The foot itself.
    #[var(get = get_point, no_set)]
    point: PhantomVar<Vector3>,
    /// `point` as three doubles.
    #[var(get = get_raw_point, no_set)]
    raw_point: PhantomVar<PackedFloat64Array>,
    /// Whether the foot is the only nearest point.
    #[var(get = get_unique, no_set)]
    unique: PhantomVar<bool>,
}

impl CadaclysmSurfaceFoot {
    fn wrap(foot: bs::SurfaceFoot) -> Gd<CadaclysmSurfaceFoot> {
        Gd::from_object(CadaclysmSurfaceFoot {
            foot,
            u: PhantomVar::default(),
            v: PhantomVar::default(),
            point: PhantomVar::default(),
            raw_point: PhantomVar::default(),
            unique: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmSurfaceFoot {
    fn to_string(&self) -> GString {
        let f = &self.foot;
        gs(format!("SurfaceFoot(u={:?}, v={:?}, point={:?}, unique={})", f.u, f.v, f.point, f.unique))
    }
}

#[godot_api]
impl CadaclysmSurfaceFoot {
    /// The surface's first parameter at the foot.
    #[func]
    fn get_u(&self) -> f64 {
        self.foot.u
    }

    /// The surface's second parameter at the foot.
    #[func]
    fn get_v(&self) -> f64 {
        self.foot.v
    }

    /// The foot itself.
    #[func]
    fn get_point(&self) -> Vector3 {
        vector3(self.foot.point)
    }

    /// `point` as three doubles.
    #[func]
    fn get_raw_point(&self) -> PackedFloat64Array {
        doubles(&self.foot.point)
    }

    /// Whether the foot is the only nearest point.
    #[func]
    fn get_unique(&self) -> bool {
        self.foot.unique
    }
}

/// The segment from `start` to `end`, as a value: its parameter runs 0..1. Its array is
/// `from[3] to[3]`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmLine {
    value: bs::Line,
    /// The point the segment starts at.
    #[var(get = get_start, no_set)]
    start: PhantomVar<Vector3>,
    /// The point the segment ends at.
    #[var(get = get_end, no_set)]
    end: PhantomVar<Vector3>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmLine {
    fn wrap(value: bs::Line) -> Gd<CadaclysmLine> {
        Gd::from_object(CadaclysmLine {
            value,
            start: PhantomVar::default(),
            end: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Line>) -> Option<Gd<CadaclysmLine>> {
        ok(result).map(CadaclysmLine::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmLine {
    fn to_string(&self) -> GString {
        gs(format!("Line{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmLine {
    /// The segment from `start` to `end` (each a `Vector3` or three numbers); `null` for two
    /// equal ends, with the reason in `Cadaclysm.last_error()`. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(start: Variant, end: Variant) -> Option<Gd<CadaclysmLine>> {
        Self::made(bs::Line::new(at(&start, "Line: start")?, at(&end, "Line: end")?))
    }

    /// A line from its raw array of 6 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmLine>> {
        Self::made(bs::Line::from_values(&number_list(&values, "value_check")?))
    }

    /// The point the segment starts at.
    #[func]
    fn get_start(&self) -> Vector3 {
        vector3(self.value.start())
    }

    /// The point the segment ends at.
    #[func]
    fn get_end(&self) -> Vector3 {
        vector3(self.value.end())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Line::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: any map that keeps its ends apart.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmLine>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The point at `t`: the fraction `t` of the way from `start` to `end` (0..1 spans the segment).
    #[func]
    fn point_at(&self, t: f64) -> Vector3 {
        point_out(self.value.point_at(t))
    }

    /// The unit tangent at `t`, the way `t` grows.
    #[func]
    fn tangent_at(&self, t: f64) -> Vector3 {
        point_out(self.value.tangent_at(t))
    }

    /// The length.
    #[func]
    fn length(&self) -> f64 {
        number_out(self.value.length())
    }

    /// The `CadaclysmCurveFoot` nearest `p` (a `Vector3` or three numbers), in closed form;
    /// `null` for a `p` that is not a point, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmCurveFoot>> {
        ok(self.value.closest_point(at(&p, "curve_value_closest_point")?)).map(CadaclysmCurveFoot::wrap)
    }

    /// How far `p` lies from the curve: the distance to its `closest_point`. `NAN` for a `p`
    /// that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "curve_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The curve as its exact `CadaclysmNurbsCurve` (a conic as a rational quadratic).
    #[func]
    fn to_nurbs(&self) -> Option<Gd<CadaclysmNurbsCurve>> {
        CadaclysmNurbsCurve::made(self.value.to_nurbs())
    }
}

/// The circle of `radius` about the frame's origin in its x-y plane, counter-clockwise about
/// its z, from its x. Its array is `frame[12] radius`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCircle {
    value: bs::Circle,
    /// The radius.
    #[var(get = get_radius, no_set)]
    radius: PhantomVar<f64>,
    /// The `CadaclysmFrame` the value is placed on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmCircle {
    fn wrap(value: bs::Circle) -> Gd<CadaclysmCircle> {
        Gd::from_object(CadaclysmCircle {
            value,
            radius: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Circle>) -> Option<Gd<CadaclysmCircle>> {
        ok(result).map(CadaclysmCircle::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCircle {
    fn to_string(&self) -> GString {
        gs(format!("Circle{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmCircle {
    /// The circle of `radius` on `frame` (a `CadaclysmFrame`, a `Transform3D` or 12 numbers). (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, radius: f64) -> Option<Gd<CadaclysmCircle>> {
        Self::made(bs::Circle::new(&self::frame(&frame, "Circle: frame")?, radius))
    }

    /// A circle from its raw array of 13 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmCircle>> {
        Self::made(bs::Circle::from_values(&number_list(&values, "value_check")?))
    }

    /// The circle through the points `a`, `b` and `c`: its x toward `a`, turning `a`, `b`, `c`
    /// counter-clockwise. `null` for three points on one line.
    #[func]
    fn through(a: Variant, b: Variant, c: Variant) -> Option<Gd<CadaclysmCircle>> {
        let call = "circle_through";
        Self::made(bs::Circle::through(at(&a, call)?, at(&b, call)?, at(&c, call)?))
    }

    /// The radius.
    #[func]
    fn get_radius(&self) -> f64 {
        self.value.radius()
    }

    /// The `CadaclysmFrame` the value is placed on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Circle::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: only a similarity.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmCircle>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The point at `t`: `t` the angle in radians from the frame's x toward its y.
    #[func]
    fn point_at(&self, t: f64) -> Vector3 {
        point_out(self.value.point_at(t))
    }

    /// The unit tangent at `t`, the way `t` grows.
    #[func]
    fn tangent_at(&self, t: f64) -> Vector3 {
        point_out(self.value.tangent_at(t))
    }

    /// The length.
    #[func]
    fn length(&self) -> f64 {
        number_out(self.value.length())
    }

    /// The `CadaclysmCurveFoot` nearest `p` (a `Vector3` or three numbers), in closed form;
    /// `null` for a `p` that is not a point, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmCurveFoot>> {
        ok(self.value.closest_point(at(&p, "curve_value_closest_point")?)).map(CadaclysmCurveFoot::wrap)
    }

    /// How far `p` lies from the curve: the distance to its `closest_point`. `NAN` for a `p`
    /// that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "curve_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The curve as its exact `CadaclysmNurbsCurve` (a conic as a rational quadratic).
    #[func]
    fn to_nurbs(&self) -> Option<Gd<CadaclysmNurbsCurve>> {
        CadaclysmNurbsCurve::made(self.value.to_nurbs())
    }
}

/// The part of a circle over `angle`, increasing by at most a full turn: the circle's frame
/// and radius, its angles from the frame's x toward its y. Its array is `frame[12] radius t0 t1`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmArc {
    value: bs::Arc,
    /// The radius.
    #[var(get = get_radius, no_set)]
    radius: PhantomVar<f64>,
    /// The angle range, a `CadaclysmInterval`.
    #[var(get = get_angle, no_set)]
    angle: PhantomVar<Gd<CadaclysmInterval>>,
    /// The point at the angle's start.
    #[var(get = get_start, no_set)]
    start: PhantomVar<Vector3>,
    /// The point at the angle's end.
    #[var(get = get_end, no_set)]
    end: PhantomVar<Vector3>,
    /// The point halfway along.
    #[var(get = get_mid, no_set)]
    mid: PhantomVar<Vector3>,
    /// The `CadaclysmFrame` the value is placed on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmArc {
    fn wrap(value: bs::Arc) -> Gd<CadaclysmArc> {
        Gd::from_object(CadaclysmArc {
            value,
            radius: PhantomVar::default(),
            angle: PhantomVar::default(),
            start: PhantomVar::default(),
            end: PhantomVar::default(),
            mid: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Arc>) -> Option<Gd<CadaclysmArc>> {
        ok(result).map(CadaclysmArc::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmArc {
    fn to_string(&self) -> GString {
        gs(format!("Arc{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmArc {
    /// The arc of `radius` on `frame` over `angle`: a `CadaclysmInterval` or two numbers. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, radius: f64, angle: Variant) -> Option<Gd<CadaclysmArc>> {
        Self::made(bs::Arc::new(&self::frame(&frame, "Arc: frame")?, radius, interval_arg(&angle, "Arc: angle")?))
    }

    /// A arc from its raw array of 15 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmArc>> {
        Self::made(bs::Arc::from_values(&number_list(&values, "value_check")?))
    }

    /// The arc from `a` through `b` to `c`; `null` for three points on one line.
    #[func]
    fn through(a: Variant, b: Variant, c: Variant) -> Option<Gd<CadaclysmArc>> {
        let call = "arc_through";
        Self::made(bs::Arc::through(at(&a, call)?, at(&b, call)?, at(&c, call)?))
    }

    /// The arc leaving `a` along `tangent` and ending at `c`; `null` for a zero tangent, or a
    /// `c` on the tangent's line.
    #[func]
    fn from_start_tangent_end(a: Variant, tangent: Variant, c: Variant) -> Option<Gd<CadaclysmArc>> {
        let call = "arc_from_start_tangent_end";
        Self::made(bs::Arc::from_start_tangent_end(at(&a, call)?, at(&tangent, call)?, at(&c, call)?))
    }

    /// The radius.
    #[func]
    fn get_radius(&self) -> f64 {
        self.value.radius()
    }

    /// The angle range, a `CadaclysmInterval`.
    #[func]
    fn get_angle(&self) -> Gd<CadaclysmInterval> {
        CadaclysmInterval::wrap(self.value.angle())
    }

    /// The point at the angle's start.
    #[func]
    fn get_start(&self) -> Vector3 {
        point_out(self.value.start())
    }

    /// The point at the angle's end.
    #[func]
    fn get_end(&self) -> Vector3 {
        point_out(self.value.end())
    }

    /// The point halfway along.
    #[func]
    fn get_mid(&self) -> Vector3 {
        point_out(self.value.mid())
    }

    /// The `CadaclysmFrame` the value is placed on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Arc::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: only a similarity.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmArc>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The point at `t`: `t` the angle in radians from the frame's x toward its y.
    #[func]
    fn point_at(&self, t: f64) -> Vector3 {
        point_out(self.value.point_at(t))
    }

    /// The unit tangent at `t`, the way `t` grows.
    #[func]
    fn tangent_at(&self, t: f64) -> Vector3 {
        point_out(self.value.tangent_at(t))
    }

    /// The length.
    #[func]
    fn length(&self) -> f64 {
        number_out(self.value.length())
    }

    /// The `CadaclysmCurveFoot` nearest `p` (a `Vector3` or three numbers), in closed form;
    /// `null` for a `p` that is not a point, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmCurveFoot>> {
        ok(self.value.closest_point(at(&p, "curve_value_closest_point")?)).map(CadaclysmCurveFoot::wrap)
    }

    /// How far `p` lies from the curve: the distance to its `closest_point`. `NAN` for a `p`
    /// that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "curve_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The curve as its exact `CadaclysmNurbsCurve` (a conic as a rational quadratic).
    #[func]
    fn to_nurbs(&self) -> Option<Gd<CadaclysmNurbsCurve>> {
        CadaclysmNurbsCurve::made(self.value.to_nurbs())
    }
}

/// The ellipse of radius `r1` along the frame's x and `r2` along its y. Its array is
/// `frame[12] r1 r2`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmEllipse {
    value: bs::Ellipse,
    /// The radius along the frame's x.
    #[var(get = get_r1, no_set)]
    r1: PhantomVar<f64>,
    /// The radius along the frame's y.
    #[var(get = get_r2, no_set)]
    r2: PhantomVar<f64>,
    /// The `CadaclysmFrame` the value is placed on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmEllipse {
    fn wrap(value: bs::Ellipse) -> Gd<CadaclysmEllipse> {
        Gd::from_object(CadaclysmEllipse {
            value,
            r1: PhantomVar::default(),
            r2: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Ellipse>) -> Option<Gd<CadaclysmEllipse>> {
        ok(result).map(CadaclysmEllipse::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmEllipse {
    fn to_string(&self) -> GString {
        gs(format!("Ellipse{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmEllipse {
    /// The ellipse of radii `r1` (along the frame's x) and `r2` (along its y) on `frame`. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, r1: f64, r2: f64) -> Option<Gd<CadaclysmEllipse>> {
        Self::made(bs::Ellipse::new(&self::frame(&frame, "Ellipse: frame")?, r1, r2))
    }

    /// A ellipse from its raw array of 14 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmEllipse>> {
        Self::made(bs::Ellipse::from_values(&number_list(&values, "value_check")?))
    }

    /// `circle` as an ellipse of two equal radii, to map by a non-uniform scale or a shear.
    #[func]
    fn from_circle(circle: Gd<CadaclysmCircle>) -> Option<Gd<CadaclysmEllipse>> {
        Self::made(bs::Ellipse::from_circle(&circle.bind().value))
    }

    /// The radius along the frame's x.
    #[func]
    fn get_r1(&self) -> f64 {
        self.value.r1()
    }

    /// The radius along the frame's y.
    #[func]
    fn get_r2(&self) -> f64 {
        self.value.r2()
    }

    /// The `CadaclysmFrame` the value is placed on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Ellipse::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: any map that keeps it an ellipse.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmEllipse>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The point at `t`: `t` the eccentric angle in radians, from the frame's x toward its y.
    #[func]
    fn point_at(&self, t: f64) -> Vector3 {
        point_out(self.value.point_at(t))
    }

    /// The unit tangent at `t`, the way `t` grows.
    #[func]
    fn tangent_at(&self, t: f64) -> Vector3 {
        point_out(self.value.tangent_at(t))
    }

    /// The length, in closed form (the perimeter).
    #[func]
    fn length(&self) -> f64 {
        number_out(self.value.length())
    }

    /// The `CadaclysmCurveFoot` nearest `p` (a `Vector3` or three numbers), in closed form;
    /// `null` for a `p` that is not a point, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmCurveFoot>> {
        ok(self.value.closest_point(at(&p, "curve_value_closest_point")?)).map(CadaclysmCurveFoot::wrap)
    }

    /// How far `p` lies from the curve: the distance to its `closest_point`. `NAN` for a `p`
    /// that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "curve_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The curve as its exact `CadaclysmNurbsCurve` (a conic as a rational quadratic).
    #[func]
    fn to_nurbs(&self) -> Option<Gd<CadaclysmNurbsCurve>> {
        CadaclysmNurbsCurve::made(self.value.to_nurbs())
    }
}

/// The sphere of `radius` about the frame's origin: `u` the longitude from the frame's x, `v`
/// the latitude toward its z. Its array is `frame[12] radius`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSphere {
    value: bs::Sphere,
    /// The radius.
    #[var(get = get_radius, no_set)]
    radius: PhantomVar<f64>,
    /// The `CadaclysmFrame` the value is placed on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmSphere {
    fn wrap(value: bs::Sphere) -> Gd<CadaclysmSphere> {
        Gd::from_object(CadaclysmSphere {
            value,
            radius: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Sphere>) -> Option<Gd<CadaclysmSphere>> {
        ok(result).map(CadaclysmSphere::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmSphere {
    fn to_string(&self) -> GString {
        gs(format!("Sphere{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmSphere {
    /// The sphere of `radius` about `frame`'s origin. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, radius: f64) -> Option<Gd<CadaclysmSphere>> {
        Self::made(bs::Sphere::new(&self::frame(&frame, "Sphere: frame")?, radius))
    }

    /// A sphere from its raw array of 13 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmSphere>> {
        Self::made(bs::Sphere::from_values(&number_list(&values, "value_check")?))
    }

    /// The radius.
    #[func]
    fn get_radius(&self) -> f64 {
        self.value.radius()
    }

    /// The `CadaclysmFrame` the value is placed on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Sphere::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: only a similarity.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmSphere>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The point at `(u, v)`, in the ranges `domain` gives.
    #[func]
    fn point_at(&self, u: f64, v: f64) -> Vector3 {
        point_out(self.value.point_at(u, v))
    }

    /// The outward unit normal at `(u, v)`.
    #[func]
    fn normal_at(&self, u: f64, v: f64) -> Vector3 {
        point_out(self.value.normal_at(u, v))
    }

    /// The `CadaclysmSurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side,
    /// not their caps), in closed form; `null` for a `p` that is not a point.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmSurfaceFoot>> {
        ok(self.value.closest_point(at(&p, "surface_value_closest_point")?)).map(CadaclysmSurfaceFoot::wrap)
    }

    /// How far `p` lies from the surface: the distance to its `closest_point`. `NAN` for a
    /// `p` that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "surface_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The `u` and `v` ranges, as two `CadaclysmInterval`s.
    #[func]
    fn domain(&self) -> Array<Gd<CadaclysmInterval>> {
        ok(self.value.domain()).map_or_else(Array::new, |(u, v)| array![&CadaclysmInterval::wrap(u), &CadaclysmInterval::wrap(v)])
    }

    /// The surface alone, as an open sheet on its exact NURBS form.
    #[func]
    fn to_nurbs_sheet(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_nurbs_sheet()).map(CadaclysmSolid::wrap)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it. `false`, with
    /// the reason in `Cadaclysm.last_error()`, for a `p` that is not a point or a tolerance
    /// negative or not finite.
    #[func]
    fn contains(&self, p: Variant, #[opt(default = bs::CONTAINS_TOLERANCE)] tolerance: f64) -> bool {
        at(&p, "solid_value_contains").and_then(|p| ok(self.value.contains(p, tolerance))).unwrap_or(false)
    }

    /// The boundary's area, in closed form.
    #[func]
    fn area(&self) -> f64 {
        number_out(self.value.area())
    }

    /// The volume enclosed, in closed form.
    #[func]
    fn volume(&self) -> f64 {
        number_out(self.value.volume())
    }

    /// The shape as a closed exact B-rep `CadaclysmSolid`.
    #[func]
    fn to_solid(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_solid()).map(CadaclysmSolid::wrap)
    }
}

/// The capped cylinder of `radius` about the frame's z over `height` along it: `u` the angle
/// from the frame's x, `v` the height. Its array is `frame[12] radius h0 h1`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCylinder {
    value: bs::Cylinder,
    /// The radius.
    #[var(get = get_radius, no_set)]
    radius: PhantomVar<f64>,
    /// The range along the frame's z, a `CadaclysmInterval`.
    #[var(get = get_height, no_set)]
    height: PhantomVar<Gd<CadaclysmInterval>>,
    /// The `CadaclysmFrame` the value is placed on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmCylinder {
    fn wrap(value: bs::Cylinder) -> Gd<CadaclysmCylinder> {
        Gd::from_object(CadaclysmCylinder {
            value,
            radius: PhantomVar::default(),
            height: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Cylinder>) -> Option<Gd<CadaclysmCylinder>> {
        ok(result).map(CadaclysmCylinder::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCylinder {
    fn to_string(&self) -> GString {
        gs(format!("Cylinder{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmCylinder {
    /// The cylinder of `radius` about `frame`'s z over `height`: an increasing
    /// `CadaclysmInterval` or two numbers. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, radius: f64, height: Variant) -> Option<Gd<CadaclysmCylinder>> {
        Self::made(bs::Cylinder::new(&self::frame(&frame, "Cylinder: frame")?, radius, interval_arg(&height, "Cylinder: height")?))
    }

    /// A cylinder from its raw array of 15 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmCylinder>> {
        Self::made(bs::Cylinder::from_values(&number_list(&values, "value_check")?))
    }

    /// The radius.
    #[func]
    fn get_radius(&self) -> f64 {
        self.value.radius()
    }

    /// The range along the frame's z, a `CadaclysmInterval`.
    #[func]
    fn get_height(&self) -> Gd<CadaclysmInterval> {
        CadaclysmInterval::wrap(self.value.height())
    }

    /// The `CadaclysmFrame` the value is placed on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Cylinder::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: only a similarity.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmCylinder>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The point at `(u, v)`, in the ranges `domain` gives.
    #[func]
    fn point_at(&self, u: f64, v: f64) -> Vector3 {
        point_out(self.value.point_at(u, v))
    }

    /// The outward unit normal at `(u, v)`.
    #[func]
    fn normal_at(&self, u: f64, v: f64) -> Vector3 {
        point_out(self.value.normal_at(u, v))
    }

    /// The `CadaclysmSurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side,
    /// not their caps), in closed form; `null` for a `p` that is not a point.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmSurfaceFoot>> {
        ok(self.value.closest_point(at(&p, "surface_value_closest_point")?)).map(CadaclysmSurfaceFoot::wrap)
    }

    /// How far `p` lies from the surface: the distance to its `closest_point`. `NAN` for a
    /// `p` that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "surface_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The `u` and `v` ranges, as two `CadaclysmInterval`s.
    #[func]
    fn domain(&self) -> Array<Gd<CadaclysmInterval>> {
        ok(self.value.domain()).map_or_else(Array::new, |(u, v)| array![&CadaclysmInterval::wrap(u), &CadaclysmInterval::wrap(v)])
    }

    /// The surface alone, as an open sheet on its exact NURBS form.
    #[func]
    fn to_nurbs_sheet(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_nurbs_sheet()).map(CadaclysmSolid::wrap)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it. `false`, with
    /// the reason in `Cadaclysm.last_error()`, for a `p` that is not a point or a tolerance
    /// negative or not finite.
    #[func]
    fn contains(&self, p: Variant, #[opt(default = bs::CONTAINS_TOLERANCE)] tolerance: f64) -> bool {
        at(&p, "solid_value_contains").and_then(|p| ok(self.value.contains(p, tolerance))).unwrap_or(false)
    }

    /// The boundary's area, in closed form.
    #[func]
    fn area(&self) -> f64 {
        number_out(self.value.area())
    }

    /// The volume enclosed, in closed form.
    #[func]
    fn volume(&self) -> f64 {
        number_out(self.value.volume())
    }

    /// The shape as a closed exact B-rep `CadaclysmSolid`.
    #[func]
    fn to_solid(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_solid()).map(CadaclysmSolid::wrap)
    }
}

/// The capped cone of base `radius` on the frame's x-y plane, its apex `height` up its z: `u`
/// the angle from the frame's x, `v` the height. Its array is `frame[12] radius height`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCone {
    value: bs::Cone,
    /// The base radius.
    #[var(get = get_radius, no_set)]
    radius: PhantomVar<f64>,
    /// How far up the frame's z the apex lies.
    #[var(get = get_height, no_set)]
    height: PhantomVar<f64>,
    /// The `CadaclysmFrame` the value is placed on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmCone {
    fn wrap(value: bs::Cone) -> Gd<CadaclysmCone> {
        Gd::from_object(CadaclysmCone {
            value,
            radius: PhantomVar::default(),
            height: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Cone>) -> Option<Gd<CadaclysmCone>> {
        ok(result).map(CadaclysmCone::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCone {
    fn to_string(&self) -> GString {
        gs(format!("Cone{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmCone {
    /// The cone of base `radius` on `frame`, its apex `height` up its z. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, radius: f64, height: f64) -> Option<Gd<CadaclysmCone>> {
        Self::made(bs::Cone::new(&self::frame(&frame, "Cone: frame")?, radius, height))
    }

    /// A cone from its raw array of 14 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmCone>> {
        Self::made(bs::Cone::from_values(&number_list(&values, "value_check")?))
    }

    /// The base radius.
    #[func]
    fn get_radius(&self) -> f64 {
        self.value.radius()
    }

    /// How far up the frame's z the apex lies.
    #[func]
    fn get_height(&self) -> f64 {
        self.value.height()
    }

    /// The `CadaclysmFrame` the value is placed on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Cone::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: only a similarity.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmCone>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The point at `(u, v)`, in the ranges `domain` gives.
    #[func]
    fn point_at(&self, u: f64, v: f64) -> Vector3 {
        point_out(self.value.point_at(u, v))
    }

    /// The outward unit normal at `(u, v)`.
    #[func]
    fn normal_at(&self, u: f64, v: f64) -> Vector3 {
        point_out(self.value.normal_at(u, v))
    }

    /// The `CadaclysmSurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side,
    /// not their caps), in closed form; `null` for a `p` that is not a point.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmSurfaceFoot>> {
        ok(self.value.closest_point(at(&p, "surface_value_closest_point")?)).map(CadaclysmSurfaceFoot::wrap)
    }

    /// How far `p` lies from the surface: the distance to its `closest_point`. `NAN` for a
    /// `p` that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "surface_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The `u` and `v` ranges, as two `CadaclysmInterval`s.
    #[func]
    fn domain(&self) -> Array<Gd<CadaclysmInterval>> {
        ok(self.value.domain()).map_or_else(Array::new, |(u, v)| array![&CadaclysmInterval::wrap(u), &CadaclysmInterval::wrap(v)])
    }

    /// The surface alone, as an open sheet on its exact NURBS form.
    #[func]
    fn to_nurbs_sheet(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_nurbs_sheet()).map(CadaclysmSolid::wrap)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it. `false`, with
    /// the reason in `Cadaclysm.last_error()`, for a `p` that is not a point or a tolerance
    /// negative or not finite.
    #[func]
    fn contains(&self, p: Variant, #[opt(default = bs::CONTAINS_TOLERANCE)] tolerance: f64) -> bool {
        at(&p, "solid_value_contains").and_then(|p| ok(self.value.contains(p, tolerance))).unwrap_or(false)
    }

    /// The boundary's area, in closed form.
    #[func]
    fn area(&self) -> f64 {
        number_out(self.value.area())
    }

    /// The volume enclosed, in closed form.
    #[func]
    fn volume(&self) -> f64 {
        number_out(self.value.volume())
    }

    /// The shape as a closed exact B-rep `CadaclysmSolid`.
    #[func]
    fn to_solid(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_solid()).map(CadaclysmSolid::wrap)
    }
}

/// The torus of `major` radius about the frame's z and `minor` radius about that circle: `u` the
/// angle about the z from the frame's x, `v` the angle about the tube. Its array is
/// `frame[12] major minor`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmTorus {
    value: bs::Torus,
    /// The radius of the tube's centre circle.
    #[var(get = get_major, no_set)]
    major: PhantomVar<f64>,
    /// The tube's own radius.
    #[var(get = get_minor, no_set)]
    minor: PhantomVar<f64>,
    /// The `CadaclysmFrame` the value is placed on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmTorus {
    fn wrap(value: bs::Torus) -> Gd<CadaclysmTorus> {
        Gd::from_object(CadaclysmTorus {
            value,
            major: PhantomVar::default(),
            minor: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Torus>) -> Option<Gd<CadaclysmTorus>> {
        ok(result).map(CadaclysmTorus::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmTorus {
    fn to_string(&self) -> GString {
        gs(format!("Torus{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmTorus {
    /// The torus of `major` and `minor` radii about `frame`'s z. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, major: f64, minor: f64) -> Option<Gd<CadaclysmTorus>> {
        Self::made(bs::Torus::new(&self::frame(&frame, "Torus: frame")?, major, minor))
    }

    /// A torus from its raw array of 14 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmTorus>> {
        Self::made(bs::Torus::from_values(&number_list(&values, "value_check")?))
    }

    /// The radius of the tube's centre circle.
    #[func]
    fn get_major(&self) -> f64 {
        self.value.major()
    }

    /// The tube's own radius.
    #[func]
    fn get_minor(&self) -> f64 {
        self.value.minor()
    }

    /// The `CadaclysmFrame` the value is placed on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Torus::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: only a similarity.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmTorus>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The point at `(u, v)`, in the ranges `domain` gives.
    #[func]
    fn point_at(&self, u: f64, v: f64) -> Vector3 {
        point_out(self.value.point_at(u, v))
    }

    /// The outward unit normal at `(u, v)`.
    #[func]
    fn normal_at(&self, u: f64, v: f64) -> Vector3 {
        point_out(self.value.normal_at(u, v))
    }

    /// The `CadaclysmSurfaceFoot` nearest `p` on the surface (a cylinder's and a cone's side,
    /// not their caps), in closed form; `null` for a `p` that is not a point.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmSurfaceFoot>> {
        ok(self.value.closest_point(at(&p, "surface_value_closest_point")?)).map(CadaclysmSurfaceFoot::wrap)
    }

    /// How far `p` lies from the surface: the distance to its `closest_point`. `NAN` for a
    /// `p` that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "surface_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The `u` and `v` ranges, as two `CadaclysmInterval`s.
    #[func]
    fn domain(&self) -> Array<Gd<CadaclysmInterval>> {
        ok(self.value.domain()).map_or_else(Array::new, |(u, v)| array![&CadaclysmInterval::wrap(u), &CadaclysmInterval::wrap(v)])
    }

    /// The surface alone, as an open sheet on its exact NURBS form.
    #[func]
    fn to_nurbs_sheet(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_nurbs_sheet()).map(CadaclysmSolid::wrap)
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it. `false`, with
    /// the reason in `Cadaclysm.last_error()`, for a `p` that is not a point or a tolerance
    /// negative or not finite.
    #[func]
    fn contains(&self, p: Variant, #[opt(default = bs::CONTAINS_TOLERANCE)] tolerance: f64) -> bool {
        at(&p, "solid_value_contains").and_then(|p| ok(self.value.contains(p, tolerance))).unwrap_or(false)
    }

    /// The boundary's area, in closed form.
    #[func]
    fn area(&self) -> f64 {
        number_out(self.value.area())
    }

    /// The volume enclosed, in closed form.
    #[func]
    fn volume(&self) -> f64 {
        number_out(self.value.volume())
    }

    /// The shape as a closed exact B-rep `CadaclysmSolid`.
    #[func]
    fn to_solid(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_solid()).map(CadaclysmSolid::wrap)
    }
}

/// The box over `x`, `y`, `z` along its frame's axes: an oriented bounding box, a region to test
/// points against, a block to make a solid of. Its array is `frame[12] x0 x1 y0 y1 z0 z1`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCuboid {
    value: bs::Cuboid,
    /// The range along the frame's x, a `CadaclysmInterval`.
    #[var(get = get_x, no_set)]
    x: PhantomVar<Gd<CadaclysmInterval>>,
    /// The range along the frame's y, a `CadaclysmInterval`.
    #[var(get = get_y, no_set)]
    y: PhantomVar<Gd<CadaclysmInterval>>,
    /// The range along the frame's z, a `CadaclysmInterval`.
    #[var(get = get_z, no_set)]
    z: PhantomVar<Gd<CadaclysmInterval>>,
    /// The `CadaclysmFrame` the value is placed on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmCuboid {
    fn wrap(value: bs::Cuboid) -> Gd<CadaclysmCuboid> {
        Gd::from_object(CadaclysmCuboid {
            value,
            x: PhantomVar::default(),
            y: PhantomVar::default(),
            z: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Cuboid>) -> Option<Gd<CadaclysmCuboid>> {
        ok(result).map(CadaclysmCuboid::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCuboid {
    fn to_string(&self) -> GString {
        gs(format!("Cuboid{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmCuboid {
    /// The box on `frame` over `x`, `y` and `z`: increasing `CadaclysmInterval`s or pairs. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, x: Variant, y: Variant, z: Variant) -> Option<Gd<CadaclysmCuboid>> {
        Self::made(bs::Cuboid::new(&self::frame(&frame, "Cuboid: frame")?, interval_arg(&x, "Cuboid: x")?, interval_arg(&y, "Cuboid: y")?, interval_arg(&z, "Cuboid: z")?))
    }

    /// A cuboid from its raw array of 18 numbers (a `PackedFloat64Array` or an Array), checked
    /// and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmCuboid>> {
        Self::made(bs::Cuboid::from_values(&number_list(&values, "value_check")?))
    }

    /// The world-aligned box from `min` to `max`; `null` for an empty or flat one.
    #[func]
    fn from_bounds(min: Variant, max: Variant) -> Option<Gd<CadaclysmCuboid>> {
        let call = "cuboid_from_bounds";
        Self::made(bs::Cuboid::from_bounds(at(&min, call)?, at(&max, call)?))
    }

    /// The tightest box holding `points` (a `PackedVector3Array` or an array of points),
    /// aligned to `frame`; `null` for no points, or points flat along an axis of the frame.
    #[func]
    fn around(frame: Variant, points: Variant) -> Option<Gd<CadaclysmCuboid>> {
        let frame = self::frame(&frame, "cuboid_around: frame")?;
        Self::made(bs::Cuboid::around(&frame, &point_list(&points, "cuboid_around")?))
    }

    /// The range along the frame's x, a `CadaclysmInterval`.
    #[func]
    fn get_x(&self) -> Gd<CadaclysmInterval> {
        CadaclysmInterval::wrap(self.value.x())
    }

    /// The range along the frame's y, a `CadaclysmInterval`.
    #[func]
    fn get_y(&self) -> Gd<CadaclysmInterval> {
        CadaclysmInterval::wrap(self.value.y())
    }

    /// The range along the frame's z, a `CadaclysmInterval`.
    #[func]
    fn get_z(&self) -> Gd<CadaclysmInterval> {
        CadaclysmInterval::wrap(self.value.z())
    }

    /// The `CadaclysmFrame` the value is placed on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Cuboid::KIND, &self.value.values(), &other)
    }

    /// The exact world box, from the closed form rather than from samples.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: only a similarity.
    /// `null` for any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmCuboid>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// Whether `p` lies inside the closed shape or within `tolerance` of it. `false`, with
    /// the reason in `Cadaclysm.last_error()`, for a `p` that is not a point or a tolerance
    /// negative or not finite.
    #[func]
    fn contains(&self, p: Variant, #[opt(default = bs::CONTAINS_TOLERANCE)] tolerance: f64) -> bool {
        at(&p, "solid_value_contains").and_then(|p| ok(self.value.contains(p, tolerance))).unwrap_or(false)
    }

    /// The boundary's area, in closed form.
    #[func]
    fn area(&self) -> f64 {
        number_out(self.value.area())
    }

    /// The volume enclosed, in closed form.
    #[func]
    fn volume(&self) -> f64 {
        number_out(self.value.volume())
    }

    /// The shape as a closed exact B-rep `CadaclysmSolid`.
    #[func]
    fn to_solid(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_solid()).map(CadaclysmSolid::wrap)
    }

    /// The eight corners: the `z0` face counter-clockwise about the frame's z from
    /// `(x0, y0)`, then the `z1` face in the same order.
    #[func]
    fn corners(&self) -> PackedVector3Array {
        ok(self.value.corners()).map_or_else(PackedVector3Array::new, |c| c.iter().map(|&p| vector3(p)).collect())
    }

    /// The point the fractions `sx`, `sy`, `sz` of the way along each range.
    #[func]
    fn point_at(&self, sx: f64, sy: f64, sz: f64) -> Vector3 {
        point_out(self.value.point_at(sx, sy, sz))
    }

    /// The closest point of the solid box to `p`: `p` itself where it lies inside. `NAN`s for
    /// a `p` that is not a point.
    #[func]
    fn closest_point(&self, p: Variant) -> Vector3 {
        at(&p, "cuboid_closest_point").map_or(NAN3, |p| point_out(self.value.closest_point(p)))
    }
}

// ---- CadaclysmRectangle, CadaclysmTriangle, CadaclysmRay (value geometry plan B4) ---------

/// The rectangle over `x` and `y` (increasing) in its frame's x-y plane, as a value. As a curve
/// it is its boundary: `t` runs 0..4, one unit a side from corner `(x0, y0)` counter-clockwise
/// about the frame's z, clamped outside that range; `closest_point` is the boundary's, not
/// unique on a tie (the centre). Its array is `frame[12] x0 x1 y0 y1`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmRectangle {
    value: bs::Rectangle,
    /// The range along the frame's x, a `CadaclysmInterval`.
    #[var(get = get_x, no_set)]
    x: PhantomVar<Gd<CadaclysmInterval>>,
    /// The range along the frame's y, a `CadaclysmInterval`.
    #[var(get = get_y, no_set)]
    y: PhantomVar<Gd<CadaclysmInterval>>,
    /// The `CadaclysmFrame` the rectangle lies on.
    #[var(get = get_frame, no_set)]
    frame: PhantomVar<Gd<CadaclysmFrame>>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmRectangle {
    fn wrap(value: bs::Rectangle) -> Gd<CadaclysmRectangle> {
        Gd::from_object(CadaclysmRectangle {
            value,
            x: PhantomVar::default(),
            y: PhantomVar::default(),
            frame: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Rectangle>) -> Option<Gd<CadaclysmRectangle>> {
        ok(result).map(CadaclysmRectangle::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmRectangle {
    fn to_string(&self) -> GString {
        gs(format!("Rectangle{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmRectangle {
    /// The rectangle on `frame` over `x` and `y`: increasing `CadaclysmInterval`s or pairs. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(frame: Variant, x: Variant, y: Variant) -> Option<Gd<CadaclysmRectangle>> {
        Self::made(bs::Rectangle::new(&self::frame(&frame, "Rectangle: frame")?, interval_arg(&x, "Rectangle: x")?, interval_arg(&y, "Rectangle: y")?))
    }

    /// A rectangle from its raw array of 16 numbers (a `PackedFloat64Array` or an Array),
    /// checked and squared up by the library: `null` for another count or a bad value.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmRectangle>> {
        Self::made(bs::Rectangle::from_values(&number_list(&values, "value_check")?))
    }

    /// The range along the frame's x, a `CadaclysmInterval`.
    #[func]
    fn get_x(&self) -> Gd<CadaclysmInterval> {
        CadaclysmInterval::wrap(self.value.x())
    }

    /// The range along the frame's y, a `CadaclysmInterval`.
    #[func]
    fn get_y(&self) -> Gd<CadaclysmInterval> {
        CadaclysmInterval::wrap(self.value.y())
    }

    /// The `CadaclysmFrame` the rectangle lies on.
    #[func]
    fn get_frame(&self) -> Gd<CadaclysmFrame> {
        CadaclysmFrame::wrap(self.value.frame())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Rectangle::KIND, &self.value.values(), &other)
    }

    /// The world box of the four corners.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: any map that keeps its sides square.
    /// `null` for a shear in its plane or any other map, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmRectangle>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The boundary's point at `t`: side `k` for `t` in `k..k+1`, clamped outside 0..4.
    #[func]
    fn point_at(&self, t: f64) -> Vector3 {
        point_out(self.value.point_at(t))
    }

    /// The unit direction of `t`'s side.
    #[func]
    fn tangent_at(&self, t: f64) -> Vector3 {
        point_out(self.value.tangent_at(t))
    }

    /// The boundary's length, the circumference.
    #[func]
    fn length(&self) -> f64 {
        number_out(self.value.length())
    }

    /// The `CadaclysmCurveFoot` on the boundary nearest `p` (a `Vector3` or three numbers);
    /// `null` for a `p` that is not a point, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmCurveFoot>> {
        ok(self.value.closest_point(at(&p, "curve_value_closest_point")?)).map(CadaclysmCurveFoot::wrap)
    }

    /// How far `p` lies from the boundary. `NAN` for a `p` that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "curve_value_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// The four corners: `(x0, y0)`, `(x1, y0)`, `(x1, y1)`, `(x0, y1)`.
    #[func]
    fn corners(&self) -> PackedVector3Array {
        ok(self.value.corners()).map_or_else(PackedVector3Array::new, |c| c.iter().map(|&p| vector3(p)).collect())
    }

    /// The filled rectangle's area.
    #[func]
    fn area(&self) -> f64 {
        number_out(self.value.area())
    }

    /// `p` projected onto the plane and clamped into the filled rectangle when
    /// `include_interior` (the default), else the boundary's closest point. `NAN`s for a `p`
    /// that is not a point.
    #[func]
    fn closest_point_in(&self, p: Variant, #[opt(default = true)] include_interior: bool) -> Vector3 {
        at(&p, "rectangle_closest_point").map_or(NAN3, |p| point_out(self.value.closest_point_in(p, include_interior)))
    }

    /// Where `p`, projected onto the plane, lies: `"inside"`, `"outside"`, or `"on"` within
    /// `tolerance` of the boundary. `NAN` (the default) is unset: the rectangle's own effective
    /// tolerance (`tolerance.relative` times its diagonal); 0 is exact. `""`, with the reason
    /// in `Cadaclysm.last_error()`, for a `p` that is not a point or a tolerance negative or
    /// infinite.
    #[func]
    fn contains(&self, p: Variant, #[opt(default = f64::NAN)] tolerance: f64) -> GString {
        let Some(p) = at(&p, "rectangle_contains") else { return GString::new() };
        gs(ok(self.value.contains(p, Some(tolerance))).unwrap_or_default())
    }

    /// The filled rectangle as a one-face planar sheet `CadaclysmSolid` facing the frame's z.
    #[func]
    fn to_sheet(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_sheet()).map(CadaclysmSolid::wrap)
    }

    /// The boundary as its exact closed degree-1 `CadaclysmNurbsCurve`, a knot at each
    /// corner, so its parameter is `t`.
    #[func]
    fn to_nurbs(&self) -> Option<Gd<CadaclysmNurbsCurve>> {
        CadaclysmNurbsCurve::made(self.value.to_nurbs())
    }
}

/// The triangle `a`, `b`, `c`, as a value; a degenerate one (collinear or coincident points)
/// is refused. Its array is `a[3] b[3] c[3]`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmTriangle {
    value: bs::Triangle,
    /// The first vertex.
    #[var(get = get_a, no_set)]
    a: PhantomVar<Vector3>,
    /// The second vertex.
    #[var(get = get_b, no_set)]
    b: PhantomVar<Vector3>,
    /// The third vertex.
    #[var(get = get_c, no_set)]
    c: PhantomVar<Vector3>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmTriangle {
    fn wrap(value: bs::Triangle) -> Gd<CadaclysmTriangle> {
        Gd::from_object(CadaclysmTriangle {
            value,
            a: PhantomVar::default(),
            b: PhantomVar::default(),
            c: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Triangle>) -> Option<Gd<CadaclysmTriangle>> {
        ok(result).map(CadaclysmTriangle::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmTriangle {
    fn to_string(&self) -> GString {
        gs(format!("Triangle{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmTriangle {
    /// The triangle `a`, `b`, `c` (each a `Vector3` or three numbers); `null` for a degenerate
    /// one, with the reason in `Cadaclysm.last_error()`. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(a: Variant, b: Variant, c: Variant) -> Option<Gd<CadaclysmTriangle>> {
        Self::made(bs::Triangle::new(at(&a, "Triangle: a")?, at(&b, "Triangle: b")?, at(&c, "Triangle: c")?))
    }

    /// A triangle from its raw array of 9 numbers (a `PackedFloat64Array` or an Array),
    /// checked by the library: `null` for another count or a degenerate triangle.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmTriangle>> {
        Self::made(bs::Triangle::from_values(&number_list(&values, "value_check")?))
    }

    /// The first vertex.
    #[func]
    fn get_a(&self) -> Vector3 {
        vector3(self.value.a())
    }

    /// The second vertex.
    #[func]
    fn get_b(&self) -> Vector3 {
        vector3(self.value.b())
    }

    /// The third vertex.
    #[func]
    fn get_c(&self) -> Vector3 {
        vector3(self.value.c())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Triangle::KIND, &self.value.values(), &other)
    }

    /// The world box of the three vertices.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: any affine map that keeps it a triangle.
    /// `null` for one that flattens it, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmTriangle>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// The area.
    #[func]
    fn area(&self) -> f64 {
        number_out(self.value.area())
    }

    /// The sum of the three sides.
    #[func]
    fn perimeter(&self) -> f64 {
        number_out(self.value.perimeter())
    }

    /// The area centroid, the vertices' mean.
    #[func]
    fn centroid(&self) -> Vector3 {
        point_out(self.value.centroid())
    }

    /// The `CadaclysmCircle` through `a`, `b` and `c`: its x toward `a`, turning them
    /// counter-clockwise.
    #[func]
    fn circumcircle(&self) -> Option<Gd<CadaclysmCircle>> {
        ok(self.value.circumcircle()).map(CadaclysmCircle::wrap)
    }

    /// The point of barycentric weights `wa`, `wb`, `wc`, used as given.
    #[func]
    fn point_at(&self, wa: f64, wb: f64, wc: f64) -> Vector3 {
        point_out(self.value.point_at(wa, wb, wc))
    }

    /// The weights `[wa, wb, wc]`, summing to 1, of `p` projected onto the plane, as doubles
    /// (weights, not a point); empty for a `p` that is not a point.
    #[func]
    fn barycentric(&self, p: Variant) -> PackedFloat64Array {
        at(&p, "triangle_barycentric").and_then(|p| ok(self.value.barycentric(p))).map_or_else(PackedFloat64Array::new, |w| doubles(&w))
    }

    /// The closest point of the filled triangle to `p`, exact. `NAN`s for a `p` that is not a
    /// point.
    #[func]
    fn closest_point(&self, p: Variant) -> Vector3 {
        at(&p, "triangle_closest_point").map_or(NAN3, |p| point_out(self.value.closest_point(p)))
    }

    /// How far `p` lies from the filled triangle. `NAN` for a `p` that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "triangle_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
    }

    /// Edge `i` as a `CadaclysmLine`: 0 `a` to `b`, 1 `b` to `c`, 2 `c` to `a`; `null` for any
    /// other `i`, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn edge(&self, i: i64) -> Option<Gd<CadaclysmLine>> {
        let Ok(index) = u32::try_from(i) else { return fail(format!("triangle_edge: edge {i} is not 0, 1 or 2")) };
        ok(self.value.edge(index)).map(CadaclysmLine::wrap)
    }

    /// The filled triangle as a one-face planar sheet `CadaclysmSolid`, its normal turning `a`,
    /// `b`, `c` counter-clockwise.
    #[func]
    fn to_sheet(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.value.to_sheet()).map(CadaclysmSolid::wrap)
    }
}

/// The half-line from `position` along `direction`, as a value. The direction is kept as
/// given, not unitised, so `t` counts lengths of it; a zero one is refused. A ray has no box:
/// `bounds` is the empty `AABB`, with the reason in `Cadaclysm.last_error()`. Its array is
/// `position[3] direction[3]`.
///
/// Immutable, with nothing to free; the maths is the library's own. `equals` compares the
/// kind and the array. Points cross as `Vector3`s, so floats in a default build; `values`
/// keeps the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmRay {
    value: bs::Ray,
    /// The start.
    #[var(get = get_position, no_set)]
    position: PhantomVar<Vector3>,
    /// The direction, as given.
    #[var(get = get_direction, no_set)]
    direction: PhantomVar<Vector3>,
    /// The canonical array, as the library squared it up.
    #[var(get = get_values, no_set)]
    values: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmRay {
    fn wrap(value: bs::Ray) -> Gd<CadaclysmRay> {
        Gd::from_object(CadaclysmRay {
            value,
            position: PhantomVar::default(),
            direction: PhantomVar::default(),
            values: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::Ray>) -> Option<Gd<CadaclysmRay>> {
        ok(result).map(CadaclysmRay::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmRay {
    fn to_string(&self) -> GString {
        gs(format!("Ray{:?}", self.value.values()))
    }
}

#[godot_api]
impl CadaclysmRay {
    /// The ray from `position` along `direction` (each a `Vector3` or three numbers); `null`
    /// for a zero direction, with the reason in `Cadaclysm.last_error()`. (`new` is GDScript's own, so this is `create`.)
    #[func]
    fn create(position: Variant, direction: Variant) -> Option<Gd<CadaclysmRay>> {
        Self::made(bs::Ray::new(at(&position, "Ray: position")?, at(&direction, "Ray: direction")?))
    }

    /// A ray from its raw array of 6 numbers (a `PackedFloat64Array` or an Array), checked by
    /// the library: `null` for another count or a zero direction.
    #[func]
    fn from_values(values: Variant) -> Option<Gd<CadaclysmRay>> {
        Self::made(bs::Ray::from_values(&number_list(&values, "value_check")?))
    }

    /// The start.
    #[func]
    fn get_position(&self) -> Vector3 {
        vector3(self.value.position())
    }

    /// The direction, as given.
    #[func]
    fn get_direction(&self) -> Vector3 {
        vector3(self.value.direction())
    }

    /// The canonical array, as the library squared it up.
    #[func]
    fn get_values(&self) -> PackedFloat64Array {
        doubles(&self.value.values())
    }

    /// Whether `other` is a value of the same kind with the same array.
    #[func]
    fn equals(&self, other: Variant) -> bool {
        same_value(bs::Ray::KIND, &self.value.values(), &other)
    }

    /// A ray has no box: the empty `AABB`, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn bounds(&self) -> Aabb {
        ok(self.value.bounds()).map_or_else(Aabb::default, |(lo, hi)| aabb(lo, hi))
    }

    /// This value under `t` (a `CadaclysmTransform`, or 16 numbers), a value of the same type: any affine map that keeps its direction.
    /// `null` for one that kills it, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmRay>> {
        Self::made(self.value.transform(&transform_arg(&t, "value_transform")?))
    }

    /// `position + t * direction`, any `t` (behind the start too).
    #[func]
    fn point_at(&self, t: f64) -> Vector3 {
        point_out(self.value.point_at(t))
    }

    /// The `CadaclysmCurveFoot` on the ray nearest `p`: `t` clamped at 0, so a point behind the
    /// start answers the start. Always unique. `null` for a `p` that is not a point.
    #[func]
    fn closest_point(&self, p: Variant) -> Option<Gd<CadaclysmCurveFoot>> {
        ok(self.value.closest_point(at(&p, "ray_closest_point")?)).map(CadaclysmCurveFoot::wrap)
    }

    /// How far `p` lies from the ray. `NAN` for a `p` that is not a point.
    #[func]
    fn distance_to(&self, p: Variant) -> f64 {
        at(&p, "ray_closest_point").map_or(f64::NAN, |p| number_out(self.value.distance_to(p)))
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
    #[var(get = get_colour, no_set)]
    colour: PhantomVar<Variant>,
}

impl CadaclysmProfile {
    fn wrap(profile: bs::Profile) -> Gd<CadaclysmProfile> {
        Gd::from_object(CadaclysmProfile { profile, colour: PhantomVar::default() })
    }

    fn made(result: sdk::Result<bs::Profile>) -> Option<Gd<CadaclysmProfile>> {
        ok(result).map(Self::wrap)
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
        ok(f(&refs)).unwrap_or_default().into_iter().map(Self::wrap).collect()
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
        let Ok(sides) = u32::try_from(sides) else {
            return fail(format!("profile_regular_polygon: sides is out of range: {sides}"));
        };
        Self::made(bs::Profile::regular_polygon(v2(&centre, "regular_polygon: centre")?, radius, sides, angle))
    }

    /// A regular polygon of `sides` sides (at least 3) whose sides touch the circle of
    /// `radius` about `centre` -- the polygon across flats, a nut's hex: its corners on the
    /// circle of `radius / cos(PI / sides)`, the first at `angle` radians from the sketch's x
    /// axis, the rest counter-clockwise, on the same rays as `regular_polygon`'s corners for
    /// the same `angle`; each side's midpoint on the circle of `radius`. `null` for `sides`
    /// outside 0 to 4294967295 (before the call), then under 3, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn circumscribed_polygon(centre: Variant, radius: f64, sides: i64, #[opt(default = 0.0)] angle: f64) -> Option<Gd<CadaclysmProfile>> {
        let Ok(sides) = u32::try_from(sides) else {
            return fail(format!("profile_circumscribed_polygon: sides is out of range: {sides}"));
        };
        Self::made(bs::Profile::circumscribed_polygon(v2(&centre, "circumscribed_polygon: centre")?, radius, sides, angle))
    }

    /// A star of `points` tips (at least 3) on the circle of `outer` about `centre`, its
    /// inner corners on the circle of `inner` (positive, under `outer`), alternating: the
    /// first tip at `angle` radians from the sketch's x axis, the rest counter-clockwise.
    #[func]
    fn star(centre: Variant, outer: f64, inner: f64, points: i64, #[opt(default = 0.0)] angle: f64) -> Option<Gd<CadaclysmProfile>> {
        let Ok(points) = u32::try_from(points) else {
            return fail(format!("profile_star: points is out of range: {points}"));
        };
        Self::made(bs::Profile::star(v2(&centre, "star: centre")?, outer, inner, points, angle))
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

    /// Start drawing on the arc of the parabola with `vertex`, axis direction `axis` and
    /// focal length `focal`, over the across-axis coordinates `from`..`to`: the path
    /// begins at the arc's first point and holds the arc -- a reflector from rim to rim,
    /// `CadaclysmProfile.parabola([0, 0], [0, 1], 20, -50, 50)` a dish 100 wide opening
    /// up.
    #[func]
    fn parabola(vertex: Variant, axis: Variant, focal: f64, from: f64, to: f64) -> Option<Gd<CadaclysmPath>> {
        let (vertex, axis) = (v2(&vertex, "parabola: vertex")?, v2(&axis, "parabola: axis")?);
        CadaclysmPath::made(bs::Path::parabola(vertex, axis, focal, from, to))
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

    /// This outline turned `radians` (counter-clockwise) about `centre` (a `Vector2` or two
    /// numbers).
    #[func]
    fn rotate(&self, centre: Variant, radians: f64) -> Option<Gd<CadaclysmProfile>> {
        Self::made(self.profile.rotate(v2(&centre, "rotate: centre")?, radians))
    }

    /// This outline scaled by `sx`, `sy` about `centre`: an arc stays an arc where the two
    /// are equal in size, and becomes exact conics otherwise. A negative factor mirrors;
    /// a zero one is singular and refused.
    #[func]
    fn scale(&self, centre: Variant, sx: f64, sy: f64) -> Option<Gd<CadaclysmProfile>> {
        Self::made(self.profile.scale(v2(&centre, "scale: centre")?, sx, sy))
    }

    /// This outline reflected across the line through `point` along `direction`; a zero
    /// `direction` is refused.
    #[func]
    fn mirror(&self, point: Variant, direction: Variant) -> Option<Gd<CadaclysmProfile>> {
        Self::made(self.profile.mirror(v2(&point, "mirror: point")?, v2(&direction, "mirror: direction")?))
    }

    /// This outline under the 2D affine map `m`, six numbers row-major (2×3):
    /// `x' = m0·x + m1·y + m2`, `y' = m3·x + m4·y + m5`. A singular map is refused.
    #[func]
    fn transform2d(&self, m: Variant) -> Option<Gd<CadaclysmProfile>> {
        Self::made(self.profile.transform2d(point::<6>(&m, "transform2d")?))
    }

    /// This outline coloured `colour` (a `Color`, `"#rrggbb"`, a CSS colour name, or three numbers in 0..1): how
    /// it is drawn. The verbs that make a profile from one carry it; a solid made from it
    /// takes nothing.
    #[func]
    fn coloured(&self, colour: Variant) -> Option<Gd<CadaclysmProfile>> {
        let rgb = colour_arg(&colour)?;
        Self::made(self.profile.coloured(rgb))
    }

    /// Its colour, or `null` where it has none.
    #[func]
    fn get_colour(&self) -> Variant {
        ok(self.profile.colour()).map_or(Variant::nil(), colour_out)
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

    /// The perimeter of the outer loop (holes are not counted), as a `CadaclysmLength`, to
    /// a relative `accuracy` in (0, 1): 0 or less is the default; NaN, infinite or 1 or
    /// more is refused. `null` on failure, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn length(&self, #[opt(default = 0.0)] accuracy: f64) -> Option<Gd<CadaclysmLength>> {
        ok(self.profile.length(accuracy)).map(CadaclysmLength::wrap)
    }

    /// The point `s` of arc length from the start of the outer loop, as a `CadaclysmAt`
    /// whose `segment` is the side it lies on. `s` is 0 to the perimeter; `accuracy` is
    /// relative, in (0, 1): 0 or less is the default; NaN, infinite or 1 or more is
    /// refused. `null` on failure, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn point_at_length(&self, s: f64, #[opt(default = 0.0)] accuracy: f64) -> Option<Gd<CadaclysmAt>> {
        ok(self.profile.point_at_length(s, accuracy)).map(CadaclysmAt::wrap)
    }

    /// The outer loop in `n` pieces of equal arc length, as an array of `CadaclysmAt`: `n`
    /// samples from its start, never the start again. `n` is 1 to 1,000,000; `accuracy` as
    /// `point_at_length`. Empty on failure (including an `n` that is not a count), with the
    /// reason in `Cadaclysm.last_error()`.
    #[func]
    fn divide_by_count(&self, n: i64, #[opt(default = 0.0)] accuracy: f64) -> Array<Gd<CadaclysmAt>> {
        let Some(n) = sample_count("profile_divide_by_count", n) else { return Array::new() };
        CadaclysmAt::wrap_all(ok(self.profile.divide_by_count(n, accuracy)).unwrap_or_default())
    }

    /// Samples of the outer loop every `step` of arc length from its start, as an array of
    /// `CadaclysmAt`; the last piece is whatever is left over, kept short, and the start is
    /// never repeated. `step` is positive and finite and may give at most 999,999 steps;
    /// `accuracy` as `point_at_length`. Empty on failure, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn divide_by_length(&self, step: f64, #[opt(default = 0.0)] accuracy: f64) -> Array<Gd<CadaclysmAt>> {
        CadaclysmAt::wrap_all(ok(self.profile.divide_by_length(step, accuracy)).unwrap_or_default())
    }

    /// The region this profile and `other` share, both read in one plane, as zero or
    /// more profiles -- each boundary counter-clockwise, each hole clockwise, arcs and
    /// splines kept exact. Both must be closed and simple. No shared area is an empty
    /// array; so is a failure (a `tolerance` not positive and finite, a profile open or
    /// crossing itself), with `Cadaclysm.last_error()` set.
    #[func]
    fn common(&self, other: Gd<CadaclysmProfile>, #[opt(default = 1e-6)] tolerance: f64) -> Array<Gd<CadaclysmProfile>> {
        let shared = ok(self.profile.common(&other.bind().profile, tolerance));
        shared.unwrap_or_default().into_iter().map(Self::wrap).collect()
    }

    /// `text` set in a font, one profile per closed shape -- a letter with its counters
    /// as holes (`o` one, `8` two; `i` is two profiles) -- on the sketch plane, the
    /// baseline along x from the origin, each outline counter-clockwise and its holes
    /// clockwise, a curved side the font's own cubic Bezier kept exactly. `size` is
    /// roughly the height of a capital. `font` is a family (optionally
    /// `"Liberation Sans:style=Bold"`), a font file's path, or empty for the bundled
    /// Liberation Sans Regular -- which also serves when the family is not found;
    /// `font_bytes` a font file's bytes, used instead of `font` when not empty. `halign`
    /// is "left", "center" or "right"; `valign` "baseline", "bottom", "center" or "top";
    /// `spacing` multiplies the gap between glyphs; `direction` "ltr" or "rtl". Empty
    /// text is an empty array; a refusal is an empty array with the error logged.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn text(
        text: GString,
        #[opt(default = 10.0)] size: f64,
        #[opt(default = "")] font: GString,
        #[opt(default = "left")] halign: GString,
        #[opt(default = "baseline")] valign: GString,
        #[opt(default = 1.0)] spacing: f64,
        #[opt(default = "ltr")] direction: GString,
        #[opt(default = &PackedByteArray::new())] font_bytes: PackedByteArray,
    ) -> Array<Gd<CadaclysmProfile>> {
        let bytes = font_bytes.to_vec();
        let set = ok(bs::Profile::text(&text.to_string(), size, &font.to_string(), &halign.to_string(), &valign.to_string(),
                                       spacing, &direction.to_string(), if bytes.is_empty() { None } else { Some(&bytes[..]) }));
        set.unwrap_or_default().into_iter().map(Self::wrap).collect()
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

    /// This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by
    /// lines and arcs within `tolerance` of it -- what a G-code writer can say. Lines and
    /// arcs pass through as they are, every loop closes on itself exactly, holes are
    /// converted the same way. Fails for a `tolerance` not positive and finite, or a
    /// spline that does not evaluate.
    #[func]
    fn to_arcs(&self, #[opt(default = 0.01)] tolerance: f64) -> Option<Gd<CadaclysmProfile>> {
        Self::made(self.profile.to_arcs(tolerance))
    }

    /// This profile grown by `distance` (shrunk where it is negative), as zero or more
    /// profiles, all lines and arcs: outward corners rounded by `|distance|`, holes moving
    /// against the boundary (a hole shrinks as the profile grows). Free-form sides are
    /// fitted to `tolerance` first (`to_arcs`). A shrink that eats the whole profile is an
    /// empty array. Fails for a `distance` not finite, a `tolerance` not positive and
    /// finite, a loop with no sides, or loops that cross or touch.
    #[func]
    fn offset(&self, distance: f64, #[opt(default = 0.01)] tolerance: f64) -> Array<Gd<CadaclysmProfile>> {
        ok(self.profile.offset(distance, tolerance)).unwrap_or_default().into_iter().map(Self::wrap).collect()
    }

    /// This profile's own loops as SVG text, from directly above by default -- a
    /// profile lies in `z = 0`, so its own plane already is the page, unlike
    /// `CadaclysmSolid.svg_text` (`"iso"`), which has no plane of its own to prefer.
    /// `""` on a refused option.
    #[func]
    fn svg_text(&self) -> GString {
        self.svg_text_with(VarDictionary::new())
    }

    /// `svg_text`, with options: see `CadaclysmScene.svg_text_with` for every key --
    /// `view` left out of `options` is `"top"` here, not `svg_options`'s own `"iso"`.
    #[func]
    fn svg_text_with(&self, options: VarDictionary) -> GString {
        let Some(opts) = reader::svg_options(&profile_svg_options(&options)) else { return GString::new() };
        gs(drawing_svg_text_of(&[], &[&self.profile], &opts).unwrap_or_default())
    }

    /// This profile written to an SVG file at `path`, by the library itself; see
    /// `svg_text` for the `top` default.
    #[func]
    fn svg(&self, path: GString) -> bool {
        self.svg_with(path, VarDictionary::new())
    }

    /// `svg`, with options: see `svg_text_with`.
    #[func]
    fn svg_with(&self, path: GString, options: VarDictionary) -> bool {
        let Some(opts) = reader::svg_options(&profile_svg_options(&options)) else { return false };
        match drawing_svg_text_of(&[], &[&self.profile], &opts) {
            Some(text) => write_text(&path, text),
            None => false,
        }
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
        Self::made(bs::Path::begin(v2(&start, "path: start")?))
    }

    fn made(result: sdk::Result<bs::Path>) -> Option<Gd<CadaclysmPath>> {
        let path = ok(result)?;
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

    /// A conic arc to (`x`, `y`) through the control point `control` with middle weight
    /// `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola -- the
    /// rational quadratic Bézier, kept exact.
    #[func]
    fn conic_to(&mut self, x: f64, y: f64, control: Variant, weight: f64) -> Option<Gd<CadaclysmPath>> {
        let control = v2(&control, "conic_to: control")?;
        self.step(|p| p.conic_to(x, y, control, weight))
    }

    /// A parabolic arc to (`x`, `y`) whose end tangents meet at `control`: `conic_to`
    /// with weight 1.
    #[func]
    fn parabola_to(&mut self, x: f64, y: f64, control: Variant) -> Option<Gd<CadaclysmPath>> {
        let control = v2(&control, "parabola_to: control")?;
        self.step(|p| p.parabola_to(x, y, control))
    }

    /// A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1.
    #[func]
    fn hyperbola_to(&mut self, x: f64, y: f64, control: Variant, weight: f64) -> Option<Gd<CadaclysmPath>> {
        let control = v2(&control, "hyperbola_to: control")?;
        self.step(|p| p.hyperbola_to(x, y, control, weight))
    }

    /// The parabolic arc to (`x`, `y`) with `vertex`: its axis and focal length solved
    /// from the two ends. Fails when no parabola with that vertex passes through both.
    #[func]
    fn parabola_by_vertex(&mut self, x: f64, y: f64, vertex: Variant) -> Option<Gd<CadaclysmPath>> {
        let vertex = v2(&vertex, "parabola_by_vertex: vertex")?;
        self.step(|p| p.parabola_by_vertex(x, y, vertex))
    }

    /// The parabolic arc to (`x`, `y`) with `focus`: of the two through the ends, the
    /// one whose vertex lies between the ends' projections, then the one whose arc cups
    /// the focus (the focus between the arc and its chord), then the more symmetric; with
    /// the focus beyond the chord that is the arch over the ends, not the shallow dish --
    /// draw that one with `CadaclysmProfile.parabola`.
    #[func]
    fn parabola_by_focus(&mut self, x: f64, y: f64, focus: Variant) -> Option<Gd<CadaclysmPath>> {
        let focus = v2(&focus, "parabola_by_focus: focus")?;
        self.step(|p| p.parabola_by_focus(x, y, focus))
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
/// `"line"`, `"circle"`, `"ellipse"`, `"parabola"`, `"hyperbola"` or `"nurbs"`.
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

    /// This curve as a value: a line a `CadaclysmLine` from `origin` to `origin + x`; a circle
    /// a `CadaclysmCircle` over a full turn, else the `CadaclysmArc` over `t0..t1`; an ellipse
    /// its whole `CadaclysmEllipse` (the range stays here: there is no elliptical-arc value);
    /// `null` for any other kind.
    #[func]
    fn value(&self) -> Variant {
        match ok(self.curve.value()).flatten() {
            Some(bs::CurveValue::Line(c)) => CadaclysmLine::wrap(c).to_variant(),
            Some(bs::CurveValue::Circle(c)) => CadaclysmCircle::wrap(c).to_variant(),
            Some(bs::CurveValue::Arc(c)) => CadaclysmArc::wrap(c).to_variant(),
            Some(bs::CurveValue::Ellipse(c)) => CadaclysmEllipse::wrap(c).to_variant(),
            // An edge's curve is never a rectangle, but the SDK's curve values include one.
            Some(bs::CurveValue::Rectangle(c)) => CadaclysmRectangle::wrap(c).to_variant(),
            None => Variant::nil(),
        }
    }
}

// ---- CadaclysmSolidHits, CadaclysmPiece -------------------------------------------------------

/// What `CadaclysmSolid.hits` found, copied out: `hits` (`CadaclysmHit`s ordered along the
/// profile; `a_start`/`a_end` on the profile, `b_start`/`b_end` on the solid's faces: a
/// `face` at (`u`, `v`)) and `pieces` (`CadaclysmPiece`s, empty for an open body).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSolidHits {
    found: Vec<bs::Hit>,
    cut: Vec<Gd<CadaclysmPiece>>,
    #[var(get = get_hits, no_set)]
    hits: PhantomVar<Array<Gd<CadaclysmHit>>>,
    #[var(get = get_pieces, no_set)]
    pieces: PhantomVar<Array<Gd<CadaclysmPiece>>>,
}

impl CadaclysmSolidHits {
    fn wrap(found: bs::SolidHits) -> Gd<CadaclysmSolidHits> {
        let cut = found.pieces.into_iter().map(CadaclysmPiece::wrap).collect();
        Gd::from_object(CadaclysmSolidHits { found: found.hits, cut, hits: PhantomVar::default(), pieces: PhantomVar::default() })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmSolidHits {
    fn to_string(&self) -> GString {
        gs(format!("SolidHits(hits={}, pieces={})", self.found.len(), self.cut.len()))
    }
}

#[godot_api]
impl CadaclysmSolidHits {
    #[func]
    fn get_hits(&self) -> Array<Gd<CadaclysmHit>> {
        self.found.iter().copied().map(CadaclysmHit::wrap).collect()
    }

    #[func]
    fn get_pieces(&self) -> Array<Gd<CadaclysmPiece>> {
        self.cut.iter().cloned().collect()
    }
}

/// One stretch of a profile loop between two cuts (`CadaclysmSolidHits.pieces`): `inside`
/// (by its middle's winding number over the body; a piece lying on the surface is inside),
/// `start`/`end` (profile `CadaclysmSpot`s -- a segment join reads as the next segment's
/// start (k + 1, 0), an open chain runs from (0, 0) to (n - 1, 1); a loop no hit cuts is
/// one closed piece) and `profile`, the piece's own open chain (what
/// `CadaclysmSweepPath.along` with `open` sweeps).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmPiece {
    is_inside: bool,
    from: bs::Spot,
    to: bs::Spot,
    own: Gd<CadaclysmProfile>,
    #[var(get = get_inside, no_set)]
    inside: PhantomVar<bool>,
    #[var(get = get_start, no_set)]
    start: PhantomVar<Gd<CadaclysmSpot>>,
    #[var(get = get_end, no_set)]
    end: PhantomVar<Gd<CadaclysmSpot>>,
    #[var(get = get_profile, no_set)]
    profile: PhantomVar<Gd<CadaclysmProfile>>,
}

impl CadaclysmPiece {
    fn wrap(piece: bs::Piece) -> Gd<CadaclysmPiece> {
        Gd::from_object(CadaclysmPiece {
            is_inside: piece.inside,
            from: piece.start,
            to: piece.end,
            own: CadaclysmProfile::wrap(piece.profile),
            inside: PhantomVar::default(),
            start: PhantomVar::default(),
            end: PhantomVar::default(),
            profile: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmPiece {
    fn to_string(&self) -> GString {
        gs(format!("Piece(inside={}, start={}, end={})", self.is_inside, CadaclysmSpot::wrap(self.from), CadaclysmSpot::wrap(self.to)))
    }
}

#[godot_api]
impl CadaclysmPiece {
    #[func]
    fn get_inside(&self) -> bool {
        self.is_inside
    }

    #[func]
    fn get_start(&self) -> Gd<CadaclysmSpot> {
        CadaclysmSpot::wrap(self.from)
    }

    #[func]
    fn get_end(&self) -> Gd<CadaclysmSpot> {
        CadaclysmSpot::wrap(self.to)
    }

    #[func]
    fn get_profile(&self) -> Gd<CadaclysmProfile> {
        self.own.clone()
    }
}

// ---- CadaclysmIntersection, CadaclysmChain, CadaclysmOverlap ---------------------------------

/// What `CadaclysmSolid.intersect` found, copied out: `chains` (`CadaclysmChain`, one per
/// face pair per branch) and `overlaps` (`CadaclysmOverlap`, one per coincident face
/// pair). Both empty where the solids do not meet.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmIntersection {
    found: bs::Intersection,
    #[var(get = get_chains, no_set)]
    chains: PhantomVar<Array<Gd<CadaclysmChain>>>,
    #[var(get = get_overlaps, no_set)]
    overlaps: PhantomVar<Array<Gd<CadaclysmOverlap>>>,
}

impl CadaclysmIntersection {
    fn wrap(found: bs::Intersection) -> Gd<CadaclysmIntersection> {
        Gd::from_object(CadaclysmIntersection { found, chains: PhantomVar::default(), overlaps: PhantomVar::default() })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmIntersection {
    fn to_string(&self) -> GString {
        gs(format!("Intersection(chains={}, overlaps={})", self.found.chains.len(), self.found.overlaps.len()))
    }
}

#[godot_api]
impl CadaclysmIntersection {
    #[func]
    fn get_chains(&self) -> Array<Gd<CadaclysmChain>> {
        self.found.chains.iter().cloned().map(CadaclysmChain::wrap).collect()
    }

    #[func]
    fn get_overlaps(&self) -> Array<Gd<CadaclysmOverlap>> {
        self.found.overlaps.iter().cloned().map(CadaclysmOverlap::wrap).collect()
    }
}

/// One branch of one face pair's crossing (`CadaclysmIntersection.chains`): `points`
/// (`Vector3`s in walk order; a closed chain does not repeat its first point;
/// `raw_points` keeps the doubles), `closed`, the faces (`face_a` in the first solid,
/// `face_b` in the second), `tangent` (the surfaces near-tangent along it, or the snap
/// unsettled -- the points their best estimate) and `curve`, its exact `CadaclysmCurve`
/// over the chain's own `t0..t1`, or `null` where the kernel found none. A chain may stop
/// at a face boundary or a closed curve's seam and continue as another: join chains by
/// matching ends.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmChain {
    chain: bs::Chain,
    #[var(get = get_points, no_set)]
    points: PhantomVar<PackedVector3Array>,
    #[var(get = get_raw_points, no_set)]
    raw_points: PhantomVar<PackedFloat64Array>,
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
    #[var(get = get_face_a, no_set)]
    face_a: PhantomVar<i64>,
    #[var(get = get_face_b, no_set)]
    face_b: PhantomVar<i64>,
    #[var(get = get_tangent, no_set)]
    tangent: PhantomVar<bool>,
    #[var(get = get_curve, no_set)]
    curve: PhantomVar<Variant>,
}

impl CadaclysmChain {
    fn wrap(chain: bs::Chain) -> Gd<CadaclysmChain> {
        Gd::from_object(CadaclysmChain {
            chain,
            points: PhantomVar::default(),
            raw_points: PhantomVar::default(),
            closed: PhantomVar::default(),
            face_a: PhantomVar::default(),
            face_b: PhantomVar::default(),
            tangent: PhantomVar::default(),
            curve: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmChain {
    fn to_string(&self) -> GString {
        let c = &self.chain;
        let curve = c.curve.as_ref().map_or_else(|| "null".to_string(), |curve| CadaclysmCurve::wrap(curve.clone()).to_string());
        gs(format!("Chain(points={}, closed={}, faces=({}, {}), tangent={}, curve={curve})", c.points.len(), c.closed, c.faces.0, c.faces.1, c.tangent))
    }
}

#[godot_api]
impl CadaclysmChain {
    #[func]
    fn get_points(&self) -> PackedVector3Array {
        self.chain.points.iter().map(|&p| vector3(p)).collect()
    }

    /// The same, as doubles: three a point.
    #[func]
    fn get_raw_points(&self) -> PackedFloat64Array {
        self.chain.points.iter().flatten().copied().collect()
    }

    #[func]
    fn get_closed(&self) -> bool {
        self.chain.closed
    }

    #[func]
    fn get_face_a(&self) -> i64 {
        self.chain.faces.0.into()
    }

    #[func]
    fn get_face_b(&self) -> i64 {
        self.chain.faces.1.into()
    }

    #[func]
    fn get_tangent(&self) -> bool {
        self.chain.tangent
    }

    /// The chain's exact curve as a `CadaclysmCurve`, or `null` for a chain with none.
    #[func]
    fn get_curve(&self) -> Variant {
        self.chain.curve.clone().map_or(Variant::nil(), |c| CadaclysmCurve::wrap(c).to_variant())
    }
}

/// A face of the first solid and a face of the second that coincide
/// (`CadaclysmIntersection.overlaps`): the faces (`face_a`, `face_b`) and `loops`, the
/// shared region's rings as `PackedVector3Array`s (outer first, holes after; each ring
/// closed without repeating its first point; `raw_loops` keeps the doubles) -- empty for a
/// partial overlap of curved faces whose outlines cross.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmOverlap {
    overlap: bs::Overlap,
    #[var(get = get_face_a, no_set)]
    face_a: PhantomVar<i64>,
    #[var(get = get_face_b, no_set)]
    face_b: PhantomVar<i64>,
    #[var(get = get_loops, no_set)]
    loops: PhantomVar<Array<PackedVector3Array>>,
    #[var(get = get_raw_loops, no_set)]
    raw_loops: PhantomVar<Array<PackedFloat64Array>>,
}

impl CadaclysmOverlap {
    fn wrap(overlap: bs::Overlap) -> Gd<CadaclysmOverlap> {
        Gd::from_object(CadaclysmOverlap {
            overlap,
            face_a: PhantomVar::default(),
            face_b: PhantomVar::default(),
            loops: PhantomVar::default(),
            raw_loops: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmOverlap {
    fn to_string(&self) -> GString {
        let o = &self.overlap;
        gs(format!("Overlap(faces=({}, {}), loops={})", o.faces.0, o.faces.1, o.loops.len()))
    }
}

#[godot_api]
impl CadaclysmOverlap {
    #[func]
    fn get_face_a(&self) -> i64 {
        self.overlap.faces.0.into()
    }

    #[func]
    fn get_face_b(&self) -> i64 {
        self.overlap.faces.1.into()
    }

    #[func]
    fn get_loops(&self) -> Array<PackedVector3Array> {
        self.overlap.loops.iter().map(|ring| ring.iter().map(|&p| vector3(p)).collect::<PackedVector3Array>()).collect()
    }

    /// The same, as doubles: three a point.
    #[func]
    fn get_raw_loops(&self) -> Array<PackedFloat64Array> {
        self.overlap.loops.iter().map(|ring| ring.iter().flatten().copied().collect::<PackedFloat64Array>()).collect()
    }
}

// ---- CadaclysmOrientedBox, CadaclysmLength, CadaclysmClosest, CadaclysmClassifier --------

/// A solid's box on its principal axes (`CadaclysmSolid.oriented_box`). Not minimal: where
/// two moments of inertia are equal (a sphere, a cube) the axes are a free choice. Vectors
/// are `Vector3`s, so floats; `raw_centre`, `raw_axes` and `raw_half` give the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmOrientedBox {
    value: bs::OrientedBox,
    /// The middle of the box, which is not the centroid.
    #[var(get = get_centre, no_set)]
    centre: PhantomVar<Vector3>,
    /// Three unit directions, right-handed: `axes[i]` is the direction of the extent `half[i]`.
    #[var(get = get_axes, no_set)]
    axes: PhantomVar<PackedVector3Array>,
    /// The extent along each axis from the centre, grown by the tolerance the measurement
    /// settled on.
    #[var(get = get_half, no_set)]
    half: PhantomVar<Vector3>,
    /// `centre` as three doubles.
    #[var(get = get_raw_centre, no_set)]
    raw_centre: PhantomVar<PackedFloat64Array>,
    /// `axes` as nine doubles, row-major: row `i` is the direction of the extent `half[i]`.
    #[var(get = get_raw_axes, no_set)]
    raw_axes: PhantomVar<PackedFloat64Array>,
    /// `half` as three doubles.
    #[var(get = get_raw_half, no_set)]
    raw_half: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmOrientedBox {
    fn wrap(value: bs::OrientedBox) -> Gd<CadaclysmOrientedBox> {
        Gd::from_object(CadaclysmOrientedBox {
            value,
            centre: PhantomVar::default(),
            axes: PhantomVar::default(),
            half: PhantomVar::default(),
            raw_centre: PhantomVar::default(),
            raw_axes: PhantomVar::default(),
            raw_half: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmOrientedBox {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!("OrientedBox(centre={:?}, axes={:?}, half={:?})", v.centre, v.axes, v.half))
    }
}

#[godot_api]
impl CadaclysmOrientedBox {
    /// The middle of the box, which is not the centroid.
    #[func]
    fn get_centre(&self) -> Vector3 {
        vector3(self.value.centre)
    }

    /// Three unit directions, right-handed: element `i` is the direction of the extent
    /// `half[i]`.
    #[func]
    fn get_axes(&self) -> PackedVector3Array {
        self.value.axes.iter().map(|&a| vector3(a)).collect()
    }

    /// The extent along each axis from the centre, grown by the tolerance the measurement
    /// settled on.
    #[func]
    fn get_half(&self) -> Vector3 {
        vector3(self.value.half)
    }

    /// `centre` as three doubles.
    #[func]
    fn get_raw_centre(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.value.centre[..])
    }

    /// `axes` as nine doubles, row-major: row `i` is the direction of the extent `half[i]`.
    #[func]
    fn get_raw_axes(&self) -> PackedFloat64Array {
        self.value.axes.iter().flatten().copied().collect()
    }

    /// `half` as three doubles.
    #[func]
    fn get_raw_half(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.value.half[..])
    }
}

/// A measured length beside the error it carries (`CadaclysmSolid.edge_length`,
/// `CadaclysmProfile.length`). `error` is an estimate of the difference from the true
/// length, not a proof.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmLength {
    value: bs::Length,
    /// The length, in the model's units.
    #[var(get = get_length, no_set)]
    length: PhantomVar<f64>,
    /// An estimate of how far `length` is from the true length.
    #[var(get = get_error, no_set)]
    error: PhantomVar<f64>,
    /// Whether the refinement reached the accuracy asked for.
    #[var(get = get_accuracy_met, no_set)]
    accuracy_met: PhantomVar<bool>,
    /// Whether the curve was a sampled polyline: exact for its points, not for what they
    /// sample.
    #[var(get = get_from_polyline, no_set)]
    from_polyline: PhantomVar<bool>,
}

impl CadaclysmLength {
    fn wrap(value: bs::Length) -> Gd<CadaclysmLength> {
        Gd::from_object(CadaclysmLength {
            value,
            length: PhantomVar::default(),
            error: PhantomVar::default(),
            accuracy_met: PhantomVar::default(),
            from_polyline: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmLength {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!(
            "Length(length={}, error={}, accuracy_met={}, from_polyline={})",
            v.length, v.error, v.accuracy_met, v.from_polyline
        ))
    }
}

#[godot_api]
impl CadaclysmLength {
    /// The length, in the model's units.
    #[func]
    fn get_length(&self) -> f64 {
        self.value.length
    }

    /// An estimate of how far `length` is from the true length.
    #[func]
    fn get_error(&self) -> f64 {
        self.value.error
    }

    /// Whether the refinement reached the accuracy asked for.
    #[func]
    fn get_accuracy_met(&self) -> bool {
        self.value.accuracy_met
    }

    /// Whether the curve was a sampled polyline: exact for its points, not for what they
    /// sample.
    #[func]
    fn get_from_polyline(&self) -> bool {
        self.value.from_polyline
    }
}

/// A point at an arc length along an edge or a profile's outer loop
/// (`CadaclysmSolid.edge_point_at_length`, `CadaclysmProfile.point_at_length` and the
/// divides). `point` and `tangent` are `Vector3`s, so floats; `tangent` is a unit vector
/// along the direction of travel. `error` is an estimate of the arc length's difference
/// from the true one, not a proof.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmAt {
    value: bs::At,
    /// The point on the curve.
    #[var(get = get_point, no_set)]
    point: PhantomVar<Vector3>,
    /// The unit tangent at `point`, along the direction of travel.
    #[var(get = get_tangent, no_set)]
    tangent: PhantomVar<Vector3>,
    /// The curve's own parameter at `point`: on a profile, that side's own (a line's 0 to
    /// 1, an arc's angle, a spline's parameter).
    #[var(get = get_parameter, no_set)]
    parameter: PhantomVar<f64>,
    /// The side of a profile `point` lies on (the segment count for the implicit closing
    /// side), -1 on a solid's edge.
    #[var(get = get_segment, no_set)]
    segment: PhantomVar<i64>,
    /// An estimate of how far the arc length is from the true one.
    #[var(get = get_error, no_set)]
    error: PhantomVar<f64>,
    /// Whether the curve was a sampled polyline: exact for its points, not for what they
    /// sample.
    #[var(get = get_from_polyline, no_set)]
    from_polyline: PhantomVar<bool>,
}

impl CadaclysmAt {
    fn wrap(value: bs::At) -> Gd<CadaclysmAt> {
        Gd::from_object(CadaclysmAt {
            value,
            point: PhantomVar::default(),
            tangent: PhantomVar::default(),
            parameter: PhantomVar::default(),
            segment: PhantomVar::default(),
            error: PhantomVar::default(),
            from_polyline: PhantomVar::default(),
        })
    }

    fn wrap_all(list: Vec<bs::At>) -> Array<Gd<CadaclysmAt>> {
        list.into_iter().map(CadaclysmAt::wrap).collect()
    }
}

/// `n` as the count the library takes, or a failure naming `call`.
fn sample_count(call: &str, n: i64) -> Option<u32> {
    match u32::try_from(n) {
        Ok(n) => Some(n),
        Err(_) => fail(format!("{call}: n is out of range: {n}")),
    }
}

#[godot_api]
impl IRefCounted for CadaclysmAt {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!(
            "At(point={:?}, tangent={:?}, parameter={}, segment={:?}, error={}, from_polyline={})",
            v.point, v.tangent, v.parameter, v.segment, v.error, v.from_polyline
        ))
    }
}

#[godot_api]
impl CadaclysmAt {
    /// The point on the curve.
    #[func]
    fn get_point(&self) -> Vector3 {
        vector3(self.value.point)
    }

    /// The unit tangent at `point`, along the direction of travel.
    #[func]
    fn get_tangent(&self) -> Vector3 {
        vector3(self.value.tangent)
    }

    /// The curve's own parameter at `point`: on a profile, that side's own (a line's 0 to
    /// 1, an arc's angle, a spline's parameter).
    #[func]
    fn get_parameter(&self) -> f64 {
        self.value.parameter
    }

    /// The side of a profile `point` lies on (the segment count for the implicit closing
    /// side), -1 on a solid's edge.
    #[func]
    fn get_segment(&self) -> i64 {
        self.value.segment.map_or(-1, i64::from)
    }

    /// An estimate of how far the arc length is from the true one.
    #[func]
    fn get_error(&self) -> f64 {
        self.value.error
    }

    /// Whether the curve was a sampled polyline: exact for its points, not for what they
    /// sample.
    #[func]
    fn get_from_polyline(&self) -> bool {
        self.value.from_polyline
    }
}

/// The closest points between two solids' boundaries (`CadaclysmSolid.closest`). `kind_a`
/// and `kind_b` are `"face"`, `"edge"` or `"vertex"`; `index_a` and `index_b` the kernel's
/// id of it; `edge_a` and `edge_b` the index `CadaclysmSolid.fillet` takes, -1 for a face,
/// a vertex or an edge with no exact curve. Points are `Vector3`s, so floats; `raw_on_a`
/// and `raw_on_b` give the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmClosest {
    value: bs::Closest,
    /// The gap between the two boundaries; 0 where they touch or cross.
    #[var(get = get_distance, no_set)]
    distance: PhantomVar<f64>,
    /// The closest point on the first solid.
    #[var(get = get_on_a, no_set)]
    on_a: PhantomVar<Vector3>,
    /// The closest point on the second solid.
    #[var(get = get_on_b, no_set)]
    on_b: PhantomVar<Vector3>,
    /// What `on_a` lies on: `"face"`, `"edge"` or `"vertex"`.
    #[var(get = get_kind_a, no_set)]
    kind_a: PhantomVar<GString>,
    /// The kernel's id of the face, edge or vertex `on_a` lies on.
    #[var(get = get_index_a, no_set)]
    index_a: PhantomVar<i64>,
    /// The fillet-table index of the edge `on_a` lies on, -1 for none.
    #[var(get = get_edge_a, no_set)]
    edge_a: PhantomVar<i64>,
    /// What `on_b` lies on: `"face"`, `"edge"` or `"vertex"`.
    #[var(get = get_kind_b, no_set)]
    kind_b: PhantomVar<GString>,
    /// The kernel's id of the face, edge or vertex `on_b` lies on.
    #[var(get = get_index_b, no_set)]
    index_b: PhantomVar<i64>,
    /// The fillet-table index of the edge `on_b` lies on, -1 for none.
    #[var(get = get_edge_b, no_set)]
    edge_b: PhantomVar<i64>,
    /// Whether the points were refined onto the exact geometry, not the mesh's answer.
    #[var(get = get_refined, no_set)]
    refined: PhantomVar<bool>,
    /// `on_a` as three doubles.
    #[var(get = get_raw_on_a, no_set)]
    raw_on_a: PhantomVar<PackedFloat64Array>,
    /// `on_b` as three doubles.
    #[var(get = get_raw_on_b, no_set)]
    raw_on_b: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmClosest {
    fn wrap(value: bs::Closest) -> Gd<CadaclysmClosest> {
        Gd::from_object(CadaclysmClosest {
            value,
            distance: PhantomVar::default(),
            on_a: PhantomVar::default(),
            on_b: PhantomVar::default(),
            kind_a: PhantomVar::default(),
            index_a: PhantomVar::default(),
            edge_a: PhantomVar::default(),
            kind_b: PhantomVar::default(),
            index_b: PhantomVar::default(),
            edge_b: PhantomVar::default(),
            refined: PhantomVar::default(),
            raw_on_a: PhantomVar::default(),
            raw_on_b: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmClosest {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!(
            "Closest(distance={}, on_a={:?}, on_b={:?}, kind_a={}, index_a={}, edge_a={:?}, kind_b={}, index_b={}, \
             edge_b={:?}, refined={})",
            v.distance, v.on_a, v.on_b, v.kind_a, v.index_a, v.edge_a, v.kind_b, v.index_b, v.edge_b, v.refined
        ))
    }
}

#[godot_api]
impl CadaclysmClosest {
    /// The gap between the two boundaries; 0 where they touch or cross.
    #[func]
    fn get_distance(&self) -> f64 {
        self.value.distance
    }

    /// The closest point on the first solid.
    #[func]
    fn get_on_a(&self) -> Vector3 {
        vector3(self.value.on_a)
    }

    /// The closest point on the second solid.
    #[func]
    fn get_on_b(&self) -> Vector3 {
        vector3(self.value.on_b)
    }

    /// `on_a` as three doubles.
    #[func]
    fn get_raw_on_a(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.value.on_a[..])
    }

    /// `on_b` as three doubles.
    #[func]
    fn get_raw_on_b(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.value.on_b[..])
    }

    /// What `on_a` lies on: `"face"`, `"edge"` or `"vertex"`.
    #[func]
    fn get_kind_a(&self) -> GString {
        gs(&self.value.kind_a)
    }

    /// The kernel's id of the face, edge or vertex `on_a` lies on.
    #[func]
    fn get_index_a(&self) -> i64 {
        self.value.index_a.into()
    }

    /// The fillet-table index of the edge `on_a` lies on, -1 for none.
    #[func]
    fn get_edge_a(&self) -> i64 {
        self.value.edge_a.map_or(-1, i64::from)
    }

    /// What `on_b` lies on: `"face"`, `"edge"` or `"vertex"`.
    #[func]
    fn get_kind_b(&self) -> GString {
        gs(&self.value.kind_b)
    }

    /// The kernel's id of the face, edge or vertex `on_b` lies on.
    #[func]
    fn get_index_b(&self) -> i64 {
        self.value.index_b.into()
    }

    /// The fillet-table index of the edge `on_b` lies on, -1 for none.
    #[func]
    fn get_edge_b(&self) -> i64 {
        self.value.edge_b.map_or(-1, i64::from)
    }

    /// Whether the points were refined onto the exact geometry, not the mesh's answer.
    #[func]
    fn get_refined(&self) -> bool {
        self.value.refined
    }
}

/// One closed solid's reusable point classifier (`CadaclysmSolid.classifier`): a point
/// is `"outside"`, `"inside"` or `"on"` (within the tolerance it was made with). It keeps
/// its own reference to the body, so it goes on answering after its solid is closed or
/// freed.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmClassifier {
    classifier: Option<bs::Classifier>,
    /// Whether `close` has freed the classifier.
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
}

impl CadaclysmClassifier {
    fn wrap(classifier: bs::Classifier) -> Gd<CadaclysmClassifier> {
        Gd::from_object(CadaclysmClassifier { classifier: Some(classifier), closed: PhantomVar::default() })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmClassifier {
    fn to_string(&self) -> GString {
        gs("Classifier")
    }
}

#[godot_api]
impl CadaclysmClassifier {
    /// `"outside"`, `"inside"` or `"on"` for `point` (a `Vector3` or three numbers), or
    /// `""` for a point that is not finite or on a closed classifier, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn contains(&self, point: Variant) -> GString {
        let Some(classifier) = &self.classifier else {
            return gs(fail::<String>("classifier: closed").unwrap_or_default());
        };
        let Some(p) = v3(&point, "classifier_contains: point") else { return GString::new() };
        gs(ok(classifier.contains(p)).unwrap_or_default())
    }

    /// Free the classifier now. Idempotent.
    #[func]
    fn close(&mut self) {
        self.classifier = None;
    }

    /// Whether `close` has freed the classifier.
    #[func]
    fn get_closed(&self) -> bool {
        self.classifier.is_none()
    }
}

// ---- CadaclysmSketch, CadaclysmSolveReport, CadaclysmDof, CadaclysmPartDof ----------------

fn ids_out(ids: &[u32]) -> PackedInt64Array {
    let wide: Vec<i64> = ids.iter().map(|&i| i64::from(i)).collect();
    PackedInt64Array::from(wide.as_slice())
}

/// A sketch id from GDScript's `int`: refused where it cannot be one (negative, or past a
/// `u32`) -- the `-1` a refused call hands back, passed on, among them.
fn sketch_id(i: i64, what: &str) -> Option<u32> {
    match u32::try_from(i) {
        Ok(i) => Some(i),
        Err(_) => fail(format!("{what} {i} is not a sketch id (0 to {})", u32::MAX)),
    }
}

/// What a `CadaclysmSketch` solve did, as plain data: `CadaclysmSketch.solve`, `drag`,
/// `set_value`, `set_driving` and `update_reference` return one. `status` is `"converged"`,
/// `"conflicting"` or `"diverged"`; `ids` the constraints a conflict ran into, or the worst
/// ones of a diverged solve (empty when it converged).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSolveReport {
    report: bs::SolveReport,
    /// `"converged"`, `"conflicting"` or `"diverged"`.
    #[var(get = get_status, no_set)]
    status: PhantomVar<GString>,
    /// Whether `status` is `"converged"`.
    #[var(get = get_converged, no_set)]
    converged: PhantomVar<bool>,
    /// The most solver iterations any one part took.
    #[var(get = get_iterations, no_set)]
    iterations: PhantomVar<i64>,
    /// The largest constraint residual left, scaled by the sketch's size.
    #[var(get = get_max_residual, no_set)]
    max_residual: PhantomVar<f64>,
    /// The constraints a conflict ran into, or the worst ones of a diverged solve.
    #[var(get = get_ids, no_set)]
    ids: PhantomVar<PackedInt64Array>,
}

impl CadaclysmSolveReport {
    fn wrap(report: bs::SolveReport) -> Gd<CadaclysmSolveReport> {
        Gd::from_object(CadaclysmSolveReport {
            report,
            status: PhantomVar::default(),
            converged: PhantomVar::default(),
            iterations: PhantomVar::default(),
            max_residual: PhantomVar::default(),
            ids: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmSolveReport {
    fn to_string(&self) -> GString {
        let r = &self.report;
        gs(format!("SolveReport(status={}, iterations={}, max_residual={}, ids={:?})", r.status, r.iterations, r.max_residual, r.ids))
    }
}

#[godot_api]
impl CadaclysmSolveReport {
    #[func]
    fn get_status(&self) -> GString {
        gs(self.report.status)
    }
    #[func]
    fn get_converged(&self) -> bool {
        self.report.converged()
    }
    #[func]
    fn get_iterations(&self) -> i64 {
        self.report.iterations.into()
    }
    #[func]
    fn get_max_residual(&self) -> f64 {
        self.report.max_residual
    }
    #[func]
    fn get_ids(&self) -> PackedInt64Array {
        ids_out(&self.report.ids)
    }
}

/// One independent part of a diagnosed sketch (`CadaclysmDof.parts`): its unknowns
/// (`params`), how many stay `free`, its `state` (`"under"`, `"full"` or `"over"`), its
/// `constraints`, the `redundant` and `conflicting` ones among them, and its
/// `free_entities`. Plain data.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmPartDof {
    part: bs::PartDof,
    /// How many unknowns the part has.
    #[var(get = get_params, no_set)]
    params: PhantomVar<i64>,
    /// How many of them stay free.
    #[var(get = get_free, no_set)]
    free: PhantomVar<i64>,
    /// `"under"`, `"full"` or `"over"`.
    #[var(get = get_state, no_set)]
    state: PhantomVar<GString>,
    /// The constraint ids in the part, in the order they were added.
    #[var(get = get_constraints, no_set)]
    constraints: PhantomVar<PackedInt64Array>,
    /// Its constraints already implied by earlier ones.
    #[var(get = get_redundant, no_set)]
    redundant: PhantomVar<PackedInt64Array>,
    /// Its constraints that fight earlier ones.
    #[var(get = get_conflicting, no_set)]
    conflicting: PhantomVar<PackedInt64Array>,
    /// Its entities that can still move.
    #[var(get = get_free_entities, no_set)]
    free_entities: PhantomVar<PackedInt64Array>,
}

impl CadaclysmPartDof {
    fn wrap(part: bs::PartDof) -> Gd<CadaclysmPartDof> {
        Gd::from_object(CadaclysmPartDof {
            part,
            params: PhantomVar::default(),
            free: PhantomVar::default(),
            state: PhantomVar::default(),
            constraints: PhantomVar::default(),
            redundant: PhantomVar::default(),
            conflicting: PhantomVar::default(),
            free_entities: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmPartDof {
    fn to_string(&self) -> GString {
        let p = &self.part;
        gs(format!(
            "PartDof(params={}, free={}, state={}, constraints={:?}, redundant={:?}, conflicting={:?}, free_entities={:?})",
            p.params, p.free, p.state, p.constraints, p.redundant, p.conflicting, p.free_entities
        ))
    }
}

#[godot_api]
impl CadaclysmPartDof {
    #[func]
    fn get_params(&self) -> i64 {
        self.part.params.into()
    }
    #[func]
    fn get_free(&self) -> i64 {
        self.part.free.into()
    }
    #[func]
    fn get_state(&self) -> GString {
        gs(self.part.state)
    }
    #[func]
    fn get_constraints(&self) -> PackedInt64Array {
        ids_out(&self.part.constraints)
    }
    #[func]
    fn get_redundant(&self) -> PackedInt64Array {
        ids_out(&self.part.redundant)
    }
    #[func]
    fn get_conflicting(&self) -> PackedInt64Array {
        ids_out(&self.part.conflicting)
    }
    #[func]
    fn get_free_entities(&self) -> PackedInt64Array {
        ids_out(&self.part.free_entities)
    }
}

/// A sketch's degrees of freedom (`CadaclysmSketch.diagnose`): how many are `free`, its
/// `state` (`"under"`, `"full"` or `"over"`), the `redundant` and `conflicting` constraint
/// ids, the `free_entities` that can still move, and the independent `parts` it splits into.
/// Plain data.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmDof {
    dof: bs::Dof,
    part_list: Vec<Gd<CadaclysmPartDof>>,
    /// How many degrees of freedom are left.
    #[var(get = get_free, no_set)]
    free: PhantomVar<i64>,
    /// `"under"`, `"full"` or `"over"`.
    #[var(get = get_state, no_set)]
    state: PhantomVar<GString>,
    /// The constraint ids already implied by earlier ones.
    #[var(get = get_redundant, no_set)]
    redundant: PhantomVar<PackedInt64Array>,
    /// The constraint ids that fight earlier ones.
    #[var(get = get_conflicting, no_set)]
    conflicting: PhantomVar<PackedInt64Array>,
    /// The entity ids that can still move, ascending.
    #[var(get = get_free_entities, no_set)]
    free_entities: PhantomVar<PackedInt64Array>,
    /// The independent parts, as `CadaclysmPartDof`s.
    #[var(get = get_parts, no_set)]
    parts: PhantomVar<Array<Gd<CadaclysmPartDof>>>,
}

impl CadaclysmDof {
    fn wrap(mut dof: bs::Dof) -> Gd<CadaclysmDof> {
        let part_list = std::mem::take(&mut dof.parts).into_iter().map(CadaclysmPartDof::wrap).collect();
        Gd::from_object(CadaclysmDof {
            dof,
            part_list,
            free: PhantomVar::default(),
            state: PhantomVar::default(),
            redundant: PhantomVar::default(),
            conflicting: PhantomVar::default(),
            free_entities: PhantomVar::default(),
            parts: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmDof {
    fn to_string(&self) -> GString {
        let d = &self.dof;
        gs(format!(
            "Dof(free={}, state={}, redundant={:?}, conflicting={:?}, free_entities={:?}, parts={})",
            d.free, d.state, d.redundant, d.conflicting, d.free_entities, self.part_list.len()
        ))
    }
}

#[godot_api]
impl CadaclysmDof {
    #[func]
    fn get_free(&self) -> i64 {
        self.dof.free.into()
    }
    #[func]
    fn get_state(&self) -> GString {
        gs(self.dof.state)
    }
    #[func]
    fn get_redundant(&self) -> PackedInt64Array {
        ids_out(&self.dof.redundant)
    }
    #[func]
    fn get_conflicting(&self) -> PackedInt64Array {
        ids_out(&self.dof.conflicting)
    }
    #[func]
    fn get_free_entities(&self) -> PackedInt64Array {
        ids_out(&self.dof.free_entities)
    }
    #[func]
    fn get_parts(&self) -> Array<Gd<CadaclysmPartDof>> {
        self.part_list.iter().cloned().collect()
    }
}

/// A 2D sketch of points, lines, circles, arcs and free curves held by geometric
/// constraints and dimensions, solved on request (`solve`), its closed loops handed on as
/// `CadaclysmProfile`s (`profiles`). Entities and constraints are named by `int` ids, never
/// reused. Kinds, senses and ends are Python's strings: entity kinds `"point"`, `"line"`,
/// `"circle"`, `"arc"` and `"free_curve"`; a constraint's kind is the name of the method
/// that added it, but for `radius_of`, whose kind is `"radius"`; senses `"auto"`,
/// `"positive"` and `"negative"`; ends `"start"` and `"end"`. A point goes in as a
/// `Vector2` or two numbers in an array, and comes back as a `Vector2`.
///
/// GDScript has no exceptions: a refused call returns `-1` (an id), `null` (a report, a
/// point), `false`, `""`, `NAN` or an empty array, reports the reason with `push_error` and
/// leaves it in `Cadaclysm.last_error()`. The ids a refusal names -- the constraints a new
/// constraint, value or reference conflicts with, or the entities still using a point --
/// are kept on the sketch, as `last_ids()`.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSketch {
    sketch: Option<bs::Sketch>,
    refused_ids: RefCell<Vec<u32>>,
    /// Whether `close` has freed the sketch.
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
}

impl CadaclysmSketch {
    fn wrap(sketch: bs::Sketch) -> Gd<CadaclysmSketch> {
        Gd::from_object(CadaclysmSketch { sketch: Some(sketch), refused_ids: RefCell::new(Vec::new()), closed: PhantomVar::default() })
    }

    /// Run `f` on the sketch. Its arguments are read inside `f` (a bad one fails there, as
    /// `None`); a kernel refusal is reported and recorded, with the ids it names kept as
    /// `last_ids`, which every other outcome empties.
    fn run<T>(&self, f: impl FnOnce(&bs::Sketch) -> Option<sdk::Result<T>>) -> Option<T> {
        self.refused_ids.borrow_mut().clear();
        let Some(sketch) = &self.sketch else { return fail("sketch: closed") };
        match f(sketch)? {
            Ok(value) => {
                clear_error();
                Some(value)
            }
            Err(error) => {
                *self.refused_ids.borrow_mut() = error.ids().to_vec();
                fail(error)
            }
        }
    }

    /// An id out, `-1` for a refusal.
    fn id(&self, f: impl FnOnce(&bs::Sketch) -> Option<sdk::Result<u32>>) -> i64 {
        self.run(f).map_or(-1, i64::from)
    }

    fn ids(&self, f: impl FnOnce(&bs::Sketch) -> Option<sdk::Result<Vec<u32>>>) -> PackedInt64Array {
        self.run(f).map(|ids| ids_out(&ids)).unwrap_or_default()
    }

    fn text(&self, f: impl FnOnce(&bs::Sketch) -> Option<sdk::Result<&'static str>>) -> GString {
        self.run(f).map(gs).unwrap_or_default()
    }

    fn done(&self, f: impl FnOnce(&bs::Sketch) -> Option<sdk::Result<()>>) -> bool {
        self.run(f).is_some()
    }

    fn report(&self, f: impl FnOnce(&bs::Sketch) -> Option<sdk::Result<bs::SolveReport>>) -> Option<Gd<CadaclysmSolveReport>> {
        self.run(f).map(CadaclysmSolveReport::wrap)
    }

    fn flag(&self, f: impl FnOnce(&bs::Sketch) -> bool) -> bool {
        self.run(|s| Some(Ok(f(s)))).unwrap_or(false)
    }

    fn chains(&self, f: impl FnOnce(&bs::Sketch) -> sdk::Result<Vec<bs::Profile>>) -> Array<Gd<CadaclysmProfile>> {
        self.run(|s| Some(f(s))).unwrap_or_default().into_iter().map(CadaclysmProfile::wrap).collect()
    }
}

#[godot_api]
impl IRefCounted for CadaclysmSketch {
    fn to_string(&self) -> GString {
        gs(if self.sketch.is_some() { "Sketch" } else { "Sketch(closed)" })
    }
}

#[godot_api]
impl CadaclysmSketch {
    /// A new, empty sketch.
    #[func]
    fn create() -> Option<Gd<CadaclysmSketch>> {
        ok(bs::Sketch::new()).map(Self::wrap)
    }

    /// A sketch of `profile`'s lines, arcs and curves, joined end to end by coincident
    /// constraints, holes included. With `infer` it also adds every constraint the geometry
    /// already meets within `tolerance` (horizontal and vertical lines, tangent joints,
    /// concentric arcs, equal radii); ends within `tolerance` count as joined.
    #[func]
    fn from_profile(profile: Gd<CadaclysmProfile>, #[opt(default = true)] infer: bool, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmSketch>> {
        ok(bs::Sketch::from_profile(&profile.bind().profile, infer, tolerance)).map(Self::wrap)
    }

    /// Free the sketch now. Idempotent; every later call fails with `sketch: closed`.
    #[func]
    fn close(&mut self) {
        self.sketch = None;
        self.refused_ids.borrow_mut().clear();
    }

    /// Whether `close` has freed the sketch.
    #[func]
    fn get_closed(&self) -> bool {
        self.sketch.is_none()
    }

    /// The ids this sketch's last call was refused with: the constraints a new constraint,
    /// value or reference conflicts with, or the entities still using a point. Empty after a
    /// call that worked, or a refusal that names none -- GDScript's stand-in for Python's
    /// `BuildError.ids`.
    #[func]
    fn last_ids(&self) -> PackedInt64Array {
        ids_out(&self.refused_ids.borrow())
    }

    // ---- entities

    /// A free point at (`x`, `y`): its id. A coordinate that is not finite is refused.
    #[func]
    fn add_point(&self, x: f64, y: f64) -> i64 {
        self.id(|s| Some(s.add_point(x, y)))
    }

    /// A line from the point `a` to the point `b`: its id.
    #[func]
    fn add_line(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.add_line(sketch_id(a, "sketch_add_line: a")?, sketch_id(b, "sketch_add_line: b")?)))
    }

    /// A circle about the point `centre`, of radius `r`: its id.
    #[func]
    fn add_circle(&self, centre: i64, r: f64) -> i64 {
        self.id(|s| Some(s.add_circle(sketch_id(centre, "sketch_add_circle: centre")?, r)))
    }

    /// A counter-clockwise arc about the point `centre` from the point `start` to the point
    /// `end`: its id.
    #[func]
    fn add_arc(&self, centre: i64, start: i64, end: i64) -> i64 {
        self.id(|s| {
            let centre = sketch_id(centre, "sketch_add_arc: centre")?;
            Some(s.add_arc(centre, sketch_id(start, "sketch_add_arc: start")?, sketch_id(end, "sketch_add_arc: end")?))
        })
    }

    /// A cubic Bezier free curve from the point `start` through the controls `c1` and `c2`
    /// to `to` (each a `Vector2` or two numbers): its id. Its control points become points
    /// of the sketch.
    #[func]
    fn add_bezier(&self, start: i64, c1: Variant, c2: Variant, to: Variant) -> i64 {
        self.id(|s| {
            let start = sketch_id(start, "sketch_add_bezier: start")?;
            let c1 = v2(&c1, "sketch_add_bezier: c1")?;
            let c2 = v2(&c2, "sketch_add_bezier: c2")?;
            Some(s.add_bezier(start, c1, c2, v2(&to, "sketch_add_bezier: to")?))
        })
    }

    /// A conic (rational quadratic) free curve from the point `start`, pulled toward
    /// `control` by `weight`, to `to`: its id.
    #[func]
    fn add_conic(&self, start: i64, control: Variant, to: Variant, weight: f64) -> i64 {
        self.id(|s| {
            let start = sketch_id(start, "sketch_add_conic: start")?;
            let control = v2(&control, "sketch_add_conic: control")?;
            Some(s.add_conic(start, control, v2(&to, "sketch_add_conic: to")?, weight))
        })
    }

    /// A NURBS free curve of `degree` from the point `start` through the control `points`
    /// after it (a `PackedVector2Array` or an array of points), on `knots`; `weights` empty
    /// for a plain B-spline, or one per control point counting the start.
    #[func]
    fn add_nurbs(
        &self,
        start: i64,
        points: Variant,
        knots: Variant,
        #[opt(default = 3)] degree: i64,
        #[opt(default = &PackedFloat64Array::new())] weights: PackedFloat64Array,
    ) -> i64 {
        self.id(|s| {
            let start = sketch_id(start, "sketch_add_nurbs: start")?;
            let points = points2(&points, "sketch_add_nurbs: points")?;
            let knots = number_list(&knots, "sketch_add_nurbs: knots")?;
            let Ok(degree) = u32::try_from(degree) else {
                return fail(format!("sketch_add_nurbs: degree must not be negative, not {degree}"));
            };
            let weights = weights.as_slice();
            Some(s.add_nurbs(start, &points, &knots, degree, (!weights.is_empty()).then_some(weights)))
        })
    }

    /// The rectangle with opposite corners `a` and `b`: `{"corners": ..., "sides": ...}`,
    /// its four corner points counter-clockwise from `a` and its four sides (side `i` from
    /// corner `i`), held square by horizontal and vertical constraints. Empty on a refusal.
    #[func]
    fn add_rect(&self, a: Variant, b: Variant) -> VarDictionary {
        self.run(|s| {
            let a = v2(&a, "sketch_add_rect: a")?;
            Some(s.add_rect(a, v2(&b, "sketch_add_rect: b")?))
        })
        .map(|(corners, sides)| dict(&[("corners", ids_out(&corners).to_variant()), ("sides", ids_out(&sides).to_variant())]))
        .unwrap_or_default()
    }

    /// The kind of the entity `id`: `"point"`, `"line"`, `"circle"`, `"arc"` or `"free_curve"`.
    #[func]
    fn kind(&self, id: i64) -> GString {
        self.text(|s| Some(s.kind(sketch_id(id, "sketch_kind: id")?)))
    }

    /// Every entity id, ascending.
    #[func]
    fn entities(&self) -> PackedInt64Array {
        self.ids(|s| Some(s.entities()))
    }

    /// Where the point `id` is now, or `null`.
    #[func]
    fn point(&self, id: i64) -> Variant {
        self.run(|s| Some(s.point(sketch_id(id, "sketch_point: id")?)))
            .map(|[x, y]| Vector2::new(x as f32, y as f32).to_variant())
            .unwrap_or_default()
    }

    /// Where the point `id` is now, in full precision: `[x, y]` as doubles (`point`'s
    /// `Vector2` is single precision), or an empty array on a refusal.
    #[func]
    fn raw_point(&self, id: i64) -> PackedFloat64Array {
        self.run(|s| Some(s.point(sketch_id(id, "sketch_point: id")?)))
            .map(|xy| PackedFloat64Array::from(xy.as_slice()))
            .unwrap_or_default()
    }

    /// Move the point `id` to (`x`, `y`) without solving; `false` on a refusal.
    #[func]
    fn set_point(&self, id: i64, x: f64, y: f64) -> bool {
        self.done(|s| Some(s.set_point(sketch_id(id, "sketch_set_point: id")?, x, y)))
    }

    /// The radius of the circle or arc `id`, or `NAN`.
    #[func]
    fn radius(&self, id: i64) -> f64 {
        self.run(|s| Some(s.radius(sketch_id(id, "sketch_radius: id")?))).unwrap_or(f64::NAN)
    }

    /// Set the radius of the circle `id` without solving; `false` on a refusal.
    #[func]
    fn set_radius(&self, id: i64, r: f64) -> bool {
        self.done(|s| Some(s.set_radius(sketch_id(id, "sketch_set_radius: id")?, r)))
    }

    /// The centre point of the circle or arc `id`, or `-1`.
    #[func]
    fn centre(&self, id: i64) -> i64 {
        self.id(|s| Some(s.centre(sketch_id(id, "sketch_centre: id")?)))
    }

    /// The points that define the entity `id`: a line's two ends, an arc's start and end, a
    /// free curve's control points in order.
    #[func]
    fn ends(&self, id: i64) -> PackedInt64Array {
        self.ids(|s| Some(s.ends(sketch_id(id, "sketch_ends: id")?)))
    }

    /// Mark the entity `id` construction geometry (`on`) or not: construction is solved
    /// with the rest, but left out of `profiles` and `open_chains`.
    #[func]
    fn set_construction(&self, id: i64, #[opt(default = true)] on: bool) -> bool {
        self.done(|s| Some(s.set_construction(sketch_id(id, "sketch_set_construction: id")?, on)))
    }

    /// Whether the entity `id` is construction geometry; `false` for an unknown id or one
    /// that cannot be an id (negative, past a `u32`), without an error. A closed sketch
    /// answers `false` and reports `sketch: closed`.
    #[func]
    fn is_construction(&self, id: i64) -> bool {
        self.flag(|s| u32::try_from(id).is_ok_and(|id| s.is_construction(id)))
    }

    /// Whether the entity `id` is a reference to another sketch's entity; `false` for an
    /// unknown id or one that cannot be an id, without an error. A closed sketch answers
    /// `false` and reports `sketch: closed`.
    #[func]
    fn is_reference(&self, id: i64) -> bool {
        self.flag(|s| u32::try_from(id).is_ok_and(|id| s.is_reference(id)))
    }

    /// Remove the entity `id` and every constraint on it: the constraint ids removed with
    /// it. A point another entity still uses is refused, naming those entities in
    /// `last_ids()`.
    #[func]
    fn remove_entity(&self, id: i64) -> PackedInt64Array {
        self.ids(|s| Some(s.remove_entity(sketch_id(id, "sketch_remove_entity: id")?)))
    }

    /// A copy of `other`'s entity `entity` in this sketch, fixed where `other` has it and
    /// marked construction: its id. `update_reference` moves it when `other` changes.
    #[func]
    fn reference(&self, other: Gd<CadaclysmSketch>, entity: i64) -> i64 {
        let other = other.bind();
        self.id(|s| {
            let Some(o) = &other.sketch else { return fail("sketch_reference: other: sketch: closed") };
            Some(s.reference(o, sketch_id(entity, "sketch_reference: entity")?))
        })
    }

    /// Move the reference `id` to where its source entity now is in `other`, and solve.
    #[func]
    fn update_reference(&self, id: i64, other: Gd<CadaclysmSketch>) -> Option<Gd<CadaclysmSolveReport>> {
        let other = other.bind();
        self.report(|s| {
            let Some(o) = &other.sketch else { return fail("sketch_update_reference: other: sketch: closed") };
            Some(s.update_reference(sketch_id(id, "sketch_update_reference: id")?, o))
        })
    }

    // ---- constraints

    /// The points `a` and `b` in one place.
    #[func]
    fn coincident(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.coincident(sketch_id(a, "coincident: a")?, sketch_id(b, "coincident: b")?)))
    }

    /// The point `point` on the line `line` (extended).
    #[func]
    fn point_on_line(&self, point: i64, line: i64) -> i64 {
        self.id(|s| Some(s.point_on_line(sketch_id(point, "point_on_line: point")?, sketch_id(line, "point_on_line: line")?)))
    }

    /// The point `point` on the circle or arc `circle`.
    #[func]
    fn point_on_circle(&self, point: i64, circle: i64) -> i64 {
        self.id(|s| Some(s.point_on_circle(sketch_id(point, "point_on_circle: point")?, sketch_id(circle, "point_on_circle: circle")?)))
    }

    /// A horizontal line (`a` alone), or two points level with each other.
    #[func]
    fn horizontal(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.horizontal(sketch_id(a, "horizontal: a")?, sketch_id(b, "horizontal: b")?)))
    }

    /// A vertical line, or two points one above the other.
    #[func]
    fn vertical(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.vertical(sketch_id(a, "vertical: a")?, sketch_id(b, "vertical: b")?)))
    }

    /// The lines `a` and `b` parallel.
    #[func]
    fn parallel(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.parallel(sketch_id(a, "parallel: a")?, sketch_id(b, "parallel: b")?)))
    }

    /// The lines `a` and `b` at right angles.
    #[func]
    fn perpendicular(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.perpendicular(sketch_id(a, "perpendicular: a")?, sketch_id(b, "perpendicular: b")?)))
    }

    /// The lines `a` and `b` on one line.
    #[func]
    fn collinear(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.collinear(sketch_id(a, "collinear: a")?, sketch_id(b, "collinear: b")?)))
    }

    /// The line or circle `a` tangent to the circle `b`, on the side `sense` names.
    #[func]
    fn tangent(&self, a: i64, b: i64, #[opt(default = "auto")] sense: GString) -> i64 {
        self.id(|s| Some(s.tangent(sketch_id(a, "tangent: a")?, sketch_id(b, "tangent: b")?, &sense.to_string())))
    }

    /// The free curve `curve` tangent, at its `end` (`"start"` or `"end"`), to the line or
    /// curve `other` it meets there.
    #[func]
    fn tangent_at_end(&self, curve: i64, other: i64, #[opt(default = "start")] end: GString) -> i64 {
        self.id(|s| {
            let curve = sketch_id(curve, "tangent_at_end: curve")?;
            Some(s.tangent_at_end(curve, sketch_id(other, "tangent_at_end: other")?, &end.to_string()))
        })
    }

    /// The circles or arcs `a` and `b` about one centre.
    #[func]
    fn concentric(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.concentric(sketch_id(a, "concentric: a")?, sketch_id(b, "concentric: b")?)))
    }

    /// The lines `a` and `b` one length.
    #[func]
    fn equal_length(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.equal_length(sketch_id(a, "equal_length: a")?, sketch_id(b, "equal_length: b")?)))
    }

    /// The circles or arcs `a` and `b` one radius.
    #[func]
    fn equal_radius(&self, a: i64, b: i64) -> i64 {
        self.id(|s| Some(s.equal_radius(sketch_id(a, "equal_radius: a")?, sketch_id(b, "equal_radius: b")?)))
    }

    /// The point `point` halfway along the line `line`.
    #[func]
    fn midpoint(&self, point: i64, line: i64) -> i64 {
        self.id(|s| Some(s.midpoint(sketch_id(point, "midpoint: point")?, sketch_id(line, "midpoint: line")?)))
    }

    /// The points `a` and `b` mirror images across the line `about`.
    #[func]
    fn symmetric(&self, a: i64, b: i64, about: i64) -> i64 {
        self.id(|s| {
            let a = sketch_id(a, "symmetric: a")?;
            Some(s.symmetric(a, sketch_id(b, "symmetric: b")?, sketch_id(about, "symmetric: about")?))
        })
    }

    /// The entity `entity` held where it is now.
    #[func]
    fn fix(&self, entity: i64) -> i64 {
        self.id(|s| Some(s.fix(sketch_id(entity, "fix: entity")?)))
    }

    /// The points `a` and `b` `value` apart; with `driving` false, a measurement only.
    #[func]
    fn distance(&self, a: i64, b: i64, value: f64, #[opt(default = true)] driving: bool) -> i64 {
        self.id(|s| Some(s.distance(sketch_id(a, "distance: a")?, sketch_id(b, "distance: b")?, value, driving)))
    }

    /// The point `point` `value` from the line `line`, on the side `sense` names.
    #[func]
    fn point_line_distance(
        &self,
        point: i64,
        line: i64,
        value: f64,
        #[opt(default = true)] driving: bool,
        #[opt(default = "auto")] sense: GString,
    ) -> i64 {
        self.id(|s| {
            let point = sketch_id(point, "point_line_distance: point")?;
            Some(s.point_line_distance(point, sketch_id(line, "point_line_distance: line")?, value, driving, &sense.to_string()))
        })
    }

    /// The parallel lines `a` and `b` `value` apart, on the side `sense` names.
    #[func]
    fn line_distance(
        &self,
        a: i64,
        b: i64,
        value: f64,
        #[opt(default = true)] driving: bool,
        #[opt(default = "auto")] sense: GString,
    ) -> i64 {
        self.id(|s| Some(s.line_distance(sketch_id(a, "line_distance: a")?, sketch_id(b, "line_distance: b")?, value, driving, &sense.to_string())))
    }

    /// The circle `circle` `value` from the line `line` (its edge to the line), on the side
    /// `sense` names.
    #[func]
    fn circle_line_distance(
        &self,
        circle: i64,
        line: i64,
        value: f64,
        #[opt(default = true)] driving: bool,
        #[opt(default = "auto")] sense: GString,
    ) -> i64 {
        self.id(|s| {
            let circle = sketch_id(circle, "circle_line_distance: circle")?;
            Some(s.circle_line_distance(circle, sketch_id(line, "circle_line_distance: line")?, value, driving, &sense.to_string()))
        })
    }

    /// The circles `a` and `b` `value` apart, edge to edge.
    #[func]
    fn circle_distance(&self, a: i64, b: i64, value: f64, #[opt(default = true)] driving: bool) -> i64 {
        self.id(|s| Some(s.circle_distance(sketch_id(a, "circle_distance: a")?, sketch_id(b, "circle_distance: b")?, value, driving)))
    }

    /// The point `b` `value` to the right of the point `a`.
    #[func]
    fn horizontal_distance(&self, a: i64, b: i64, value: f64, #[opt(default = true)] driving: bool) -> i64 {
        self.id(|s| Some(s.horizontal_distance(sketch_id(a, "horizontal_distance: a")?, sketch_id(b, "horizontal_distance: b")?, value, driving)))
    }

    /// The point `b` `value` above the point `a`.
    #[func]
    fn vertical_distance(&self, a: i64, b: i64, value: f64, #[opt(default = true)] driving: bool) -> i64 {
        self.id(|s| Some(s.vertical_distance(sketch_id(a, "vertical_distance: a")?, sketch_id(b, "vertical_distance: b")?, value, driving)))
    }

    /// The line `line` `value` long.
    #[func]
    fn length(&self, line: i64, value: f64, #[opt(default = true)] driving: bool) -> i64 {
        self.id(|s| Some(s.length(sketch_id(line, "length: line")?, value, driving)))
    }

    /// The lines `a` and `b` at `value` radians.
    #[func]
    fn angle(&self, a: i64, b: i64, value: f64, #[opt(default = true)] driving: bool) -> i64 {
        self.id(|s| Some(s.angle(sketch_id(a, "angle: a")?, sketch_id(b, "angle: b")?, value, driving)))
    }

    /// The circle or arc `circle` of radius `value`; its kind is `"radius"`.
    #[func]
    fn radius_of(&self, circle: i64, value: f64, #[opt(default = true)] driving: bool) -> i64 {
        self.id(|s| Some(s.radius_of(sketch_id(circle, "radius_of: circle")?, value, driving)))
    }

    /// The circle or arc `circle` of diameter `value`.
    #[func]
    fn diameter(&self, circle: i64, value: f64, #[opt(default = true)] driving: bool) -> i64 {
        self.id(|s| Some(s.diameter(sketch_id(circle, "diameter: circle")?, value, driving)))
    }

    // ---- reading constraints back

    /// Every constraint id, ascending.
    #[func]
    fn constraints(&self) -> PackedInt64Array {
        self.ids(|s| Some(s.constraints()))
    }

    /// The kind of the constraint `id`: the name of the method that added it.
    #[func]
    fn constraint_kind(&self, id: i64) -> GString {
        self.text(|s| Some(s.constraint_kind(sketch_id(id, "sketch_constraint_kind: id")?)))
    }

    /// The entities the constraint `id` holds, in the order its method takes them.
    #[func]
    fn constraint_refs(&self, id: i64) -> PackedInt64Array {
        self.ids(|s| Some(s.constraint_refs(sketch_id(id, "sketch_constraint_refs: id")?)))
    }

    /// The value of the dimension `id`, or `null` for a constraint that has none (and for a
    /// refused id, the reason in `Cadaclysm.last_error()`).
    #[func]
    fn constraint_value(&self, id: i64) -> Variant {
        match self.run(|s| Some(s.constraint_value(sketch_id(id, "sketch_constraint_value: id")?))) {
            Some(Some(value)) => value.to_variant(),
            _ => Variant::nil(),
        }
    }

    /// Whether the dimension `id` drives the geometry; `false` for a measurement and for a
    /// constraint that is not a dimension.
    #[func]
    fn constraint_driving(&self, id: i64) -> bool {
        self.run(|s| Some(s.constraint_driving(sketch_id(id, "sketch_constraint_driving: id")?))).unwrap_or(false)
    }

    /// The sense of the constraint `id`: `"auto"`, `"positive"` or `"negative"`.
    #[func]
    fn constraint_sense(&self, id: i64) -> GString {
        self.text(|s| Some(s.constraint_sense(sketch_id(id, "sketch_constraint_sense: id")?)))
    }

    /// The end of the constraint `id`: `"start"` or `"end"` (`"start"` for every kind but
    /// `tangent_at_end`).
    #[func]
    fn constraint_end(&self, id: i64) -> GString {
        self.text(|s| Some(s.constraint_end(sketch_id(id, "sketch_constraint_end: id")?)))
    }

    /// Whether the constraint `id` is a tangent `from_profile` put at a joint; `false` for an
    /// unknown id or one that cannot be an id, without an error. A closed sketch answers
    /// `false` and reports `sketch: closed`.
    #[func]
    fn is_joint_tangent(&self, id: i64) -> bool {
        self.flag(|s| u32::try_from(id).is_ok_and(|id| s.is_joint_tangent(id)))
    }

    /// Remove the constraint `id`; `false` on a refusal.
    #[func]
    fn remove(&self, id: i64) -> bool {
        self.done(|s| Some(s.remove(sketch_id(id, "sketch_remove: id")?)))
    }

    /// Set the dimension `id` to `value` and solve; an edit that will not converge is rolled
    /// back and refused, naming the constraints in `last_ids()`.
    #[func]
    fn set_value(&self, id: i64, value: f64) -> Option<Gd<CadaclysmSolveReport>> {
        self.report(|s| Some(s.set_value(sketch_id(id, "sketch_set_value: id")?, value)))
    }

    /// Make the dimension `id` driving or a measurement, and solve.
    #[func]
    fn set_driving(&self, id: i64, driving: bool) -> Option<Gd<CadaclysmSolveReport>> {
        self.report(|s| Some(s.set_driving(sketch_id(id, "sketch_set_driving: id")?, driving)))
    }

    /// What the dimension `id` measures in the geometry now, or `NAN`.
    #[func]
    fn measure(&self, id: i64) -> f64 {
        self.run(|s| Some(s.measure(sketch_id(id, "sketch_measure: id")?))).unwrap_or(f64::NAN)
    }

    // ---- solving

    /// Solve every constraint: the report.
    #[func]
    fn solve(&self) -> Option<Gd<CadaclysmSolveReport>> {
        self.report(|s| Some(s.solve()))
    }

    /// Pull each point in `moves` (a Dictionary of point id to target, a `Vector2` or two
    /// numbers) toward its target and solve the rest around it, as a mouse drag does. The
    /// moves go to the kernel in ascending id order, whatever the Dictionary's order (which
    /// holds each id once).
    #[func]
    fn drag(&self, moves: VarDictionary) -> Option<Gd<CadaclysmSolveReport>> {
        self.report(|s| {
            let mut targets = Vec::with_capacity(moves.len());
            for (key, value) in moves.iter_shared() {
                if key.get_type() != VariantType::INT {
                    return fail(format!("sketch_drag: a key must be a point id (an int), not {key}"));
                }
                let id = sketch_id(key.to::<i64>(), "sketch_drag: point")?;
                targets.push((id, v2(&value, &format!("sketch_drag: moves[{id}]"))?));
            }
            Some(s.drag(&targets))
        })
    }

    /// The sketch's degrees of freedom, read after a solve: a `CadaclysmDof`.
    #[func]
    fn diagnose(&self) -> Option<Gd<CadaclysmDof>> {
        self.run(|s| Some(s.diagnose())).map(CadaclysmDof::wrap)
    }

    /// The closed loops among the solved, non-construction curves, as `CadaclysmProfile`s; a
    /// loop inside another becomes its hole. Ends within `tolerance` join.
    #[func]
    fn profiles(&self, #[opt(default = 1e-6)] tolerance: f64) -> Array<Gd<CadaclysmProfile>> {
        self.chains(|s| s.profiles(tolerance))
    }

    /// The chains of curves that do not close, as open `CadaclysmProfile`s -- sweep paths.
    #[func]
    fn open_chains(&self, #[opt(default = 1e-6)] tolerance: f64) -> Array<Gd<CadaclysmProfile>> {
        self.chains(|s| s.open_chains(tolerance))
    }
}

// ---- CadaclysmBox, CadaclysmColliderStats, CadaclysmCollisionHit, CadaclysmCollider ------

/// An axis-aligned box: `lo` and `hi`, three numbers each (`Vector3`). The broad phase's
/// own shape (`CadaclysmSolid.bounds_box`, `CadaclysmCollider`'s own boxes): cheap to move
/// and to test against another, before anything is meshed.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmBox {
    aabb: bs::Aabb,
    #[var(get = get_lo, no_set)]
    lo: PhantomVar<Vector3>,
    #[var(get = get_hi, no_set)]
    hi: PhantomVar<Vector3>,
}

impl CadaclysmBox {
    pub(crate) fn wrap(aabb: bs::Aabb) -> Gd<CadaclysmBox> {
        Gd::from_object(CadaclysmBox { aabb, lo: PhantomVar::default(), hi: PhantomVar::default() })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmBox {
    fn to_string(&self) -> GString {
        gs(format!("Box(lo={:?}, hi={:?})", self.aabb.lo, self.aabb.hi))
    }
}

#[godot_api]
impl CadaclysmBox {
    /// A box from its low and high corners.
    #[func]
    fn create(lo: Vector3, hi: Vector3) -> Gd<CadaclysmBox> {
        CadaclysmBox::wrap(bs::Aabb::new([f64::from(lo.x), f64::from(lo.y), f64::from(lo.z)],
            [f64::from(hi.x), f64::from(hi.y), f64::from(hi.z)]))
    }

    #[func]
    fn get_lo(&self) -> Vector3 {
        vector3(self.aabb.lo)
    }

    #[func]
    fn get_hi(&self) -> Vector3 {
        vector3(self.aabb.hi)
    }

    /// This box moved by `frame` (a `CadaclysmFrame`, a `Transform3D`, twelve numbers or
    /// four triples), boxed again on the world axes -- not this box's corners
    /// individually moved, which would not in general be a box at all: the *bounding*
    /// box of the moved corners.
    #[func]
    fn moved(&self, frame_arg: Variant) -> Option<Gd<CadaclysmBox>> {
        let f = frame(&frame_arg, "Box.moved: frame")?;
        ok(self.aabb.moved(&f)).map(CadaclysmBox::wrap)
    }

    /// Whether this box and `other` share a point (touching counts).
    #[func]
    fn overlaps(&self, other: Gd<CadaclysmBox>) -> bool {
        ok(self.aabb.overlaps(&other.bind().aabb)).unwrap_or(false)
    }

    /// True only if box `a` at `frame_a` and box `b` at `frame_b` cannot touch -- a
    /// separating axis among the boxes' face normals and edge-direction crosses;
    /// touching is not apart. Sharper than moving each box and asking `overlaps`, which
    /// boxes the *result* on the world axes again and so can call two oriented boxes
    /// overlapping when they are not (two unit boxes, the second turned 45 degrees
    /// about z and moved 2.3 along x: their world boxes overlap, but the boxes
    /// themselves do not touch).
    #[func]
    fn boxes_apart(a: Gd<CadaclysmBox>, frame_a: Variant, b: Gd<CadaclysmBox>, frame_b: Variant) -> bool {
        let Some(fa) = frame(&frame_a, "boxes_apart: frame_a") else { return false };
        let Some(fb) = frame(&frame_b, "boxes_apart: frame_b") else { return false };
        ok(bs::boxes_apart(&a.bind().aabb, &fa, &b.bind().aabb, &fb)).unwrap_or(false)
    }
}

/// Counts of one `CadaclysmCollider.check` call: the candidate pairs `considered`, how
/// many of them the world boxes and the oriented boxes cleared, how many the share left
/// to another call, how the rest were answered (`cached`, `closed_form`, `meshed`), and
/// how many were `refused`. `confirmed` is the subset of `meshed` that were thin
/// mesh-path overlaps sent to `CadaclysmSolid.common` itself for a final answer.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmColliderStats {
    stats: bs::ColliderStats,
    #[var(get = get_considered, no_set)]
    considered: PhantomVar<i64>,
    #[var(get = get_world_boxes, no_set)]
    world_boxes: PhantomVar<i64>,
    #[var(get = get_oriented_boxes, no_set)]
    oriented_boxes: PhantomVar<i64>,
    #[var(get = get_skipped_share, no_set)]
    skipped_share: PhantomVar<i64>,
    #[var(get = get_cached, no_set)]
    cached: PhantomVar<i64>,
    #[var(get = get_closed_form, no_set)]
    closed_form: PhantomVar<i64>,
    #[var(get = get_meshed, no_set)]
    meshed: PhantomVar<i64>,
    #[var(get = get_refused, no_set)]
    refused: PhantomVar<i64>,
    #[var(get = get_confirmed, no_set)]
    confirmed: PhantomVar<i64>,
}

impl CadaclysmColliderStats {
    fn wrap(stats: bs::ColliderStats) -> Gd<CadaclysmColliderStats> {
        Gd::from_object(CadaclysmColliderStats {
            stats,
            considered: PhantomVar::default(),
            world_boxes: PhantomVar::default(),
            oriented_boxes: PhantomVar::default(),
            skipped_share: PhantomVar::default(),
            cached: PhantomVar::default(),
            closed_form: PhantomVar::default(),
            meshed: PhantomVar::default(),
            refused: PhantomVar::default(),
            confirmed: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmColliderStats {
    fn to_string(&self) -> GString {
        let s = &self.stats;
        gs(format!(
            "ColliderStats(considered={}, world_boxes={}, oriented_boxes={}, skipped_share={}, cached={}, \
             closed_form={}, meshed={}, refused={}, confirmed={})",
            s.considered, s.world_boxes, s.oriented_boxes, s.skipped_share, s.cached, s.closed_form, s.meshed,
            s.refused, s.confirmed
        ))
    }
}

#[godot_api]
impl CadaclysmColliderStats {
    #[func]
    fn get_considered(&self) -> i64 {
        self.stats.considered.into()
    }
    #[func]
    fn get_world_boxes(&self) -> i64 {
        self.stats.world_boxes.into()
    }
    #[func]
    fn get_oriented_boxes(&self) -> i64 {
        self.stats.oriented_boxes.into()
    }
    #[func]
    fn get_skipped_share(&self) -> i64 {
        self.stats.skipped_share.into()
    }
    #[func]
    fn get_cached(&self) -> i64 {
        self.stats.cached.into()
    }
    #[func]
    fn get_closed_form(&self) -> i64 {
        self.stats.closed_form.into()
    }
    #[func]
    fn get_meshed(&self) -> i64 {
        self.stats.meshed.into()
    }
    #[func]
    fn get_refused(&self) -> i64 {
        self.stats.refused.into()
    }
    #[func]
    fn get_confirmed(&self) -> i64 {
        self.stats.confirmed.into()
    }
}

/// One pair `CadaclysmCollider.check` found overlapping (`overlap` true), or could not
/// decide (`overlap` false; `text` says why, empty for an overlap). `positions`/
/// `normals` are world xyz triples, three per triangle (unwelded); `indices` indexes
/// them -- all empty for a refused pair. `depth` is the thinnest side of the overlap's
/// world box, 0 for a refused pair.
///
/// `solid()` rebuilds the exact overlap now, from the frames `CadaclysmCollider.check`
/// found it at; this keeps the collisions handle behind every hit of one `check` call
/// alive until the last of them is released, freeing it only then. Named
/// `CadaclysmCollisionHit` rather than the plainer `CadaclysmHit`, which this module
/// already uses for a curve-crossing result (`CadaclysmSolid.hits`).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCollisionHit {
    hit: bs::CollisionHit,
    #[var(get = get_a, no_set)]
    a: PhantomVar<i64>,
    #[var(get = get_b, no_set)]
    b: PhantomVar<i64>,
    #[var(get = get_overlap, no_set)]
    overlap: PhantomVar<bool>,
    #[var(get = get_kind, no_set)]
    kind: PhantomVar<GString>,
    #[var(get = get_depth, no_set)]
    depth: PhantomVar<f64>,
    #[var(get = get_text, no_set)]
    text: PhantomVar<GString>,
    #[var(get = get_positions, no_set)]
    positions: PhantomVar<PackedVector3Array>,
    #[var(get = get_normals, no_set)]
    normals: PhantomVar<PackedVector3Array>,
    #[var(get = get_indices, no_set)]
    indices: PhantomVar<PackedInt32Array>,
}

impl CadaclysmCollisionHit {
    fn wrap(hit: bs::CollisionHit) -> Gd<CadaclysmCollisionHit> {
        Gd::from_object(CadaclysmCollisionHit {
            hit,
            a: PhantomVar::default(),
            b: PhantomVar::default(),
            overlap: PhantomVar::default(),
            kind: PhantomVar::default(),
            depth: PhantomVar::default(),
            text: PhantomVar::default(),
            positions: PhantomVar::default(),
            normals: PhantomVar::default(),
            indices: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCollisionHit {
    fn to_string(&self) -> GString {
        gs(format!("CollisionHit(a={}, b={}, overlap={}, depth={})", self.hit.a, self.hit.b, self.hit.overlap, self.hit.depth))
    }
}

#[godot_api]
impl CadaclysmCollisionHit {
    #[func]
    fn get_a(&self) -> i64 {
        self.hit.a.into()
    }
    #[func]
    fn get_b(&self) -> i64 {
        self.hit.b.into()
    }
    #[func]
    fn get_overlap(&self) -> bool {
        self.hit.overlap
    }
    #[func]
    fn get_kind(&self) -> GString {
        gs(&self.hit.kind)
    }
    #[func]
    fn get_depth(&self) -> f64 {
        self.hit.depth
    }
    #[func]
    fn get_text(&self) -> GString {
        gs(&self.hit.text)
    }
    #[func]
    fn get_positions(&self) -> PackedVector3Array {
        self.hit.positions.iter().map(|&p| vector3(p)).collect()
    }
    #[func]
    fn get_normals(&self) -> PackedVector3Array {
        self.hit.normals.iter().map(|&p| vector3(p)).collect()
    }
    #[func]
    fn get_indices(&self) -> PackedInt32Array {
        self.hit.indices.iter().map(|&i| i as i32).collect()
    }

    /// The exact overlap of this pair at the frames `CadaclysmCollider.check` found it
    /// at, as a new solid. `null` for a refused pair (`overlap` false) or a collisions
    /// handle already closed some other way.
    #[func]
    fn solid(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.hit.solid()).map(CadaclysmSolid::wrap)
    }
}

/// One pair `CadaclysmBlacksmith.clash` or `CadaclysmCollider.clash` found, as plain data.
/// `a`, `b` are the part indices: for one set or a collider `a < b`; for two sets `a`
/// indexes `parts` and `b` indexes `others`. `kind` is `"penetrating"` (the volumes
/// overlap), `"touching"` (the boundaries within the tolerance of each other),
/// `"too_close"` (apart by more than the tolerance but less than the clearance) or
/// `"refused"` (the pair could not be decided; `text` says why).
///
/// The feature fields are `CadaclysmClosest`'s, flat: what each point lies on (`"face"`,
/// `"edge"` or `"vertex"`), the kernel's id, and the `CadaclysmSolid.edges` index (-1 for a
/// face, a vertex or an edge the fillet table does not hold). For a penetrating or refused
/// pair there is no closest point: `kind_a` and `kind_b` are `"none"` and `index_*` and
/// `edge_*` are -1. Points are `Vector3`s, so floats; `raw_on_a` and `raw_on_b` give the
/// doubles.
///
/// `solid()` and `intersect()` are built on demand, from the placement the pair was found
/// at; the answer of the call that found the rows is kept alive behind every row of it --
/// past the collider and the solids -- until the last one is released, freeing it only
/// then.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmClash {
    row: bs::Clash,
    /// The first part's index: in the one set, or in the collider (then `a < b`); with two
    /// sets, an index into `parts`.
    #[var(get = get_a, no_set)]
    a: PhantomVar<i64>,
    /// The second part's index; with two sets, an index into `others`.
    #[var(get = get_b, no_set)]
    b: PhantomVar<i64>,
    /// `"penetrating"`, `"touching"`, `"too_close"` or `"refused"`.
    #[var(get = get_kind, no_set)]
    kind: PhantomVar<GString>,
    /// The gap between the two boundaries; 0 for a penetrating or refused pair.
    #[var(get = get_distance, no_set)]
    distance: PhantomVar<f64>,
    /// A world point on part `a`: the closest of the pair; for a penetrating pair the
    /// centre of the overlap's world box; the origin for a refused one.
    #[var(get = get_on_a, no_set)]
    on_a: PhantomVar<Vector3>,
    /// The matching world point on part `b`, as `on_a`.
    #[var(get = get_on_b, no_set)]
    on_b: PhantomVar<Vector3>,
    /// What `on_a` lies on: `"face"`, `"edge"` or `"vertex"`; `"none"` for a penetrating or
    /// refused pair.
    #[var(get = get_kind_a, no_set)]
    kind_a: PhantomVar<GString>,
    /// The kernel's id for part `a`'s feature; -1 for a penetrating or refused pair.
    #[var(get = get_index_a, no_set)]
    index_a: PhantomVar<i64>,
    /// Part `a`'s edge as the index `CadaclysmSolid.edges` uses; -1 for a face, a vertex, an
    /// edge the fillet table does not hold, and a penetrating or refused pair.
    #[var(get = get_edge_a, no_set)]
    edge_a: PhantomVar<i64>,
    /// What `on_b` lies on, as `kind_a`.
    #[var(get = get_kind_b, no_set)]
    kind_b: PhantomVar<GString>,
    /// The kernel's id for part `b`'s feature, as `index_a`.
    #[var(get = get_index_b, no_set)]
    index_b: PhantomVar<i64>,
    /// Part `b`'s edge, as `edge_a`.
    #[var(get = get_edge_b, no_set)]
    edge_b: PhantomVar<i64>,
    /// Whether the distance was measured on the exact surfaces; false for a penetrating or
    /// refused pair.
    #[var(get = get_refined, no_set)]
    refined: PhantomVar<bool>,
    /// The thinnest side of a penetrating pair's overlap box; 0 for any other.
    #[var(get = get_depth, no_set)]
    depth: PhantomVar<f64>,
    /// Why a refused pair could not be decided; empty otherwise.
    #[var(get = get_text, no_set)]
    text: PhantomVar<GString>,
    /// `on_a` as three doubles.
    #[var(get = get_raw_on_a, no_set)]
    raw_on_a: PhantomVar<PackedFloat64Array>,
    /// `on_b` as three doubles.
    #[var(get = get_raw_on_b, no_set)]
    raw_on_b: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmClash {
    fn wrap(row: bs::Clash) -> Gd<CadaclysmClash> {
        Gd::from_object(CadaclysmClash {
            row,
            a: PhantomVar::default(),
            b: PhantomVar::default(),
            kind: PhantomVar::default(),
            distance: PhantomVar::default(),
            on_a: PhantomVar::default(),
            on_b: PhantomVar::default(),
            kind_a: PhantomVar::default(),
            index_a: PhantomVar::default(),
            edge_a: PhantomVar::default(),
            kind_b: PhantomVar::default(),
            index_b: PhantomVar::default(),
            edge_b: PhantomVar::default(),
            refined: PhantomVar::default(),
            depth: PhantomVar::default(),
            text: PhantomVar::default(),
            raw_on_a: PhantomVar::default(),
            raw_on_b: PhantomVar::default(),
        })
    }

    /// A clash call's rows as the `Array` GDScript reads, or `null` (the reason recorded).
    fn rows(found: sdk::Result<Vec<bs::Clash>>) -> Variant {
        match ok(found) {
            Some(rows) => rows.into_iter().map(CadaclysmClash::wrap).collect::<Array<Gd<CadaclysmClash>>>().to_variant(),
            None => Variant::nil(),
        }
    }
}

#[godot_api]
impl IRefCounted for CadaclysmClash {
    fn to_string(&self) -> GString {
        let r = &self.row;
        gs(format!("Clash(a={}, b={}, kind={}, distance={}, depth={})", r.a, r.b, r.kind, r.distance, r.depth))
    }
}

#[godot_api]
impl CadaclysmClash {
    /// The first part's index.
    #[func]
    fn get_a(&self) -> i64 {
        self.row.a.into()
    }

    /// The second part's index.
    #[func]
    fn get_b(&self) -> i64 {
        self.row.b.into()
    }

    /// `"penetrating"`, `"touching"`, `"too_close"` or `"refused"`.
    #[func]
    fn get_kind(&self) -> GString {
        gs(&self.row.kind)
    }

    /// The gap between the two boundaries; 0 for a penetrating or refused pair.
    #[func]
    fn get_distance(&self) -> f64 {
        self.row.distance
    }

    /// The world point on part `a`.
    #[func]
    fn get_on_a(&self) -> Vector3 {
        vector3(self.row.on_a)
    }

    /// The world point on part `b`.
    #[func]
    fn get_on_b(&self) -> Vector3 {
        vector3(self.row.on_b)
    }

    /// `on_a` as three doubles.
    #[func]
    fn get_raw_on_a(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.row.on_a[..])
    }

    /// `on_b` as three doubles.
    #[func]
    fn get_raw_on_b(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.row.on_b[..])
    }

    /// What `on_a` lies on; `"none"` for a penetrating or refused pair.
    #[func]
    fn get_kind_a(&self) -> GString {
        gs(&self.row.kind_a)
    }

    /// The kernel's id for part `a`'s feature, -1 for none.
    #[func]
    fn get_index_a(&self) -> i64 {
        self.row.index_a.map_or(-1, i64::from)
    }

    /// Part `a`'s edge index, -1 for none.
    #[func]
    fn get_edge_a(&self) -> i64 {
        self.row.edge_a.map_or(-1, i64::from)
    }

    /// What `on_b` lies on; `"none"` for a penetrating or refused pair.
    #[func]
    fn get_kind_b(&self) -> GString {
        gs(&self.row.kind_b)
    }

    /// The kernel's id for part `b`'s feature, -1 for none.
    #[func]
    fn get_index_b(&self) -> i64 {
        self.row.index_b.map_or(-1, i64::from)
    }

    /// Part `b`'s edge index, -1 for none.
    #[func]
    fn get_edge_b(&self) -> i64 {
        self.row.edge_b.map_or(-1, i64::from)
    }

    /// Whether the distance was measured on the exact surfaces.
    #[func]
    fn get_refined(&self) -> bool {
        self.row.refined
    }

    /// The thinnest side of a penetrating pair's overlap box; 0 for any other.
    #[func]
    fn get_depth(&self) -> f64 {
        self.row.depth
    }

    /// Why a refused pair could not be decided; empty otherwise.
    #[func]
    fn get_text(&self) -> GString {
        gs(&self.row.text)
    }

    /// The exact shared volume of this penetrating pair, at the placement it was found at,
    /// as a new solid. `null` (`clashes_solid: ...` in `Cadaclysm.last_error()`) for a pair
    /// that is not penetrating.
    #[func]
    fn solid(&self) -> Option<Gd<CadaclysmSolid>> {
        ok(self.row.solid()).map(CadaclysmSolid::wrap)
    }

    /// Where this pair's two parts cross or coincide at the placement it was found at, as
    /// `CadaclysmSolid.intersect` reports it: a touching pair's shared face is a
    /// `CadaclysmOverlap`. `null` (`clashes_intersect: ...` in `Cadaclysm.last_error()`) for
    /// a refused pair.
    #[func]
    fn intersect(&self) -> Option<Gd<CadaclysmIntersection>> {
        ok(self.row.intersect()).map(CadaclysmIntersection::wrap)
    }
}

/// One pair `CadaclysmBlacksmith.swept_clash` or `CadaclysmCollider.swept_clash` found to
/// clash somewhere on the path, as plain data: when it first came within the clearance, the
/// `CadaclysmClash` there, and every time range it stays in clash. Times are in pose units:
/// pose `k` is at time `k`, and a time between two poses is the fraction of the way from one
/// to the next.
///
/// `first` keeps its own clash answer alive, as every `CadaclysmClash` does -- past the
/// collider, the solids, the call and this row -- so its `solid()` and `intersect()` rebuild
/// the contact at `first_time` for as long as it is held.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSweptClash {
    pair: (u32, u32),
    time: f64,
    clash: Gd<CadaclysmClash>,
    spans: Vec<(f64, f64)>,
    /// The first part's index: in the one set, or in the collider (then `a < b`); with two
    /// sets, an index into `parts`.
    #[var(get = get_a, no_set)]
    a: PhantomVar<i64>,
    /// The second part's index; with two sets, an index into `others`.
    #[var(get = get_b, no_set)]
    b: PhantomVar<i64>,
    /// The first time the pair came within the clearance, in pose units; for a refused pair
    /// the time it was refused at.
    #[var(get = get_first_time, no_set)]
    first_time: PhantomVar<f64>,
    /// The `CadaclysmClash` at `first_time`: its kind, distance, points, features and depth,
    /// at the frames the motion places the two parts at that time. A pair refused on the way
    /// has a `"refused"` first, whose `text` says why.
    #[var(get = get_first, no_set)]
    first: PhantomVar<Gd<CadaclysmClash>>,
    /// The time ranges the pair stays in clash, each a `PackedFloat64Array` `[start, end]`,
    /// ascending and disjoint; the first starts at `first_time`. Empty for a refused pair.
    #[var(get = get_intervals, no_set)]
    intervals: PhantomVar<Array<PackedFloat64Array>>,
}

impl CadaclysmSweptClash {
    fn wrap(row: bs::SweptClash) -> Gd<CadaclysmSweptClash> {
        Gd::from_object(CadaclysmSweptClash {
            pair: (row.a, row.b),
            time: row.first_time,
            clash: CadaclysmClash::wrap(row.first),
            spans: row.intervals,
            a: PhantomVar::default(),
            b: PhantomVar::default(),
            first_time: PhantomVar::default(),
            first: PhantomVar::default(),
            intervals: PhantomVar::default(),
        })
    }

    /// A swept clash call's rows as the `Array` GDScript reads, or `null` (the reason
    /// recorded).
    fn rows(found: sdk::Result<Vec<bs::SweptClash>>) -> Variant {
        match ok(found) {
            Some(rows) => rows.into_iter().map(CadaclysmSweptClash::wrap).collect::<Array<Gd<CadaclysmSweptClash>>>().to_variant(),
            None => Variant::nil(),
        }
    }
}

#[godot_api]
impl IRefCounted for CadaclysmSweptClash {
    fn to_string(&self) -> GString {
        let kind = self.clash.bind().row.kind.clone();
        gs(format!(
            "SweptClash(a={}, b={}, first_time={}, kind={}, intervals={})",
            self.pair.0,
            self.pair.1,
            self.time,
            kind,
            self.spans.len()
        ))
    }
}

#[godot_api]
impl CadaclysmSweptClash {
    /// The first part's index.
    #[func]
    fn get_a(&self) -> i64 {
        self.pair.0.into()
    }

    /// The second part's index.
    #[func]
    fn get_b(&self) -> i64 {
        self.pair.1.into()
    }

    /// The first time the pair came within the clearance, in pose units.
    #[func]
    fn get_first_time(&self) -> f64 {
        self.time
    }

    /// The `CadaclysmClash` at `first_time`; the same object at every ask.
    #[func]
    fn get_first(&self) -> Gd<CadaclysmClash> {
        self.clash.clone()
    }

    /// The time ranges the pair stays in clash, `[start, end]` each; a copy at every ask.
    #[func]
    fn get_intervals(&self) -> Array<PackedFloat64Array> {
        self.spans.iter().map(|&(start, end)| PackedFloat64Array::from(&[start, end][..])).collect()
    }
}

/// Parts meshed once, asked pose after pose which of them interfere: `solids` at rest,
/// meshed at `tolerance`; `groups` one group index per solid (empty: each solid its own
/// group -- `check` then takes one frame per solid), `allowed` pairs of part indices
/// never tested (designed contacts, by part index, flat: `[a0, b0, a1, b1, ...]`).
/// `close()` frees this handle; so does the garbage collector.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCollider {
    collider: Option<bs::Collider>,
    #[var(get = get_group_count, no_set)]
    group_count: PhantomVar<i64>,
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
}

impl CadaclysmCollider {
    fn wrap(collider: bs::Collider) -> Gd<CadaclysmCollider> {
        Gd::from_object(CadaclysmCollider { collider: Some(collider), group_count: PhantomVar::default(), closed: PhantomVar::default() })
    }

    fn held(&self) -> Option<&bs::Collider> {
        match &self.collider {
            Some(collider) => Some(collider),
            None => fail("the collider is closed"),
        }
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCollider {
    fn to_string(&self) -> GString {
        gs("Collider")
    }
}

#[godot_api]
impl CadaclysmCollider {
    /// `solids` at rest, meshed at `tolerance`; `groups` one group index per solid
    /// (empty: each solid its own group), `allowed` part-index pairs never tested,
    /// flat: `[a0, b0, a1, b1, ...]`. `null` (reason in `Cadaclysm.last_error()`) for
    /// a negative group or part index, an odd-length `allowed`, or the kernel's refusal.
    #[func]
    fn create(
        solids: Array<Gd<CadaclysmSolid>>,
        #[opt(default = 0.05)] tolerance: f64,
        #[opt(default = &PackedInt32Array::new())] groups: PackedInt32Array,
        #[opt(default = &PackedInt32Array::new())] allowed: PackedInt32Array,
    ) -> Option<Gd<CadaclysmCollider>> {
        let owners: Vec<Gd<CadaclysmSolid>> = solids.iter_shared().collect();
        let guards: Vec<GdRef<CadaclysmSolid>> = owners.iter().map(Gd::bind).collect();
        let mut refs: Vec<&bs::Solid> = Vec::with_capacity(guards.len());
        for g in &guards {
            refs.push(g.held()?);
        }
        let Ok(groups_vec) = groups.as_slice().iter().map(|&g| u32::try_from(g)).collect::<Result<Vec<u32>, _>>() else {
            return fail("create: a group index is negative");
        };
        if allowed.len() % 2 != 0 {
            return fail(format!("create: allowed is {} numbers, not pairs", allowed.len()));
        }
        let Ok(allowed_vec) = allowed
            .as_slice()
            .chunks_exact(2)
            .map(|c| Ok::<_, std::num::TryFromIntError>((u32::try_from(c[0])?, u32::try_from(c[1])?)))
            .collect::<Result<Vec<(u32, u32)>, _>>()
        else {
            return fail("create: an allowed part index is negative");
        };
        ok(bs::Collider::new(&refs, tolerance, (!groups_vec.is_empty()).then_some(&groups_vec[..]), &allowed_vec))
            .map(CadaclysmCollider::wrap)
    }

    /// Free the collider now. Idempotent; a `CadaclysmCollisionHit`'s own `solid()`
    /// still works afterwards -- it keeps the collisions handle, not this one.
    #[func]
    fn close(&mut self) {
        self.collider = None;
    }

    #[func]
    fn get_closed(&self) -> bool {
        self.collider.is_none()
    }

    /// How many groups this collider has -- the highest group index past `create`,
    /// plus one.
    #[func]
    fn get_group_count(&self) -> i64 {
        self.held().map_or(0, |c| i64::from(c.group_count()))
    }

    /// Counts of the last `check` call (all zero before the first one).
    #[func]
    fn stats(&self) -> Option<Gd<CadaclysmColliderStats>> {
        self.held().and_then(|c| ok(c.stats())).map(CadaclysmColliderStats::wrap)
    }

    /// The pairs that interfere, or could not be decided, with each group placed at its
    /// matching frame in `frames` (an array of frames -- `CadaclysmFrame`, `Transform3D`,
    /// twelve numbers or four triples -- one per group, in group order). `share_n` 0:
    /// every pair past the box filters is decided now; otherwise only those whose index
    /// is `share_k` modulo `share_n` (the shares of one pose are disjoint and cover it --
    /// split one `check` across `share_n` workers).
    ///
    /// Returns an `Array` of `CadaclysmCollisionHit` -- empty only when every pair is
    /// proved clear -- or `null` when the check is refused, with the reason in
    /// `Cadaclysm.last_error()`: a closed collider, a frame that is not a frame (or
    /// scales, shears or mirrors), a frame count other than `group_count`, or a share
    /// out of range (`share_n` negative, or `share_k` not in `0 <= share_k < share_n`).
    /// Test for `null` before reading the hits: a refusal is never "clear".
    #[func]
    fn check(&self, frames: VarArray, #[opt(default = 0)] share_k: i64, #[opt(default = 0)] share_n: i64) -> Variant {
        let Some(collider) = self.held() else { return Variant::nil() };
        let mut fs = Vec::with_capacity(frames.len());
        for (i, item) in frames.iter_shared().enumerate() {
            let Some(f) = frame(&item, &format!("check: frame {i}")) else { return Variant::nil() };
            fs.push(f);
        }
        let share = match (u32::try_from(share_k), u32::try_from(share_n)) {
            (_, Ok(0)) => None,
            (Ok(k), Ok(n)) if k < n => Some((k, n)),
            _ => {
                fail::<()>(format!("check: share ({share_k}, {share_n}) is not 0 <= k < n"));
                return Variant::nil();
            }
        };
        match ok(collider.check(&fs, share)) {
            Some(hits) => hits.into_iter().map(CadaclysmCollisionHit::wrap).collect::<Array<Gd<CadaclysmCollisionHit>>>().to_variant(),
            None => Variant::nil(),
        }
    }

    /// Every pair of parts that penetrates, touches or lies within `clearance` of the
    /// other, as `CadaclysmClash` rows in pair order, with each group placed at its
    /// matching frame in `frames` (as for `check`, which answers overlap alone). The kinds
    /// and `clearance` are `CadaclysmBlacksmith.clash`'s; the tolerance is the one the
    /// collider was built with. `share_k`/`share_n` as for `check` (`share_n` 0, the
    /// default, decides every pair now): the rows of the shares of one pose are disjoint
    /// and cover it. The collider keeps each part's closest mesh (at a third of its
    /// tolerance) for its lifetime once a pair needed one.
    ///
    /// Returns an `Array` of `CadaclysmClash` -- empty when no pair is in trouble -- or
    /// `null` with the reason in `Cadaclysm.last_error()`: a closed collider, a frame that is
    /// not a frame (or scales, shears or mirrors), and in the kernel's words
    /// (`collider_clash: ...`) a `clearance` negative or not finite, a frame count other
    /// than `group_count`, or a `share_k` not below `share_n`; a `share_k` or `share_n`
    /// negative or past a `u32` is refused here (`collider_clash: share (k, n) ...`).
    #[func]
    fn clash(
        &self,
        frames: VarArray,
        #[opt(default = 0.0)] clearance: f64,
        #[opt(default = 0)] share_k: i64,
        #[opt(default = 0)] share_n: i64,
    ) -> Variant {
        let Some(collider) = self.held() else { return Variant::nil() };
        let mut fs = Vec::with_capacity(frames.len());
        for (i, item) in frames.iter_shared().enumerate() {
            let Some(f) = frame(&item, &format!("collider_clash: frame {i}")) else { return Variant::nil() };
            fs.push(f);
        }
        // An in-range share the kernel judges itself (`k >= n` in its own words); only what
        // a `u32` cannot carry is refused here.
        let share = match (u32::try_from(share_k), u32::try_from(share_n)) {
            (_, Ok(0)) => None,
            (Ok(k), Ok(n)) => Some((k, n)),
            _ => {
                fail::<()>(format!("collider_clash: share ({share_k}, {share_n}) is not 0 <= k < n"));
                return Variant::nil();
            }
        };
        CadaclysmClash::rows(collider.clash(&fs, clearance, share))
    }

    /// Every pair of parts that penetrates, touches or comes within `clearance` of the
    /// other anywhere on the path through `poses` -- not only at the poses -- as
    /// `CadaclysmSweptClash` rows in pair order, each with the first time it does and the
    /// time ranges it stays in clash. `poses` is an array of two or more poses, each the
    /// `frames` `clash` takes (an array of one frame per group); time runs in pose units,
    /// pose `k` at time `k`. Between two poses each group moves rigidly about the centre of
    /// its rest box: that point on the straight line between its two places, the rotation
    /// turning at a steady rate the shorter way round.
    ///
    /// No moment where the true gap is below `clearance` less the collider's tolerance (for
    /// clearance 0: no penetration deeper than the tolerance) falls between two steps.
    /// `resolution` (in (0, 1], a fraction of a segment) is how closely an interval's end is
    /// found; `max_steps` the pose-wise tests one pair may take -- a pair that needs more is
    /// a `"refused"` row. `share_k`/`share_n` as for `check` (`share_n` 0, the default,
    /// decides every pair now), over the pairs whose swept boxes meet. The pose caches
    /// `check` and `clash` keep are neither read nor filled.
    ///
    /// Returns an `Array` of `CadaclysmSweptClash` -- empty when no pair is in trouble on the
    /// way -- or `null` with the reason in `Cadaclysm.last_error()`: a closed collider, a pose
    /// that is not an array or a frame that is not a frame, a `max_steps`, `share_k` or
    /// `share_n` negative or past a `u32` (`collider_swept_clash: ...`); and in the kernel's
    /// words (`collider_swept_clash: ...`) fewer than two poses, a pose whose frame count is
    /// not `group_count` (`N frames for M groups`, for the first pose that is off), a
    /// `clearance` negative or not finite, a `resolution` outside (0, 1], `max_steps` 0 or a
    /// `share_k` not below `share_n`.
    #[func]
    fn swept_clash(
        &self,
        poses: AnyArray,
        #[opt(default = 0.0)] clearance: f64,
        #[opt(default = 1e-3)] resolution: f64,
        #[opt(default = 100000)] max_steps: i64,
        #[opt(default = 0)] share_k: i64,
        #[opt(default = 0)] share_n: i64,
    ) -> Variant {
        let Some(collider) = self.held() else { return Variant::nil() };
        let Some(set) = swept_poses(&poses, "collider_swept_clash", "") else { return Variant::nil() };
        let Some(steps) = swept_max_steps(max_steps, "collider_swept_clash") else { return Variant::nil() };
        // As `clash`: an in-range share the kernel judges itself.
        let share = match (u32::try_from(share_k), u32::try_from(share_n)) {
            (_, Ok(0)) => None,
            (Ok(k), Ok(n)) => Some((k, n)),
            _ => {
                fail::<()>(format!("collider_swept_clash: share ({share_k}, {share_n}) is not 0 <= k < n"));
                return Variant::nil();
            }
        };
        let refs: Vec<&[bs::Frame]> = set.iter().map(Vec::as_slice).collect();
        // A pose whose frame count differs from another's is refused by the SDK, in the
        // kernel's words.
        CadaclysmSweptClash::rows(collider.swept_clash(&refs, clearance, resolution, steps, share))
    }
}

// ---- CadaclysmThicknessGauge and its rows -------------------------------------------------

/// A point for a thickness call: three numbers (a `Vector3`, an `Array` or a packed array),
/// refused under `call`'s name as Python words it.
fn thickness_point(v: &Variant, call: &str) -> Option<[f64; 3]> {
    match numbers(v, false) {
        Some(w) if w.len() == 3 => Some([w[0], w[1], w[2]]),
        Some(w) => fail(format!("{call}: a point is 3 numbers, got {}", w.len())),
        None => fail(format!("{call}: a point is 3 numbers, not {v}")),
    }
}

/// An optional point: `null` is none.
fn thickness_optional_point(v: &Variant, call: &str) -> Option<Option<[f64; 3]>> {
    if v.is_nil() {
        Some(None)
    } else {
        thickness_point(v, call).map(Some)
    }
}

/// One wall-thickness reading on a solid (`CadaclysmThicknessGauge.thickness`,
/// `CadaclysmThicknessGauge.thickness_at`, `CadaclysmBlacksmith.thickness`), as plain data.
/// Points are `Vector3`s, so floats (compare to 1e-5, not 1e-9); `raw_point`,
/// `raw_opposite` and `raw_exact_opposite` give the doubles. `vertex` is -1 for a reading at
/// a point, and `sphere` is NaN (with `has_sphere` false) where no ball under the maximum is
/// bounded.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmThickness {
    row: bs::Thickness,
    /// The body read: its index among the gauge's solids.
    #[var(get = get_body, no_set)]
    body: PhantomVar<i64>,
    /// The vertex of that body's measuring mesh the reading is at; -1 for a reading at a
    /// point (`CadaclysmThicknessGauge.thickness_at`).
    #[var(get = get_vertex, no_set)]
    vertex: PhantomVar<i64>,
    /// The face of `body` that `point` lies on.
    #[var(get = get_face, no_set)]
    face: PhantomVar<i64>,
    /// Where the wall is read.
    #[var(get = get_point, no_set)]
    point: PhantomVar<Vector3>,
    /// The rule's figure on the measuring mesh: the distance from `point` to `opposite`; 0 on
    /// a knife edge.
    #[var(get = get_thickness, no_set)]
    thickness: PhantomVar<f64>,
    /// The nearest point on the opposing triangle; `point` itself on a knife edge.
    #[var(get = get_opposite, no_set)]
    opposite: PhantomVar<Vector3>,
    /// The body `opposite` lies on: the gauge's bodies are measured against each other.
    #[var(get = get_opposite_body, no_set)]
    opposite_body: PhantomVar<i64>,
    /// The face of `opposite_body` that `opposite` lies on.
    #[var(get = get_opposite_face, no_set)]
    opposite_face: PhantomVar<i64>,
    /// Whether `point` is a knife edge: thickness 0, `opposite` equal to `point`.
    #[var(get = get_knife, no_set)]
    knife: PhantomVar<bool>,
    /// The distance from `point` to `exact_opposite`: the figure to compare with a closed form.
    #[var(get = get_exact_thickness, no_set)]
    exact_thickness: PhantomVar<f64>,
    /// `opposite` moved onto its face's exact surface, where that foot lies within the
    /// tolerance of it and inside the face's trims; otherwise `opposite` itself.
    #[var(get = get_exact_opposite, no_set)]
    exact_opposite: PhantomVar<Vector3>,
    /// The diameter of the largest ball tangent at `point` that holds none of the surfaces;
    /// NaN where `has_sphere` is false.
    #[var(get = get_sphere, no_set)]
    sphere: PhantomVar<f64>,
    /// Whether `sphere` is a figure: false where no ball up to the maximum is bounded.
    #[var(get = get_has_sphere, no_set)]
    has_sphere: PhantomVar<bool>,
    /// `point` as three doubles.
    #[var(get = get_raw_point, no_set)]
    raw_point: PhantomVar<PackedFloat64Array>,
    /// `opposite` as three doubles.
    #[var(get = get_raw_opposite, no_set)]
    raw_opposite: PhantomVar<PackedFloat64Array>,
    /// `exact_opposite` as three doubles.
    #[var(get = get_raw_exact_opposite, no_set)]
    raw_exact_opposite: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmThickness {
    fn wrap(row: bs::Thickness) -> Gd<CadaclysmThickness> {
        Gd::from_object(CadaclysmThickness {
            row,
            body: PhantomVar::default(),
            vertex: PhantomVar::default(),
            face: PhantomVar::default(),
            point: PhantomVar::default(),
            thickness: PhantomVar::default(),
            opposite: PhantomVar::default(),
            opposite_body: PhantomVar::default(),
            opposite_face: PhantomVar::default(),
            knife: PhantomVar::default(),
            exact_thickness: PhantomVar::default(),
            exact_opposite: PhantomVar::default(),
            sphere: PhantomVar::default(),
            has_sphere: PhantomVar::default(),
            raw_point: PhantomVar::default(),
            raw_opposite: PhantomVar::default(),
            raw_exact_opposite: PhantomVar::default(),
        })
    }

    /// A thickness call's rows as the `Array` GDScript reads, or `null` (the reason recorded).
    fn rows(found: sdk::Result<Vec<bs::Thickness>>) -> Variant {
        match ok(found) {
            Some(rows) => rows.into_iter().map(CadaclysmThickness::wrap).collect::<Array<Gd<CadaclysmThickness>>>().to_variant(),
            None => Variant::nil(),
        }
    }
}

#[godot_api]
impl IRefCounted for CadaclysmThickness {
    fn to_string(&self) -> GString {
        let r = &self.row;
        gs(format!(
            "Thickness(body={}, vertex={:?}, face={}, thickness={}, opposite_body={}, opposite_face={}, knife={})",
            r.body, r.vertex, r.face, r.thickness, r.opposite_body, r.opposite_face, r.knife
        ))
    }
}

#[godot_api]
impl CadaclysmThickness {
    /// The body read: its index among the gauge's solids.
    #[func]
    fn get_body(&self) -> i64 {
        self.row.body.into()
    }

    /// The vertex of the measuring mesh the reading is at; -1 for a reading at a point.
    #[func]
    fn get_vertex(&self) -> i64 {
        self.row.vertex.map_or(-1, i64::from)
    }

    /// The face of `body` that `point` lies on.
    #[func]
    fn get_face(&self) -> i64 {
        self.row.face.into()
    }

    /// Where the wall is read.
    #[func]
    fn get_point(&self) -> Vector3 {
        vector3(self.row.point)
    }

    /// The distance from `point` to `opposite` on the measuring mesh; 0 on a knife edge.
    #[func]
    fn get_thickness(&self) -> f64 {
        self.row.thickness
    }

    /// The nearest point on the opposing triangle.
    #[func]
    fn get_opposite(&self) -> Vector3 {
        vector3(self.row.opposite)
    }

    /// The body `opposite` lies on.
    #[func]
    fn get_opposite_body(&self) -> i64 {
        self.row.opposite_body.into()
    }

    /// The face of `opposite_body` that `opposite` lies on.
    #[func]
    fn get_opposite_face(&self) -> i64 {
        self.row.opposite_face.into()
    }

    /// Whether `point` is a knife edge.
    #[func]
    fn get_knife(&self) -> bool {
        self.row.knife
    }

    /// The distance from `point` to `exact_opposite`.
    #[func]
    fn get_exact_thickness(&self) -> f64 {
        self.row.exact_thickness
    }

    /// `opposite` moved onto its face's exact surface.
    #[func]
    fn get_exact_opposite(&self) -> Vector3 {
        vector3(self.row.exact_opposite)
    }

    /// The inscribed ball's diameter; NaN where there is none.
    #[func]
    fn get_sphere(&self) -> f64 {
        self.row.sphere.unwrap_or(f64::NAN)
    }

    /// Whether `sphere` is a figure.
    #[func]
    fn get_has_sphere(&self) -> bool {
        self.row.sphere.is_some()
    }

    /// `point` as three doubles.
    #[func]
    fn get_raw_point(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.row.point[..])
    }

    /// `opposite` as three doubles.
    #[func]
    fn get_raw_opposite(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.row.opposite[..])
    }

    /// `exact_opposite` as three doubles.
    #[func]
    fn get_raw_exact_opposite(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.row.exact_opposite[..])
    }
}

/// One face's wall thickness (`CadaclysmThicknessGauge.thickness_at_face`,
/// `CadaclysmSolid.thickness_at_face`), as plain data.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmFaceThickness {
    value: bs::FaceThickness,
    /// The median of the face's readings, or the reading at the point asked.
    #[var(get = get_thickness, no_set)]
    thickness: PhantomVar<f64>,
    /// The thinnest reading on the face.
    #[var(get = get_min, no_set)]
    min: PhantomVar<f64>,
    /// The thickest reading on the face.
    #[var(get = get_max, no_set)]
    max: PhantomVar<f64>,
    /// Whether `max - min` is within the gauge's tolerance.
    #[var(get = get_uniform, no_set)]
    uniform: PhantomVar<bool>,
}

impl CadaclysmFaceThickness {
    fn wrap(value: bs::FaceThickness) -> Gd<CadaclysmFaceThickness> {
        Gd::from_object(CadaclysmFaceThickness {
            value,
            thickness: PhantomVar::default(),
            min: PhantomVar::default(),
            max: PhantomVar::default(),
            uniform: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmFaceThickness {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!("FaceThickness(thickness={}, min={}, max={}, uniform={})", v.thickness, v.min, v.max, v.uniform))
    }
}

#[godot_api]
impl CadaclysmFaceThickness {
    /// The median of the face's readings, or the reading at the point asked.
    #[func]
    fn get_thickness(&self) -> f64 {
        self.value.thickness
    }

    /// The thinnest reading on the face.
    #[func]
    fn get_min(&self) -> f64 {
        self.value.min
    }

    /// The thickest reading on the face.
    #[func]
    fn get_max(&self) -> f64 {
        self.value.max
    }

    /// Whether `max - min` is within the gauge's tolerance.
    #[func]
    fn get_uniform(&self) -> bool {
        self.value.uniform
    }
}

/// A body's measuring mesh (`CadaclysmThicknessGauge.mesh`), copied out of the gauge.
/// Points are `Vector3`s, so floats; a reading's `vertex` indexes `positions`.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmThicknessMesh {
    value: bs::ThicknessMesh,
    /// One point per vertex; a reading's `vertex` indexes them.
    #[var(get = get_positions, no_set)]
    positions: PhantomVar<PackedVector3Array>,
    /// One unit outward normal per vertex.
    #[var(get = get_normals, no_set)]
    normals: PhantomVar<PackedVector3Array>,
    /// Three vertex indices per triangle, flat.
    #[var(get = get_triangles, no_set)]
    triangles: PhantomVar<PackedInt32Array>,
    /// The face of the body each triangle lies on.
    #[var(get = get_faces, no_set)]
    faces: PhantomVar<PackedInt32Array>,
}

impl CadaclysmThicknessMesh {
    fn wrap(value: bs::ThicknessMesh) -> Gd<CadaclysmThicknessMesh> {
        Gd::from_object(CadaclysmThicknessMesh {
            value,
            positions: PhantomVar::default(),
            normals: PhantomVar::default(),
            triangles: PhantomVar::default(),
            faces: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmThicknessMesh {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!("ThicknessMesh(vertices={}, triangles={})", v.positions.len(), v.triangles.len()))
    }
}

#[godot_api]
impl CadaclysmThicknessMesh {
    /// One point per vertex; a reading's `vertex` indexes them.
    #[func]
    fn get_positions(&self) -> PackedVector3Array {
        self.value.positions.iter().map(|&p| vector3(p)).collect()
    }

    /// One unit outward normal per vertex.
    #[func]
    fn get_normals(&self) -> PackedVector3Array {
        self.value.normals.iter().map(|&p| vector3(p)).collect()
    }

    /// Three vertex indices per triangle, flat.
    #[func]
    fn get_triangles(&self) -> PackedInt32Array {
        self.value.triangles.iter().flatten().map(|&i| i as i32).collect()
    }

    /// The face of the body each triangle lies on.
    #[func]
    fn get_faces(&self) -> PackedInt32Array {
        self.value.faces.iter().map(|&f| f as i32).collect()
    }
}

/// One reading on a plain mesh (`CadaclysmBlacksmith.mesh_thickness`), as plain data.
/// Points are `Vector3`s, so floats; `raw_point` and `raw_opposite` give the doubles.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmMeshThickness {
    row: bs::MeshThickness,
    /// The mesh read: its index among the meshes passed.
    #[var(get = get_mesh, no_set)]
    mesh: PhantomVar<i64>,
    /// The vertex of that mesh the reading is at.
    #[var(get = get_vertex, no_set)]
    vertex: PhantomVar<i64>,
    /// The distance from `point` to `opposite`; 0 on a knife edge.
    #[var(get = get_thickness, no_set)]
    thickness: PhantomVar<f64>,
    /// The vertex's position.
    #[var(get = get_point, no_set)]
    point: PhantomVar<Vector3>,
    /// The nearest point on the opposing triangle; `point` itself on a knife edge.
    #[var(get = get_opposite, no_set)]
    opposite: PhantomVar<Vector3>,
    /// The mesh `opposite` lies on: the meshes are measured against each other.
    #[var(get = get_opposite_mesh, no_set)]
    opposite_mesh: PhantomVar<i64>,
    /// The triangle of `opposite_mesh` that `opposite` lies on.
    #[var(get = get_opposite_triangle, no_set)]
    opposite_triangle: PhantomVar<i64>,
    /// Whether the vertex is a knife edge: thickness 0, `opposite` equal to `point`.
    #[var(get = get_knife, no_set)]
    knife: PhantomVar<bool>,
    /// `point` as three doubles.
    #[var(get = get_raw_point, no_set)]
    raw_point: PhantomVar<PackedFloat64Array>,
    /// `opposite` as three doubles.
    #[var(get = get_raw_opposite, no_set)]
    raw_opposite: PhantomVar<PackedFloat64Array>,
}

impl CadaclysmMeshThickness {
    fn wrap(row: bs::MeshThickness) -> Gd<CadaclysmMeshThickness> {
        Gd::from_object(CadaclysmMeshThickness {
            row,
            mesh: PhantomVar::default(),
            vertex: PhantomVar::default(),
            thickness: PhantomVar::default(),
            point: PhantomVar::default(),
            opposite: PhantomVar::default(),
            opposite_mesh: PhantomVar::default(),
            opposite_triangle: PhantomVar::default(),
            knife: PhantomVar::default(),
            raw_point: PhantomVar::default(),
            raw_opposite: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmMeshThickness {
    fn to_string(&self) -> GString {
        let r = &self.row;
        gs(format!(
            "MeshThickness(mesh={}, vertex={}, thickness={}, opposite_mesh={}, opposite_triangle={}, knife={})",
            r.mesh, r.vertex, r.thickness, r.opposite_mesh, r.opposite_triangle, r.knife
        ))
    }
}

#[godot_api]
impl CadaclysmMeshThickness {
    /// The mesh read: its index among the meshes passed.
    #[func]
    fn get_mesh(&self) -> i64 {
        self.row.mesh.into()
    }

    /// The vertex of that mesh the reading is at.
    #[func]
    fn get_vertex(&self) -> i64 {
        self.row.vertex.into()
    }

    /// The distance from `point` to `opposite`; 0 on a knife edge.
    #[func]
    fn get_thickness(&self) -> f64 {
        self.row.thickness
    }

    /// The vertex's position.
    #[func]
    fn get_point(&self) -> Vector3 {
        vector3(self.row.point)
    }

    /// The nearest point on the opposing triangle.
    #[func]
    fn get_opposite(&self) -> Vector3 {
        vector3(self.row.opposite)
    }

    /// The mesh `opposite` lies on.
    #[func]
    fn get_opposite_mesh(&self) -> i64 {
        self.row.opposite_mesh.into()
    }

    /// The triangle of `opposite_mesh` that `opposite` lies on.
    #[func]
    fn get_opposite_triangle(&self) -> i64 {
        self.row.opposite_triangle.into()
    }

    /// Whether the vertex is a knife edge.
    #[func]
    fn get_knife(&self) -> bool {
        self.row.knife
    }

    /// `point` as three doubles.
    #[func]
    fn get_raw_point(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.row.point[..])
    }

    /// `opposite` as three doubles.
    #[func]
    fn get_raw_opposite(&self) -> PackedFloat64Array {
        PackedFloat64Array::from(&self.row.opposite[..])
    }
}

/// `meshes` as `mesh_thickness` takes them: each `[positions, triangles]`, positions a
/// `PackedVector3Array` or an array of points (each a `Vector3` or three numbers), triangles
/// a flat `PackedInt32Array` / `PackedInt64Array` or an array of triples (each a `Vector3i`
/// or three whole numbers). Refused as Python words it.
#[allow(clippy::type_complexity)]
fn thickness_meshes(meshes: &AnyArray) -> Option<Vec<(Vec<[f64; 3]>, Vec<[u32; 3]>)>> {
    let mut out = Vec::with_capacity(meshes.len());
    for (m, item) in meshes.iter_shared().enumerate() {
        let pair = match item.try_to::<AnyArray>() {
            Ok(pair) if pair.len() == 2 => pair,
            _ => return fail(format!("mesh_thickness: mesh {m} is not a [positions, triangles] pair")),
        };
        let (points, triangles) = (pair.at(0), pair.at(1));
        let positions: Vec<[f64; 3]> = match points.get_type() {
            VariantType::PACKED_VECTOR3_ARRAY => {
                points.to::<PackedVector3Array>().as_slice().iter().map(|p| [f64::from(p.x), f64::from(p.y), f64::from(p.z)]).collect()
            }
            VariantType::ARRAY => {
                let list = points.to::<AnyArray>();
                let mut rows = Vec::with_capacity(list.len());
                for (i, p) in list.iter_shared().enumerate() {
                    match numbers(&p, false) {
                        Some(w) if w.len() == 3 => rows.push([w[0], w[1], w[2]]),
                        _ => return fail(format!("mesh_thickness: mesh {m} position {i} is not three numbers")),
                    }
                }
                rows
            }
            _ => return fail(format!("mesh_thickness: mesh {m} is not a [positions, triangles] pair")),
        };
        let index = |x: f64| (x.fract() == 0.0 && (0.0..=f64::from(u32::MAX)).contains(&x)).then_some(x as u32);
        let flat = |values: Vec<i64>| -> Option<Vec<[u32; 3]>> {
            if values.len() % 3 != 0 {
                return fail(format!("mesh_thickness: mesh {m} triangle {} is not three indices", values.len() / 3));
            }
            values
                .chunks_exact(3)
                .enumerate()
                .map(|(t, c)| match (u32::try_from(c[0]), u32::try_from(c[1]), u32::try_from(c[2])) {
                    (Ok(a), Ok(b), Ok(d)) => Some([a, b, d]),
                    _ => fail(format!("mesh_thickness: mesh {m} triangle {t} is not three indices")),
                })
                .collect()
        };
        let tris: Vec<[u32; 3]> = match triangles.get_type() {
            VariantType::PACKED_INT32_ARRAY => flat(triangles.to::<PackedInt32Array>().as_slice().iter().map(|&x| i64::from(x)).collect())?,
            VariantType::PACKED_INT64_ARRAY => flat(triangles.to::<PackedInt64Array>().as_slice().to_vec())?,
            VariantType::ARRAY => {
                let list = triangles.to::<AnyArray>();
                let mut rows = Vec::with_capacity(list.len());
                for (t, tri) in list.iter_shared().enumerate() {
                    let w = if tri.get_type() == VariantType::PACKED_FLOAT64_ARRAY || tri.get_type() == VariantType::PACKED_FLOAT32_ARRAY {
                        None
                    } else {
                        numbers(&tri, false)
                    };
                    match w.as_deref() {
                        Some([a, b, c]) => match (index(*a), index(*b), index(*c)) {
                            (Some(a), Some(b), Some(c)) => rows.push([a, b, c]),
                            _ => return fail(format!("mesh_thickness: mesh {m} triangle {t} is not three indices")),
                        },
                        _ => return fail(format!("mesh_thickness: mesh {m} triangle {t} is not three indices")),
                    }
                }
                rows
            }
            _ => return fail(format!("mesh_thickness: mesh {m} is not a [positions, triangles] pair")),
        };
        out.push((positions, tris));
    }
    Some(out)
}

/// Wall thickness over `solids`, measured against each other: each solid meshed once at
/// `tolerance` -- absolute, in model units (0.01 by default) -- and indexed, then asked
/// reading after reading. A reading's `body` is the solid's index in `solids`. The gauge
/// keeps its own reference to the bodies, so it answers on after they are closed.
/// `close()` frees this handle; so does the garbage collector.
///
/// The rule reads the measuring mesh (`mesh`). From a point P the thickness is the distance
/// to the nearest triangle that opposes P's own face (their normals more than 89 degrees
/// apart) with P on or behind its plane -- not a ray cast along the normal. A point with no
/// such triangle, or one further than `maximum`, gives no reading: readings are dropped,
/// not clamped.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmThicknessGauge {
    gauge: Option<bs::ThicknessGauge>,
    /// How many bodies the gauge measures: the length of `solids` it was built from; 0 once
    /// closed.
    #[var(get = get_body_count, no_set)]
    body_count: PhantomVar<i64>,
    /// The tolerance the gauge meshed its bodies at; 0 once closed.
    #[var(get = get_tolerance, no_set)]
    tolerance: PhantomVar<f64>,
    /// Whether `close` has freed the gauge.
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
}

impl CadaclysmThicknessGauge {
    fn wrap(gauge: bs::ThicknessGauge) -> Gd<CadaclysmThicknessGauge> {
        Gd::from_object(CadaclysmThicknessGauge {
            gauge: Some(gauge),
            body_count: PhantomVar::default(),
            tolerance: PhantomVar::default(),
            closed: PhantomVar::default(),
        })
    }

    fn held(&self) -> Option<&bs::ThicknessGauge> {
        match &self.gauge {
            Some(gauge) => Some(gauge),
            None => fail("thickness_gauge: closed"),
        }
    }
}

#[godot_api]
impl IRefCounted for CadaclysmThicknessGauge {
    fn to_string(&self) -> GString {
        match &self.gauge {
            Some(g) => gs(format!("ThicknessGauge(bodies={}, tolerance={})", g.body_count(), g.tolerance())),
            None => gs("ThicknessGauge(closed)"),
        }
    }
}

#[godot_api]
impl CadaclysmThicknessGauge {
    /// `solids` meshed at `tolerance` (0.01 by default). `null` (reason in
    /// `Cadaclysm.last_error()`) for a tolerance not positive and finite
    /// (`thickness_gauge_new: ...`) or a solid that is closed.
    #[func]
    fn create(solids: Array<Gd<CadaclysmSolid>>, #[opt(default = 0.01)] tolerance: f64) -> Option<Gd<CadaclysmThicknessGauge>> {
        let owners: Vec<Gd<CadaclysmSolid>> = solids.iter_shared().collect();
        let guards: Vec<GdRef<CadaclysmSolid>> = owners.iter().map(Gd::bind).collect();
        let mut refs: Vec<&bs::Solid> = Vec::with_capacity(guards.len());
        for g in &guards {
            refs.push(g.held()?);
        }
        ok(bs::ThicknessGauge::new(&refs, tolerance)).map(CadaclysmThicknessGauge::wrap)
    }

    /// Free the gauge now. Idempotent; a `CadaclysmThicknessMesh` already read stays valid.
    #[func]
    fn close(&mut self) {
        self.gauge = None;
    }

    /// Whether `close` has freed the gauge.
    #[func]
    fn get_closed(&self) -> bool {
        self.gauge.is_none()
    }

    /// How many bodies the gauge measures; 0 once closed.
    #[func]
    fn get_body_count(&self) -> i64 {
        self.gauge.as_ref().map_or(0, |g| i64::from(g.body_count()))
    }

    /// The tolerance the gauge meshed its bodies at; 0 once closed.
    #[func]
    fn get_tolerance(&self) -> f64 {
        self.gauge.as_ref().map_or(0.0, |g| g.tolerance())
    }

    /// One `CadaclysmThickness` per measuring-mesh vertex that reads within `maximum`, by
    /// body then vertex; `sharp_angle` (radians, 0 by default) sets which vertices are knife
    /// edges. Returns an `Array` -- empty when nothing reads -- or `null` with the reason in
    /// `Cadaclysm.last_error()`: a closed gauge (`thickness_gauge: closed`), or in the
    /// kernel's words (`thickness_gauge_measure: ...`) a `maximum` not positive and finite or
    /// a `sharp_angle` negative or not finite.
    #[func]
    fn thickness(&self, maximum: f64, #[opt(default = 0.0)] sharp_angle: f64) -> Variant {
        let Some(gauge) = self.held() else { return Variant::nil() };
        CadaclysmThickness::rows(gauge.thickness(maximum, sharp_angle))
    }

    /// The reading at `point`'s foot on face `face` of body `body`, its `vertex` -1: the
    /// foot read against the exact tangent plane there, so a wall is measured between the
    /// mesh's vertices too. `point` is a `Vector3` or three numbers. Returns a
    /// `CadaclysmThickness`, or `null` where the foot lies off the face or the wall there is
    /// thicker than `maximum` (then `Cadaclysm.last_error()` is empty), or with the reason in
    /// `Cadaclysm.last_error()` for a closed gauge, a `body` or `face` negative or past a
    /// `u32` (`thickness_gauge_at: ... is out of range`), a point that is not three numbers
    /// (`thickness_gauge_at: a point is 3 numbers, got N`), and in the kernel's words
    /// (`thickness_gauge_at: ...`) a body or face past the end, a point not finite, or a bad
    /// `maximum` or `sharp_angle`.
    #[func]
    fn thickness_at(
        &self,
        body: i64,
        face: i64,
        point: Variant,
        maximum: f64,
        #[opt(default = 0.0)] sharp_angle: f64,
    ) -> Option<Gd<CadaclysmThickness>> {
        let gauge = self.held()?;
        let body = rtree_u32(body, "thickness_gauge_at", "body")?;
        let face = rtree_u32(face, "thickness_gauge_at", "face")?;
        let point = thickness_point(&point, "thickness_gauge_at")?;
        ok(gauge.thickness_at(body, face, point, maximum, sharp_angle)).flatten().map(CadaclysmThickness::wrap)
    }

    /// One figure for face `face` of body `body`, as a `CadaclysmFaceThickness`, the other
    /// bodies measured with it: at `at`'s foot on the face (a `Vector3` or three numbers), or
    /// with `at` `null` over the face's vertices. `maximum` has no default. `null` where
    /// nothing on the face reads within `maximum`, or `at`'s foot lies off the face (then
    /// `Cadaclysm.last_error()` is empty); `null` with the reason in `Cadaclysm.last_error()`
    /// for a closed gauge, an index negative or past a `u32`, an `at` that is not three
    /// numbers, and in the kernel's words (`thickness_gauge_face: ...`) a body or face past
    /// the end, an `at` not finite, or a `maximum` not positive and finite.
    #[func]
    fn thickness_at_face(&self, body: i64, face: i64, at: Variant, maximum: f64) -> Option<Gd<CadaclysmFaceThickness>> {
        let gauge = self.held()?;
        let body = rtree_u32(body, "thickness_gauge_face", "body")?;
        let face = rtree_u32(face, "thickness_gauge_face", "face")?;
        let at = thickness_optional_point(&at, "thickness_gauge_face")?;
        ok(gauge.thickness_at_face(body, face, at, maximum)).flatten().map(CadaclysmFaceThickness::wrap)
    }

    /// Body `body`'s measuring mesh, as a `CadaclysmThicknessMesh`: the mesh a reading's
    /// `vertex` indexes, copied out, so it outlives the gauge. `null` with the reason in
    /// `Cadaclysm.last_error()` for a closed gauge, a `body` negative or past a `u32`, or a
    /// body past the end (`thickness_gauge_mesh: ...`).
    #[func]
    fn mesh(&self, body: i64) -> Option<Gd<CadaclysmThicknessMesh>> {
        let gauge = self.held()?;
        let body = rtree_u32(body, "thickness_gauge_mesh", "body")?;
        ok(gauge.mesh(body)).map(CadaclysmThicknessMesh::wrap)
    }
}

// ---- CadaclysmRTree, CadaclysmRTreeHit, CadaclysmRTreePair -------------------------------

/// An id or a `k` from GDScript's `int` as the `u32` the kernel takes, refused by `call`'s
/// name where it does not fit -- never wrapped.
fn rtree_u32(value: i64, call: &str, name: &str) -> Option<u32> {
    match u32::try_from(value) {
        Ok(v) => Some(v),
        Err(_) => fail(format!("{call}: {name} is out of range: {value}")),
    }
}

/// A box as the R-tree takes one: a `CadaclysmBox`, `[min, max]` (two points, each a
/// `Vector3` or three numbers), or six numbers `[minx, miny, minz, maxx, maxy, maxz]`.
/// The shape is refused here by `what`; a NaN or an inverted box is the kernel's to refuse.
fn rtree_box(v: &Variant, what: &str) -> Option<bs::Aabb> {
    if let Ok(b) = v.try_to::<Gd<CadaclysmBox>>() {
        return Some(b.bind().aabb);
    }
    if let Ok(pair) = v.try_to::<AnyArray>() {
        if pair.len() == 2 {
            if let (Some(lo), Some(hi)) = (numbers(&pair.at(0), false), numbers(&pair.at(1), false)) {
                if lo.len() == 3 && hi.len() == 3 {
                    return Some(bs::Aabb::new([lo[0], lo[1], lo[2]], [hi[0], hi[1], hi[2]]));
                }
            }
        }
    }
    match numbers(v, false) {
        Some(w) if w.len() == 6 => Some(bs::Aabb::new([w[0], w[1], w[2]], [w[3], w[4], w[5]])),
        _ => fail(format!("{what}: a box is a CadaclysmBox, [min, max] (two points) or six numbers, not {v}")),
    }
}

/// A list of 3D points: a `PackedVector3Array`, or an array of points (each a `Vector3` or
/// three numbers), the first that is not one refused by index under `what`.
fn rtree_points(v: &Variant, what: &str, name: &str) -> Option<Vec<[f64; 3]>> {
    match v.get_type() {
        VariantType::PACKED_VECTOR3_ARRAY => Some(v.to::<PackedVector3Array>().as_slice().iter().map(|p| {
            [f64::from(p.x), f64::from(p.y), f64::from(p.z)]
        }).collect()),
        VariantType::ARRAY => {
            let array = v.try_to::<AnyArray>().ok()?;
            array.iter_shared().enumerate().map(|(i, p)| v3(&p, &format!("{what}: {name} {i}"))).collect()
        }
        _ => fail(format!("{what}: expected a PackedVector3Array or an array of points, not {v}")),
    }
}

/// A mesh's triangles as three `u32` indices each: an array of triangles (each an array of
/// three ints), or a flat `PackedInt32Array` / `PackedInt64Array`, three indices a triangle
/// (the way `CadaclysmFemMesh.triangles` hands them out). The shape and an index outside 0 to
/// 4294967295 are refused here, by triangle; an index past the points is the kernel's.
fn rtree_triangles(v: &Variant) -> Option<Vec<[u32; 3]>> {
    const CALL: &str = "rtree_from_triangles";
    let flat = |list: Vec<i64>| -> Option<Vec<[u32; 3]>> {
        if list.len() % 3 != 0 {
            return fail(format!("{CALL}: {} indices are not whole triangles", list.len()));
        }
        list.chunks(3)
            .enumerate()
            .map(|(i, t)| {
                let what = format!("triangle {i}'s index");
                Some([rtree_u32(t[0], CALL, &what)?, rtree_u32(t[1], CALL, &what)?, rtree_u32(t[2], CALL, &what)?])
            })
            .collect()
    };
    match v.get_type() {
        VariantType::PACKED_INT32_ARRAY => flat(v.to::<PackedInt32Array>().as_slice().iter().map(|&x| i64::from(x)).collect()),
        VariantType::PACKED_INT64_ARRAY => flat(v.to::<PackedInt64Array>().as_slice().to_vec()),
        VariantType::ARRAY => {
            let array = v.try_to::<AnyArray>().ok()?;
            let mut out = Vec::with_capacity(array.len());
            for (i, item) in array.iter_shared().enumerate() {
                let corners = match item.try_to::<AnyArray>() {
                    Ok(t) if t.len() == 3 && t.iter_shared().all(|k| k.get_type() == VariantType::INT) => t,
                    _ => return fail(format!("{CALL}: triangle {i} is not 3 indices: {item}")),
                };
                let what = format!("triangle {i}'s index");
                let k = |n: usize| rtree_u32(corners.at(n).to::<i64>(), CALL, &what);
                out.push([k(0)?, k(1)?, k(2)?]);
            }
            Some(out)
        }
        _ => fail(format!("{CALL}: expected an array of triangles or a packed array of indices, not {v}")),
    }
}

/// The first hay point, then needle, with a coordinate that is not finite, refused by
/// index as the kernel's `closest_points` / `k_neighbors` refuse it.
fn rtree_finite(call: &str, hay: &[[f64; 3]], needles: &[[f64; 3]]) -> Option<()> {
    for (name, points) in [("hay", hay), ("needle", needles)] {
        if let Some(i) = points.iter().position(|p| !p.iter().all(|x| x.is_finite())) {
            return fail(format!("{call}: {name} point {i} is not finite"));
        }
    }
    Some(())
}

/// Each needle's indices as one `PackedInt64Array`, in an `Array`.
fn rtree_index_lists(lists: Vec<Vec<usize>>) -> Array<PackedInt64Array> {
    lists.into_iter().map(|ids| ids.into_iter().map(|i| i as i64).collect::<PackedInt64Array>()).collect()
}

/// `CadaclysmBlacksmith.closest_points`: the limit, then the points, checked in Python's order.
fn rtree_closest_points(hay: &Variant, needles: &Variant, limit: f64) -> Option<Array<PackedInt64Array>> {
    if limit.is_nan() || limit < 0.0 {
        return fail(format!("closest_points: limit {limit} is not a distance"));
    }
    let hay = rtree_points(hay, "closest_points", "hay point")?;
    let needles = rtree_points(needles, "closest_points", "needle point")?;
    ok(bs::closest_points(&hay, &needles, limit)).map(rtree_index_lists)
}

/// `CadaclysmBlacksmith.k_neighbors`: the points, then `k`, checked in Python's order.
fn rtree_k_neighbors(hay: &Variant, needles: &Variant, k: i64) -> Option<Array<PackedInt64Array>> {
    let hay = rtree_points(hay, "k_neighbors", "hay point")?;
    let needles = rtree_points(needles, "k_neighbors", "needle point")?;
    rtree_finite("k_neighbors", &hay, &needles)?;
    let k = rtree_u32(k, "k_neighbors", "k")?;
    ok(bs::k_neighbors(&hay, &needles, k)).map(rtree_index_lists)
}

/// One entry `CadaclysmRTree.within` or `nearest` found: its `id` and the `distance` from
/// the point asked to its box (0 inside the box).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmRTreeHit {
    hit: bs::RTreeHit,
    /// The entry's id.
    #[var(get = get_id, no_set)]
    id: PhantomVar<i64>,
    /// The distance from the point asked to the entry's box, 0 inside it.
    #[var(get = get_distance, no_set)]
    distance: PhantomVar<f64>,
}

impl CadaclysmRTreeHit {
    fn wrap_all(hits: Vec<bs::RTreeHit>) -> Array<Gd<CadaclysmRTreeHit>> {
        hits.into_iter()
            .map(|hit| Gd::from_object(CadaclysmRTreeHit { hit, id: PhantomVar::default(), distance: PhantomVar::default() }))
            .collect()
    }
}

#[godot_api]
impl IRefCounted for CadaclysmRTreeHit {
    fn to_string(&self) -> GString {
        gs(format!("RTreeHit(id={}, distance={})", self.hit.id, self.hit.distance))
    }
}

#[godot_api]
impl CadaclysmRTreeHit {
    /// The entry's id.
    #[func]
    fn get_id(&self) -> i64 {
        self.hit.id.into()
    }

    /// The distance from the point asked to the entry's box, 0 inside it.
    #[func]
    fn get_distance(&self) -> f64 {
        self.hit.distance
    }
}

/// One pair of entries `CadaclysmRTree.overlaps` or `self_overlaps` found: `a`'s id and
/// `b`'s (on `self_overlaps`, the smaller first).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmRTreePair {
    pair: bs::RTreePair,
    /// The first entry's id: this tree's, on `overlaps`.
    #[var(get = get_a, no_set)]
    a: PhantomVar<i64>,
    /// The second entry's id: the other tree's, on `overlaps`.
    #[var(get = get_b, no_set)]
    b: PhantomVar<i64>,
}

impl CadaclysmRTreePair {
    fn wrap_all(pairs: Vec<bs::RTreePair>) -> Array<Gd<CadaclysmRTreePair>> {
        pairs.into_iter()
            .map(|pair| Gd::from_object(CadaclysmRTreePair { pair, a: PhantomVar::default(), b: PhantomVar::default() }))
            .collect()
    }
}

#[godot_api]
impl IRefCounted for CadaclysmRTreePair {
    fn to_string(&self) -> GString {
        gs(format!("RTreePair(a={}, b={})", self.pair.a, self.pair.b))
    }
}

#[godot_api]
impl CadaclysmRTreePair {
    /// The first entry's id: this tree's, on `overlaps`.
    #[func]
    fn get_a(&self) -> i64 {
        self.pair.a.into()
    }

    /// The second entry's id: the other tree's, on `overlaps`.
    #[func]
    fn get_b(&self) -> i64 {
        self.pair.b.into()
    }
}

/// A spatial index over boxes with ids (an R*-tree): `search` a box for the entries it
/// meets, `within` / `nearest` a point for the closest (`CadaclysmRTreeHit`s),
/// `overlaps` / `self_overlaps` for every pair of boxes that meet (`CadaclysmRTreePair`s).
/// Ids are the caller's own (0 to 4294967295) and may repeat; the same `(id, box)` twice
/// is two entries. Touching boxes meet.
///
/// A box is a `CadaclysmBox`, `[min, max]` (two points) or six numbers; a point is a
/// `Vector3` or three numbers (`[1.5, 2.0, 0.0]` keeps a double's precision). Answers
/// come in a fixed order: `search` ids ascending, `within` / `nearest` by distance then id,
/// pairs ascending. The tree changes in place (`insert`, `remove`). A call that fails
/// answers empty, `false` or `null`, with the reason in `Cadaclysm.last_error()`.
/// `close()` frees the tree; so does the last reference going.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmRTree {
    tree: Option<bs::RTree>,
    /// The union of every entry's box, a `CadaclysmBox`, or `null` for an empty tree.
    #[var(get = get_bounds, no_set)]
    bounds: PhantomVar<Variant>,
    /// Whether `close` has freed the tree.
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
}

impl CadaclysmRTree {
    fn wrap(tree: bs::RTree) -> Gd<CadaclysmRTree> {
        Gd::from_object(CadaclysmRTree { tree: Some(tree), bounds: PhantomVar::default(), closed: PhantomVar::default() })
    }

    fn held(&self) -> Option<&bs::RTree> {
        match &self.tree {
            Some(tree) => Some(tree),
            None => fail("rtree: closed"),
        }
    }

    fn held_mut(&mut self) -> Option<&mut bs::RTree> {
        match &mut self.tree {
            Some(tree) => Some(tree),
            None => fail("rtree: closed"),
        }
    }
}

#[godot_api]
impl IRefCounted for CadaclysmRTree {
    fn to_string(&self) -> GString {
        match &self.tree {
            Some(tree) => gs(format!("RTree({} entries)", tree.len())),
            None => gs("RTree(closed)"),
        }
    }
}

#[godot_api]
impl CadaclysmRTree {
    /// An empty tree. (`new` is GDScript's own, as `CadaclysmFrame.create` is, so the
    /// constructor is `create`.)
    #[func]
    fn create() -> Option<Gd<CadaclysmRTree>> {
        ok(bs::RTree::new()).map(CadaclysmRTree::wrap)
    }

    /// A tree over `entries`, an array of `[id, box]` pairs, packed at once
    /// (sort-tile-recursive): fuller and faster to query than the same entries inserted one
    /// by one. `null` for an entry that is not a pair, an id out of range, or the first box
    /// that is not a box, by index, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn from_boxes(entries: AnyArray) -> Option<Gd<CadaclysmRTree>> {
        let mut items = Vec::with_capacity(entries.len());
        for (i, entry) in entries.iter_shared().enumerate() {
            let what = format!("rtree_from_boxes: entry {i}");
            let pair = match entry.try_to::<AnyArray>() {
                Ok(pair) if pair.len() == 2 && pair.at(0).get_type() == VariantType::INT => pair,
                _ => return fail(format!("{what} is not an [id, box] pair: {entry}")),
            };
            let id = rtree_u32(pair.at(0).to::<i64>(), &what, "id")?;
            items.push((id, rtree_box(&pair.at(1), &what)?));
        }
        ok(bs::RTree::from_boxes(&items)).map(CadaclysmRTree::wrap)
    }

    /// A tree over `points` (a `PackedVector3Array` or an array of points), each a zero box
    /// whose id is its index. `null` for the first point with a NaN or infinite coordinate,
    /// by index.
    #[func]
    fn from_points(points: Variant) -> Option<Gd<CadaclysmRTree>> {
        let points = rtree_points(&points, "rtree_from_points", "point")?;
        ok(bs::RTree::from_points(&points)).map(CadaclysmRTree::wrap)
    }

    /// A tree over a mesh's triangles -- RhinoCommon's `RTree.CreateMeshFaceTree`: one entry
    /// per triangle, its id the triangle's index and its box its three corners' box.
    /// `positions` is a `PackedVector3Array` or an array of points; `triangles` an array of
    /// triangles (each three ints into `positions`) or a flat `PackedInt32Array` /
    /// `PackedInt64Array`, three indices a triangle. `null` for a shape that is not one, an
    /// index outside 0 to 4294967295, or the first corner past the points or at a point with a
    /// NaN or infinite coordinate, by triangle and point (points no triangle uses are not
    /// checked), with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn from_triangles(positions: Variant, triangles: Variant) -> Option<Gd<CadaclysmRTree>> {
        let positions = rtree_points(&positions, "rtree_from_triangles", "point")?;
        let triangles = rtree_triangles(&triangles)?;
        ok(bs::RTree::from_triangles(&positions, &triangles)).map(CadaclysmRTree::wrap)
    }

    /// Free the tree now. Idempotent.
    #[func]
    fn close(&mut self) {
        self.tree = None;
    }

    /// Whether `close` has freed the tree.
    #[func]
    fn get_closed(&self) -> bool {
        self.tree.is_none()
    }

    /// How many entries the tree holds; 0 on a closed tree, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn count(&self) -> i64 {
        self.held().map_or(0, |t| {
            clear_error();
            t.len() as i64
        })
    }

    /// The union of every entry's box, a `CadaclysmBox`, or `null` for an empty tree (and a
    /// closed one, with the reason in `Cadaclysm.last_error()`).
    #[func]
    fn get_bounds(&self) -> Variant {
        match self.held().and_then(|t| ok(t.bounds())) {
            Some(Some(b)) => CadaclysmBox::wrap(b).to_variant(),
            _ => Variant::nil(),
        }
    }

    /// Add the entry `(id, box)`. `false` for an id out of range, or a box that is not a box,
    /// leaving the tree as it was.
    #[func]
    fn insert(&mut self, id: i64, box_: Variant) -> bool {
        let Some(id) = rtree_u32(id, "rtree_insert", "id") else { return false };
        let Some(b) = rtree_box(&box_, "rtree_insert") else { return false };
        self.held_mut().and_then(|t| ok(t.insert(id, &b))).is_some()
    }

    /// Add the entry `(id, point)`, the point (a `Vector3` or three numbers) a zero box.
    /// `false` for an id out of range or a point that is not finite.
    #[func]
    fn insert_point(&mut self, id: i64, point: Variant) -> bool {
        let Some(id) = rtree_u32(id, "rtree_insert_point", "id") else { return false };
        let Some(p) = v3(&point, "rtree_insert_point: point") else { return false };
        self.held_mut().and_then(|t| ok(t.insert_point(id, p))).is_some()
    }

    /// Take out one entry equal to `(id, box)` -- the box it was inserted with, compared
    /// coordinate by coordinate -- and say whether there was one: `false`, with
    /// `Cadaclysm.last_error()` empty, when there is none. With duplicates one goes per call.
    /// `false` with the reason there for an id out of range or a box that is not a box.
    #[func]
    fn remove(&mut self, id: i64, box_: Variant) -> bool {
        let Some(id) = rtree_u32(id, "rtree_remove", "id") else { return false };
        let Some(b) = rtree_box(&box_, "rtree_remove") else { return false };
        self.held_mut().and_then(|t| ok(t.remove(id, &b))).unwrap_or(false)
    }

    /// `remove` for an entry inserted with `insert_point`: the same point finds it.
    #[func]
    fn remove_point(&mut self, id: i64, point: Variant) -> bool {
        let Some(id) = rtree_u32(id, "rtree_remove", "id") else { return false };
        let Some(p) = v3(&point, "rtree_remove: point") else { return false };
        self.held_mut().and_then(|t| ok(t.remove_point(id, p))).unwrap_or(false)
    }

    /// The ids of every entry whose box meets `box_` (touching counts), ascending -- a
    /// repeated id as often as it was inserted. Empty for a box that is not a box, with the
    /// reason in `Cadaclysm.last_error()`.
    #[func]
    fn search(&self, box_: Variant) -> PackedInt64Array {
        let Some(b) = rtree_box(&box_, "rtree_search") else { return PackedInt64Array::new() };
        let ids = self.held().and_then(|t| ok(t.search(&b))).unwrap_or_default();
        ids.into_iter().map(i64::from).collect()
    }

    /// Every entry whose box is within `r` of `point` (0 inside the box; exactly `r`
    /// counts), as `CadaclysmRTreeHit`s by distance then id. Empty for a point not finite
    /// or an `r` negative or NaN, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn within(&self, point: Variant, r: f64) -> Array<Gd<CadaclysmRTreeHit>> {
        let Some(p) = v3(&point, "rtree_within: point") else { return Array::new() };
        CadaclysmRTreeHit::wrap_all(self.held().and_then(|t| ok(t.within(p, r))).unwrap_or_default())
    }

    /// The `k` entries whose boxes are nearest `point`, as `CadaclysmRTreeHit`s by distance
    /// then id (the smaller ids win a tie at the `k`-th place); every entry when `k` is over
    /// the count. Empty for a point not finite, or a `k` negative or above 1,000,000, with
    /// the reason in `Cadaclysm.last_error()`.
    #[func]
    fn nearest(&self, point: Variant, k: i64) -> Array<Gd<CadaclysmRTreeHit>> {
        let Some(p) = v3(&point, "rtree_nearest: point") else { return Array::new() };
        let Some(k) = rtree_u32(k, "rtree_nearest", "k") else { return Array::new() };
        CadaclysmRTreeHit::wrap_all(self.held().and_then(|t| ok(t.nearest(p, k))).unwrap_or_default())
    }

    /// Every entry whose box the ray `origin + t * direction`, `0 <= t <= max_t`, meets, as
    /// `CadaclysmRTreeHit`s by `t` then id, each hit's `distance` the `t` where the ray enters
    /// the box (0 when `origin` is inside it). Touching counts. `t` is in units of
    /// `direction`'s length, which is not normalised; `max_t` defaults to `INF`. The boxes are
    /// what is tested: for a triangle or a face, test the hits' own geometry. `origin` and
    /// `direction` are `Vector3`s or three numbers each. Empty for an origin or direction not
    /// finite, a zero direction, or a `max_t` negative or NaN, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn ray(&self, origin: Variant, direction: Variant, #[opt(default = f64::INFINITY)] max_t: f64) -> Array<Gd<CadaclysmRTreeHit>> {
        let Some(o) = v3(&origin, "rtree_ray: origin") else { return Array::new() };
        let Some(d) = v3(&direction, "rtree_ray: direction") else { return Array::new() };
        CadaclysmRTreeHit::wrap_all(self.held().and_then(|t| ok(t.ray(o, d, max_t))).unwrap_or_default())
    }

    /// Every pair `(a, b)`, `a` an entry of this tree and `b` one of `other` (this tree too,
    /// if it is), whose boxes are at most `slack` apart on every axis (0: touching), as
    /// `CadaclysmRTreePair`s, ascending. Empty for a `slack` negative or NaN, or a closed
    /// tree on either side, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn overlaps(&self, other: Gd<CadaclysmRTree>, #[opt(default = 0.0)] slack: f64) -> Array<Gd<CadaclysmRTreePair>> {
        let Some(tree) = self.held() else { return Array::new() };
        let other = other.bind();
        let Some(theirs) = other.held() else { return Array::new() };
        CadaclysmRTreePair::wrap_all(ok(tree.overlaps(theirs, slack)).unwrap_or_default())
    }

    /// Every unordered pair of distinct entries at most `slack` apart on every axis, once
    /// each as a `CadaclysmRTreePair` `(smaller id, larger id)`, ascending -- an id pairs
    /// with itself only where two entries share it. Empty for a `slack` negative or NaN.
    #[func]
    fn self_overlaps(&self, #[opt(default = 0.0)] slack: f64) -> Array<Gd<CadaclysmRTreePair>> {
        CadaclysmRTreePair::wrap_all(self.held().and_then(|t| ok(t.self_overlaps(slack))).unwrap_or_default())
    }
}

// ---- CadaclysmInterpolator ---------------------------------------------------------------

/// A mode from GDScript's `int` (a `CadaclysmInterpolator.MODE_*`) as the kernel's, refused by
/// `call`'s name outside 0 to 4 -- before any call, as the C library refuses it.
fn interpolator_mode(mode: i64, call: &str) -> Option<bs::InterpolatorMode> {
    match mode {
        0 => Some(bs::InterpolatorMode::Nearest),
        1 => Some(bs::InterpolatorMode::Linear),
        2 => Some(bs::InterpolatorMode::Cosine),
        3 => Some(bs::InterpolatorMode::Cubic),
        4 => Some(bs::InterpolatorMode::CatmullRom),
        _ => fail(format!("{call}: mode {mode} is not a mode")),
    }
}

/// A list of samples read at a fractional index, as Rhino's `Interpolator`: `t = 2` is sample
/// 2, `t = 2.5` halfway between samples 2 and 3. Animation keys, a value along a pattern, a
/// smoothed profile of measurements.
///
/// `create` takes the samples as one `PackedFloat64Array` of `dimension` numbers a sample --
/// numbers (dimension 1), 2D or 3D points, or vectors of any dimension, each component read on
/// its own -- and every value comes back as a `PackedFloat64Array` of `dimension` numbers. An
/// open list clamps `t` to `[0, count() - 1]` and stops on its end samples; a cyclic one wraps
/// `t` with period `count()` (`t = -0.5` is halfway between the last sample and the first).
///
/// The five modes are the `MODE_*` constants, Paul Bourke's formulas; every mode returns the
/// sample itself at a whole `t`. It never changes once made. A call that fails answers empty
/// (or `null`), with the reason in `Cadaclysm.last_error()`. `close()` frees it; so does the
/// last reference going.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmInterpolator {
    interpolator: Option<bs::Interpolator>,
    /// How many numbers a sample holds, and so every value read.
    #[var(get = get_dimension, no_set)]
    dimension: PhantomVar<i64>,
    /// Whether `t` wraps round the list (else it is clamped to the first and last samples).
    #[var(get = get_cyclic, no_set)]
    cyclic: PhantomVar<bool>,
}

impl CadaclysmInterpolator {
    fn wrap(interpolator: bs::Interpolator) -> Gd<CadaclysmInterpolator> {
        Gd::from_object(CadaclysmInterpolator { interpolator: Some(interpolator), dimension: PhantomVar::default(), cyclic: PhantomVar::default() })
    }

    fn held(&self) -> Option<&bs::Interpolator> {
        match &self.interpolator {
            Some(interpolator) => Some(interpolator),
            None => fail("interpolator: closed"),
        }
    }

    /// The value at `t` by `mode` (checked first), empty on a refusal.
    fn read(&self, t: f64, mode: i64) -> PackedFloat64Array {
        let Some(interpolator) = self.held() else { return PackedFloat64Array::new() };
        let Some(mode) = interpolator_mode(mode, "interpolator_at") else { return PackedFloat64Array::new() };
        ok(interpolator.at(t, mode)).map(|v| PackedFloat64Array::from(v.as_slice())).unwrap_or_default()
    }
}

#[godot_api]
impl IRefCounted for CadaclysmInterpolator {
    fn to_string(&self) -> GString {
        match &self.interpolator {
            Some(interpolator) => gs(format!("{interpolator:?}")),
            None => gs("Interpolator(closed)"),
        }
    }
}

#[godot_api]
impl CadaclysmInterpolator {
    /// The sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap.
    #[constant]
    const MODE_NEAREST: i64 = 0;
    /// Straight between the samples either side of `t`: `y1 + (y2 - y1) mu`. The default.
    #[constant]
    const MODE_LINEAR: i64 = 1;
    /// Linear at `(1 - cos(pi mu)) / 2` instead of `mu`: an ease, flat at every sample.
    #[constant]
    const MODE_COSINE: i64 = 2;
    /// Bourke's cubic over the four samples about `t`: through every sample, not C1.
    #[constant]
    const MODE_CUBIC: i64 = 3;
    /// The Catmull-Rom spline over the four samples about `t`: through every sample, C1.
    #[constant]
    const MODE_CATMULL_ROM: i64 = 4;

    /// An interpolator over `samples`, `dimension` numbers a sample (1: numbers); `cyclic`
    /// wraps `t` round the list, else it is clamped to the first and last samples. (`new` is
    /// GDScript's own, as `CadaclysmFrame.create` is, so the constructor is `create`.) `null`
    /// for a count of numbers that is not whole samples (`interpolator: samples differ in
    /// length`) or a `dimension` outside 0 to 4294967295, both before the call, then for no
    /// samples, a dimension of 0 or a sample NaN or infinite (by its index), with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn create(samples: PackedFloat64Array, #[opt(default = 1)] dimension: i64, #[opt(default = false)] cyclic: bool) -> Option<Gd<CadaclysmInterpolator>> {
        let flat = samples.as_slice();
        let made = match dimension {
            1 => bs::Interpolator::new(flat, cyclic),
            // No numbers a sample: the kernel's own words refuse it.
            0 => bs::Interpolator::rows::<&[f64]>(&[&[]], cyclic),
            _ => {
                let d = match usize::try_from(dimension) {
                    Ok(d) if u32::try_from(d).is_ok() => d,
                    _ => return fail(format!("interpolator_new: dimension is out of range: {dimension}")),
                };
                if flat.len() % d != 0 {
                    return fail(format!("interpolator: samples differ in length: {} numbers are not whole samples of {d}", flat.len()));
                }
                bs::Interpolator::rows(&flat.chunks_exact(d).collect::<Vec<&[f64]>>(), cyclic)
            }
        };
        ok(made).map(CadaclysmInterpolator::wrap)
    }

    /// Free the handle now. Idempotent; a call after it refuses (`interpolator: closed`).
    #[func]
    fn close(&mut self) {
        self.interpolator = None;
    }

    /// How many samples it holds -- Python's `len(interpolator)`; 0 on a closed one, with the
    /// reason in `Cadaclysm.last_error()`.
    #[func]
    fn count(&self) -> i64 {
        self.held().map_or(0, |i| {
            clear_error();
            i.len() as i64
        })
    }

    /// How many numbers a sample holds, and so every value read; 0 on a closed one.
    #[func]
    fn get_dimension(&self) -> i64 {
        self.held().map_or(0, |i| {
            clear_error();
            i.dimension() as i64
        })
    }

    /// Whether `t` wraps round the list (else it is clamped to the first and last samples).
    #[func]
    fn get_cyclic(&self) -> bool {
        self.held().is_some_and(|i| {
            clear_error();
            i.cyclic()
        })
    }

    /// The value at the fractional index `t` by `mode` (a `MODE_*`, `MODE_LINEAR` by default),
    /// a `PackedFloat64Array` of `dimension` numbers. Empty for a mode outside 0 to 4 (before
    /// the call) or a `t` NaN or infinite, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn at(&self, t: f64, #[opt(default = 1)] mode: i64) -> PackedFloat64Array {
        self.read(t, mode)
    }

    /// The values at every `t` of `ts` by `mode`, as `at` reads each, in one call: one
    /// `PackedFloat64Array` of `dimension` numbers a `t`. Empty for no `ts`, and for a mode
    /// outside 0 to 4 (before the call), a value of `t` NaN or infinite (by its index) or more
    /// than 1,000,000 of them, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn sample(&self, ts: PackedFloat64Array, #[opt(default = 1)] mode: i64) -> Array<PackedFloat64Array> {
        let Some(interpolator) = self.held() else { return Array::new() };
        let Some(mode) = interpolator_mode(mode, "interpolator_sample") else { return Array::new() };
        let values = ok(interpolator.sample(ts.as_slice(), mode)).unwrap_or_default();
        values.iter().map(|v| PackedFloat64Array::from(v.as_slice())).collect()
    }

    /// `at(t, MODE_NEAREST)`: the sample at `floor(t + 1/2)` (a half rounds up).
    #[func]
    fn nearest(&self, t: f64) -> PackedFloat64Array {
        self.read(t, Self::MODE_NEAREST)
    }

    /// `at(t, MODE_LINEAR)`: straight between the two samples either side of `t`.
    #[func]
    fn linear(&self, t: f64) -> PackedFloat64Array {
        self.read(t, Self::MODE_LINEAR)
    }

    /// `at(t, MODE_COSINE)`: between the two samples either side of `t` on a cosine ease.
    #[func]
    fn cosine(&self, t: f64) -> PackedFloat64Array {
        self.read(t, Self::MODE_COSINE)
    }

    /// `at(t, MODE_CUBIC)`: Bourke's cubic over the four samples about `t`.
    #[func]
    fn cubic(&self, t: f64) -> PackedFloat64Array {
        self.read(t, Self::MODE_CUBIC)
    }

    /// `at(t, MODE_CATMULL_ROM)`: the Catmull-Rom spline over the four samples about `t`.
    #[func]
    fn catmull_rom(&self, t: f64) -> PackedFloat64Array {
        self.read(t, Self::MODE_CATMULL_ROM)
    }
}

// ---- CadaclysmRegion and CadaclysmFaceSide -----------------------------------------------

/// One side of one face, as a `CadaclysmRegion` lists its sides: `face` the face's index in
/// the solid, `sense` +1 for the side its normal points to, -1 for the other. A solid's inside
/// is behind its faces, at -1. Python's `FaceSide`.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmFaceSide {
    side: bs::FaceSide,
    /// The face's index in the solid.
    #[var(get = get_face, no_set)]
    face: PhantomVar<i64>,
    /// +1 for the side the face's normal points to, -1 for the other.
    #[var(get = get_sense, no_set)]
    sense: PhantomVar<i64>,
}

#[godot_api]
impl IRefCounted for CadaclysmFaceSide {
    fn to_string(&self) -> GString {
        gs(format!("FaceSide(face={}, sense={})", self.side.face, self.side.sense))
    }
}

#[godot_api]
impl CadaclysmFaceSide {
    /// The face's index in the solid.
    #[func]
    fn get_face(&self) -> i64 {
        self.side.face.into()
    }

    /// +1 for the side the face's normal points to, -1 for the other.
    #[func]
    fn get_sense(&self) -> i64 {
        self.side.sense.into()
    }
}

/// One region of space a solid's faces bound, as `CadaclysmSolid.regions` lists them: its
/// `index` (0 the infinite region, whose `finite` is false), the `box` round the faces bounding
/// it, its `sides` (`CadaclysmFaceSide`s ascending by face then sense) and its `shells` -- 1,
/// plus one per void inside it. `CadaclysmSolid.region_solid` takes a finite one as a solid of
/// its own. Python's `Region`.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmRegion {
    region: bs::Region,
    /// Its index in `CadaclysmSolid.regions`: 0 for the infinite region.
    #[var(get = get_index, no_set)]
    index: PhantomVar<i64>,
    /// `false` for region 0, the one reaching to infinity; `true` for every other.
    #[var(get = get_finite, no_set)]
    finite: PhantomVar<bool>,
    /// The `CadaclysmBox` round the faces bounding it.
    #[var(rename = box, get = get_box, no_set)]
    box_: PhantomVar<Gd<CadaclysmBox>>,
    /// Every face side bounding it, ascending by face and then sense (-1 first).
    #[var(get = get_sides, no_set)]
    sides: PhantomVar<Array<Gd<CadaclysmFaceSide>>>,
    /// How many connected boundaries it has: 1, plus one per void inside it.
    #[var(get = get_shells, no_set)]
    shells: PhantomVar<i64>,
}

impl CadaclysmRegion {
    fn wrap_all(regions: Vec<bs::Region>) -> Array<Gd<CadaclysmRegion>> {
        regions
            .into_iter()
            .map(|region| {
                Gd::from_object(CadaclysmRegion {
                    region,
                    index: PhantomVar::default(),
                    finite: PhantomVar::default(),
                    box_: PhantomVar::default(),
                    sides: PhantomVar::default(),
                    shells: PhantomVar::default(),
                })
            })
            .collect()
    }
}

#[godot_api]
impl IRefCounted for CadaclysmRegion {
    fn to_string(&self) -> GString {
        let r = &self.region;
        gs(format!("Region(index={}, finite={}, sides={}, shells={})", r.index, r.finite, r.sides.len(), r.shells))
    }
}

#[godot_api]
impl CadaclysmRegion {
    /// Its index in `CadaclysmSolid.regions`: 0 for the infinite region.
    #[func]
    fn get_index(&self) -> i64 {
        self.region.index.into()
    }

    /// `false` for region 0, the one reaching to infinity; `true` for every other.
    #[func]
    fn get_finite(&self) -> bool {
        self.region.finite
    }

    /// The `CadaclysmBox` round the faces bounding it.
    #[func]
    fn get_box(&self) -> Gd<CadaclysmBox> {
        CadaclysmBox::wrap(self.region.bounds)
    }

    /// Every face side bounding it, as `CadaclysmFaceSide`s, ascending by face and then sense
    /// (-1 first).
    #[func]
    fn get_sides(&self) -> Array<Gd<CadaclysmFaceSide>> {
        self.region
            .sides
            .iter()
            .map(|&side| Gd::from_object(CadaclysmFaceSide { side, face: PhantomVar::default(), sense: PhantomVar::default() }))
            .collect()
    }

    /// How many connected boundaries it has: 1, plus one per void inside it.
    #[func]
    fn get_shells(&self) -> i64 {
        self.region.shells.into()
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

// ---- CadaclysmHistory --------------------------------------------------------------------

/// An origin `(operand, id)` as GDScript reads it: `[operand, id]`.
fn origin_pair((operand, id): bs::Origin) -> VarArray {
    varray![i64::from(operand), id as i64]
}

/// Ids as an `Array` of ints. Ids count up from 1 per solid, so they never reach
/// `i64::MAX`.
fn id_list(ids: &[u64]) -> VarArray {
    ids.iter().map(|&id| (id as i64).to_variant()).collect()
}

/// What a verb did to its inputs' faces (or edges): what `CadaclysmSolid.history` and
/// `edge_history` return, read off the result's ids and origins alone. An input face is
/// `[operand, id]`: the operand its input's index in the verb's operand order (a boolean's
/// target 0, its tool 1), the id its `face_id`. Each list is in `[operand, id]` order,
/// `generated` in id order. Read whole when made; the kernel's handle is already freed.
///
/// ```gdscript
/// var block := CadaclysmSolid.cuboid(10, 10, 10).tracked()
/// var pin := CadaclysmSolid.cylinder(2, 20).translate(0, 0, -10).tracked()
/// var h := block.cut(pin).history([block, pin])
/// print(h.deleted)   # the pin's two caps, [1, id] each
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmHistory {
    history: bs::History,
    /// The inputs that became exactly one output and kept their id, each
    /// `[[operand, id], output id]`.
    #[var(get = get_kept, no_set)]
    kept: PhantomVar<VarArray>,
    /// The inputs split (several outputs name them), merged (their output has other origins
    /// too) or renumbered (a cut's bore, a later operand's clashing id), each
    /// `[[operand, id], [output ids]]`; a split's first piece, which keeps the id, first.
    #[var(get = get_modified, no_set)]
    modified: PhantomVar<VarArray>,
    /// The outputs with no origin (a fillet's round, the faces a split cuts), in id order.
    #[var(get = get_generated, no_set)]
    generated: PhantomVar<VarArray>,
    /// The inputs no output names (a cut tool's caps), each `[operand, id]`.
    #[var(get = get_deleted, no_set)]
    deleted: PhantomVar<VarArray>,
}

impl CadaclysmHistory {
    fn wrap(history: bs::History) -> Gd<CadaclysmHistory> {
        Gd::from_object(CadaclysmHistory {
            history,
            kept: PhantomVar::default(),
            modified: PhantomVar::default(),
            generated: PhantomVar::default(),
            deleted: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmHistory {
    fn to_string(&self) -> GString {
        let h = &self.history;
        gs(format!(
            "History(kept={}, modified={}, generated={}, deleted={})",
            h.kept.len(),
            h.modified.len(),
            h.generated.len(),
            h.deleted.len()
        ))
    }
}

#[godot_api]
impl CadaclysmHistory {
    /// The inputs kept, each `[[operand, id], output id]`; a copy at every ask.
    #[func]
    fn get_kept(&self) -> VarArray {
        self.history.kept.iter().map(|&(o, out)| varray![&origin_pair(o), out as i64].to_variant()).collect()
    }

    /// The inputs modified, each `[[operand, id], [output ids]]`; a copy at every ask.
    #[func]
    fn get_modified(&self) -> VarArray {
        self.history.modified.iter().map(|(o, outs)| varray![&origin_pair(*o), &id_list(outs)].to_variant()).collect()
    }

    /// The outputs generated, by id; a copy at every ask.
    #[func]
    fn get_generated(&self) -> VarArray {
        id_list(&self.history.generated)
    }

    /// The inputs deleted, each `[operand, id]`; a copy at every ask.
    #[func]
    fn get_deleted(&self) -> VarArray {
        self.history.deleted.iter().map(|&o| origin_pair(o).to_variant()).collect()
    }
}

// ---- CadaclysmNurbsCurve, CadaclysmCurvature and the sheet records ---------------------------

/// An optional vector: an empty `PackedFloat64Array` (the default) is none, three numbers
/// are one.
fn optional_v3(v: &PackedFloat64Array, what: &str) -> Option<Option<[f64; 3]>> {
    match v.as_slice() {
        [] => Some(None),
        [x, y, z] => Some(Some([*x, *y, *z])),
        other => fail(format!("{what}: expected 3 numbers or none, got {}", other.len())),
    }
}

/// An optional number: `NAN` (the default) is none.
fn optional_number(x: f64) -> Option<f64> {
    (!x.is_nan()).then_some(x)
}

/// A side of a sheet's face, `"u0"`, `"u1"`, `"v0"` or `"v1"`, refused in Python's words.
fn sheet_side(side: &GString) -> Option<bs::SheetSide> {
    ok(side.to_string().parse::<bs::SheetSide>())
}

/// An edge argument: a `CadaclysmEdge` or its index.
fn edge_arg(v: &Variant, what: &str) -> Option<u32> {
    if v.get_type() == VariantType::INT {
        return index(v.to::<i64>(), what);
    }
    match v.try_to::<Gd<CadaclysmEdge>>() {
        Ok(edge) => Some(edge.bind().edge.index),
        Err(_) => fail(format!("{what}: expected an int or a CadaclysmEdge, not {v}")),
    }
}

/// `f` on the curves `list` holds (`CadaclysmNurbsCurve`s), borrowed for the call.
fn with_curves<R>(list: &AnyArray, what: &str, f: impl FnOnce(&[&bs::NurbsCurve]) -> Option<R>) -> Option<R> {
    let curves = object_list::<CadaclysmNurbsCurve>(list, what)?;
    let guards: Vec<GdRef<CadaclysmNurbsCurve>> = curves.iter().map(|c| c.bind()).collect();
    let refs: Vec<&bs::NurbsCurve> = guards.iter().map(|g| &g.curve).collect();
    f(&refs)
}

/// Points as the curve hands them back: three doubles each, in a row.
fn flat_triples(points: &[[f64; 3]]) -> PackedFloat64Array {
    points.iter().flatten().copied().collect()
}

/// A curve in space to model with -- always a NURBS, so a line, an arc or a conic is an exact
/// rational one: built from its control points (`create`), through points, fitted, read off an
/// edge or a face, projected onto a plane or a face, trimmed, extended and blended; asked for its
/// points, derivatives, curvature, length and crossings. Immutable: every edit returns a new
/// curve, or `null` with the reason in `Cadaclysm.last_error()`. Not `CadaclysmCurve`, the plain
/// data an edge's curve is copied out as.
///
/// The curve keeps the kernel's doubles: a point is a `PackedFloat64Array` of three, and the
/// control points are three doubles each in a row, as `CadaclysmCurve.poles`. A point or a
/// direction argument is a `Vector3` or three numbers (an array keeps a double's precision); an
/// optional one is a `PackedFloat64Array`, empty for none. A face here is its whole surface:
/// projecting onto, pulling to and crossing a face ignore its trims.
///
/// ```gdscript
/// var arc := CadaclysmNurbsCurve.create([[2, 0, 0], [2, 2, 0], [0, 2, 0]], 2, PackedFloat64Array([1, sqrt(0.5), 1]))
/// print(arc.length().length)   # PI
/// ```
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmNurbsCurve {
    curve: bs::NurbsCurve,
    /// The curve's degree.
    #[var(get = get_degree, no_set)]
    degree: PhantomVar<i64>,
    /// The control points, three doubles each in a row.
    #[var(get = get_control_points, no_set)]
    control_points: PhantomVar<PackedFloat64Array>,
    /// One weight per control point; all 1 for a plain B-spline.
    #[var(get = get_weights, no_set)]
    weights: PhantomVar<PackedFloat64Array>,
    /// The full knot vector: the control-point count + `degree` + 1 values.
    #[var(get = get_knots, no_set)]
    knots: PhantomVar<PackedFloat64Array>,
    /// The parameter domain, `[lo, hi]`.
    #[var(get = get_domain, no_set)]
    domain: PhantomVar<PackedFloat64Array>,
    /// Whether the weights differ: a true NURBS rather than a plain B-spline.
    #[var(get = get_is_rational, no_set)]
    is_rational: PhantomVar<bool>,
    /// Whether the curve ends where it starts.
    #[var(get = get_is_closed, no_set)]
    is_closed: PhantomVar<bool>,
    /// On a curve from `fit`, `projected_to_face` or `pulled_to_face`, the largest distance
    /// found between it and what it was fitted to; `null` on any other.
    #[var(get = get_fit_error, no_set)]
    fit_error: PhantomVar<Variant>,
}

impl CadaclysmNurbsCurve {
    fn wrap(curve: bs::NurbsCurve) -> Gd<CadaclysmNurbsCurve> {
        Gd::from_object(CadaclysmNurbsCurve {
            curve,
            degree: PhantomVar::default(),
            control_points: PhantomVar::default(),
            weights: PhantomVar::default(),
            knots: PhantomVar::default(),
            domain: PhantomVar::default(),
            is_rational: PhantomVar::default(),
            is_closed: PhantomVar::default(),
            fit_error: PhantomVar::default(),
        })
    }

    fn made(result: sdk::Result<bs::NurbsCurve>) -> Option<Gd<CadaclysmNurbsCurve>> {
        ok(result).map(CadaclysmNurbsCurve::wrap)
    }

    /// `f` on this curve, its result wrapped.
    fn then(&self, f: impl FnOnce(&bs::NurbsCurve) -> sdk::Result<bs::NurbsCurve>) -> Option<Gd<CadaclysmNurbsCurve>> {
        Self::made(f(&self.curve))
    }

    fn many(result: Option<sdk::Result<Vec<bs::NurbsCurve>>>) -> Array<Gd<CadaclysmNurbsCurve>> {
        result.and_then(ok).unwrap_or_default().into_iter().map(CadaclysmNurbsCurve::wrap).collect()
    }

    fn samples(result: Option<sdk::Result<Vec<bs::At>>>) -> Array<Gd<CadaclysmAt>> {
        CadaclysmAt::wrap_all(result.and_then(ok).unwrap_or_default())
    }
}

#[godot_api]
impl IRefCounted for CadaclysmNurbsCurve {
    fn to_string(&self) -> GString {
        let c = &self.curve;
        let points = c.control_points().map_or(0, |p| p.len());
        gs(format!("NurbsCurve(degree={}, control_points={points}, rational={}, closed={})", c.degree(), c.is_rational(), c.is_closed()))
    }
}

#[godot_api]
impl CadaclysmNurbsCurve {
    // -- building

    /// The curve with control points `points` (a `PackedVector3Array` or an array of points),
    /// of `degree` (1 to 7), `weights` one per point (positive; empty for a plain B-spline) and
    /// the full knot vector `knots` (non-decreasing; empty for clamped and uniform). (`new` is
    /// GDScript's own, so this is `create`.)
    #[func]
    fn create(
        points: Variant,
        #[opt(default = 3)] degree: i64,
        #[opt(default = &PackedFloat64Array::new())] weights: PackedFloat64Array,
        #[opt(default = &PackedFloat64Array::new())] knots: PackedFloat64Array,
    ) -> Option<Gd<CadaclysmNurbsCurve>> {
        let points = point_list(&points, "nurbs_curve_new")?;
        let degree = index(degree, "nurbs_curve_new: degree")?;
        let weights = (!weights.is_empty()).then(|| weights.as_slice().to_vec());
        let knots = (!knots.is_empty()).then(|| knots.as_slice().to_vec());
        Self::made(bs::NurbsCurve::new(&points, degree, weights.as_deref(), knots.as_deref()))
    }

    /// The curve of `degree` through `points` in order, chord-length parametrised. `closed`
    /// closes it back to the first point, smooth across the seam; an open curve may leave along
    /// `start_tangent` and arrive along `end_tangent` (three numbers each, empty for none; their
    /// length does not matter).
    #[func]
    fn through(
        points: Variant,
        #[opt(default = 3)] degree: i64,
        #[opt(default = false)] closed: bool,
        #[opt(default = &PackedFloat64Array::new())] start_tangent: PackedFloat64Array,
        #[opt(default = &PackedFloat64Array::new())] end_tangent: PackedFloat64Array,
    ) -> Option<Gd<CadaclysmNurbsCurve>> {
        let points = point_list(&points, "nurbs_curve_through")?;
        let degree = index(degree, "nurbs_curve_through: degree")?;
        let start = optional_v3(&start_tangent, "nurbs_curve_through: start_tangent")?;
        let end = optional_v3(&end_tangent, "nurbs_curve_through: end_tangent")?;
        Self::made(bs::NurbsCurve::through(&points, degree, closed, start, end))
    }

    /// A curve of `degree` within `tolerance` of every point, through the first and the last
    /// (least squares); its `fit_error` is the largest distance from a point to it.
    #[func]
    fn fit(points: Variant, #[opt(default = 3)] degree: i64, #[opt(default = 1e-3)] tolerance: f64) -> Option<Gd<CadaclysmNurbsCurve>> {
        let points = point_list(&points, "nurbs_curve_fit")?;
        let degree = index(degree, "nurbs_curve_fit: degree")?;
        Self::made(bs::NurbsCurve::fit(&points, degree, Some(tolerance)))
    }

    /// Edge `edge` of `solid` (a `CadaclysmEdge` or its index) as an exact NURBS over the
    /// edge's own span of its curve, running the way the edge runs.
    #[func]
    fn from_edge(solid: Gd<CadaclysmSolid>, edge: Variant) -> Option<Gd<CadaclysmNurbsCurve>> {
        let edge = edge_arg(&edge, "nurbs_curve_from_edge: edge")?;
        let solid = solid.bind();
        Self::made(bs::NurbsCurve::from_edge(solid.held()?, edge))
    }

    /// The isocurve of face `face` of `solid`'s surface: along `u` at `v = at` when `along_u`,
    /// else along `v` at `u = at`. NURBS faces only.
    #[func]
    fn isocurve(solid: Gd<CadaclysmSolid>, face: i64, along_u: bool, at: f64) -> Option<Gd<CadaclysmNurbsCurve>> {
        let face = index(face, "nurbs_curve_from_face_isocurve: face")?;
        let solid = solid.bind();
        Self::made(bs::NurbsCurve::isocurve(solid.held()?, face, along_u, at))
    }

    /// The curve bridging `a` (at its end when `a_end`, else its start) to `b` (at its end when
    /// `b_end`, else its start): `continuity` 1 matches position and tangent (a cubic), 2 also
    /// the curvature (a quintic); `bulge` (positive) scales how far the tangents reach.
    #[func]
    fn blend(
        a: Gd<CadaclysmNurbsCurve>,
        a_end: bool,
        b: Gd<CadaclysmNurbsCurve>,
        b_end: bool,
        #[opt(default = 2)] continuity: i64,
        #[opt(default = 1.0)] bulge: f64,
    ) -> Option<Gd<CadaclysmNurbsCurve>> {
        let continuity = index(continuity, "nurbs_curve_blend: continuity")?;
        Self::made(bs::NurbsCurve::blend(&a.bind().curve, a_end, &b.bind().curve, b_end, continuity, bulge))
    }

    /// `curves` (an array of `CadaclysmNurbsCurve`s) joined end to end into one curve: in the
    /// order given, each turned where needed so its start meets the previous one's end within
    /// `tolerance`, all raised to the highest degree among them, each over `k..k + 1`, joined
    /// C0. No curves, or a gap past `tolerance`, is refused naming the two curves.
    #[func]
    fn joined(curves: AnyArray, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmNurbsCurve>> {
        with_curves(&curves, "nurbs_curve_joined: curves", |list| Self::made(bs::NurbsCurve::joined(list, tolerance)))
    }

    /// `count` curves blending evenly from this curve to `other`, the `i`-th at the fraction
    /// `(i + 1) / (count + 1)`, as an array. `method` is `"plain"`, `"matching"` or
    /// `"sampling"`; `samples` (0 for none) is required by sampling and refused by the others.
    /// `align` lines `other` up with this curve first. `tolerance` 0: the curves' effective
    /// tolerance. Empty on failure, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn tween(
        &self,
        other: Gd<CadaclysmNurbsCurve>,
        count: i64,
        #[opt(default = "matching")] method: GString,
        #[opt(default = 0)] samples: i64,
        #[opt(default = true)] align: bool,
        #[opt(default = 0.0)] tolerance: f64,
    ) -> Array<Gd<CadaclysmNurbsCurve>> {
        let found = (|| {
            let method = ok(bs::TweenMethod::parse(&method.to_string()))?;
            let count = index(count, "nurbs_curve_tween: count")?;
            let samples = match samples {
                0 => None,
                n => Some(index(n, "nurbs_curve_tween: samples")?),
            };
            Some(self.curve.tween(&other.bind().curve, count, method, samples, align, Some(tolerance)))
        })();
        Self::many(found)
    }

    // -- edits

    /// This curve projected onto the plane through `origin` with `normal`, along `direction`
    /// (empty: the normal). Exact.
    #[func]
    fn projected_to_plane(
        &self,
        origin: Variant,
        normal: Variant,
        #[opt(default = &PackedFloat64Array::new())] direction: PackedFloat64Array,
    ) -> Option<Gd<CadaclysmNurbsCurve>> {
        let origin = at(&origin, "nurbs_curve_projected_to_plane")?;
        let normal = at(&normal, "nurbs_curve_projected_to_plane")?;
        let direction = optional_v3(&direction, "nurbs_curve_projected_to_plane: direction")?;
        self.then(|c| c.projected_to_plane(origin, normal, direction))
    }

    /// This curve projected along `direction` onto face `face` of `solid` (its whole surface),
    /// fitted within `tolerance`; the result's `fit_error` says how close.
    #[func]
    fn projected_to_face(
        &self,
        solid: Gd<CadaclysmSolid>,
        face: i64,
        direction: Variant,
        #[opt(default = 1e-3)] tolerance: f64,
    ) -> Option<Gd<CadaclysmNurbsCurve>> {
        let face = index(face, "nurbs_curve_projected_to_face: face")?;
        let direction = at(&direction, "nurbs_curve_projected_to_face")?;
        let solid = solid.bind();
        let held = solid.held()?;
        self.then(|c| c.projected_to_face(held, face, direction, Some(tolerance)))
    }

    /// This curve pulled onto face `face` of `solid` (its whole surface): every point to its
    /// nearest surface point, fitted within `tolerance` (`fit_error` as for the projection).
    #[func]
    fn pulled_to_face(&self, solid: Gd<CadaclysmSolid>, face: i64, #[opt(default = 1e-3)] tolerance: f64) -> Option<Gd<CadaclysmNurbsCurve>> {
        let face = index(face, "nurbs_curve_pulled_to_face: face")?;
        let solid = solid.bind();
        let held = solid.held()?;
        self.then(|c| c.pulled_to_face(held, face, Some(tolerance)))
    }

    /// The same curve run the other way over the same domain.
    #[func]
    fn reversed(&self) -> Option<Gd<CadaclysmNurbsCurve>> {
        self.then(|c| c.reversed())
    }

    /// The part from `t0` to `t1` (`t0 < t1`, both inside the domain), over `t0..t1`.
    #[func]
    fn trimmed(&self, t0: f64, t1: f64) -> Option<Gd<CadaclysmNurbsCurve>> {
        self.then(|c| c.trimmed(t0, t1))
    }

    /// This curve continued `length` past its end (or its start when `at_start`) along its own
    /// end polynomial; every old parameter keeps its old point.
    #[func]
    fn extended(&self, length: f64, #[opt(default = false)] at_start: bool) -> Option<Gd<CadaclysmNurbsCurve>> {
        self.then(|c| c.extended(length, at_start))
    }

    /// The same curve at degree `degree + by` (at most 12).
    #[func]
    fn elevated(&self, #[opt(default = 1)] by: i64) -> Option<Gd<CadaclysmNurbsCurve>> {
        let by = index(by, "nurbs_curve_elevated: by")?;
        self.then(|c| c.elevated(by))
    }

    /// This curve through the affine map `t` (a `CadaclysmTransform`, or 16 numbers
    /// row-major): its control points mapped, weights and knots kept -- exact.
    #[func]
    fn transformed(&self, t: Variant) -> Option<Gd<CadaclysmNurbsCurve>> {
        let t = transform_arg(&t, "nurbs_curve_transformed")?;
        self.then(|c| c.transformed(&t))
    }

    // -- reading

    /// The curve's degree.
    #[func]
    fn get_degree(&self) -> i64 {
        self.curve.degree().into()
    }

    /// The control points, three doubles each in a row.
    #[func]
    fn get_control_points(&self) -> PackedFloat64Array {
        ok(self.curve.control_points()).map_or_else(PackedFloat64Array::new, |p| flat_triples(&p))
    }

    /// One weight per control point; all 1 for a plain B-spline.
    #[func]
    fn get_weights(&self) -> PackedFloat64Array {
        ok(self.curve.weights()).map_or_else(PackedFloat64Array::new, |w| doubles(&w))
    }

    /// The full knot vector.
    #[func]
    fn get_knots(&self) -> PackedFloat64Array {
        ok(self.curve.knots()).map_or_else(PackedFloat64Array::new, |k| doubles(&k))
    }

    /// The parameter domain, `[lo, hi]`.
    #[func]
    fn get_domain(&self) -> PackedFloat64Array {
        ok(self.curve.domain()).map_or_else(PackedFloat64Array::new, |(lo, hi)| doubles(&[lo, hi]))
    }

    /// Whether the weights differ: a true NURBS rather than a plain B-spline.
    #[func]
    fn get_is_rational(&self) -> bool {
        self.curve.is_rational()
    }

    /// Whether the curve ends where it starts.
    #[func]
    fn get_is_closed(&self) -> bool {
        self.curve.is_closed()
    }

    /// The largest distance found between a fitted curve and what it was fitted to; `null` on a
    /// curve not from `fit`, `projected_to_face` or `pulled_to_face`.
    #[func]
    fn get_fit_error(&self) -> Variant {
        self.curve.fit_error().map_or_else(Variant::nil, |e| e.to_variant())
    }

    /// The point at parameter `t` (inside the domain), three doubles; empty on a refusal, with
    /// the reason in `Cadaclysm.last_error()`.
    #[func]
    fn point(&self, t: f64) -> PackedFloat64Array {
        ok(self.curve.point(t)).map_or_else(PackedFloat64Array::new, |p| doubles(&p))
    }

    /// The point and its derivatives at `t` up to `order` (at most 8): `[C, C', C'', ...]`,
    /// `order + 1` arrays of three doubles. Empty on a refusal.
    #[func]
    fn derivatives(&self, t: f64, #[opt(default = 2)] order: i64) -> Array<PackedFloat64Array> {
        let Some(order) = index(order, "nurbs_curve_derivatives: order") else { return Array::new() };
        ok(self.curve.derivatives(t, order)).unwrap_or_default().iter().map(|d| doubles(d)).collect()
    }

    /// The `CadaclysmCurvature` and Frenet frame at `t`.
    #[func]
    fn curvature(&self, t: f64) -> Option<Gd<CadaclysmCurvature>> {
        ok(self.curve.curvature(t)).map(CadaclysmCurvature::wrap)
    }

    /// The curve's length as a `CadaclysmLength`, to the relative `accuracy` (0 asks for the
    /// default).
    #[func]
    fn length(&self, #[opt(default = 0.0)] accuracy: f64) -> Option<Gd<CadaclysmLength>> {
        ok(self.curve.length(accuracy)).map(CadaclysmLength::wrap)
    }

    /// The point at arc length `s` from the start, as a `CadaclysmAt` (`segment` -1).
    #[func]
    fn point_at_length(&self, s: f64, #[opt(default = 0.0)] accuracy: f64) -> Option<Gd<CadaclysmAt>> {
        ok(self.curve.point_at_length(s, accuracy)).map(CadaclysmAt::wrap)
    }

    /// The curve in `n` pieces of equal arc length: `n + 1` `CadaclysmAt` samples, `n` for a
    /// closed curve. Empty on failure.
    #[func]
    fn divide_by_count(&self, n: i64, #[opt(default = 0.0)] accuracy: f64) -> Array<Gd<CadaclysmAt>> {
        Self::samples(sample_count("nurbs_curve_divide_by_count", n).map(|n| self.curve.divide_by_count(n, accuracy)))
    }

    /// Samples every `step` of arc length from the start; a closed curve never repeats its
    /// start. Empty on failure.
    #[func]
    fn divide_by_length(&self, step: f64, #[opt(default = 0.0)] accuracy: f64) -> Array<Gd<CadaclysmAt>> {
        Self::samples(Some(self.curve.divide_by_length(step, accuracy)))
    }

    /// Where the curve crosses the plane through `origin` with `normal`, in parameter order,
    /// each a `CadaclysmAt` whose `error` is its distance from the plane. Empty on failure (a
    /// curve lying in the plane among them).
    #[func]
    fn plane_hits(&self, origin: Variant, normal: Variant) -> Array<Gd<CadaclysmAt>> {
        let found = (|| Some(self.curve.plane_hits(at(&origin, "nurbs_curve_plane_hits")?, at(&normal, "nurbs_curve_plane_hits")?)))();
        Self::samples(found)
    }

    /// Where the curve crosses face `face` of `solid` (its whole surface), within `tolerance`
    /// of it, in parameter order. Empty on failure.
    #[func]
    fn face_hits(&self, solid: Gd<CadaclysmSolid>, face: i64, #[opt(default = 1e-3)] tolerance: f64) -> Array<Gd<CadaclysmAt>> {
        let solid = solid.bind();
        let found = (|| Some(self.curve.face_hits(solid.held()?, index(face, "nurbs_curve_face_hits: face")?, Some(tolerance))))();
        Self::samples(found)
    }

    /// A curvature comb to draw, as segment pairs: at `n + 1` even parameters the curve point
    /// and that point moved by `-scale * kappa * normal`, out of the bend. `Vector3`s, so
    /// floats. Empty on failure.
    #[func]
    fn comb(&self, #[opt(default = 64)] n: i64, #[opt(default = 1.0)] scale: f64) -> PackedVector3Array {
        let Some(n) = index(n, "comb: n") else { return PackedVector3Array::new() };
        ok(self.curve.comb(n, scale)).unwrap_or_default().iter().flat_map(|(p, q)| [vector3(*p), vector3(*q)]).collect()
    }
}

/// A curve's bending at a parameter (`CadaclysmNurbsCurve.curvature`), in doubles: `kappa`
/// (1 / radius), the unit `tangent`, the unit `normal` toward the centre and the `binormal`
/// (`tangent x normal`), three doubles each, and the `centre` of the osculating circle --
/// `null` on a straight piece, where `kappa` is 0 and `normal`, `binormal` are zero.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmCurvature {
    value: bs::Curvature,
    /// The curvature, 1 / radius; 0 on a straight piece.
    #[var(get = get_kappa, no_set)]
    kappa: PhantomVar<f64>,
    /// The unit tangent, along increasing parameter.
    #[var(get = get_tangent, no_set)]
    tangent: PhantomVar<PackedFloat64Array>,
    /// The unit normal toward the centre of curvature; zero on a straight piece.
    #[var(get = get_normal, no_set)]
    normal: PhantomVar<PackedFloat64Array>,
    /// `tangent x normal`; zero on a straight piece.
    #[var(get = get_binormal, no_set)]
    binormal: PhantomVar<PackedFloat64Array>,
    /// The centre of the osculating circle, or `null` on a straight piece.
    #[var(get = get_centre, no_set)]
    centre: PhantomVar<Variant>,
}

impl CadaclysmCurvature {
    fn wrap(value: bs::Curvature) -> Gd<CadaclysmCurvature> {
        Gd::from_object(CadaclysmCurvature {
            value,
            kappa: PhantomVar::default(),
            tangent: PhantomVar::default(),
            normal: PhantomVar::default(),
            binormal: PhantomVar::default(),
            centre: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmCurvature {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!("Curvature(kappa={}, tangent={:?}, normal={:?}, centre={:?})", v.kappa, v.tangent, v.normal, v.centre))
    }
}

#[godot_api]
impl CadaclysmCurvature {
    /// The curvature, 1 / radius; 0 on a straight piece.
    #[func]
    fn get_kappa(&self) -> f64 {
        self.value.kappa
    }

    /// The unit tangent, along increasing parameter.
    #[func]
    fn get_tangent(&self) -> PackedFloat64Array {
        doubles(&self.value.tangent)
    }

    /// The unit normal toward the centre of curvature; zero on a straight piece.
    #[func]
    fn get_normal(&self) -> PackedFloat64Array {
        doubles(&self.value.normal)
    }

    /// `tangent x normal`; zero on a straight piece.
    #[func]
    fn get_binormal(&self) -> PackedFloat64Array {
        doubles(&self.value.binormal)
    }

    /// The centre of the osculating circle, three doubles, or `null` on a straight piece.
    #[func]
    fn get_centre(&self) -> Variant {
        self.value.centre.map_or_else(Variant::nil, |c| doubles(&c).to_variant())
    }
}

/// How well two faces meet along their sides (`CadaclysmSolid.continuity`): the largest `gap`
/// between the sides (G0), the largest `angle` between their normals in radians (G1), the
/// largest difference of normal `curvature` across the edge (G2), each with where on the first
/// side it was found (three doubles), and how many points were asked (`samples`).
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmContinuity {
    value: bs::Continuity,
    /// The largest distance between the two sides (G0).
    #[var(get = get_gap, no_set)]
    gap: PhantomVar<f64>,
    /// Where on the first side it is.
    #[var(get = get_gap_at, no_set)]
    gap_at: PhantomVar<PackedFloat64Array>,
    /// The largest angle between the faces' normals, in radians (G1).
    #[var(get = get_angle, no_set)]
    angle: PhantomVar<f64>,
    /// Where on the first side it is.
    #[var(get = get_angle_at, no_set)]
    angle_at: PhantomVar<PackedFloat64Array>,
    /// The largest difference of normal curvature across the edge (G2).
    #[var(get = get_curvature, no_set)]
    curvature: PhantomVar<f64>,
    /// Where on the first side it is.
    #[var(get = get_curvature_at, no_set)]
    curvature_at: PhantomVar<PackedFloat64Array>,
    /// How many points along the first side were asked.
    #[var(get = get_samples, no_set)]
    samples: PhantomVar<i64>,
}

impl CadaclysmContinuity {
    fn wrap(value: bs::Continuity) -> Gd<CadaclysmContinuity> {
        Gd::from_object(CadaclysmContinuity {
            value,
            gap: PhantomVar::default(),
            gap_at: PhantomVar::default(),
            angle: PhantomVar::default(),
            angle_at: PhantomVar::default(),
            curvature: PhantomVar::default(),
            curvature_at: PhantomVar::default(),
            samples: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmContinuity {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!("Continuity(gap={}, angle={}, curvature={}, samples={})", v.gap, v.angle, v.curvature, v.samples))
    }
}

#[godot_api]
impl CadaclysmContinuity {
    /// The largest distance between the two sides (G0).
    #[func]
    fn get_gap(&self) -> f64 {
        self.value.gap
    }

    /// Where on the first side the gap is.
    #[func]
    fn get_gap_at(&self) -> PackedFloat64Array {
        doubles(&self.value.gap_at)
    }

    /// The largest angle between the faces' normals, in radians (G1).
    #[func]
    fn get_angle(&self) -> f64 {
        self.value.angle
    }

    /// Where on the first side the angle is.
    #[func]
    fn get_angle_at(&self) -> PackedFloat64Array {
        doubles(&self.value.angle_at)
    }

    /// The largest difference of normal curvature across the edge (G2).
    #[func]
    fn get_curvature(&self) -> f64 {
        self.value.curvature
    }

    /// Where on the first side the curvature difference is.
    #[func]
    fn get_curvature_at(&self) -> PackedFloat64Array {
        doubles(&self.value.curvature_at)
    }

    /// How many points along the first side were asked.
    #[func]
    fn get_samples(&self) -> i64 {
        self.value.samples.into()
    }
}

/// How well an N-sided patch meets (`CadaclysmSolid.patch_report`): `faces` sub-patches, the
/// worst `boundary` `CadaclysmContinuity` against the neighbours, the worst `internal` across
/// the patch's own spokes, and `corner_angle` (radians), what no patch can meet at a corner of
/// the hole.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmPatchReport {
    value: bs::PatchReport,
    /// How many faces: one per side of the hole.
    #[var(get = get_faces, no_set)]
    faces: PhantomVar<i64>,
    /// The worst `CadaclysmContinuity` against the neighbours.
    #[var(get = get_boundary, no_set)]
    boundary: PhantomVar<Gd<CadaclysmContinuity>>,
    /// The worst `CadaclysmContinuity` across the patch's own spokes.
    #[var(get = get_internal, no_set)]
    internal: PhantomVar<Gd<CadaclysmContinuity>>,
    /// The largest angle, in radians, a corner of the hole leaves no patch able to meet.
    #[var(get = get_corner_angle, no_set)]
    corner_angle: PhantomVar<f64>,
}

impl CadaclysmPatchReport {
    fn wrap(value: bs::PatchReport) -> Gd<CadaclysmPatchReport> {
        Gd::from_object(CadaclysmPatchReport {
            value,
            faces: PhantomVar::default(),
            boundary: PhantomVar::default(),
            internal: PhantomVar::default(),
            corner_angle: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmPatchReport {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!("PatchReport(faces={}, boundary.gap={}, boundary.angle={}, corner_angle={})", v.faces, v.boundary.gap, v.boundary.angle, v.corner_angle))
    }
}

#[godot_api]
impl CadaclysmPatchReport {
    /// How many faces: one per side of the hole.
    #[func]
    fn get_faces(&self) -> i64 {
        self.value.faces.into()
    }

    /// The worst `CadaclysmContinuity` against the neighbours.
    #[func]
    fn get_boundary(&self) -> Gd<CadaclysmContinuity> {
        CadaclysmContinuity::wrap(self.value.boundary)
    }

    /// The worst `CadaclysmContinuity` across the patch's own spokes.
    #[func]
    fn get_internal(&self) -> Gd<CadaclysmContinuity> {
        CadaclysmContinuity::wrap(self.value.internal)
    }

    /// The largest angle, in radians, a corner of the hole leaves no patch able to meet.
    #[func]
    fn get_corner_angle(&self) -> f64 {
        self.value.corner_angle
    }
}

/// What `CadaclysmSolid.join_sheets` did: `sewn` edges, the widest `worst_gap` between two sewn
/// edges, the naked edges `naked_before` and `naked_after`, `refused` groups left apart, faces
/// `turned`, and whether the result is `closed`: a solid.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmJoinReport {
    value: bs::JoinReport,
    /// Edges sewn: each is two naked edges become one shared edge.
    #[var(get = get_sewn, no_set)]
    sewn: PhantomVar<i64>,
    /// The widest gap between two sewn edges; 0 where every edge met exactly.
    #[var(get = get_worst_gap, no_set)]
    worst_gap: PhantomVar<f64>,
    /// Edges bordered by one face before the sewing.
    #[var(get = get_naked_before, no_set)]
    naked_before: PhantomVar<i64>,
    /// Edges bordered by one face after it: 0 for a closed result.
    #[var(get = get_naked_after, no_set)]
    naked_after: PhantomVar<i64>,
    /// Groups of naked edges sharing both ends that were left apart.
    #[var(get = get_refused, no_set)]
    refused: PhantomVar<i64>,
    /// Faces whose sense the join turned.
    #[var(get = get_turned, no_set)]
    turned: PhantomVar<i64>,
    /// Whether the result is closed -- every edge bordered twice -- and so a solid.
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
}

impl CadaclysmJoinReport {
    fn wrap(value: bs::JoinReport) -> Gd<CadaclysmJoinReport> {
        Gd::from_object(CadaclysmJoinReport {
            value,
            sewn: PhantomVar::default(),
            worst_gap: PhantomVar::default(),
            naked_before: PhantomVar::default(),
            naked_after: PhantomVar::default(),
            refused: PhantomVar::default(),
            turned: PhantomVar::default(),
            closed: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmJoinReport {
    fn to_string(&self) -> GString {
        let v = &self.value;
        gs(format!(
            "JoinReport(sewn={}, worst_gap={}, naked_before={}, naked_after={}, refused={}, turned={}, closed={})",
            v.sewn, v.worst_gap, v.naked_before, v.naked_after, v.refused, v.turned, v.closed
        ))
    }
}

#[godot_api]
impl CadaclysmJoinReport {
    /// Edges sewn: each is two naked edges become one shared edge.
    #[func]
    fn get_sewn(&self) -> i64 {
        self.value.sewn.into()
    }

    /// The widest gap between two sewn edges; 0 where every edge met exactly.
    #[func]
    fn get_worst_gap(&self) -> f64 {
        self.value.worst_gap
    }

    /// Edges bordered by one face before the sewing.
    #[func]
    fn get_naked_before(&self) -> i64 {
        self.value.naked_before.into()
    }

    /// Edges bordered by one face after it: 0 for a closed result.
    #[func]
    fn get_naked_after(&self) -> i64 {
        self.value.naked_after.into()
    }

    /// Groups of naked edges sharing both ends that were left apart.
    #[func]
    fn get_refused(&self) -> i64 {
        self.value.refused.into()
    }

    /// Faces whose sense the join turned.
    #[func]
    fn get_turned(&self) -> i64 {
        self.value.turned.into()
    }

    /// Whether the result is closed -- every edge bordered twice -- and so a solid.
    #[func]
    fn get_closed(&self) -> bool {
        self.value.closed
    }
}

/// One boundary of `CadaclysmSolid.n_sided_patch`'s hole, as given: a sheet's side, or a curve.
enum BoundaryArg {
    Side { sheet: Gd<CadaclysmSolid>, side: bs::SheetSide, face: u32, level: u32, range: (f64, f64) },
    Curve(Gd<CadaclysmNurbsCurve>),
}

/// An int field of a boundary, refused under `what` for anything else.
fn boundary_u32(v: &Variant, what: &str) -> Option<u32> {
    if v.get_type() == VariantType::INT {
        index(v.to::<i64>(), what)
    } else {
        fail(format!("{what}: expected an int, not {v}"))
    }
}

fn boundary_sheet(v: &Variant, i: usize) -> Option<Gd<CadaclysmSolid>> {
    match v.try_to::<Gd<CadaclysmSolid>>() {
        Ok(sheet) => Some(sheet),
        Err(_) => fail(format!("n_sided_patch: boundary {i}'s sheet is not a CadaclysmSolid: {v}")),
    }
}

fn boundary_side(v: &Variant, i: usize) -> Option<bs::SheetSide> {
    match v.try_to::<GString>() {
        Ok(side) => sheet_side(&side),
        Err(_) => fail(format!("n_sided_patch: boundary {i}'s side is not a String: {v}")),
    }
}

/// Boundary `i` of `n_sided_patch`: a `CadaclysmNurbsCurve`, `[sheet, side]`,
/// `[sheet, side, level]`, or a `Dictionary` with `sheet`, `side` and any of `level`, `face`
/// and `range` -- unknown keys refused in Python's words.
fn patch_boundary(item: &Variant, i: usize) -> Option<BoundaryArg> {
    if let Ok(curve) = item.try_to::<Gd<CadaclysmNurbsCurve>>() {
        return Some(BoundaryArg::Curve(curve));
    }
    if let Ok(d) = item.try_to::<VarDictionary>() {
        let (mut sheet, mut side, mut face, mut level, mut range) = (None, None, 0, 2, (0.0, 1.0));
        let mut unknown = Vec::new();
        for (key, value) in d.iter_shared() {
            match key.try_to::<GString>().map(|k| k.to_string()).as_deref() {
                Ok("sheet") => sheet = Some(boundary_sheet(&value, i)?),
                Ok("side") => side = Some(boundary_side(&value, i)?),
                Ok("face") => face = boundary_u32(&value, "n_sided_patch: face")?,
                Ok("level") => level = boundary_u32(&value, "n_sided_patch: level")?,
                Ok("range") => {
                    let [from, to] = point::<2>(&value, &format!("n_sided_patch: boundary {i}'s range"))?;
                    range = (from, to);
                }
                _ => unknown.push(format!("'{key}'")),
            }
        }
        if !unknown.is_empty() {
            unknown.sort();
            return fail(format!("n_sided_patch: boundary {i}: unknown keys [{}]", unknown.join(", ")));
        }
        let Some(sheet) = sheet else { return fail(format!("n_sided_patch: boundary {i} has no sheet")) };
        let Some(side) = side else { return fail(format!("n_sided_patch: boundary {i} has no side")) };
        return Some(BoundaryArg::Side { sheet, side, face, level, range });
    }
    if let Ok(row) = item.try_to::<VarArray>() {
        if !(2..=3).contains(&row.len()) {
            return fail(format!("n_sided_patch: boundary {i} is [sheet, side] or [sheet, side, level]"));
        }
        let sheet = boundary_sheet(&row.at(0), i)?;
        let side = boundary_side(&row.at(1), i)?;
        let level = if row.len() == 3 { boundary_u32(&row.at(2), "n_sided_patch: level")? } else { 2 };
        return Some(BoundaryArg::Side { sheet, side, face: 0, level, range: (0.0, 1.0) });
    }
    fail(format!("n_sided_patch: boundary {i} is a CadaclysmNurbsCurve, [sheet, side, level] or a Dictionary, not {item}"))
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
    #[var(get = get_name, no_set)]
    name: PhantomVar<GString>,
    #[var(get = get_material, no_set)]
    material: PhantomVar<GString>,
    #[var(get = get_style_location, no_set)]
    style_location: PhantomVar<GString>,
    #[var(get = get_style_identification, no_set)]
    style_identification: PhantomVar<GString>,
    #[var(get = get_inexact_trims, no_set)]
    inexact_trims: PhantomVar<i64>,
    #[var(get = get_is_tracked, no_set)]
    is_tracked: PhantomVar<bool>,
    #[var(get = get_attributes, no_set)]
    attributes: PhantomVar<VarDictionary>,
    #[var(get = get_vertex_count, no_set)]
    vertex_count: PhantomVar<i64>,
    #[var(get = get_sheet_error, no_set)]
    sheet_error: PhantomVar<Variant>,
    #[var(get = get_patch_report, no_set)]
    patch_report: PhantomVar<Variant>,
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
            name: PhantomVar::default(),
            material: PhantomVar::default(),
            style_location: PhantomVar::default(),
            style_identification: PhantomVar::default(),
            inexact_trims: PhantomVar::default(),
            is_tracked: PhantomVar::default(),
            attributes: PhantomVar::default(),
            vertex_count: PhantomVar::default(),
            sheet_error: PhantomVar::default(),
            patch_report: PhantomVar::default(),
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

    fn edge_index(edge: i64, what: &str) -> Option<u32> {
        match u32::try_from(edge) {
            Ok(e) => Some(e),
            Err(_) => fail(format!("{what}: no edge {edge}")),
        }
    }

    /// An id as GDScript reads it: -1 for none (untracked, or a refusal already recorded).
    fn id_or_none(id: Option<Option<u64>>) -> i64 {
        id.flatten().map_or(-1, |id| id as i64)
    }

    /// -1 for a lookup by a negative id, which no face or edge has: not an error.
    fn no_index() -> i64 {
        clear_error();
        -1
    }

    fn origin_list(origins: Option<Vec<bs::Origin>>) -> VarArray {
        origins.unwrap_or_default().into_iter().map(|o| origin_pair(o).to_variant()).collect()
    }

    /// `f` on this solid and the solids of `inputs`, its history wrapped.
    fn read_history(
        &self,
        inputs: &AnyArray,
        what: &str,
        f: impl FnOnce(&bs::Solid, &[&bs::Solid]) -> sdk::Result<bs::History>,
    ) -> Option<Gd<CadaclysmHistory>> {
        let list = object_list::<CadaclysmSolid>(inputs, what)?;
        let guards: Vec<GdRef<CadaclysmSolid>> = list.iter().map(|s| s.bind()).collect();
        let held: Vec<&bs::Solid> = guards.iter().map(|g| g.held()).collect::<Option<_>>()?;
        ok(f(self.held()?, &held)).map(CadaclysmHistory::wrap)
    }

    /// Attributes read in key order as a read-only `Dictionary`, whose order is its
    /// insertion order.
    fn attribute_dictionary(attributes: Option<std::collections::BTreeMap<String, String>>) -> VarDictionary {
        let mut out = VarDictionary::new();
        for (key, value) in attributes.unwrap_or_default() {
            out.set(&gs(key), &gs(value));
        }
        out.into_read_only()
    }

    fn text_or_null(text: Option<Option<String>>) -> Variant {
        text.flatten().map_or_else(Variant::nil, |t| gs(t).to_variant())
    }

    /// A `Dictionary` of `String` keys and values as pairs, refused under `what` otherwise.
    fn attribute_pairs(attributes: &VarDictionary, what: &str) -> Option<Vec<(String, String)>> {
        attributes
            .iter_shared()
            .map(|(key, value)| match (key.try_to::<GString>(), value.try_to::<GString>()) {
                (Ok(key), Ok(value)) => Some((key.to_string(), value.to_string())),
                _ => fail(format!("{what}: keys and values are Strings, not {key}: {value}")),
            })
            .collect()
    }

    /// A boolean's result, its flush faces merged where `merge` asks. A tracked result's
    /// merge reads its origins back through the boolean's (`origins_through`), as Python's
    /// `_combine` does, so they name this solid as operand 0 and `other` as 1, not the faces
    /// between the two steps.
    fn combined(result: Option<bs::Solid>, merge: bool) -> Option<Gd<CadaclysmSolid>> {
        let solid = result?;
        if !merge {
            return Some(CadaclysmSolid::wrap(solid));
        }
        let merged = ok(solid.merge_flush())?;
        if ok(solid.is_tracked())? {
            return Self::made(merged.origins_through(&solid));
        }
        Some(CadaclysmSolid::wrap(merged))
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

    /// A right pyramid of `sides` sides (at least 3): its base the regular polygon of
    /// circumradius `r` on z=0, its first corner on +x, its tip at (0, 0, `h`).
    #[func]
    fn pyramid(sides: i64, r: f64, h: f64) -> Option<Gd<CadaclysmSolid>> {
        let sides = u32::try_from(sides).unwrap_or(0);
        Self::made(bs::Solid::pyramid(sides, r, h))
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

    /// This solid scaled by `factor` about the origin: every length times `factor`, exactly.
    #[func]
    fn scaled(&self, factor: f64) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.scaled(factor))
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

    /// This solid through the affine map `t` -- a `CadaclysmTransform`, or 16 numbers
    /// row-major -- exactly, its colours and name kept. A rigid map or a similarity keeps
    /// every surface's kind; a map within 1e-6 of a similarity (a rotation written in
    /// float32 among them) is applied as the exact similarity nearest it. Any other map (a
    /// non-uniform scale, a shear) turns the curved surfaces into their exact NURBS and maps
    /// those. The result's `inexact_trims` counts the trims this call lost. `null` for a
    /// singular map (it flattens the solid), with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn transform(&self, t: Variant) -> Option<Gd<CadaclysmSolid>> {
        let t = transform_arg(&t, "transform")?;
        self.then(|s| s.transform(&t))
    }

    /// This solid with the surfaces `level` selects rewritten as their exact NURBS, its
    /// colours and name kept: `"procedural"` the revolutions, extrusions and sums;
    /// `"analytic"` those and the cylinders, cones, spheres and tori; `"all"` everything,
    /// planes and edge curves too. `inexact_trims` counts the trims this call lost. `null`
    /// for another level, or a surface or edge curve with no exact NURBS form, with the
    /// reason in `Cadaclysm.last_error()`.
    #[func]
    fn convert_to_nurbs(&self, #[opt(default = "all")] level: GString) -> Option<Gd<CadaclysmSolid>> {
        let level = match level.to_string().as_str() {
            "procedural" => bs::NurbsLevel::Procedural,
            "analytic" => bs::NurbsLevel::Analytic,
            "all" => bs::NurbsLevel::All,
            other => return fail(format!("convert_to_nurbs: level '{other}' is not \"procedural\", \"analytic\" or \"all\"")),
        };
        self.then(|s| s.convert_to_nurbs(level))
    }

    /// On a solid from `transform` or `convert_to_nurbs`, the trims **that call** lost:
    /// face boundaries kept only as a polyline lifted through the old surface, where no
    /// exact edge curve was left. Per call -- not the solid's history -- and 0 for a rigid
    /// map or a similarity, and on every other solid.
    #[func]
    fn get_inexact_trims(&self) -> i64 {
        self.held().map_or(0, |s| s.inexact_trims().into())
    }

    // -- naming

    /// This solid, named `name` -- see `name`. Refused for an empty name.
    #[func]
    fn named(&self, name: GString) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.named(&name.to_string()))
    }

    /// This solid's name, or `""` where it has none -- Godot has no null string, unlike
    /// `bs::Solid::name`'s own `Option<String>`, so a closed solid (also `""` here) and
    /// an unnamed one read the same; `CadaclysmSolid.closed` tells them apart.
    #[func]
    fn get_name(&self) -> GString {
        gs(self.held().and_then(|s| s.name()).unwrap_or_default())
    }

    // -- material and look defined outside the file

    /// This solid made of `material` -- written to STEP as its product's
    /// `MATERIAL_DESIGNATION`, kept by operations as a colour is. Refused when blank.
    #[func]
    fn with_material(&self, material: GString) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.with_material(&material.to_string()))
    }

    /// What this solid is made of, or `""` where it has none (as `get_name`).
    #[func]
    fn get_material(&self) -> GString {
        gs(self.held().and_then(|s| s.material()).unwrap_or_default())
    }

    /// This solid drawn in a style defined outside the file: `identification` the
    /// style's name in the library at `location` (a MaterialX or MDL file). An empty
    /// string is left out -- Godot has no null string -- and leaving out both is refused.
    #[func]
    fn styled(&self, location: GString, identification: GString) -> Option<Gd<CadaclysmSolid>> {
        let (location, identification) = (location.to_string(), identification.to_string());
        fn given(t: &str) -> Option<&str> {
            (!t.is_empty()).then_some(t)
        }
        self.then(|s| s.styled(given(&location), given(&identification)))
    }

    /// Where this solid's outside style lives, or `""` where it has none.
    #[func]
    fn get_style_location(&self) -> GString {
        gs(self.held().and_then(|s| s.style_location()).unwrap_or_default())
    }

    /// This solid's outside style's name in its library, or `""` where it has none.
    #[func]
    fn get_style_identification(&self) -> GString {
        gs(self.held().and_then(|s| s.style_identification()).unwrap_or_default())
    }

    // -- combining

    /// This solid and `other` as one. `merge` then merges the flush faces the join
    /// leaves (`merge_flush`).
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

    /// This solid and `other` as one body that keeps every piece -- a union that keeps the
    /// inside pieces: its regions are this solid less `other`, the two together, and `other`
    /// less this one (those that are not empty), and the walls between them are faces of both.
    /// The body is non-manifold where a wall meets the outside (edges of three or four faces),
    /// so the verbs that need a manifold solid -- the booleans, fillet, chamfer, shell,
    /// thicken, `mass` -- refuse it; take its cells with `regions` and `region_solid`.
    ///
    /// Built exactly: both solids closed, every face a plane, cylinder, cone, sphere or torus.
    /// Walls of the two lying on one another in part are a case it refuses, in words. `null`
    /// for that, or a `tolerance` not positive and finite, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn merge(&self, other: Gd<CadaclysmSolid>, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        self.with(&other, |a, b| a.merge(b, tolerance)).map(CadaclysmSolid::wrap)
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

    /// Where this solid's faces cross or coincide with `other`'s, at `tolerance`, as a
    /// `CadaclysmIntersection`: `chains` along the curves the faces meet on and
    /// `overlaps` where a face pair coincides. Neither solid is changed; either may be an
    /// open sheet. No crossing is an empty result, never an error. Each chain's points are
    /// within `tolerance` of both faces' exact surfaces; one chain per face pair per
    /// branch -- chains are not joined across a face boundary or a closed curve's seam, so
    /// join them by matching ends. `null` (and the error) for a `tolerance` not positive
    /// and finite, a solid with no faces, or one that meshes to nothing.
    #[func]
    fn intersect(&self, other: Gd<CadaclysmSolid>, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmIntersection>> {
        self.with(&other, |a, b| a.intersect(b, tolerance)).map(CadaclysmIntersection::wrap)
    }

    /// Where `profile`, placed on `frame`, pierces this solid's faces, and the pieces its
    /// loops cut into, as a `CadaclysmSolidHits`. Neither is changed. A point hit lies
    /// within `tolerance` of the segment's exact curve and of the face's exact surface,
    /// inside the face's trim; its profile spot (`a_start`) and face spot (`b_start`: face,
    /// u, v) evaluate to the point within `tolerance`; `touch` at a graze (the curve's
    /// tangent within 1e-3, sine, of the tangent plane), false at a crossing; a run is a
    /// stretch of one segment lying on one face, longer than `tolerance`; hits within
    /// `tolerance` of each other merge (a segment join reported once, as (k, t = 1); a
    /// closed loop's closing join reads (0, 0)); every
    /// point in world space. Pieces only for a closed body -- an open body has none -- in
    /// loop order, covering every loop exactly: a segment join reads as (k + 1, 0), an open
    /// chain runs from (0, 0) to (n - 1, 1), a loop no hit cuts is one closed piece, and a
    /// piece lying on the surface is inside. `null` (and the error) for a `tolerance` not
    /// positive and finite, a solid with no faces or that meshes to nothing, a profile with
    /// no segments, or a free-form segment that is not an evaluable NURBS curve.
    #[func]
    fn hits(&self, profile: Gd<CadaclysmProfile>, frame: Variant, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmSolidHits>> {
        let f = self::frame(&frame, "hits: frame")?;
        let found = ok(self.held()?.hits(&profile.bind().profile, &f, tolerance))?;
        Some(CadaclysmSolidHits::wrap(found))
    }

    /// Round `edges` (`CadaclysmEdge`s or their indices) to `radius`. A `radius_end` (`NAN`,
    /// the default, for none) other than `radius` runs the radius linearly from `radius` to it
    /// in arc length along each edge, `radius` where the edge's curve starts -- spline edges
    /// only.
    #[func]
    fn fillet(
        &self,
        edges: Variant,
        radius: f64,
        #[opt(default = 1e-6)] tolerance: f64,
        #[opt(default = f64::NAN)] radius_end: f64,
    ) -> Option<Gd<CadaclysmSolid>> {
        let edges = indices(&edges, "fillet: edges")?;
        self.then(|s| s.fillet_varying(&edges, radius, optional_number(radius_end), tolerance))
    }

    // -- sheets from curves

    /// On a sheet from `sweep_rail`, `sweep_two_rails`, `edge_surface`, `network_surface`,
    /// `fillet_surfaces`, `flange` or `extrude_to`, how far it came from its definition; `null`
    /// on every other solid.
    #[func]
    fn get_sheet_error(&self) -> Variant {
        self.held().and_then(|s| s.sheet_error()).map_or_else(Variant::nil, |e| e.to_variant())
    }

    /// On a sheet from `n_sided_patch`, the `CadaclysmPatchReport` of how well it meets; `null`
    /// on every other solid.
    #[func]
    fn get_patch_report(&self) -> Variant {
        self.held().and_then(|s| s.patch_report()).map_or_else(Variant::nil, |r| CadaclysmPatchReport::wrap(*r).to_variant())
    }

    /// A sheet lofted through `sections` (an array of `CadaclysmNurbsCurve`s): one face on one
    /// NURBS surface, `degree` across the sections (lowered to fit); `loose` shapes it by them
    /// instead, through the first and last only; `closed` makes it periodic across them.
    #[func]
    fn loft_curves(
        sections: AnyArray,
        #[opt(default = 3)] degree: i64,
        #[opt(default = false)] loose: bool,
        #[opt(default = false)] closed: bool,
    ) -> Option<Gd<CadaclysmSolid>> {
        let degree = index(degree, "loft_curves: degree")?;
        with_curves(&sections, "loft_curves: sections", |c| Self::made(bs::Solid::loft_curves(c, degree, loose, closed)))
    }

    /// A sheet of `sections` swept along `rail`: `frame` `"rmf"` turns them no more than the
    /// rail makes them (rotation-minimising), `"fixed"` keeps `up` (three numbers) upright.
    /// Fitted within `tolerance`; `sheet_error` says how close.
    #[func]
    fn sweep_rail(
        rail: Gd<CadaclysmNurbsCurve>,
        sections: AnyArray,
        #[opt(default = "rmf")] frame: GString,
        #[opt(default = &PackedFloat64Array::new())] up: PackedFloat64Array,
        #[opt(default = 1e-3)] tolerance: f64,
    ) -> Option<Gd<CadaclysmSolid>> {
        let frame = ok(frame.to_string().parse::<bs::SweepFrame>())?;
        let up = optional_v3(&up, "sweep_rail: up")?;
        let rail = rail.bind();
        with_curves(&sections, "sweep_rail: sections", |c| Self::made(bs::Solid::sweep_rail(&rail.curve, c, frame, up, Some(tolerance))))
    }

    /// A sheet of `sections` swept between two rails: each section's first end on `rail_a`, its
    /// last on `rail_b`. Fitted within `tolerance` (`sheet_error`).
    #[func]
    fn sweep_two_rails(
        rail_a: Gd<CadaclysmNurbsCurve>,
        rail_b: Gd<CadaclysmNurbsCurve>,
        sections: AnyArray,
        #[opt(default = 1e-3)] tolerance: f64,
    ) -> Option<Gd<CadaclysmSolid>> {
        let (a, b) = (rail_a.bind(), rail_b.bind());
        with_curves(&sections, "sweep_two_rails: sections", |c| Self::made(bs::Solid::sweep_two_rails(&a.curve, &b.curve, c, Some(tolerance))))
    }

    /// The Coons sheet of 2, 3 or 4 boundary curves meeting end to end within `tolerance`, in
    /// order round the boundary: exact for non-rational ones, rational ones fitted first
    /// (`sheet_error`).
    #[func]
    fn edge_surface(curves: AnyArray, #[opt(default = 1e-3)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        with_curves(&curves, "edge_surface: curves", |c| Self::made(bs::Solid::edge_surface(c, Some(tolerance))))
    }

    /// The Gordon sheet of a curve network: every one of `u_curves` crossing every one of
    /// `v_curves` within `tolerance`. `sheet_error` is the largest distance from the sheet to
    /// the curves.
    #[func]
    fn network_surface(u_curves: AnyArray, v_curves: AnyArray, #[opt(default = 1e-3)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        with_curves(&u_curves, "network_surface: u_curves", |u| {
            with_curves(&v_curves, "network_surface: v_curves", |v| Self::made(bs::Solid::network_surface(u, v, Some(tolerance))))
        })
    }

    /// How well face `face` of this solid, along `side` (`"u0"`, `"u1"`, `"v0"` or `"v1"`),
    /// meets face `other_face` of `other` along `other_side`, from `samples` points along the
    /// first side, as a `CadaclysmContinuity`.
    #[func]
    fn continuity(
        &self,
        side: GString,
        other: Gd<CadaclysmSolid>,
        other_side: GString,
        #[opt(default = 0)] face: i64,
        #[opt(default = 0)] other_face: i64,
        #[opt(default = 64)] samples: i64,
    ) -> Option<Gd<CadaclysmContinuity>> {
        let (side, other_side) = (sheet_side(&side)?, sheet_side(&other_side)?);
        let face = Self::face_index(face, "continuity")?;
        let other_face = Self::face_index(other_face, "continuity")?;
        let samples = index(samples, "continuity: samples")?;
        self.with(&other, |a, b| a.continuity(side, b, other_side, face, other_face, samples)).map(CadaclysmContinuity::wrap)
    }

    /// Face `face` as a sheet of its own, its side `side` bent to meet `other`'s `other_side`
    /// at G`level`: 0 position, 1 tangent plane, 2 curvature. The opposite side stays.
    #[func]
    fn matched(
        &self,
        side: GString,
        other: Gd<CadaclysmSolid>,
        other_side: GString,
        #[opt(default = 2)] level: i64,
        #[opt(default = 0)] face: i64,
        #[opt(default = 0)] other_face: i64,
    ) -> Option<Gd<CadaclysmSolid>> {
        let (side, other_side) = (sheet_side(&side)?, sheet_side(&other_side)?);
        let level = index(level, "match_side: level")?;
        let face = Self::face_index(face, "match_side")?;
        let other_face = Self::face_index(other_face, "match_side")?;
        self.with(&other, |a, b| a.matched(side, b, other_side, level, face, other_face)).map(CadaclysmSolid::wrap)
    }

    /// A sheet spanning from `a`'s side `side_a` to `b`'s side `side_b`, meeting each at
    /// G`level` (1 or 2); `bulge` scales how far it leaves each edge.
    #[func]
    fn blend_sides(
        a: Gd<CadaclysmSolid>,
        side_a: GString,
        b: Gd<CadaclysmSolid>,
        side_b: GString,
        #[opt(default = 2)] level: i64,
        #[opt(default = 1.0)] bulge: f64,
        #[opt(default = 0)] face_a: i64,
        #[opt(default = 0)] face_b: i64,
    ) -> Option<Gd<CadaclysmSolid>> {
        let (side_a, side_b) = (sheet_side(&side_a)?, sheet_side(&side_b)?);
        let level = index(level, "blend_sides: level")?;
        let face_a = Self::face_index(face_a, "blend_sides")?;
        let face_b = Self::face_index(face_b, "blend_sides")?;
        a.bind().with(&b, |x, y| bs::Solid::blend_sides(x, side_a, y, side_b, level, bulge, face_a, face_b)).map(CadaclysmSolid::wrap)
    }

    /// The sheet filling a hole of three or more sides: N four-sided NURBS faces round a
    /// central point. Each of `boundaries`, in order round the hole, is a sheet's side met at
    /// G2, `[sheet, side]`; `[sheet, side, level]`; a `Dictionary` with `sheet`, `side` and any
    /// of `level`, `face` and `range` (`[from, to]` of the side's parameter); or a
    /// `CadaclysmNurbsCurve`, met at G0. Its `patch_report` says how well it meets.
    #[func]
    fn n_sided_patch(boundaries: AnyArray, #[opt(default = 1.0)] bulge: f64, #[opt(default = 0.01)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        let args: Vec<BoundaryArg> = boundaries.iter_shared().enumerate().map(|(i, b)| patch_boundary(&b, i)).collect::<Option<_>>()?;
        let sheets: Vec<GdRef<CadaclysmSolid>> = args
            .iter()
            .filter_map(|b| match b {
                BoundaryArg::Side { sheet, .. } => Some(sheet.bind()),
                BoundaryArg::Curve(_) => None,
            })
            .collect();
        let curves: Vec<GdRef<CadaclysmNurbsCurve>> = args
            .iter()
            .filter_map(|b| match b {
                BoundaryArg::Curve(curve) => Some(curve.bind()),
                BoundaryArg::Side { .. } => None,
            })
            .collect();
        let (mut sheet, mut curve) = (sheets.iter(), curves.iter());
        let mut rows = Vec::with_capacity(args.len());
        for b in &args {
            rows.push(match b {
                BoundaryArg::Side { side, face, level, range, .. } => {
                    bs::PatchBoundary::side(sheet.next()?.held()?, *side).face(*face).level(*level).range(range.0, range.1)
                }
                BoundaryArg::Curve(_) => bs::PatchBoundary::curve(&curve.next()?.curve),
            });
        }
        Self::made(bs::Solid::n_sided_patch(&rows, bulge, Some(tolerance)))
    }

    /// The rolling-ball fillet between face `face_a` of `a` and face `face_b` of `b` (their
    /// whole NURBS surfaces), of `radius`, or running linearly to `radius_end` (`NAN`, the
    /// default: constant); `flip_a` / `flip_b` put the ball on the other side of a face. An
    /// array `[sheet, rail_a, rail_b]` -- the fillet sheet (its `sheet_error` set) and the
    /// `CadaclysmNurbsCurve`s the ball touches each face along -- or `null`, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn fillet_surfaces(
        a: Gd<CadaclysmSolid>,
        b: Gd<CadaclysmSolid>,
        radius: f64,
        #[opt(default = f64::NAN)] radius_end: f64,
        #[opt(default = false)] flip_a: bool,
        #[opt(default = false)] flip_b: bool,
        #[opt(default = 1e-3)] tolerance: f64,
        #[opt(default = 0)] face_a: i64,
        #[opt(default = 0)] face_b: i64,
    ) -> Variant {
        let found = (|| {
            let face_a = Self::face_index(face_a, "fillet_surfaces")?;
            let face_b = Self::face_index(face_b, "fillet_surfaces")?;
            let end = optional_number(radius_end);
            a.bind().with(&b, |x, y| bs::Solid::fillet_surfaces(x, y, radius, end, flip_a, flip_b, Some(tolerance), face_a, face_b))
        })();
        match found {
            Some((sheet, rail_a, rail_b)) => {
                varray![&CadaclysmSolid::wrap(sheet), &CadaclysmNurbsCurve::wrap(rail_a), &CadaclysmNurbsCurve::wrap(rail_b)].to_variant()
            }
            None => Variant::nil(),
        }
    }

    /// This sheet cut along `curve` (a `CadaclysmNurbsCurve` lying on it) and nothing removed:
    /// each face comes back as its pieces outside the cutter, then its pieces inside. The cutter
    /// is the curve run along `direction` (three numbers; empty: the mean of the sheet's normals
    /// along the curve). `tolerance` is the split's meshing tolerance.
    #[func]
    fn split_by_curve(
        &self,
        curve: Gd<CadaclysmNurbsCurve>,
        #[opt(default = &PackedFloat64Array::new())] direction: PackedFloat64Array,
        #[opt(default = 0.05)] tolerance: f64,
    ) -> Option<Gd<CadaclysmSolid>> {
        let direction = optional_v3(&direction, "split_by_curve: direction")?;
        let curve = curve.bind();
        self.then(|s| s.split_by_curve(&curve.curve, direction, Some(tolerance)))
    }

    /// This sheet cut along `curve` and one side thrown away: `keep` `"outside"` keeps the
    /// sheet with the hole a closed curve cuts, `"inside"` the island; for an open curve
    /// `"left"` (the same as `"inside"`) keeps the side left of its run seen from where
    /// `direction` points, `"right"` the other.
    #[func]
    fn trim_by_curve(
        &self,
        curve: Gd<CadaclysmNurbsCurve>,
        #[opt(default = "outside")] keep: GString,
        #[opt(default = &PackedFloat64Array::new())] direction: PackedFloat64Array,
        #[opt(default = 0.05)] tolerance: f64,
    ) -> Option<Gd<CadaclysmSolid>> {
        let keep = ok(keep.to_string().parse::<bs::TrimKeep>())?;
        let direction = optional_v3(&direction, "trim_by_curve: direction")?;
        let curve = curve.bind();
        self.then(|s| s.trim_by_curve(&curve.curve, keep, direction, Some(tolerance)))
    }

    /// `section` (a `CadaclysmNurbsCurve` in the plane z = 0 starting at the origin) swept
    /// along each of `edges` (naked edges of this sheet: `CadaclysmEdge`s or their indices) on
    /// the face's own frame: the section's x runs outward from the face, square to the edge in
    /// its tangent plane, and its y along the face's normal, so `(0, 0)` to `(0, -10)` turns the
    /// edge under by 10 and `(0, 0)` to `(10, 0)` carries the face on. With `join` the sweeps
    /// come back sewn to this sheet (its faces first, then one per edge), else alone. Fitted
    /// within `tolerance`; `sheet_error` says how close.
    #[func]
    fn flange(
        &self,
        edges: Variant,
        section: Gd<CadaclysmNurbsCurve>,
        #[opt(default = 1e-3)] tolerance: f64,
        #[opt(default = true)] join: bool,
    ) -> Option<Gd<CadaclysmSolid>> {
        let edges = indices(&edges, "flange: edges")?;
        let section = section.bind();
        self.then(|s| s.flange(&edges, &section.curve, Some(tolerance), join))
    }

    /// Each of `edges` (naked edges of this sheet: `CadaclysmEdge`s or their indices) slid
    /// along `direction` (three numbers) until it meets `target` (a `CadaclysmSolid`): one wall
    /// per edge, the edge's curve swept straight to the curve through its first hits on
    /// `target`'s faces, fitted within `tolerance` (`sheet_error`). With `join` the walls come
    /// back sewn to this sheet (its faces first, then one per edge), else alone.
    #[func]
    fn extrude_to(
        &self,
        edges: Variant,
        direction: Variant,
        target: Gd<CadaclysmSolid>,
        #[opt(default = 1e-3)] tolerance: f64,
        #[opt(default = true)] join: bool,
    ) -> Option<Gd<CadaclysmSolid>> {
        let edges = indices(&edges, "extrude_to: edges")?;
        let direction = v3(&direction, "extrude_to: direction")?;
        self.with(&target, |a, b| a.extrude_to(&edges, direction, b, Some(tolerance), join)).map(CadaclysmSolid::wrap)
    }

    /// `sheets` (an array of `CadaclysmSolid`s) joined into one body, their faces in order:
    /// every two naked edges agreeing within `tolerance` (0: a rounding of the body's size)
    /// sewn into one. An array `[solid, report]`, the report a `CadaclysmJoinReport`, or `null`
    /// with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn join_sheets(sheets: AnyArray, #[opt(default = 0.0)] tolerance: f64) -> Variant {
        let found = (|| {
            let list = object_list::<CadaclysmSolid>(&sheets, "join_sheets: sheets")?;
            let guards: Vec<GdRef<CadaclysmSolid>> = list.iter().map(|s| s.bind()).collect();
            let held: Vec<&bs::Solid> = guards.iter().map(|g| g.held()).collect::<Option<_>>()?;
            ok(bs::Solid::join_sheets(&held, Some(tolerance)))
        })();
        match found {
            Some((solid, report)) => varray![&CadaclysmSolid::wrap(solid), &CadaclysmJoinReport::wrap(report)].to_variant(),
            None => Variant::nil(),
        }
    }

    /// `fillet` with a flat bevel: each edge cut back `distance` along both its faces.
    #[func]
    fn chamfer(&self, edges: Variant, distance: f64, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        let edges = indices(&edges, "chamfer: edges")?;
        self.then(|s| s.chamfer(&edges, distance, tolerance))
    }

    /// Face `face` pushed out by `distance` along its outward normal (in, negative) and
    /// the flush faces merged, as a face extrude does it. A face on a cylinder,
    /// a cone, a sphere or a torus moves out along its normal instead, the flat faces
    /// beside it carried along.
    ///
    /// `face` may be a list of faces (ints or a `PackedInt32Array`), pushed together as
    /// a press-pull on a selection: a box's top and a side pushed 5 is the box 5
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

    /// This solid split by the closed `profile` drawn on `frame`, pushed straight
    /// through it along the frame's z both ways: the bodies outside the profile first,
    /// then those inside. Empty on failure.
    #[func]
    fn split_by_profile(&self, profile: Gd<CadaclysmProfile>, frame: Variant, #[opt(default = 0.05)] tolerance: f64) -> Array<Gd<CadaclysmSolid>> {
        let (Some(f), Some(s)) = (self::frame(&frame, "split_by_profile: frame"), self.held()) else { return Array::new() };
        Self::many(s.split_by_profile(&profile.bind().profile, &f, tolerance))
    }

    /// This solid's connected bodies, each a solid of its own, in the order of their
    /// first faces.
    #[func]
    fn lumps(&self) -> Array<Gd<CadaclysmSolid>> {
        self.held().map(|s| Self::many(s.lumps())).unwrap_or_default()
    }

    /// The regions of space this solid's faces bound, as `CadaclysmRegion`s, region 0 the
    /// infinite one: two for an ordinary solid (outside, inside), one per cell for a `merge`'s
    /// body, one more per cavity. Each lists its sides -- a face and `sense` +1 where the region
    /// is the side the face's normal points to, -1 the other -- and its `shells`. Empty for
    /// faces that leave an edge the same way, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn regions(&self) -> Array<Gd<CadaclysmRegion>> {
        self.held().and_then(|s| ok(s.regions())).map(CadaclysmRegion::wrap_all).unwrap_or_default()
    }

    /// Finite region `region` (an index into `regions`) as a closed solid of its own: the
    /// faces bounding it, each turned to point out of it, each keeping its colour. `null` for
    /// `region` outside 0 to 4294967295 (before the call), region 0 (the infinite one) or a
    /// region past the count, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn region_solid(&self, region: i64) -> Option<Gd<CadaclysmSolid>> {
        let Ok(region) = u32::try_from(region) else {
            return fail(format!("region_solid: region is out of range: {region}"));
        };
        self.then(|s| s.region_solid(region))
    }

    /// This solid with its flush faces merged: the seams a `join` leaves where two
    /// parts are flush.
    #[func]
    fn merge_flush(&self) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.merge_flush())
    }

    /// The round `face` belongs to, made again at `radius` (a press-pull on a
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

    /// This sheet made a solid `thickness` thick: its faces, their
    /// twins moved along the faces' normals, and a wall round every open edge.
    #[func]
    fn thicken(&self, thickness: f64, #[opt(default = 1e-6)] tolerance: f64) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.thicken(thickness, tolerance))
    }

    // -- colour

    /// This solid coloured `colour` (a `Color`, `"#rrggbb"`, a CSS colour name, or three numbers in 0..1),
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

    /// This solid with every edge coloured `colour`. Inherited as face colours are: a
    /// move keeps every one, a boolean or a fillet gives each edge the colour of the
    /// input edge it lies on, a new edge the all-edges one. `#[opt(default = ...)]` has no
    /// truly-immutable `Variant` to default `edges` to (unlike `coloured`'s `face: i64`),
    /// so this is split as `svg_text`/`svg_text_with` are: call `edges_coloured_with` to
    /// pick edges.
    #[func]
    fn edges_coloured(&self, colour: Variant) -> Option<Gd<CadaclysmSolid>> {
        self.edges_coloured_with(colour, Variant::nil())
    }

    /// `edges_coloured`, with `edges` (`CadaclysmEdge`s or their indices, as `fillet`
    /// takes them) picked: just those are coloured, a colour that wins over the
    /// all-edges one; an empty list colours none, `null` every edge (`edges_coloured`'s
    /// own case).
    #[func]
    fn edges_coloured_with(&self, colour: Variant, edges: Variant) -> Option<Gd<CadaclysmSolid>> {
        let rgb = colour_arg(&colour)?;
        if edges.is_nil() {
            return self.then(|s| s.edges_coloured(rgb, None));
        }
        let edges = indices(&edges, "edges_coloured: edges")?;
        self.then(|s| s.edges_coloured(rgb, Some(&edges)))
    }

    /// Edge `edge`'s colour as drawn -- its own, else the solid's edge colour -- or `null`.
    #[func]
    fn edge_colour(&self, edge: i64) -> Variant {
        let Some(solid) = self.held() else { return Variant::nil() };
        let colour = match u32::try_from(edge) {
            Ok(e) => ok(solid.edge_colour(e)),
            Err(_) => {
                let count = solid.edges().map(|e| e.len()).unwrap_or_default();
                fail(format!("edge_colour: edge {edge} is not one of the solid's {count}"))
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

    /// Edge `edge` (an index into `edges`) by what it is, fifteen doubles: its kind (line 0,
    /// circle 1, ellipse 2, B-spline 3, other 4), its midpoint (x y z), its unit tangent there
    /// (x y z), its length, the outward normals there of the two faces meeting on it (x y z
    /// each; an open sheet's rim gives its one face's twice), and its span -- how far from the
    /// midpoint `find_edge` may look on a resized solid. `face_ref`'s twin: take it before any
    /// move you apply to the solid. Empty for an edge past the table or one with no length,
    /// the reason in `Cadaclysm.last_error()`.
    #[func]
    fn edge_ref(&self, edge: i64) -> PackedFloat64Array {
        let Some(edge) = Self::edge_index(edge, "edge_ref") else { return PackedFloat64Array::new() };
        self.held().and_then(|s| ok(s.edge_ref(edge))).map(|r| PackedFloat64Array::from(&r[..])).unwrap_or_default()
    }

    /// The edge `edge_ref` (from `edge_ref`) refers to: of the edges of that kind passing
    /// within `tolerance` of its midpoint and running the same way, the one of nearest
    /// length; where none does (the solid was resized), the edge of that kind running the
    /// same way between faces facing the same two ways, the only one or the one clearly
    /// nearest, no farther than the span. -1 where the edge is gone, and -1 for a reference
    /// that is not fifteen finite numbers or a `tolerance` not positive, the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn find_edge(&self, edge_ref: PackedFloat64Array, #[opt(default = 1e-3)] tolerance: f64) -> i64 {
        let Ok(r) = <[f64; 15]>::try_from(edge_ref.as_slice()) else {
            return fail::<()>("find_edge: an edge reference is fifteen finite numbers").map_or(-1, |()| -1);
        };
        self.held().and_then(|s| ok(s.find_edge(&r, tolerance))).flatten().map_or(-1, i64::from)
    }

    /// How many vertices this solid has: its edges' ends, welded, in the order `vertex_ref`
    /// and `find_vertex` index. 0 on failure.
    #[func]
    fn get_vertex_count(&self) -> i64 {
        self.held().and_then(|s| ok(s.vertex_count())).map_or(0, i64::from)
    }

    /// Vertex `vertex` by where it is, three doubles: `[x, y, z]` in the solid's own
    /// coordinates. Empty for a vertex the solid does not have, the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn vertex_ref(&self, vertex: i64) -> PackedFloat64Array {
        let Ok(vertex) = u32::try_from(vertex) else {
            fail::<()>(format!("vertex_ref: no vertex {vertex}"));
            return PackedFloat64Array::new();
        };
        self.held().and_then(|s| ok(s.vertex_ref(vertex))).map(|r| PackedFloat64Array::from(&r[..])).unwrap_or_default()
    }

    /// The vertex nearest `vertex_ref` -- a `vertex_ref`, or any point picked: a `Vector3`
    /// or three numbers -- within `tolerance`. -1 where no vertex is that near, and -1 for a
    /// point that is not three finite numbers or a `tolerance` not positive, the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn find_vertex(&self, vertex_ref: Variant, #[opt(default = 1e-3)] tolerance: f64) -> i64 {
        let Some(p) = v3(&vertex_ref, "find_vertex") else { return -1 };
        self.held().and_then(|s| ok(s.find_vertex(&p, tolerance))).flatten().map_or(-1, i64::from)
    }

    // -- identity: ids on faces and edges, where each came from, and a verb's history

    /// This solid tracked: its faces numbered 1..n in face order and its edges 1..m in
    /// `edges`' order, each its own origin. Tracking rides on from here: a verb on a tracked
    /// solid gives a tracked result, each face keeping the id of the input face it lies on
    /// and naming that face as its origin. Opt-in, as it costs time after every verb. A
    /// tracked solid comes back as it is.
    #[func]
    fn tracked(&self) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.tracked())
    }

    /// Whether this solid carries face and edge ids: it was `tracked`, made from a tracked
    /// solid, or given an attribute.
    #[func]
    fn get_is_tracked(&self) -> bool {
        self.held().and_then(|s| ok(s.is_tracked())).unwrap_or(false)
    }

    /// Face `face`'s id, **-1 where this solid is untracked** (Godot has no null int; an id
    /// is never below 1). An id stays with its face through every verb that keeps the face
    /// -- a move, a boolean, a fillet of another edge -- so it names "the same face, through
    /// my edits" within a session; a piece split off, a later operand's face whose id an
    /// earlier one already has, and a face on no input get fresh ids, the same run after
    /// run. Ids are not written to files: to find a face on a model rebuilt or read again,
    /// use `face_ref`. -1 too for a face the solid does not have, the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn face_id(&self, face: i64) -> i64 {
        let Some(face) = Self::face_index(face, "face_id") else { return -1 };
        Self::id_or_none(self.held().and_then(|s| ok(s.face_id(face))))
    }

    /// The face whose id is `id`, -1 where no face has it (an untracked solid, an id 0, a
    /// face a verb deleted).
    #[func]
    fn face_with_id(&self, id: i64) -> i64 {
        let Ok(id) = u64::try_from(id) else { return Self::no_index() };
        self.held().and_then(|s| ok(s.face_with_id(id))).flatten().map_or(-1, i64::from)
    }

    /// The input faces face `face` came from, each `[operand, id]`: the operand the input's
    /// index in the verb's operand order (a boolean's target 0, its tool 1), the id that
    /// input face's `face_id`. The face it lies on most first; empty for a face the verb
    /// generated (a fillet's round, a split's cut face) or an untracked solid; more than one
    /// for a face merged from several (a `join` with `merge`). Empty too for a face the solid
    /// does not have, the reason in `Cadaclysm.last_error()`.
    #[func]
    fn face_origins(&self, face: i64) -> VarArray {
        let Some(face) = Self::face_index(face, "face_origins") else { return VarArray::new() };
        Self::origin_list(self.held().and_then(|s| ok(s.face_origins(face))))
    }

    /// Edge `edge`'s id (an index into `edges`), as `face_id`: -1 where this solid is
    /// untracked.
    #[func]
    fn edge_id(&self, edge: i64) -> i64 {
        let Some(edge) = Self::edge_index(edge, "edge_id") else { return -1 };
        Self::id_or_none(self.held().and_then(|s| ok(s.edge_id(edge))))
    }

    /// The edge whose id is `id`, -1 where no edge has it.
    #[func]
    fn edge_with_id(&self, id: i64) -> i64 {
        let Ok(id) = u64::try_from(id) else { return Self::no_index() };
        self.held().and_then(|s| ok(s.edge_with_id(id))).flatten().map_or(-1, i64::from)
    }

    /// The input edge edge `edge` lies on, as `face_origins`: one `[operand, id]`, or none
    /// for a new edge. Edges merged from several are not seen.
    #[func]
    fn edge_origins(&self, edge: i64) -> VarArray {
        let Some(edge) = Self::edge_index(edge, "edge_origins") else { return VarArray::new() };
        Self::origin_list(self.held().and_then(|s| ok(s.edge_origins(edge))))
    }

    /// What the verb that made this solid did to the faces of `inputs` -- `CadaclysmSolid`s
    /// in its operand order (`a.cut(b).history([a, b])`) -- as a `CadaclysmHistory`. Read
    /// off this solid's ids and origins alone, so it costs no geometry. `null` where this
    /// solid or an input is untracked, or an origin names an operand past the inputs, the
    /// reason in `Cadaclysm.last_error()`.
    #[func]
    fn history(&self, inputs: AnyArray) -> Option<Gd<CadaclysmHistory>> {
        self.read_history(&inputs, "history", |s, i| s.history(i))
    }

    /// `history` for the edges, by edge id.
    #[func]
    fn edge_history(&self, inputs: AnyArray) -> Option<Gd<CadaclysmHistory>> {
        self.read_history(&inputs, "edge_history", |s, i| s.edge_history(i))
    }

    // -- attributes: text on a solid (written to STEP files) and on its faces (in memory)

    /// This solid's attributes, a read-only `Dictionary` of `String` keys and values built in
    /// key order. A solid's attributes go with it through every verb (a verb's result takes
    /// its first operand's) and are written to STEP files as user-defined attributes. Empty
    /// on failure.
    #[func]
    fn get_attributes(&self) -> VarDictionary {
        Self::attribute_dictionary(self.held().and_then(|s| ok(s.attributes())))
    }

    /// Attribute `key`, a `String`, or `null` where this solid has none -- `null` rather
    /// than `""`, which is a value an attribute can have.
    #[func]
    fn attribute(&self, key: GString) -> Variant {
        Self::text_or_null(self.held().and_then(|s| ok(s.attribute(&key.to_string()))))
    }

    /// This solid with attribute `key` set to `value`, over any it had: a new solid, tracked
    /// if this one was not. Keys and values are text with no NUL; an empty key is refused.
    #[func]
    fn with_attribute(&self, key: GString, value: GString) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.with_attribute(&key.to_string(), &value.to_string()))
    }

    /// This solid with every attribute of `attributes` -- a `Dictionary` of `String` keys and
    /// values -- set, in key order. An empty `Dictionary` gives a solid equal to this one.
    #[func]
    fn with_attributes(&self, attributes: VarDictionary) -> Option<Gd<CadaclysmSolid>> {
        let pairs = Self::attribute_pairs(&attributes, "with_attributes")?;
        self.then(|s| s.with_attributes(pairs))
    }

    /// This solid without attribute `key`: a new solid, equal to this one where it had none.
    #[func]
    fn without_attribute(&self, key: GString) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.without_attribute(&key.to_string()))
    }

    /// Face `face`'s attributes, a read-only `Dictionary` in key order, as `attributes`. A
    /// face's attributes follow its id: kept through a verb, and copied to every face that
    /// names it as an origin (each piece of a split face has its parent's). They stay in
    /// memory: no file carries them. Empty for a face the solid does not have, the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn face_attributes(&self, face: i64) -> VarDictionary {
        let Some(face) = Self::face_index(face, "face_attributes") else { return VarDictionary::new() };
        Self::attribute_dictionary(self.held().and_then(|s| ok(s.face_attributes(face))))
    }

    /// Face `face`'s attribute `key`, a `String`, or `null` where it has none (and for a face
    /// the solid does not have, the reason in `Cadaclysm.last_error()`).
    #[func]
    fn face_attribute(&self, face: i64, key: GString) -> Variant {
        let Some(face) = Self::face_index(face, "face_attribute") else { return Variant::nil() };
        Self::text_or_null(self.held().and_then(|s| ok(s.face_attribute(face, &key.to_string()))))
    }

    /// This solid with face `face`'s attribute `key` set to `value`: a new solid, tracked if
    /// this one was not. Refused as `with_attribute`, and for a face the solid does not have.
    #[func]
    fn with_face_attribute(&self, face: i64, key: GString, value: GString) -> Option<Gd<CadaclysmSolid>> {
        let face = Self::face_index(face, "with_face_attribute")?;
        self.then(|s| s.with_face_attribute(face, &key.to_string(), &value.to_string()))
    }

    /// This solid with every attribute of `attributes` (a `Dictionary` of `String`s) set on
    /// face `face`, in key order, as `with_attributes`.
    #[func]
    fn with_face_attributes(&self, face: i64, attributes: VarDictionary) -> Option<Gd<CadaclysmSolid>> {
        let face = Self::face_index(face, "with_face_attributes")?;
        let pairs = Self::attribute_pairs(&attributes, "with_face_attributes")?;
        self.then(|s| s.with_face_attributes(face, pairs))
    }

    /// This solid without face `face`'s attribute `key`: a new solid, equal to this one where
    /// the face had none. Refused for a face the solid does not have.
    #[func]
    fn without_face_attribute(&self, face: i64, key: GString) -> Option<Gd<CadaclysmSolid>> {
        let face = Self::face_index(face, "without_face_attribute")?;
        self.then(|s| s.without_face_attribute(face, &key.to_string()))
    }

    /// The solid's axis-aligned box, at the same cost whatever its size: its mesh at a
    /// thousandth of its own extent, so the box is inside the exact one and short of it by at
    /// most that. `bounds_at` is the box of the mesh at a tolerance you name.
    #[func]
    fn get_bounds(&self) -> Aabb {
        self.held().and_then(|s| ok(s.bounds())).map(|(lo, hi)| aabb(lo, hi)).unwrap_or_default()
    }

    /// The axis-aligned box around its mesh at `tolerance` (the same cache `mesh`
    /// fills).
    #[func]
    fn bounds_at(&self, tolerance: f64) -> Aabb {
        self.held().and_then(|s| ok(s.bounds_at(tolerance))).map(|(lo, hi)| aabb(lo, hi)).unwrap_or_default()
    }

    /// `bounds_at(tolerance)`'s box as six doubles: min x, y, z, then max x, y, z. Empty on
    /// failure.
    #[func]
    fn raw_bounds(&self, #[opt(default = 0.05)] tolerance: f64) -> PackedFloat64Array {
        let bounds = self.held().and_then(|s| ok(s.bounds_at(tolerance)));
        bounds.map(|(lo, hi)| PackedFloat64Array::from(&[lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]][..])).unwrap_or_default()
    }

    /// This solid's box at `tolerance`: its boolean mesh, padded by twice that -- the
    /// broad phase's own shape, cheaper to move and test than the solid itself.
    #[func]
    fn bounds_box(&self, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmBox>> {
        self.held().and_then(|s| ok(s.bounds_box(tolerance))).map(CadaclysmBox::wrap)
    }

    /// A `CadaclysmRTree` over this solid's faces: one entry per face, its id the face index
    /// the other face calls take, its box holding the face (the box the boolean's broad phase
    /// pairs faces by, grown by a thousandth of the solid's extent). No faces give an empty
    /// tree. The tree is its own and outlives the solid. `null` for a face that cannot be
    /// boxed, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn face_tree(&self) -> Option<Gd<CadaclysmRTree>> {
        self.held().and_then(|s| ok(s.face_tree())).map(CadaclysmRTree::wrap)
    }

    /// The solid's box on its principal axes, as a `CadaclysmOrientedBox`, measured to a
    /// relative `accuracy`: 0 or less is the box's own default, 1e-5; NaN or infinite is
    /// refused. `null` on failure (an open body, a bad accuracy), with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn oriented_box(&self, #[opt(default = 0.0)] accuracy: f64) -> Option<Gd<CadaclysmOrientedBox>> {
        self.held().and_then(|s| ok(s.oriented_box(accuracy))).map(CadaclysmOrientedBox::wrap)
    }

    /// The length of edge `edge` (an index from `edges`, the one `fillet` takes), as a
    /// `CadaclysmLength`, to a relative `accuracy` in (0, 1): 0 or less is the default;
    /// NaN, infinite or 1 or more is refused. `null` on failure (no such edge, a bad
    /// accuracy), with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn edge_length(&self, edge: i64, #[opt(default = 0.0)] accuracy: f64) -> Option<Gd<CadaclysmLength>> {
        let Ok(edge) = u32::try_from(edge) else { return fail(format!("edge_length: no edge {edge}")) };
        self.held().and_then(|s| ok(s.edge_length(edge, accuracy))).map(CadaclysmLength::wrap)
    }

    /// The point `s` of arc length from the start of edge `edge` (an index from `edges`,
    /// the one `edge_length` takes), as a `CadaclysmAt`. `s` is 0 to the edge's length;
    /// `accuracy` is relative, in (0, 1): 0 or less is the default; NaN, infinite or 1 or
    /// more is refused. `null` on failure (no such edge, no exact curve, `s` outside the
    /// edge, a bad accuracy), with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn edge_point_at_length(&self, edge: i64, s: f64, #[opt(default = 0.0)] accuracy: f64) -> Option<Gd<CadaclysmAt>> {
        let Ok(edge) = u32::try_from(edge) else { return fail(format!("edge_point_at_length: no edge {edge}")) };
        self.held().and_then(|x| ok(x.edge_point_at_length(edge, s, accuracy))).map(CadaclysmAt::wrap)
    }

    /// Edge `edge` in `n` pieces of equal arc length, as an array of `CadaclysmAt`: an open
    /// edge gives `n + 1` samples from its start to its end, a closed one `n`, never its
    /// start again. `n` is 1 to 1,000,000; `accuracy` as `edge_point_at_length`. Empty on
    /// failure (including an `n` that is not a count), with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn edge_divide_by_count(&self, edge: i64, n: i64, #[opt(default = 0.0)] accuracy: f64) -> Array<Gd<CadaclysmAt>> {
        let Some(n) = sample_count("edge_divide_by_count", n) else { return Array::new() };
        let Ok(edge) = u32::try_from(edge) else {
            fail::<()>(format!("edge_divide_by_count: no edge {edge}"));
            return Array::new();
        };
        let list = self.held().and_then(|x| ok(x.edge_divide_by_count(edge, n, accuracy)));
        CadaclysmAt::wrap_all(list.unwrap_or_default())
    }

    /// Samples of edge `edge` every `step` of arc length from its start, as an array of
    /// `CadaclysmAt`; the last piece is whatever is left over, kept short, and a closed
    /// edge never repeats its start. `step` is positive and finite and may give at most
    /// 999,999 steps; `accuracy` as `edge_point_at_length`. Empty on failure, with the
    /// reason in `Cadaclysm.last_error()`.
    #[func]
    fn edge_divide_by_length(&self, edge: i64, step: f64, #[opt(default = 0.0)] accuracy: f64) -> Array<Gd<CadaclysmAt>> {
        let Ok(edge) = u32::try_from(edge) else {
            fail::<()>(format!("edge_divide_by_length: no edge {edge}"));
            return Array::new();
        };
        let list = self.held().and_then(|x| ok(x.edge_divide_by_length(edge, step, accuracy)));
        CadaclysmAt::wrap_all(list.unwrap_or_default())
    }

    /// Where `point` (a `Vector3` or three numbers) lies against the solid: `"outside"`,
    /// `"inside"` or `"on"` (within `tolerance` of the surface). `""` on failure (a point
    /// that is not finite, a tolerance not positive and finite, an open sheet), with the
    /// reason in `Cadaclysm.last_error()`. `classifier` answers many points faster.
    #[func]
    fn contains(&self, point: Variant, #[opt(default = 0.05)] tolerance: f64) -> GString {
        let Some(p) = v3(&point, "contains: point") else { return GString::new() };
        gs(self.held().and_then(|s| ok(s.contains(p, tolerance))).unwrap_or_default())
    }

    /// A reusable `CadaclysmClassifier` for many `contains` questions on this solid,
    /// within `tolerance`. It keeps its own reference to the body, so it outlives this
    /// solid. `null` on failure (a tolerance not positive and finite, an open sheet), with
    /// the reason in `Cadaclysm.last_error()`.
    #[func]
    fn classifier(&self, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmClassifier>> {
        self.held().and_then(|s| ok(s.classifier(tolerance))).map(CadaclysmClassifier::wrap)
    }

    /// The closest points between this solid's boundary and `other`'s, as a
    /// `CadaclysmClosest`, found to `tolerance`. Open bodies and sheets are accepted. `null` on
    /// failure (a tolerance not positive and finite, a solid with no faces), with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn closest(&self, other: Gd<CadaclysmSolid>, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmClosest>> {
        let other = other.bind();
        let theirs = other.held()?;
        self.held().and_then(|s| ok(s.closest(theirs, tolerance))).map(CadaclysmClosest::wrap)
    }

    /// How thick this solid's walls are at face `face`, as a `CadaclysmFaceThickness`, on a
    /// `CadaclysmThicknessGauge` of this solid alone built at `tolerance` (0.01 by default),
    /// asked `thickness_at_face` once and freed: at `at`'s foot on the face (a `Vector3` or
    /// three numbers), or with `at` `null` over the face's vertices. `null` where nothing on
    /// the face reads within `maximum`, or `at`'s foot lies off the face (then
    /// `Cadaclysm.last_error()` is empty); `null` with the reason in `Cadaclysm.last_error()`
    /// for a `face` negative or past a `u32`, an `at` that is not three numbers, and in the
    /// gauge's words (`thickness_gauge_new: ...`, `thickness_gauge_face: ...`) a face past the
    /// end, an `at` not finite, a `maximum` or a `tolerance` not positive and finite.
    #[func]
    fn thickness_at_face(&self, face: i64, at: Variant, maximum: f64, #[opt(default = 0.01)] tolerance: f64) -> Option<Gd<CadaclysmFaceThickness>> {
        let solid = self.held()?;
        let face = rtree_u32(face, "thickness_gauge_face", "face")?;
        let at = thickness_optional_point(&at, "thickness_gauge_face")?;
        ok(solid.thickness_at_face(face, at, maximum, tolerance)).flatten().map(CadaclysmFaceThickness::wrap)
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

    /// What is wrong with this solid, as a Dictionary with `HealthReport`'s keys -- the same
    /// Dictionary `CadaclysmBrep.health` gives: `tolerance`, `rounding`, `extent`, `free_edges`
    /// (Dictionaries `{trim, edge, face, wire, partner, shared_ends, length, gap}`, `edge` and
    /// `partner` -1 for none), `wires` (`{first, count, closed, length, widest_gap}`), `small`
    /// (`{kind, index, size}`, `kind` a String), `loose_edges`, `worst_loose`, `sew_pairs`,
    /// `sew_refused`, `sew_worst_gap`, `cracks` (`{watertight, open, folded, crossings,
    /// edges}`, or `null` unless `mesh`) and `worst_gap`. Nothing moves. `tolerance` is an
    /// absolute length; 0 (the default), a negative, NaN or INF takes the library's default,
    /// `1e-4` times the diagonal. A wire's edges are `free_edges.slice(w.first, w.first +
    /// w.count)`. An empty Dictionary on failure (a closed solid), with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn health(&self, #[opt(default = 0.0)] tolerance: f64, #[opt(default = false)] mesh: bool) -> VarDictionary {
        self.held()
            .and_then(|s| ok(s.health(reader::heal_tolerance(tolerance), mesh)))
            .map(|r| reader::health_report(&r))
            .unwrap_or_default()
    }

    /// This solid with its small features removed, beside what was done, as a Dictionary
    /// `{body, report}`: `body` a new `CadaclysmSolid` keeping this one's name and colours
    /// (this one is left as it was), `report` the Dictionary `CadaclysmBrep.healed` gives --
    /// `tolerance`, `moved`, `guarded`, `fixes` (`{kind, index, size, moved}`), `refused`
    /// (`{kind, index, why, figure}`, `why` a String), `small_before`, `small_after`,
    /// `free_before`, `free_after`, `closed_before`, `closed_after`, `nonmanifold_before`,
    /// `nonmanifold_after`. `edges`, `faces` and `holes` switch each kind of fix; a kind
    /// switched off is refused as `"toggled"`. `tolerance` as `health`'s. An empty Dictionary
    /// on failure, with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn healed(
        &self,
        #[opt(default = 0.0)] tolerance: f64,
        #[opt(default = true)] edges: bool,
        #[opt(default = true)] faces: bool,
        #[opt(default = true)] holes: bool,
    ) -> VarDictionary {
        let kinds = reader::heal_kinds(edges, faces, holes);
        self.held()
            .and_then(|s| ok(s.healed(reader::heal_tolerance(tolerance), kinds)))
            .map(|(solid, report)| reader::healed_pair(CadaclysmSolid::wrap(solid).to_variant(), &report))
            .unwrap_or_default()
    }

    /// How far brep edge `edge` (an id as a free edge or a fix names one) may lie off its
    /// curve: 0 for an exact edge, the distance healing or sewing moved it where that is
    /// recorded, `NAN` when no trim names the id (Godot has no null number). `NAN` too on
    /// failure (a closed solid, one the kernel cannot read, an id outside 0 to 4294967295),
    /// with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn edge_tolerance(&self, edge: i64) -> f64 {
        let Some(edge) = reader::edge_id(edge) else { return f64::NAN };
        self.held().and_then(|s| ok(s.edge_tolerance(edge))).flatten().unwrap_or(f64::NAN)
    }

    /// What this solid declares about its own precision, as a Dictionary: `absolute` (a length)
    /// and `angular` (radians), each `NAN` where nothing declared it (Godot has no null number)
    /// -- read from its file, inherited through every verb from the loosest of its inputs, or set
    /// by `with_tolerances`. A verb given a tolerance of 0 works at
    /// `CadaclysmBlacksmith.effective_tolerance`, which takes it into account. An empty
    /// Dictionary on failure (a closed solid), with the reason in `Cadaclysm.last_error()`.
    #[func]
    fn tolerances(&self) -> VarDictionary {
        match self.held().and_then(|s| ok(s.tolerances())) {
            Some(t) => reader::tolerances_dict(t),
            None => VarDictionary::new(),
        }
    }

    /// A new solid: this one declaring `absolute` (a length) and `angular` (radians) instead of
    /// what it declared, its name, paint and marks kept. 0 (the default) or `NAN` declares
    /// nothing for that field. `null` for a negative or infinite value, with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn with_tolerances(&self, #[opt(default = 0.0)] absolute: f64, #[opt(default = 0.0)] angular: f64) -> Option<Gd<CadaclysmSolid>> {
        self.then(|s| s.with_tolerances(absolute, angular))
    }

    /// How loose this solid's vertex at `point` (a `Vector3` or three numbers) is, where its
    /// producer said (an OCCT `.brep` records one per vertex): the tolerance of the nearest
    /// recorded vertex within its own tolerance of `point`. `NAN` where none is recorded there,
    /// and on failure (a point that is not three numbers, a closed solid) with the reason in
    /// `Cadaclysm.last_error()`.
    #[func]
    fn vertex_tolerance(&self, point: Variant) -> f64 {
        let Some(p) = v3(&point, "vertex_tolerance") else { return f64::NAN };
        self.held().and_then(|s| ok(s.vertex_tolerance(p))).flatten().unwrap_or(f64::NAN)
    }

    /// What it measures, per unit density, each figure beside a bound on its own error, as a
    /// Dictionary: `closed`, `inverted`, `accuracy_met` and `from_mesh` (bools), `area`,
    /// `area_error`, `volume`, `volume_error`, `centroid_error` and `inertia_error` (floats),
    /// `centroid` and `principal_moments` (three floats each) and `inertia` and `principal_axes`
    /// (nine each, row-major). `accuracy` is relative; 0 asks for the library's default.
    ///
    /// A body's weight is `density * volume` and its inertia scales the same way -- nothing here
    /// assumes a density. The volume-side figures mean something only where `closed`.
    #[func]
    fn mass(&self, #[opt(default = 0.0)] accuracy: f64) -> VarDictionary {
        let Some(m) = self.held().and_then(|s| ok(s.mass(accuracy))) else {
            return VarDictionary::default();
        };
        let flat = |rows: [[f64; 3]; 3]| {
            PackedFloat64Array::from(rows.concat().as_slice())
        };
        dict(&[
            ("closed", m.closed.to_variant()),
            ("inverted", m.inverted.to_variant()),
            ("accuracy_met", m.accuracy_met.to_variant()),
            ("from_mesh", m.from_mesh.to_variant()),
            ("area", m.area.to_variant()),
            ("area_error", m.area_error.to_variant()),
            ("volume", m.volume.to_variant()),
            ("volume_error", m.volume_error.to_variant()),
            ("centroid", PackedFloat64Array::from(m.centroid.as_slice()).to_variant()),
            ("centroid_error", m.centroid_error.to_variant()),
            ("inertia", flat(m.inertia).to_variant()),
            ("inertia_error", m.inertia_error.to_variant()),
            ("principal_moments", PackedFloat64Array::from(m.principal_moments.as_slice()).to_variant()),
            ("principal_axes", flat(m.principal_axes).to_variant()),
        ])
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

    /// This solid meshed for a solver, as a `CadaclysmSolidFemMesh`: nodes welded by bits,
    /// triangles wound outward, every node tagged with the lowest-dimension B-rep entity
    /// it lies on, and every crack reported rather than closed. `null` for a tolerance or
    /// size the mesher refuses, a closed solid it cannot mesh, or one that meshes to no
    /// triangles; `Cadaclysm.last_error()` says which.
    ///
    /// `tolerance` is how far the mesh may stray from the exact surface, and `max_size` an
    /// upper bound on element size (`0` for none). **Both default to
    /// `FemOptions::default()`'s own figures, `0.01` and `0`** -- not to the `0.05`
    /// `CadaclysmBlacksmith.default_tolerance` gives every neighbouring call here. Neither
    /// is checked by this extension: both go through as given and the library refuses what
    /// it will not take, in its own words. A solver mesh nearer its curve lowers the
    /// `tolerance`, where `max_size` only makes the elements smaller;
    /// `CadaclysmSolidFemMesh.longest_edge` is what the mesh came to.
    ///
    /// **Unlike `mesh`, this does not touch the solid's tessellation cache**: the FEM mesh
    /// is a handle of its own, so meshing the solid again at another tolerance leaves it
    /// untouched, and the solid stays free to be meshed, written or combined while one is
    /// held.
    ///
    /// `fem_mesh_placed` is the same call with a placement: a frame, as every frame
    /// argument here -- a `CadaclysmFrame`, a `Transform3D`, **twelve** numbers or four
    /// triples. The reader's `CadaclysmNode.fem_mesh_placed` takes **sixteen**,
    /// column-major, so a caller moving between the two reformats it.
    ///
    /// **A cracked solid is not a failure**: it comes back with
    /// `CadaclysmSolidFemMesh.watertight` false and its cracks in `open_edges` and
    /// `folded_edges`. **No unlicensed notice here**: this library prints it on
    /// `CadaclysmSolidFemMesh.msh_text` and `save_msh`, noticing on its writers where the
    /// reader library notices in its own constructor.
    #[func]
    fn fem_mesh(&self, #[opt(default = 0.01)] tolerance: f64, #[opt(default = 0.0)] max_size: f64) -> Option<Gd<CadaclysmSolidFemMesh>> {
        let mesh = ok(self.held()?.fem_mesh(tolerance, max_size, None))?;
        Some(CadaclysmSolidFemMesh::wrap(mesh))
    }

    /// `fem_mesh`, placed: a frame -- a `CadaclysmFrame`, a `Transform3D`, twelve numbers
    /// or four triples. See there.
    #[func]
    fn fem_mesh_placed(&self, tolerance: f64, max_size: f64, placement: Variant) -> Option<Gd<CadaclysmSolidFemMesh>> {
        let placed = frame(&placement, "fem_mesh_placed: placement")?;
        let mesh = ok(self.held()?.fem_mesh(tolerance, max_size, Some(&placed)))?;
        Some(CadaclysmSolidFemMesh::wrap(mesh))
    }

    /// Its feature edges at `tolerance`, as polylines.
    #[func]
    fn edge_polylines(&mut self, #[opt(default = 0.05)] tolerance: f64) -> Option<Gd<CadaclysmPolylines>> {
        let (positions, counts) = self.edge_runs(tolerance)?;
        Some(CadaclysmPolylines::from_runs(positions, counts))
    }

    /// A colour per polyline of `edge_polylines` at the same tolerance, as drawn: a `Color`,
    /// or `null` for a polyline on no coloured edge; an empty array where the solid has no
    /// edge paint at all. Fills the solid's cache at `tolerance`, as `edge_polylines` does.
    #[func]
    fn edge_polyline_colours(&mut self, #[opt(default = 0.05)] tolerance: f64) -> Array<Variant> {
        let Some(colours) = self.held_mut().and_then(|s| ok(s.edge_polyline_colours(tolerance))) else { return Array::new() };
        colours.into_iter().map(colour_out).collect()
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

    // -- machining

    /// This solid cut by the plane `Z = z`: its closed outlines there, in XY, nested into
    /// profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a
    /// circle crossing kept exact and any other curve as lines within `tolerance`. A plane
    /// that misses the solid is an empty array. Fails for a `z` not finite, a `tolerance`
    /// not positive and finite, a face lying in the plane (section a little above or below
    /// it), or a crossing that does not close.
    #[func]
    fn section(&self, z: f64, #[opt(default = 0.05)] tolerance: f64) -> Array<Gd<CadaclysmProfile>> {
        self.held().and_then(|s| ok(s.section(z, tolerance))).unwrap_or_default().into_iter().map(CadaclysmProfile::wrap).collect()
    }
}

// ---- CadaclysmAssembly --------------------------------------------------------------------

/// A mutable tree of placements: a name, and zero or more solids or other assemblies
/// placed in it at a frame. Placing shares rather than copies, as `bs::Assembly` -- a
/// later placement on an already-placed assembly shows up wherever it sits. `new` is
/// GDScript's own reserved name, so the constructor is `create`, as `CadaclysmFrame`'s
/// is.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmAssembly {
    base: Base<RefCounted>,
    assembly: Option<bs::Assembly>,
    #[var(get = get_name, no_set)]
    name: PhantomVar<GString>,
}

impl CadaclysmAssembly {
    fn made(result: sdk::Result<bs::Assembly>) -> Option<Gd<CadaclysmAssembly>> {
        let assembly = ok(result)?;
        Some(Gd::from_init_fn(|base| CadaclysmAssembly { base, assembly: Some(assembly), name: PhantomVar::default() }))
    }

    fn held(&self) -> Option<&bs::Assembly> {
        match &self.assembly {
            Some(assembly) => Some(assembly),
            None => fail("assembly: closed"),
        }
    }

    /// This assembly's STEP text; `schema`/`unit` as `CadaclysmSolid.step_text` takes them.
    fn own_step_text(&self, schema: &GString, unit: &GString) -> Option<String> {
        let unit = step_unit(unit)?;
        let schema = schema_arg(schema);
        ok(self.held()?.step_text(schema.as_deref(), unit))
    }

    /// `thing` (a `CadaclysmSolid` or a `CadaclysmAssembly`) placed at `f`, named `name`
    /// where it is not empty -- Godot has no null default, so `place` reads `""` as
    /// Python's `name=None`. Tried as a solid first, then an assembly, since a
    /// `Gd<CadaclysmSolid>` never casts to `Gd<CadaclysmAssembly>` or back (`try_to`
    /// checks the Godot class, not just the Rust type), so the order between the two
    /// does not matter -- exactly one ever matches.
    fn placed(&self, thing: &Variant, f: &bs::Frame, name: Option<&str>) -> Option<String> {
        let assembly = self.held()?;
        if let Ok(solid) = thing.try_to::<Gd<CadaclysmSolid>>() {
            let solid = solid.bind();
            return ok(assembly.place_solid(solid.held()?, f, name));
        }
        if let Ok(placed) = thing.try_to::<Gd<CadaclysmAssembly>>() {
            let placed = placed.bind();
            return ok(assembly.place_assembly(placed.held()?, f, name));
        }
        fail(format!("place: expected a CadaclysmSolid or a CadaclysmAssembly, not {thing}"))
    }

    /// Declare a rigid link called `name` over `placements`, through the SDK's own
    /// `Assembly::link` -- see the `#[func]` doc comment for the rules it enforces.
    fn linked(&self, name: &str, placements: &[&str]) -> Option<()> {
        ok(self.held()?.link(name, placements))
    }

    /// Connect `start` and `end` as a joint called `name`, through the SDK's own
    /// `Assembly::joint` -- see the `#[func]` doc comment for the rules it enforces.
    fn jointed(&self, name: &str, start: &str, end: &str) -> Option<()> {
        ok(self.held()?.joint(name, start, end))
    }

    /// Gives `joint` its pair, through the SDK's own `Assembly::pair` -- see the
    /// `#[func]` doc comment for the rules it enforces.
    fn paired(&self, joint: &str, kind: &str, frame: &bs::Frame, options: &bs::PairOptions) -> Option<()> {
        ok(self.held()?.pair(joint, kind, frame, options))
    }

    /// Gives `joint` its pair with the kind's own numbers, through the SDK's own
    /// `Assembly::pair_with` -- see the `#[func]` doc comment for the rules it enforces.
    fn paired_with(&self, joint: &str, kind: &str, frame: &bs::Frame, options: &bs::PairOptions, params: &[f64]) -> Option<()> {
        ok(self.held()?.pair_with(joint, kind, frame, options, params))
    }

    /// A posed copy, through the SDK's own `Assembly::posed` -- see the `#[func]` doc
    /// comment for the rules it enforces.
    fn posed_copy(&self, rows: &[(&str, &[f64])], state: Option<&str>, ground: Option<&str>) -> Option<Gd<CadaclysmAssembly>> {
        Self::made(self.held()?.posed(rows, state, ground))
    }

    /// Adds a named state, through the SDK's own `Assembly::state` -- see the `#[func]`
    /// doc comment for the rules it enforces.
    fn stated(&self, name: &str, rows: &[(&str, &[f64])]) -> Option<()> {
        ok(self.held()?.state(name, rows))
    }

    /// Adds a named motion sequence, through the SDK's own `Assembly::sequence` -- see
    /// the `#[func]` doc comment for the rules it enforces.
    fn sequenced(&self, name: &str, segments: &[(&str, f64, &str)], seconds: bool) -> Option<()> {
        ok(self.held()?.sequence(name, segments, seconds))
    }

    /// Declares this assembly's base link, through the SDK's own `Assembly::base` --
    /// see the `#[func]` doc comment for the rules it enforces.
    fn based(&self, link: &str) -> Option<()> {
        ok(self.held()?.base(link))
    }
}

#[godot_api]
impl CadaclysmAssembly {
    /// A new, empty assembly called `name`. Refused for an empty name.
    #[func]
    fn create(name: GString) -> Option<Gd<CadaclysmAssembly>> {
        Self::made(bs::Assembly::new(&name.to_string()))
    }

    /// This assembly's own name, given when it was made.
    #[func]
    fn get_name(&self) -> GString {
        gs(self.held().map(|a| a.name()).unwrap_or_default())
    }

    /// Place `thing` (a `CadaclysmSolid` or another `CadaclysmAssembly`) at `frame` in
    /// this assembly, called `name` -- or, `name` left `""`, `thing`'s own name (its
    /// `CadaclysmSolid.name`, `"part"` for an unnamed one, or the placed assembly's own
    /// name), numbered past any already taken here (`"bolt"`, `"bolt 2"`, ...). `frame`
    /// must be right-handed and orthonormal, or the call fails. An explicit `name`
    /// already taken here fails. Placing an assembly that is this one, or anywhere above
    /// this one in the tree already, fails naming the cycle. Returns the placement's
    /// name, or `""` on failure -- check `Cadaclysm.last_error()`.
    #[func]
    fn place(&self, thing: Variant, frame: Variant, #[opt(default = "")] name: GString) -> GString {
        let Some(f) = self::frame(&frame, "place: frame") else { return GString::new() };
        let name = name.to_string();
        let name = (!name.is_empty()).then_some(name.as_str());
        gs(self.placed(&thing, &f, name).unwrap_or_default())
    }

    /// Declare a rigid link called `name` over `placements`: names of placements of
    /// this assembly itself (not of assemblies placed in it -- give those their own
    /// mechanism). A placed assembly in a link moves as one piece. An empty name, a
    /// name taken by another link here, no placements, a placement named twice, one
    /// this assembly does not have, or one already in another link fails, and the
    /// assembly is left as it was -- check `Cadaclysm.last_error()`. Written as an
    /// AP242 kinematic link; a mechanism anywhere in the tree makes AP242 the default
    /// schema of `step_text`, and an explicit schema without the kinematic entities
    /// then fails. A reader `CadaclysmScene` reads it back as links and joints.
    #[func]
    fn link(&self, name: GString, placements: PackedStringArray) -> bool {
        let placements: Vec<String> = placements.as_slice().iter().map(|s| s.to_string()).collect();
        let refs: Vec<&str> = placements.iter().map(String::as_str).collect();
        self.linked(&name.to_string(), &refs).is_some()
    }

    /// Connect this assembly's links `start` and `end`, kept in that order, as a joint
    /// called `name`. An empty name, a name taken by another joint here, a link this
    /// assembly does not have, a link joined to itself, or a (start, end) pair already
    /// joined fails, and the assembly is left as it was -- check
    /// `Cadaclysm.last_error()`; the reverse pair is a different joint.
    #[func]
    fn joint(&self, name: GString, start: GString, end: GString) -> bool {
        self.jointed(&name.to_string(), &start.to_string(), &end.to_string()).is_some()
    }

    /// Gives `joint` its pair: `kind` (one of `"revolute"`, `"prismatic"`,
    /// `"cylindrical"`, `"screw"`, `"spherical"`, `"spherical_with_pin"`, `"planar"`,
    /// `"universal"`, `"homokinetic"`, `"fully_constrained"` or `"unconstrained"`),
    /// the contact frame at rest (a `CadaclysmFrame`, a `Transform3D` or twelve
    /// numbers, as `place`'s `frame` takes it), `end_frame` (the same shapes, or
    /// `null` for the pair's own rest frame unmoved), `ranges` (an array of
    /// `[lower, upper]`, each side `null` for unbounded, one entry per freedom of
    /// `kind` -- see `pair_freedom_count`; `[]` for none, read the same as giving none
    /// at all) and `pitch` (a length per revolution, required and non-zero for
    /// `"screw"`, refused for any other kind; `NAN` for none). An unknown or
    /// already-paired joint, an unknown kind, a bad pitch, ranges of the wrong length,
    /// a non-finite or inverted range, or an end frame this kind's motion cannot reach
    /// fails, and the assembly is left as it was -- check `Cadaclysm.last_error()`.
    #[func]
    fn pair(&self, joint: GString, kind: GString, frame: Variant, end_frame: Variant, ranges: AnyArray, pitch: f64) -> bool {
        let Some(f) = self::frame(&frame, "pair: frame") else { return false };
        let end_frame = if end_frame.is_nil() {
            None
        } else {
            let Some(e) = self::frame(&end_frame, "pair: end_frame") else { return false };
            Some(e)
        };
        let Some(ranges) = ranges_arg(&ranges, "pair: ranges") else { return false };
        let pitch = (!pitch.is_nan()).then_some(pitch);
        let options = bs::PairOptions { end_frame, ranges, pitch };
        self.paired(&joint.to_string(), &kind.to_string(), &f, &options).is_some()
    }

    /// `pair`, with the kind's own numbers as `params` (a `PackedFloat64Array`) in place
    /// of `pitch`: `"screw"` `[pitch]`; `"rack_and_pinion"` `[pinion_radius]`; `"gear"`
    /// `[radius_first, radius_second, ratio]` or plus `[bevel, helical_angle]`
    /// (radians), `ratio` the second link's rotation over the first's, signed; empty for
    /// every other kind. A wrong count fails (`pair: a gear takes 3 or 5 parameters, not
    /// 2`), and the assembly is left as it was -- check `Cadaclysm.last_error()`. The
    /// rest is `pair`'s.
    #[func]
    fn pair_with(&self, joint: GString, kind: GString, frame: Variant, end_frame: Variant, ranges: AnyArray, params: PackedFloat64Array) -> bool {
        let Some(f) = self::frame(&frame, "pair_with: frame") else { return false };
        let end_frame = if end_frame.is_nil() {
            None
        } else {
            let Some(e) = self::frame(&end_frame, "pair_with: end_frame") else { return false };
            Some(e)
        };
        let Some(ranges) = ranges_arg(&ranges, "pair_with: ranges") else { return false };
        let options = bs::PairOptions { end_frame, ranges, pitch: None };
        self.paired_with(&joint.to_string(), &kind.to_string(), &f, &options, params.as_slice()).is_some()
    }

    /// Adds a named state: `rows` (an array of `[joint, values]`, `values` a
    /// `PackedFloat64Array` of one number per freedom of that joint's pair, in the
    /// pair's freedom order) sets each named joint, in that order. An empty or
    /// duplicate name, no rows, an unknown joint, a joint set twice, a joint with no
    /// pair or none of its pair's freedoms, a row of the wrong length, or a non-finite
    /// or out-of-range value fails, and the assembly is left as it was -- check
    /// `Cadaclysm.last_error()`.
    #[func]
    fn state(&self, name: GString, rows: AnyArray) -> bool {
        let Some(rows) = state_rows_arg(&rows, "state: rows") else { return false };
        let refs: Vec<(&str, &[f64])> = rows.iter().map(|(joint, values)| (joint.as_str(), values.as_slice())).collect();
        self.stated(&name.to_string(), &refs).is_some()
    }

    /// This assembly with its mechanism posed, as a new `CadaclysmAssembly` (this one is
    /// unchanged either way; null on a refusal, with the kernel's own text in
    /// `Cadaclysm.last_error()`). `values` is a `Dictionary` of joint to value (or an array
    /// of `[joint, value]` rows, or `{}`): a joint is a path of placement names then the
    /// joint's name joined by "/" (a "/" or "\" inside a name escaped with "\"), or an
    /// array of the names, which this escapes and joins; a value is one number for a
    /// one-freedom joint, else an array of numbers in the pair's freedom order (radians,
    /// the assembly's units). `state` is a state's path, applied first and overridden row
    /// by row; `ground` is one of this assembly's own links, held fixed; "" for either
    /// means none. A sub-assembly no row reaches is shared with this one. A name that
    /// matches several joints, an unknown joint or state, or an out-of-range value is
    /// refused.
    #[func]
    fn posed(&self, values: Variant, #[opt(default = "")] state: GString, #[opt(default = "")] ground: GString) -> Option<Gd<CadaclysmAssembly>> {
        let rows = posed_rows_arg(&values, "posed: values")?;
        let refs: Vec<(&str, &[f64])> = rows.iter().map(|(joint, values)| (joint.as_str(), values.as_slice())).collect();
        let (state, ground) = (state.to_string(), ground.to_string());
        self.posed_copy(&refs, Some(state.as_str()).filter(|s| !s.is_empty()), Some(ground.as_str()).filter(|s| !s.is_empty()))
    }

    /// The placement path of every solid under this assembly, at any depth: depth first,
    /// placements in order, names joined by "/" with a "/" or "\" inside a name escaped
    /// with "\" (as `posed`'s keys). The index `swept_clash`'s rows use: a row's `a` and
    /// `b` are positions in this array. Empty for an assembly that places no solid, and on
    /// a refusal (a closed assembly), the reason then in `Cadaclysm.last_error()`.
    #[func]
    fn parts(&self) -> PackedStringArray {
        let Some(assembly) = self.held() else { return PackedStringArray::new() };
        ok(assembly.parts()).unwrap_or_default().into_iter().map(gs).collect()
    }

    /// Every pair of this assembly's solids (indexed as `parts` lists them) that
    /// penetrates, touches or comes within `clearance` of the other anywhere while this
    /// assembly's own mechanism moves through `keyframes`, as `CadaclysmSweptClash` rows
    /// in pair order. `keyframes` is an array of two or more keyframes, each in the shape
    /// `posed` takes its `values`: a `Dictionary` of joint to value, or an array of
    /// `[joint, value]` rows -- a joint a path `String` or an array of names, a value one
    /// number or an array of numbers. Every keyframe names the same joints; keyframe 0
    /// fixes their order and their value counts. Time runs in keyframe units, keyframe
    /// `k` at time `k`: between two keyframes each joint value moves linearly and each
    /// link is posed from those values, so a link swinging about a joint goes round its
    /// arc, not along its chord. Only this assembly's own joints move: a sub-assembly
    /// rides the link its placement is in. `ground` is one of this assembly's links held
    /// fixed (`""`, the default, for its own base); solids in no link stay still. Pairs on
    /// two links a joint joins are not tested unless `joined`; `allowed` (flat:
    /// `[a0, b0, a1, b1, ...]`, as `CadaclysmBlacksmith.clash`'s) pairs of part indices
    /// are never tested. `tolerance` meshes the parts (absolute, 0.05 by default);
    /// `resolution` and `max_steps` are `CadaclysmCollider.swept_clash`'s.
    ///
    /// Returns an `Array` of `CadaclysmSweptClash` -- empty when no pair is in trouble on
    /// the way -- or `null` with the reason in `Cadaclysm.last_error()`: a closed assembly
    /// (`assembly: closed`); and, prefixed `swept_clash:`, a keyframe or a row not in
    /// `posed`'s shape (`keyframe 1: expected a Dictionary or an array of [joint, values]
    /// rows, not 5`); an odd-length `allowed` (`allowed is N numbers, not pairs`) or a negative
    /// index in it (`allowed pair (x, y) is not two indices`); a `max_steps` negative or
    /// past a `u32`; a later keyframe naming other joints than keyframe 0 (`joint 'x' is
    /// in keyframe 0 and not in keyframe 2`, or `... is in keyframe 2 and not in keyframe
    /// 0`), naming a joint twice (`joint 'x' is given twice`) or giving a joint another
    /// number of values (`joint 'x' has 2 values in keyframe 0 and 1 in keyframe 1`); and
    /// in the kernel's words fewer than two keyframes, an unknown joint or one in a
    /// sub-assembly, a wrong value count, a bad `resolution`, `max_steps` 0, an `allowed`
    /// index out of range or an unknown `ground`.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn swept_clash(
        &self,
        keyframes: AnyArray,
        #[opt(default = 0.0)] clearance: f64,
        #[opt(default = 0.05)] tolerance: f64,
        #[opt(default = 1e-3)] resolution: f64,
        #[opt(default = 100000)] max_steps: i64,
        #[opt(default = &PackedInt32Array::new())] allowed: PackedInt32Array,
        #[opt(default = "")] ground: GString,
        #[opt(default = false)] joined: bool,
    ) -> Variant {
        let Some(assembly) = self.held() else { return Variant::nil() };
        let mut keys: Vec<Vec<(String, Vec<f64>)>> = Vec::with_capacity(keyframes.len());
        for (k, keyframe) in keyframes.iter_shared().enumerate() {
            let Some(rows) = posed_rows_arg(&keyframe, &format!("swept_clash: keyframe {k}")) else { return Variant::nil() };
            keys.push(rows);
        }
        let Some(steps) = swept_max_steps(max_steps, "swept_clash") else { return Variant::nil() };
        let Some(pairs) = allowed_pairs(&allowed, "swept_clash") else { return Variant::nil() };
        let rows: Vec<Vec<(&str, &[f64])>> =
            keys.iter().map(|key| key.iter().map(|(joint, values)| (joint.as_str(), values.as_slice())).collect()).collect();
        let refs: Vec<&[(&str, &[f64])]> = rows.iter().map(Vec::as_slice).collect();
        let ground = ground.to_string();
        // The keyframes' agreement (the same joints, once each, with the same counts) is
        // the SDK's to refuse, in Python's words, before the kernel is called.
        CadaclysmSweptClash::rows(assembly.swept_clash(
            &refs,
            clearance,
            tolerance,
            resolution,
            steps,
            &pairs,
            Some(ground.as_str()).filter(|g| !g.is_empty()),
            joined,
        ))
    }

    /// Adds a named motion sequence: `segments` (an array of `[state, t, interpolation]`,
    /// `state` the name of one of this assembly's states, `t` a number and
    /// `interpolation` one of `"undefined"`, `"discontinuous"`, `"synchronous"` or
    /// `"linear"`) in order; `seconds` says the parameter is in seconds. The sequence is
    /// closed unless its last segment is `"discontinuous"`. An empty or duplicate name,
    /// fewer than two segments, an unknown state, a non-finite or decreasing parameter or
    /// an unknown word fails, and the assembly is left as it was -- check
    /// `Cadaclysm.last_error()`.
    #[func]
    fn sequence(&self, name: GString, segments: AnyArray, #[opt(default = false)] seconds: bool) -> bool {
        let Some(rows) = sequence_rows_arg(&segments, "sequence: segments") else { return false };
        let refs: Vec<(&str, f64, &str)> = rows.iter().map(|(s, t, w)| (s.as_str(), *t, w.as_str())).collect();
        self.sequenced(&name.to_string(), &refs, seconds).is_some()
    }

    /// Declares this assembly's base link. `link` naming no link of this assembly, or
    /// a base already declared, fails, naming the link already there -- check
    /// `Cadaclysm.last_error()`.
    #[func]
    fn base(&self, link: GString) -> bool {
        self.based(&link.to_string()).is_some()
    }

    /// This assembly, and everything placed under it, as one STEP file: this assembly
    /// the root product, each sub-assembly and each distinct part written once, each
    /// placement an occurrence named as it was placed. `schema` and `unit` as
    /// `CadaclysmSolid.step_text` takes them. `""` on failure -- an assembly reachable
    /// from this one, this one included, that places nothing fails, since a reader would
    /// never show it.
    #[func]
    fn step_text(&self, #[opt(default = "")] schema: GString, #[opt(default = "mm")] unit: GString) -> GString {
        gs(self.own_step_text(&schema, &unit).unwrap_or_default())
    }

    /// This assembly written to a STEP file at `path`.
    #[func]
    fn step(&self, path: GString, #[opt(default = "")] schema: GString, #[opt(default = "mm")] unit: GString) -> bool {
        match self.own_step_text(&schema, &unit) {
            Some(text) => write_text(&path, text),
            None => false,
        }
    }

    /// This assembly as a reader `CadaclysmScene`, through STEP text: see
    /// `CadaclysmSolid.to_scene`.
    #[func]
    fn to_scene(&self, #[opt(default = "")] schema: GString) -> Option<Gd<CadaclysmScene>> {
        let schema = schema_arg(&schema);
        ok(self.held()?.to_scene(schema.as_deref())).map(CadaclysmScene::wrap)
    }

    /// Free it now; later calls fail with "closed". Does not free what was placed in it
    /// if that is still reachable from somewhere else.
    #[func]
    fn close(&mut self) {
        self.assembly = None;
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

    /// A chain on `frame` (a `CadaclysmFrame`, a `Transform3D` or twelve numbers). Re-checked
    /// through `bs::Frame::of`, same as `CadaclysmFrame.of`: `self::frame` itself reads raw
    /// numbers unchecked, and `get_frame` hands the held frame back out as a `CadaclysmFrame`,
    /// so a frame built here must be as checked as one built any other way.
    #[func]
    fn on(frame: Variant) -> Option<Gd<CadaclysmWorkplane>> {
        let f = self::frame(&frame, "Workplane.on: frame")?;
        ok(bs::Frame::of(f.raw()))?;
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

// ---- CadaclysmSolidFemMesh ---------------------------------------------------------------

/// One solid meshed for a solver: nodes welded by bits, triangles wound outward, every
/// node tagged with the lowest-dimension B-rep entity it lies on, and every crack
/// reported rather than closed. What `CadaclysmSolid.fem_mesh` returns.
///
/// **A handle of its own.** `CadaclysmSolid.close` neither frees it nor stales it, and
/// neither does meshing the solid again at another tolerance -- unlike
/// `CadaclysmSolid.mesh`, whose triangles come out of the solid's tessellation cache.
/// `release()` hands it back early; letting the last reference go does the same.
///
/// **A class of its own, spelled `CadaclysmSolidFemMesh`**, because Godot's class names
/// are one global namespace and the reader library has a FEM mesh too
/// (`CadaclysmFemMesh`, off `CadaclysmNode.fem_mesh`). The two carry the same properties,
/// hand over the same Dictionaries, and read the same on both pages; they are two classes
/// here for the same reason they are two types in every other wrapper -- two libraries,
/// two handles -- and the differences between the two ABIs are noted where they bite
/// (`msh_text`).
///
/// Every array is a copy, as `CadaclysmMesh`'s are, so nothing taken from it can go
/// stale; `nodes` and a vertex's `point` come over as **doubles**, the kernel working in
/// doubles and Godot's `Vector3` holding floats.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmSolidFemMesh {
    mesh: RefCell<Option<bs::FemMesh>>,
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
    #[var(get = get_crossings, no_set)]
    crossings: PhantomVar<Array<PackedInt64Array>>,
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

impl CadaclysmSolidFemMesh {
    fn wrap(mesh: bs::FemMesh) -> Gd<CadaclysmSolidFemMesh> {
        Gd::from_object(CadaclysmSolidFemMesh {
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
            crossings: PhantomVar::default(),
            watertight: PhantomVar::default(),
            from_mesh: PhantomVar::default(),
            min_angle: PhantomVar::default(),
            worst_triangle: PhantomVar::default(),
            longest_edge: PhantomVar::default(),
            released: PhantomVar::default(),
        })
    }

    /// `f` on the mesh, its answer **by value**: the SDK lends its arrays from the handle,
    /// so a getter copies inside the closure and the borrow ends with it. The reader's
    /// `CadaclysmFemMesh::with` is the same shape over the other library's handle.
    fn with<R>(&self, f: impl FnOnce(&bs::FemMesh) -> R) -> Option<R> {
        match self.mesh.borrow().as_ref() {
            Some(mesh) => Some(f(mesh)),
            None => fail("the FEM mesh was released"),
        }
    }
}

#[godot_api]
impl IRefCounted for CadaclysmSolidFemMesh {
    fn to_string(&self) -> GString {
        let text = self.with(|m| {
            format!("FemMesh(nodes={}, triangles={}, watertight={}, from_mesh={})", m.nodes().len(), m.triangles().len(), m.watertight(), m.from_mesh())
        });
        // Clears the error for the reason `CadaclysmFemMesh::to_string` gives, and at the
        // same cost: these two are the only `to_string`s in the module that do.
        clear_error();
        gs(text.unwrap_or_else(|| "FemMesh(released)".to_string()))
    }
}

#[godot_api]
impl CadaclysmSolidFemMesh {
    /// Every node's position, three doubles a node: placed by
    /// `CadaclysmSolid.fem_mesh_placed`'s frame, in the solid's own coordinates otherwise.
    /// Every node is used by at least one triangle.
    #[func]
    fn get_nodes(&self) -> PackedFloat64Array {
        self.with(|m| reader::fem_nodes(m.nodes())).unwrap_or_default()
    }

    /// Three node indices a triangle, wound outward -- a mirroring frame is wound back.
    /// Not turned round for Godot: these are a solver's triangles, not a mesh to draw.
    #[func]
    fn get_triangles(&self) -> PackedInt32Array {
        self.with(|m| reader::fem_triangles(m.triangles())).unwrap_or_default()
    }

    /// Which face each triangle lies on, one per triangle: the same faces
    /// `CadaclysmSolid.face_kind` names.
    #[func]
    fn get_triangle_face(&self) -> PackedInt32Array {
        self.with(|m| reader::fem_indices(m.triangle_face())).unwrap_or_default()
    }

    /// What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per
    /// node: the lowest-dimension entity it lies on, which is the `.msh` format's own
    /// classification rule. `node_entity` says which entity of that kind.
    #[func]
    fn get_node_kind(&self) -> PackedInt32Array {
        self.with(|m| reader::fem_indices(m.node_kind())).unwrap_or_default()
    }

    /// Which vertex, edge or face each node lies on, read by the matching `node_kind`: an
    /// index into `vertices`, into `edges`, or into the solid's faces.
    #[func]
    fn get_node_entity(&self) -> PackedInt32Array {
        self.with(|m| reader::fem_indices(m.node_entity())).unwrap_or_default()
    }

    /// The solid's faces -- the same faces `CadaclysmSolid.faces` counts.
    #[func]
    fn get_face_count(&self) -> i64 {
        self.with(|m| i64::from(m.face_count())).unwrap_or_default()
    }

    /// One Dictionary per B-rep edge -- `id`, `nodes`, `runs`, `faces`, `ends`, `closed`,
    /// `seam` -- in the order a `node_kind` of `1` indexes them. **Not
    /// `CadaclysmSolid.edges`' numbering**: these are the manifold analysis's, ascending
    /// by edge id. One call to the library per edge, so read it once into a variable.
    #[func]
    fn get_edges(&self) -> Array<VarDictionary> {
        let rows = self.with(|m| {
            ok(m.edges()).map(|edges| edges.iter().map(|e| reader::fem_edge(e.id, e.nodes, e.runs, e.faces, e.ends, e.closed, e.seam)).collect())
        });
        rows.flatten().unwrap_or_default()
    }

    /// One Dictionary per B-rep vertex -- `node`, `point`, `has_position` -- in the order
    /// a `node_kind` of `0` indexes them.
    #[func]
    fn get_vertices(&self) -> Array<VarDictionary> {
        let rows = self.with(|m| ok(m.vertices()).map(|found| found.iter().map(|v| reader::fem_vertex(v.node, v.point, v.has_position)).collect()));
        rows.flatten().unwrap_or_default()
    }

    /// Every crack, as `[a, b, brep_edge]`: a directed mesh edge `(a, b)` with no
    /// `(b, a)`, and the B-rep edge both nodes lie on or `NONE` (4294967295) where they
    /// share none. **Empty unless the solid's topology is closed**, an open sheet making
    /// no claim to check: such a solid reports `watertight` false with this and
    /// `folded_edges` both empty, and that trio together says "not asked", not "nothing
    /// found".
    #[func]
    fn get_open_edges(&self) -> Array<PackedInt64Array> {
        self.with(|m| ok(m.open_edges()).map(|rows| reader::fem_census(&rows))).flatten().unwrap_or_default()
    }

    /// Every fold, as `open_edges` reports a crack: a directed mesh edge used by more than
    /// one triangle. **A solid can be folded without being open** -- one no thicker than a
    /// line leaves no hole for an open edge to find -- so a caller that checks
    /// `open_edges` alone calls such a solid sound. Empty under the same rule.
    #[func]
    fn get_folded_edges(&self) -> Array<PackedInt64Array> {
        self.with(|m| ok(m.folded_edges()).map(|rows| reader::fem_census(&rows))).flatten().unwrap_or_default()
    }

    /// Every pair of triangles that pass through each other, as `[a, b]` with `a < b`,
    /// sorted: an edge of one through the other's interior. Their faces are
    /// `triangle_face[a]` and `[b]`.
    ///
    /// **Computed for every solid, open or closed.** The census `watertight`, `open_edges`
    /// and `folded_edges` report is topological and cannot see a surface passing through
    /// itself; a mesh is ready for a volume mesher when it is `watertight` **and** this is
    /// empty -- Gmsh refuses one that crosses. A copy.
    #[func]
    fn get_crossings(&self) -> Array<PackedInt64Array> {
        self.with(|m| ok(m.crossings()).map(|rows| reader::fem_crossings(&rows))).flatten().unwrap_or_default()
    }

    /// The welded mesh closes -- every directed mesh edge paired with its reverse and none
    /// used twice -- and so does the topology behind it. **False for every solid whose
    /// topology is not closed**, whose mesh is then not asked about; read `open_edges` for
    /// what an empty census beside a false here does and does not mean.
    #[func]
    fn get_watertight(&self) -> bool {
        self.with(|m| m.watertight()).unwrap_or_default()
    }

    /// Always false here: this library has no mesh-only path, every FEM mesh coming off a
    /// solid's own faces. It is on the class so the two libraries' FEM meshes read the
    /// same, and it is what the reader's `CadaclysmFemMesh.from_mesh` reports for a node
    /// with no B-rep.
    #[func]
    fn get_from_mesh(&self) -> bool {
        self.with(|m| m.from_mesh()).unwrap_or_default()
    }

    /// The smallest interior angle of any triangle, in degrees. There is always one: a
    /// solid that meshed to no triangles is a refusal, not a mesh.
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
    /// `CadaclysmSolid.fem_mesh`'s `max_size`, and the only one that says what the mesh
    /// actually is**: `max_size` bounds the boundary segments and merely targets the
    /// interior -- measured at 1.03x on a face whose parameters run unevenly -- and one
    /// small enough beside the solid to reach the mesher's own ceilings is not honoured at
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
    /// a volume where the solid closes, and a physical group naming each. `""` for a mesh
    /// the writer refuses, naming the field it cannot honour, and for a released handle.
    ///
    /// **On this side of the ABI the library's text is owned** -- released by the wrapper
    /// (`cadaclysm_blacksmith_string_free`), two asks giving two independent texts. The
    /// reader library's `CadaclysmFemMesh.msh_text` is the other way round, a slot
    /// borrowed from the handle; a reader porting one side's reasoning onto the other leaks
    /// or double-frees.
    ///
    /// **The unlicensed notice is printed here**, and by `save_msh`, and **not** by
    /// `CadaclysmSolid.fem_mesh`: this library notices on its writers where the reader
    /// library notices in its own constructor.
    #[func]
    fn msh_text(&self) -> GString {
        gs(self.with(|m| ok(m.msh_text())).flatten().unwrap_or_default())
    }

    /// `msh_text` written to `path` by the library itself: the same bytes from the same
    /// writer. A `user://` path works, and `res://` in the editor -- an exported game's
    /// `res://` lives inside its pack, which nothing can write to. False for a mesh the
    /// writer refuses or a file it cannot write.
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

// ---- CadaclysmTool ------------------------------------------------------------------------

/// A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and `flute_length` in
/// mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts at
/// `ramp_angle` degrees. Immutable; a `CadaclysmJob` keeps its own copy, so dropping a tool a
/// job has used changes nothing there. Freed when the last reference goes.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmTool {
    tool: bs::Tool,
}

impl CadaclysmTool {
    fn wrap(tool: bs::Tool) -> Gd<CadaclysmTool> {
        Gd::from_object(CadaclysmTool { tool })
    }

    fn made(result: sdk::Result<bs::Tool>) -> Option<Gd<CadaclysmTool>> {
        ok(result).map(Self::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmTool {
    fn to_string(&self) -> GString {
        gs(format!("{:?}", self.tool))
    }
}

#[godot_api]
impl CadaclysmTool {
    /// A flat end mill: Grbl tool `number` (at least 1), `diameter` and `flute_length` in
    /// mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed. It ramps into its cuts
    /// at `ramp_angle` degrees. Fails for a `number` of 0 or above 255, a size, feed or
    /// speed not positive and finite, or a `ramp_angle` outside (0, 90].
    #[func]
    fn flat(
        number: i64,
        diameter: f64,
        flute_length: f64,
        feed: f64,
        plunge: f64,
        rpm: f64,
        #[opt(default = 3.0)] ramp_angle: f64,
    ) -> Option<Gd<CadaclysmTool>> {
        Self::made(bs::Tool::flat(tool_number(number), diameter, flute_length, feed, plunge, rpm, ramp_angle))
    }

    /// A ball end mill, as `flat`, its tip a half sphere of the diameter; in 2.5D it cuts
    /// where a flat does, `bottom` being the tip.
    #[func]
    fn ball(
        number: i64,
        diameter: f64,
        flute_length: f64,
        feed: f64,
        plunge: f64,
        rpm: f64,
        #[opt(default = 3.0)] ramp_angle: f64,
    ) -> Option<Gd<CadaclysmTool>> {
        Self::made(bs::Tool::ball(tool_number(number), diameter, flute_length, feed, plunge, rpm, ramp_angle))
    }

    /// A drill: as `flat`, plunging at `feed`. A `CadaclysmJob` takes it for `drill` (and
    /// `machine`'s drills) only.
    #[func]
    fn drill(number: i64, diameter: f64, flute_length: f64, feed: f64, rpm: f64) -> Option<Gd<CadaclysmTool>> {
        Self::made(bs::Tool::drill(tool_number(number), diameter, flute_length, feed, rpm))
    }

    /// A new tool: this one, ramping into its cuts at `degrees` from the horizontal
    /// instead. Fails for an angle outside (0, 90].
    #[func]
    fn with_ramp_angle(&self, degrees: f64) -> Option<Gd<CadaclysmTool>> {
        Self::made(self.tool.with_ramp_angle(degrees))
    }
}

// ---- CadaclysmStock -----------------------------------------------------------------------

/// The block of material a job cuts, an axis-aligned box. Immutable; a `CadaclysmJob` keeps
/// its own copy. Freed when the last reference goes.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmStock {
    stock: bs::Stock,
}

impl CadaclysmStock {
    fn wrap(stock: bs::Stock) -> Gd<CadaclysmStock> {
        Gd::from_object(CadaclysmStock { stock })
    }

    fn made(result: sdk::Result<bs::Stock>) -> Option<Gd<CadaclysmStock>> {
        ok(result).map(Self::wrap)
    }
}

#[godot_api]
impl IRefCounted for CadaclysmStock {
    fn to_string(&self) -> GString {
        gs(format!("{:?}", self.stock))
    }
}

#[godot_api]
impl CadaclysmStock {
    /// The box from `min` (x, y, z) to `max`. Fails unless every min is below its max and
    /// all six are finite. Python's `Stock.box` -- `box` is a Rust keyword, so this
    /// method (and the SDK's own it calls) is `box_`, as the Rust wrapper's own is.
    #[func]
    fn box_(min: Variant, max: Variant) -> Option<Gd<CadaclysmStock>> {
        let (min, max) = (v3(&min, "box_: min")?, v3(&max, "box_: max")?);
        Self::made(bs::Stock::box_(min, max))
    }

    /// `solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at the
    /// solid's lowest Z. Fails for a `margin` negative or not finite.
    #[func]
    fn around(solid: Gd<CadaclysmSolid>, #[opt(default = 0.0)] margin: f64) -> Option<Gd<CadaclysmStock>> {
        Self::made(bs::Stock::around(solid.bind().held()?, margin))
    }
}

// ---- CadaclysmProgram ----------------------------------------------------------------------

/// One file a `CadaclysmJob` wrote: a Grbl program (`tool` its `T` number, `name`
/// `<job name>-T<n>`, or `<job name>-<k>-T<n>` for a repeated tool) from `CadaclysmJob.gcode`,
/// or one of `CadaclysmJob.write_camotics`'s files (`tool` 0 for the simulation copies and
/// the project). Copied out; read-only.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmProgram {
    own_tool: u32,
    own_name: String,
    own_text: String,
    #[var(get = get_tool, no_set)]
    tool: PhantomVar<i64>,
    #[var(get = get_name, no_set)]
    name: PhantomVar<GString>,
    #[var(get = get_text, no_set)]
    text: PhantomVar<GString>,
}

impl CadaclysmProgram {
    fn wrap(program: bs::Program) -> Gd<CadaclysmProgram> {
        Gd::from_object(CadaclysmProgram {
            own_tool: program.tool,
            own_name: program.name,
            own_text: program.text,
            tool: PhantomVar::default(),
            name: PhantomVar::default(),
            text: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmProgram {
    fn to_string(&self) -> GString {
        gs(format!("Program(tool={}, name={:?})", self.own_tool, self.own_name))
    }
}

#[godot_api]
impl CadaclysmProgram {
    #[func]
    fn get_tool(&self) -> i64 {
        self.own_tool as i64
    }

    #[func]
    fn get_name(&self) -> GString {
        gs(&self.own_name)
    }

    #[func]
    fn get_text(&self) -> GString {
        gs(&self.own_text)
    }
}

// ---- CadaclysmOperation --------------------------------------------------------------------

/// One operation of a `CadaclysmJob`, read back by `CadaclysmJob.operations`: `kind`
/// (`"face"`, `"contour"`, `"pocket"` or `"drill"`), `tool` (its Grbl `T` number) and
/// `params`, a Dictionary (sorted by key, for a stable order) of the operation's own
/// arguments in the library's own numbers -- `side` 0 outside, 1 inside or 2 on its line;
/// `climb` and `open` 1 or 0; `points` a count; a `peck` of none reads as `null`. Copied
/// out; read-only.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmOperation {
    own_kind: String,
    own_tool: u32,
    own_params: Vec<(String, Option<f64>)>,
    #[var(get = get_kind, no_set)]
    kind: PhantomVar<GString>,
    #[var(get = get_tool, no_set)]
    tool: PhantomVar<i64>,
    #[var(get = get_params, no_set)]
    params: PhantomVar<VarDictionary>,
}

impl CadaclysmOperation {
    fn wrap(operation: bs::Operation) -> Gd<CadaclysmOperation> {
        Gd::from_object(CadaclysmOperation {
            own_kind: operation.kind,
            own_tool: operation.tool,
            own_params: operation.params.into_iter().collect(),
            kind: PhantomVar::default(),
            tool: PhantomVar::default(),
            params: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmOperation {
    fn to_string(&self) -> GString {
        gs(format!("Operation(kind={:?}, tool={})", self.own_kind, self.own_tool))
    }
}

#[godot_api]
impl CadaclysmOperation {
    #[func]
    fn get_kind(&self) -> GString {
        gs(&self.own_kind)
    }

    #[func]
    fn get_tool(&self) -> i64 {
        self.own_tool as i64
    }

    #[func]
    fn get_params(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        for (key, value) in &self.own_params {
            let v = match value {
                Some(x) => x.to_variant(),
                None => Variant::nil(),
            };
            d.set(key.as_str(), &v);
        }
        d
    }
}

// ---- CadaclysmReportItem, CadaclysmReport ------------------------------------------------

/// One thing `CadaclysmJob.machine` left uncut, one of `CadaclysmReport`'s items: `kind`
/// (`"corner"`, material the end mill doesn't reach; `"hole"`, a round hole no drill
/// matches or a matched drill can't make; `"slope"`, a face that is neither horizontal nor
/// vertical, cut as steps; `"undercut"`, material under an overhang; or `"too_deep"`, a
/// level below the end mill's flute length, cut only that far), `at` (the item's XYZ
/// location -- a centroid for an area, the axis point at the top for a hole), `size` (an
/// area in mm^2 for `corner`/`undercut`, a diameter in mm for `hole`, and a height in mm --
/// its Z range -- for `slope` and `too_deep`), `top` and `bottom` (the Z range the item
/// spans, in mm: a corner's "from z top down to z bottom"; a hole's top, a slope's head, or
/// for `too_deep` the flutes' reach), `reason` (one sentence naming the cause and
/// the tool involved) and `region` (the XY area the item covers). Copied out; read-only.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmReportItem {
    own_kind: String,
    own_at: [f64; 3],
    own_size: f64,
    own_top: f64,
    own_bottom: f64,
    own_reason: String,
    own_region: Vec<Gd<CadaclysmProfile>>,
    #[var(get = get_kind, no_set)]
    kind: PhantomVar<GString>,
    #[var(get = get_at, no_set)]
    at: PhantomVar<Vector3>,
    #[var(get = get_size, no_set)]
    size: PhantomVar<f64>,
    #[var(get = get_top, no_set)]
    top: PhantomVar<f64>,
    #[var(get = get_bottom, no_set)]
    bottom: PhantomVar<f64>,
    #[var(get = get_reason, no_set)]
    reason: PhantomVar<GString>,
    #[var(get = get_region, no_set)]
    region: PhantomVar<Array<Gd<CadaclysmProfile>>>,
}

impl CadaclysmReportItem {
    fn wrap(item: bs::ReportItem) -> Gd<CadaclysmReportItem> {
        Gd::from_object(CadaclysmReportItem {
            own_kind: item.kind,
            own_at: item.at,
            own_size: item.size,
            own_top: item.top,
            own_bottom: item.bottom,
            own_reason: item.reason,
            own_region: item.region.into_iter().map(CadaclysmProfile::wrap).collect(),
            kind: PhantomVar::default(),
            at: PhantomVar::default(),
            size: PhantomVar::default(),
            top: PhantomVar::default(),
            bottom: PhantomVar::default(),
            reason: PhantomVar::default(),
            region: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmReportItem {
    fn to_string(&self) -> GString {
        gs(format!("ReportItem(kind={:?}, size={}, top={}, bottom={})", self.own_kind, self.own_size, self.own_top, self.own_bottom))
    }
}

#[godot_api]
impl CadaclysmReportItem {
    #[func]
    fn get_kind(&self) -> GString {
        gs(&self.own_kind)
    }

    #[func]
    fn get_at(&self) -> Vector3 {
        vector3(self.own_at)
    }

    #[func]
    fn get_size(&self) -> f64 {
        self.own_size
    }

    #[func]
    fn get_top(&self) -> f64 {
        self.own_top
    }

    #[func]
    fn get_bottom(&self) -> f64 {
        self.own_bottom
    }

    #[func]
    fn get_reason(&self) -> GString {
        gs(&self.own_reason)
    }

    #[func]
    fn get_region(&self) -> Array<Gd<CadaclysmProfile>> {
        self.own_region.iter().cloned().collect()
    }
}

/// What `CadaclysmJob.machine` could not make: `items`, in order, read once when `machine`
/// returns, and `text` -- the kernel's own: one line per item, or `"nothing left uncut"`.
/// `to_string()` is that same text. Copied out; read-only.
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmReport {
    own_items: Vec<Gd<CadaclysmReportItem>>,
    own_text: String,
    #[var(get = get_items, no_set)]
    items: PhantomVar<Array<Gd<CadaclysmReportItem>>>,
    #[var(get = get_text, no_set)]
    text: PhantomVar<GString>,
    #[var(get = get_is_empty, no_set)]
    is_empty: PhantomVar<bool>,
}

impl CadaclysmReport {
    fn wrap(report: bs::Report) -> Gd<CadaclysmReport> {
        let text = report.text().to_string();
        let items = report.into_items().into_iter().map(CadaclysmReportItem::wrap).collect();
        Gd::from_object(CadaclysmReport {
            own_items: items,
            own_text: text,
            items: PhantomVar::default(),
            text: PhantomVar::default(),
            is_empty: PhantomVar::default(),
        })
    }
}

#[godot_api]
impl IRefCounted for CadaclysmReport {
    fn to_string(&self) -> GString {
        gs(&self.own_text)
    }
}

#[godot_api]
impl CadaclysmReport {
    #[func]
    fn get_items(&self) -> Array<Gd<CadaclysmReportItem>> {
        self.own_items.iter().cloned().collect()
    }

    #[func]
    fn get_text(&self) -> GString {
        gs(&self.own_text)
    }

    /// Whether nothing was left uncut (no items) -- `true` for `"nothing left uncut"`.
    #[func]
    fn get_is_empty(&self) -> bool {
        self.own_items.is_empty()
    }
}

// ---- CadaclysmJob --------------------------------------------------------------------------

/// A mutable machining job on a `CadaclysmStock`: operations kept in the order they are
/// added, written as one Grbl 1.1 program per run of operations sharing a tool. Each
/// operation is added in place, and a refused one leaves the job as it was. `new` is
/// GDScript's own reserved name, so the constructor is `create`, as `CadaclysmFrame`'s and
/// `CadaclysmAssembly`'s are. Godot's objects are not deterministically dropped, so, as
/// `CadaclysmSolid` and `CadaclysmAssembly` do, this one takes an explicit `close()`; every
/// call after fails with "job: closed".
#[derive(GodotClass)]
#[class(no_init, base = RefCounted)]
pub struct CadaclysmJob {
    job: Option<bs::Job>,
    #[var(get = get_closed, no_set)]
    closed: PhantomVar<bool>,
}

impl CadaclysmJob {
    fn held(&self) -> Option<&bs::Job> {
        match &self.job {
            Some(job) => Some(job),
            None => fail("job: closed"),
        }
    }

    fn held_mut(&mut self) -> Option<&mut bs::Job> {
        match &mut self.job {
            Some(job) => Some(job),
            None => fail("job: closed"),
        }
    }

    /// `machine`/`machine_with_drills`/`machine_with_end_mills`'s shared body, once
    /// `end_mills` and `drills` are resolved to borrowed tool handles.
    fn machined(
        &mut self,
        part: &Gd<CadaclysmSolid>,
        end_mills: &[&bs::Tool],
        drills: &[Option<&bs::Tool>],
        stepover: f64,
        stepdown: f64,
        skin: f64,
        peck: f64,
    ) -> Option<Gd<CadaclysmReport>> {
        let part = part.bind();
        let stepover = (!stepover.is_nan()).then_some(stepover);
        let stepdown = (!stepdown.is_nan()).then_some(stepdown);
        let peck = (!peck.is_nan()).then_some(peck);
        let part_ref = part.held()?;
        let job = self.held_mut()?;
        let report = ok(job.machine_with(part_ref, end_mills, drills, stepover, stepdown, skin, peck))?;
        Some(CadaclysmReport::wrap(report))
    }
}

#[godot_api]
impl IRefCounted for CadaclysmJob {
    fn to_string(&self) -> GString {
        match &self.job {
            Some(job) => gs(format!("{job:?}")),
            None => gs("Job(closed)"),
        }
    }
}

#[godot_api]
impl CadaclysmJob {
    /// An empty job on `stock`, rapids at `safe_z` (above the stock's top). `clearance` is
    /// how far above an operation's top it enters and leaves its passes; `tolerance` fits
    /// free-form sides and offsets; `name` names the programs (`<name>-T<n>`);
    /// `spindle_dwell` is how long every program waits after starting the spindle;
    /// `resolution` is the CAMotics project's voxel size in mm. Fails for a `safe_z` not
    /// above the stock's top, or a setting the job refuses.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn create(
        stock: Gd<CadaclysmStock>,
        safe_z: f64,
        #[opt(default = 1.0)] clearance: f64,
        #[opt(default = 0.01)] tolerance: f64,
        #[opt(default = "job")] name: GString,
        #[opt(default = 2.0)] spindle_dwell: f64,
        #[opt(default = 0.1)] resolution: f64,
    ) -> Option<Gd<CadaclysmJob>> {
        let job = ok(bs::Job::new(&stock.bind().stock, safe_z, clearance, tolerance, &name.to_string(), spindle_dwell, resolution))?;
        Some(Gd::from_object(CadaclysmJob { job: Some(job), closed: PhantomVar::default() }))
    }

    /// Free it now rather than when the last reference goes; later calls fail with
    /// "job: closed".
    #[func]
    fn close(&mut self) {
        self.job = None;
    }

    #[func]
    fn get_closed(&self) -> bool {
        self.job.is_none()
    }

    /// Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and
    /// passes at most `stepdown` deep, with `tool`. Fails for a drill, a `z` above the
    /// stock's top, a stepover past the tool's diameter, or what the job otherwise
    /// refuses.
    #[func]
    fn face(&mut self, tool: Gd<CadaclysmTool>, z: f64, stepover: f64, stepdown: f64) -> bool {
        let Some(job) = self.held_mut() else { return false };
        ok(job.face(&tool.bind().tool, z, stepover, stepdown)).is_some()
    }

    /// Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep, with
    /// `tool`: `side` "outside" the profile, "inside" it, or "on" its line; `climb` for
    /// climb milling, else conventional; `open` to cut the outline as an open chain (only
    /// "on" its line, and with no holes). Fails for any other `side`, or what the job
    /// otherwise refuses -- unchanged either way.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn contour(
        &mut self,
        tool: Gd<CadaclysmTool>,
        profile: Gd<CadaclysmProfile>,
        top: f64,
        bottom: f64,
        #[opt(default = "outside")] side: GString,
        #[opt(default = 1.0)] stepdown: f64,
        #[opt(default = true)] climb: bool,
        #[opt(default = false)] open: bool,
    ) -> bool {
        let Some(job) = self.held_mut() else { return false };
        ok(job.contour(&tool.bind().tool, &profile.bind().profile, top, bottom, &side.to_string(), stepdown, climb, open)).is_some()
    }

    /// Clear `profile` -- its holes left standing as islands -- from `top` to `bottom`, in
    /// rings `stepover` apart (at most the tool's radius) and passes at most `stepdown`
    /// deep, with `tool`. Fails for what the job refuses; a pocket too small for the tool
    /// is refused by `gcode`, naming the operation.
    #[func]
    fn pocket(&mut self, tool: Gd<CadaclysmTool>, profile: Gd<CadaclysmProfile>, top: f64, bottom: f64, stepover: f64, stepdown: f64) -> bool {
        let Some(job) = self.held_mut() else { return false };
        ok(job.pocket(&tool.bind().tool, &profile.bind().profile, top, bottom, stepover, stepdown)).is_some()
    }

    /// A hole at each (x, y) of `points`, from `top` to `bottom` with `tool`, pecking
    /// `peck` deep at a time (retracting between pecks), or straight to depth for `NAN`
    /// (Godot has no null default for a number; `NAN` is the sentinel, as the C ABI's
    /// own is). Fails for what the job refuses (a tool that is not a drill, no points,
    /// ...).
    #[func]
    fn drill(&mut self, tool: Gd<CadaclysmTool>, points: Variant, top: f64, bottom: f64, #[opt(default = f64::NAN)] peck: f64) -> bool {
        let Some(pts) = points2(&points, "drill: points") else { return false };
        let Some(job) = self.held_mut() else { return false };
        let peck = (!peck.is_nan()).then_some(peck);
        ok(job.drill(&tool.bind().tool, &pts, top, bottom, peck)).is_some()
    }

    /// Recognise `part` and append the operations that make it: faced, contoured and
    /// pocketed with `end_mill`, no holes drilled (see `machine_with_drills` for that).
    /// `stepover` and `stepdown` of `NAN` are the kernel's own defaults; `skin` (at least
    /// 0) is how far above the part's lowest point the outline stops, so the part stays
    /// attached to the stock -- 0 cuts through; `peck` of `NAN` is none (a drill straight
    /// to depth, not that this call ever drills). Returns a `CadaclysmReport` of what
    /// could not be cut. Fails for what the kernel refuses (a drill as `end_mill`, ...);
    /// the job changes only on success -- a refusal leaves it exactly as it was.
    #[func]
    fn machine(
        &mut self,
        part: Gd<CadaclysmSolid>,
        end_mill: Gd<CadaclysmTool>,
        #[opt(default = f64::NAN)] stepover: f64,
        #[opt(default = f64::NAN)] stepdown: f64,
        #[opt(default = 0.3)] skin: f64,
        #[opt(default = f64::NAN)] peck: f64,
    ) -> Option<Gd<CadaclysmReport>> {
        let end_mill = end_mill.bind();
        self.machined(&part, &[&end_mill.tool], &[], stepover, stepdown, skin, peck)
    }

    /// `machine`, with `drills` (`CadaclysmTool`s) tried against each round hole found --
    /// a tool per required diameter -- since Godot has no null default for an array to
    /// give `machine` an optional one of its own (as `CadaclysmScene.open`/`open_with`
    /// are two calls for the same reason).
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn machine_with_drills(
        &mut self,
        part: Gd<CadaclysmSolid>,
        end_mill: Gd<CadaclysmTool>,
        drills: AnyArray,
        #[opt(default = f64::NAN)] stepover: f64,
        #[opt(default = f64::NAN)] stepdown: f64,
        #[opt(default = 0.3)] skin: f64,
        #[opt(default = f64::NAN)] peck: f64,
    ) -> Option<Gd<CadaclysmReport>> {
        let drill_list = object_list::<CadaclysmTool>(&drills, "machine_with_drills: drills")?;
        let guards: Vec<GdRef<CadaclysmTool>> = drill_list.iter().map(|t| t.bind()).collect();
        let refs: Vec<Option<&bs::Tool>> = guards.iter().map(|g| Some(&g.tool)).collect();
        let end_mill = end_mill.bind();
        self.machined(&part, &[&end_mill.tool], &refs, stepover, stepdown, skin, peck)
    }

    /// `machine_with_drills`, with `end_mills` (`CadaclysmTool`s, at least one) in place of
    /// the one end mill: what the first leaves (inside corners tighter than its radius)
    /// goes to the next. `drills` may be `[]`. An empty `end_mills` is refused.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn machine_with_end_mills(
        &mut self,
        part: Gd<CadaclysmSolid>,
        end_mills: AnyArray,
        drills: AnyArray,
        #[opt(default = f64::NAN)] stepover: f64,
        #[opt(default = f64::NAN)] stepdown: f64,
        #[opt(default = 0.3)] skin: f64,
        #[opt(default = f64::NAN)] peck: f64,
    ) -> Option<Gd<CadaclysmReport>> {
        let end_mill_list =
            object_list::<CadaclysmTool>(&end_mills, "machine_with_end_mills: end_mills")?;
        let drill_list = object_list::<CadaclysmTool>(&drills, "machine_with_end_mills: drills")?;
        let end_mill_guards: Vec<GdRef<CadaclysmTool>> = end_mill_list.iter().map(|t| t.bind()).collect();
        let end_mill_refs: Vec<&bs::Tool> = end_mill_guards.iter().map(|g| &g.tool).collect();
        let guards: Vec<GdRef<CadaclysmTool>> = drill_list.iter().map(|t| t.bind()).collect();
        let refs: Vec<Option<&bs::Tool>> = guards.iter().map(|g| Some(&g.tool)).collect();
        self.machined(&part, &end_mill_refs, &refs, stepover, stepdown, skin, peck)
    }

    /// Every operation added to this job so far, in order -- whether added by `face`,
    /// `contour`, `pocket`, `drill` or `machine`.
    #[func]
    fn operations(&self) -> Array<Gd<CadaclysmOperation>> {
        self.held().and_then(|j| ok(j.operations())).unwrap_or_default().into_iter().map(CadaclysmOperation::wrap).collect()
    }

    /// The job as Grbl 1.1 programs, one per run of consecutive operations sharing a tool
    /// (T1, T2, T1 gives three), each named `<name>-T<n>` (or `<name>-<k>-T<n>` for run
    /// `k` of a tool that runs more than once); an empty array for a job with no
    /// operations. Fails for an operation whose geometry the tool cannot cut (named by
    /// its index and kind).
    #[func]
    fn gcode(&self) -> Array<Gd<CadaclysmProgram>> {
        self.held().and_then(|j| ok(j.gcode())).unwrap_or_default().into_iter().map(CadaclysmProgram::wrap).collect()
    }

    /// A CAMotics project at `path` and its files beside it, named after the project's
    /// file stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each
    /// program, a simulation copy of it (`.sim.nc`, which the project lists), and the
    /// project last. Creates the directory. Returns the paths written, the project last.
    /// Fails for a path with no file stem, what `gcode` refuses, or a file that cannot be
    /// written.
    #[func]
    fn write_camotics(&self, path: GString) -> PackedStringArray {
        let Some(job) = self.held() else { return PackedStringArray::new() };
        let written = ok(job.write_camotics(os_path(&path))).unwrap_or_default();
        written.into_iter().map(|p| gs(p.display().to_string())).collect()
    }
}
