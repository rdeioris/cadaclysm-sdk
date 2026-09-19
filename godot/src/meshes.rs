//! From the library's arrays to Godot's: `ArrayMesh`es, materials, and a scene as a
//! tree of `MeshInstance3D`s.
use std::collections::HashMap;

use cadaclysm_sdk as sdk;
use godot::classes::base_material_3d::{CullMode, Flags, ShadingMode, Transparency};
use godot::classes::geometry_instance_3d::ShadowCastingSetting;
use godot::classes::mesh::{ArrayType, PrimitiveType};
use godot::classes::{ArrayMesh, Material, MeshInstance3D, Node, Node3D, Shader, ShaderMaterial, StandardMaterial3D};
use godot::prelude::*;

use crate::fail;
use crate::reader::transform;

pub(crate) fn points(p: &[[f32; 3]]) -> PackedVector3Array {
    p.iter().map(|v| Vector3::new(v[0], v[1], v[2])).collect()
}

pub(crate) fn uvs(p: &[[f32; 2]]) -> PackedVector2Array {
    p.iter().map(|v| Vector2::new(v[0], v[1])).collect()
}

pub(crate) fn colors(p: &[[f32; 4]]) -> PackedColorArray {
    p.iter().map(|v| Color::from_rgba(v[0], v[1], v[2], v[3])).collect()
}

/// A mesh's triangles as a one-surface `ArrayMesh`, or `None` when it has none.
///
/// The library winds front faces counter-clockwise; Godot wants them clockwise, so
/// each triangle's last two indices trade places.
pub(crate) fn triangles(mesh: &sdk::Mesh<'_>) -> Option<Gd<ArrayMesh>> {
    if mesh.is_empty() {
        return None;
    }
    let mut indices = PackedInt32Array::new();
    indices.resize(mesh.indices.len());
    for (out, tri) in indices.as_mut_slice().chunks_exact_mut(3).zip(mesh.indices.chunks_exact(3)) {
        out[0] = tri[0] as i32;
        out[1] = tri[2] as i32;
        out[2] = tri[1] as i32;
    }
    let mut arrays = VarArray::new();
    arrays.resize(ArrayType::MAX.ord() as usize, &Variant::nil());
    arrays.set(ArrayType::VERTEX.ord() as usize, &points(mesh.positions).to_variant());
    if let Some(normals) = mesh.normals {
        arrays.set(ArrayType::NORMAL.ord() as usize, &points(normals).to_variant());
    }
    if let Some(uv) = mesh.uvs {
        arrays.set(ArrayType::TEX_UV.ord() as usize, &uvs(uv).to_variant());
    }
    if let Some(c) = mesh.colors {
        arrays.set(ArrayType::COLOR.ord() as usize, &colors(c).to_variant());
    }
    arrays.set(ArrayType::INDEX.ord() as usize, &indices.to_variant());
    let mut out = ArrayMesh::new_gd();
    out.add_surface_from_arrays(PrimitiveType::TRIANGLES, &arrays);
    Some(out)
}

