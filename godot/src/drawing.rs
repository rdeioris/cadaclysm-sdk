//! A scene's edges flattened onto a page, for 2D drawing (`CadaclysmScene.drawing`).
use cadaclysm_sdk as sdk;
use godot::prelude::*;

use crate::fail;

/// (x, y, z) -> (u, v), `v` down the page, for a model read Y up.
fn projection(view: &str) -> Option<fn([f64; 3]) -> [f64; 2]> {
    Some(match view {
        "front" => |p| [p[0], -p[1]],
        "back" => |p| [-p[0], -p[1]],
        "top" => |p| [p[0], p[2]],
        "bottom" => |p| [p[0], -p[2]],
        "right" => |p| [-p[2], -p[1]],
        "left" => |p| [p[2], -p[1]],
        _ => return fail(format!("no view called {view:?}: front, back, top, bottom, left or right")),
    })
}

pub(crate) fn drawing(scene: &sdk::Scene, view: &str) -> Option<VarDictionary> {
    let project = projection(view)?;
    let mut segments = PackedVector2Array::new();
    let (mut lo, mut hi) = ([f64::INFINITY; 2], [f64::NEG_INFINITY; 2]);
    for placement in scene.placements() {
        let m = placement.raw_transform();
        let mut place = |p: &[f32; 3]| {
            let (x, y, z) = (p[0] as f64, p[1] as f64, p[2] as f64);
            let uv = project([0, 1, 2].map(|r| m[r] * x + m[4 + r] * y + m[8 + r] * z + m[12 + r]));
            for k in 0..2 {
                lo[k] = lo[k].min(uv[k]);
                hi[k] = hi[k].max(uv[k]);
            }
            Vector2::new(uv[0] as f32, uv[1] as f32)
        };
        let geometry = placement.geometry();
        for lines in [geometry.edges(), geometry.curves()] {
            for run in lines.iter() {
                let mut previous: Option<Vector2> = None;
                for p in run {
                    let here = place(p);
                    if let Some(before) = previous {
                        segments.push(before);
                        segments.push(here);
                    }
                    previous = Some(here);
                }
            }
        }
    }
    if segments.is_empty() {
        (lo, hi) = ([0.0; 2], [0.0; 2]);
    }
    let v = |p: [f64; 2]| Vector2::new(p[0] as f32, p[1] as f32);
    Some(crate::dict(&[("segments", segments.to_variant()), ("lo", v(lo).to_variant()), ("hi", v(hi).to_variant())]))
}