/// Every segment of every run as one `lines` `ArrayMesh`, each run carried through
/// `place` first where given; `None` when there is nothing to draw.
pub(crate) fn lines(sources: &[sdk::Polylines<'_>], place: Option<Transform3D>) -> Option<Gd<ArrayMesh>> {
    let mut pairs = PackedVector3Array::new();
    for lines in sources {
        for run in lines.iter() {
            for pair in run.windows(2) {
                for p in pair {
                    let v = Vector3::new(p[0], p[1], p[2]);
                    pairs.push(place.map_or(v, |t| t * v));
                }
            }
        }
    }
    if pairs.is_empty() {
        return None;
    }
    let mut arrays = VarArray::new();
    arrays.resize(ArrayType::MAX.ord() as usize, &Variant::nil());
    arrays.set(ArrayType::VERTEX.ord() as usize, &pairs.to_variant());
    let mut out = ArrayMesh::new_gd();
    out.add_surface_from_arrays(PrimitiveType::LINES, &arrays);
    Some(out)
}

/// The grey a body the file paints nothing is drawn in.
pub(crate) const DEFAULT_GREY: [f32; 4] = [0.72, 0.70, 0.66, 1.0];

/// A lit material in `colour` (the default grey for none); see-through where its
/// alpha is under one; per-vertex colours as albedo where `vertex_colours`.
pub(crate) fn material_for(colour: Option<[f32; 4]>, vertex_colours: bool) -> Gd<Material> {
    let c = colour.unwrap_or(DEFAULT_GREY);
    let mut m = StandardMaterial3D::new_gd();
    m.set_albedo(Color::from_rgba(c[0], c[1], c[2], c[3]));
    m.set_roughness(0.55);
    if c[3] < 1.0 {
        m.set_transparency(Transparency::ALPHA_DEPTH_PRE_PASS);
    }
    if vertex_colours {
        m.set_flag(Flags::ALBEDO_FROM_VERTEX_COLOR, true);
    }
    m.upcast()
}

/// A material that draws both sides of a face (sheets, open shells).
pub(crate) fn double_sided(material: &Gd<Material>) -> Gd<Material> {
    match material.clone().try_cast::<StandardMaterial3D>() {
        Ok(standard) => {
            let mut copy = standard.duplicate_resource();
            copy.set_cull_mode(CullMode::DISABLED);
            copy.upcast()
        }
        Err(other) => other,
    }
}

const EDGE_SHADER: &str = r#"
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 colour : source_color = vec4(0.07, 0.07, 0.08, 1.0);
// Pulled a hair towards the camera, so an edge on a face wins the depth test:
// depth is reversed (near is 1), so scaling it up by `pull` brings the point that
// fraction of its distance nearer -- the same share from a bolt to a building.
uniform float pull = 0.002;
void vertex() {
	POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	POSITION.z *= 1.0 + pull;
}
void fragment() {
	ALBEDO = colour.rgb;
	ALPHA = colour.a;
}
"#;

thread_local! {
    static EDGE: std::cell::RefCell<Option<Gd<Shader>>> = const { std::cell::RefCell::new(None) };
}

/// Let go of the cached shader while the engine is still there to free it.
pub(crate) fn release_cache() {
    EDGE.with(|cell| cell.borrow_mut().take());
}

/// An unshaded material for edges in `colour`, drawn over the faces they lie on.
pub(crate) fn edge_material(colour: Color) -> Gd<Material> {
    let shader = EDGE.with(|cell| {
        cell.borrow_mut()
            .get_or_insert_with(|| {
                let mut shader = Shader::new_gd();
                shader.set_code(EDGE_SHADER);
                shader
            })
            .clone()
    });
    let mut m = ShaderMaterial::new_gd();
    m.set_shader(&shader);
    m.set_shader_parameter("colour", &colour.to_variant());
    m.upcast()
}

/// A material that ignores light, for a flat picture.
#[allow(dead_code)]
pub(crate) fn unshaded(colour: Color) -> Gd<Material> {
    let mut m = StandardMaterial3D::new_gd();
    m.set_shading_mode(ShadingMode::UNSHADED);
    m.set_albedo(colour);
    m.upcast()
}

// ---- a scene as nodes --------------------------------------------------------------

/// `CadaclysmScene.instantiate`'s options.
pub(crate) struct BuildOptions {
    pub edges: bool,
    pub edge_colour: Color,
    pub material: Option<Gd<Material>>,
    pub tree: bool,
    pub double_sided: bool,
}

impl BuildOptions {
    pub(crate) fn from_dictionary(d: &VarDictionary) -> Option<BuildOptions> {
        let known = ["double_sided", "edge_color", "edges", "material", "tree"];
        for key in d.keys_array().iter_shared() {
            let key = key.to_string();
            if !known.contains(&key.as_str()) {
                return fail(format!("no instantiate option called {key:?}: {}", known.join(", ")));
            }
        }
        let flag = |name: &str| d.get(name).is_some_and(|v| v.booleanize());
        let material = match d.get("material") {
            Some(v) if !v.is_nil() => match v.try_to::<Gd<Material>>() {
                Ok(m) => Some(m),
                Err(_) => return fail("instantiate's material must be a Material"),
            },
            _ => None,
        };
        Some(BuildOptions {
            edges: flag("edges"),
            edge_colour: d.get("edge_color").and_then(|v| v.try_to::<Color>().ok()).unwrap_or(Color::from_rgb(0.07, 0.07, 0.08)),
            material,
            tree: flag("tree"),
            double_sided: flag("double_sided"),
        })
    }
}

/// Names made unique among siblings cheaply (Godot's own check is linear per add).
#[derive(Default)]
struct Names(HashMap<(i64, String), u32>);

impl Names {
    fn unique(&mut self, parent: i64, name: &str) -> String {
        let clean: String = name.chars().map(|c| if ".:@/\"%".contains(c) { '_' } else { c }).collect();
        let clean = if clean.trim().is_empty() { "Body".to_string() } else { clean };
        let n = self.0.entry((parent, clean.clone())).or_insert(0);
        *n += 1;
        if *n == 1 {
            clean
        } else {
            format!("{clean} {n}")
        }
    }
}

/// The scene as a `Node3D` named `name`: a `MeshInstance3D` per placement, each body's
/// `ArrayMesh` built once and shared by every placement of it.
pub(crate) fn instantiate(scene: &sdk::Scene, name: &str, options: &BuildOptions) -> Gd<Node3D> {
    let mut root = Node3D::new_alloc();
    root.set_name(name);
    let mut names = Names::default();
    let mut bodies: HashMap<u32, Option<Gd<ArrayMesh>>> = HashMap::new();
    let mut edges: HashMap<u32, Option<Gd<ArrayMesh>>> = HashMap::new();
    let mut materials: HashMap<[u32; 4], Gd<Material>> = HashMap::new();
    let mut groups: HashMap<u32, Gd<Node3D>> = HashMap::new();
    let edge_material = options.edges.then(|| edge_material(options.edge_colour));

    for (index, placement) in scene.placements().into_iter().enumerate() {
        let geometry = placement.geometry();
        let body = bodies
            .entry(geometry.index())
            .or_insert_with(|| {
                let mesh = geometry.mesh();
                let mut built = triangles(&mesh)?;
                let material = match &options.material {
                    Some(m) => m.clone(),
                    None => {
                        let colour = geometry.colour();
                        let key = colour.unwrap_or(DEFAULT_GREY).map(f32::to_bits);
                        let vertex = mesh.colors.is_some();
                        if vertex {
                            material_for(colour, true)
                        } else {
                            materials.entry(key).or_insert_with(|| material_for(colour, false)).clone()
                        }
                    }
                };
                let material = if options.double_sided { double_sided(&material) } else { material };
                built.surface_set_material(0, &material);
                Some(built)
            })
            .clone();
        let lines = if options.edges {
            edges
                .entry(geometry.index())
                .or_insert_with(|| {
                    let mut built = lines(&[geometry.edges(), geometry.curves()], None)?;
                    built.surface_set_material(0, edge_material.as_ref().unwrap());
                    Some(built)
                })
                .clone()
        } else {
            None
        };
        if body.is_none() && lines.is_none() {
            continue;
        }

        let select = placement.select();
        let mut parent: Gd<Node3D> = if options.tree { group(scene, &mut root, &mut groups, &mut names, select.parent()) } else { root.clone() };
        let mut instance = MeshInstance3D::new_alloc();
        instance.set_name(&names.unique(parent.instance_id().to_i64(), &select.label()));
        instance.set_transform(transform(placement.raw_transform()));
        // Back from a Godot node to the file's: `CadaclysmScene.node(get_meta("cadaclysm_node"))`.
        instance.set_meta("cadaclysm_node", &(select.index() as i64).to_variant());
        instance.set_meta("cadaclysm_geometry", &(geometry.index() as i64).to_variant());
        instance.set_meta("cadaclysm_placement", &(index as i64).to_variant());
        match (&body, &lines) {
            (Some(mesh), _) => instance.set_mesh(mesh),
            (None, Some(mesh)) => {
                instance.set_mesh(mesh);
                instance.set_cast_shadows_setting(ShadowCastingSetting::OFF);
            }
            (None, None) => unreachable!(),
        }
        parent.add_child(&instance);
        instance.set_owner(&root);
        if let (Some(_), Some(mesh)) = (&body, &lines) {
            let mut outline = MeshInstance3D::new_alloc();
            outline.set_name("edges");
            outline.set_mesh(mesh);
            outline.set_cast_shadows_setting(ShadowCastingSetting::OFF);
            instance.add_child(&outline);
            outline.set_owner(&root);
        }
    }
    root
}

/// The `Node3D` standing for node `node` of the file's tree (and its ancestors), made
/// on first need; the root for none.
fn group(
    scene: &sdk::Scene,
    root: &mut Gd<Node3D>,
    groups: &mut HashMap<u32, Gd<Node3D>>,
    names: &mut Names,
    node: Option<sdk::Node<'_>>,
) -> Gd<Node3D> {
    let Some(node) = node else { return root.clone() };
    if let Some(existing) = groups.get(&node.index()) {
        return existing.clone();
    }
    let mut parent = group(scene, root, groups, names, node.parent());
    let mut made = Node3D::new_alloc();
    made.set_name(&names.unique(parent.instance_id().to_i64(), &node.label()));
    parent.add_child(&made);
    made.set_owner(&root.clone().upcast::<Node>());
    groups.insert(node.index(), made.clone());
    made
}
