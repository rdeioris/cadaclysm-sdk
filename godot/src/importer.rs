//! CAD files as Godot scenes in the editor: drop a `.step` into the FileSystem dock and
//! it imports like a `.glb`, a scene of `MeshInstance3D`s to instance or inherit.
use godot::classes::{EditorPlugin, EditorSceneFormatImporter, IEditorPlugin, IEditorSceneFormatImporter, Object};
use godot::prelude::*;

use crate::meshes::{self, BuildOptions};
use crate::os_path;

/// Registers `CadaclysmImporter` with the editor; nothing to enable, the extension does it.
#[derive(GodotClass)]
#[class(tool, init, base = EditorPlugin)]
pub struct CadaclysmEditorPlugin {
    importer: Option<Gd<CadaclysmImporter>>,
    base: Base<EditorPlugin>,
}

#[godot_api]
impl IEditorPlugin for CadaclysmEditorPlugin {
    fn enter_tree(&mut self) {
        let importer = CadaclysmImporter::new_gd();
        self.base_mut().add_scene_format_importer_plugin(&importer);
        self.importer = Some(importer);
    }

    fn exit_tree(&mut self) {
        if let Some(importer) = self.importer.take() {
            self.base_mut().remove_scene_format_importer_plugin(&importer);
        }
    }
}

/// Imports STEP, IGES, IFC, Rhino 3dm, ACIS SAT, OCCT BREP and OpenSCAD files as
/// scenes. The Import dock's options: edges, the file's tree as nodes, double-sided
/// faces, and world-scale UVs.
#[derive(GodotClass)]
#[class(tool, init, base = EditorSceneFormatImporter)]
pub struct CadaclysmImporter {
    base: Base<EditorSceneFormatImporter>,
}

const OPTIONS: [(&str, bool); 4] =
    [("cadaclysm/edges", false), ("cadaclysm/tree", true), ("cadaclysm/double_sided", false), ("cadaclysm/uv_world", false)];

#[godot_api]
impl IEditorSceneFormatImporter for CadaclysmImporter {
    fn get_extensions(&self) -> PackedStringArray {
        ["step", "stp", "p21", "iges", "igs", "ifc", "3dm", "sat", "sab", "brep", "scad"]
            .into_iter()
            .map(GString::from)
            .collect()
    }

    fn get_import_options(&mut self, _path: GString) {
        for (name, default) in OPTIONS {
            self.base_mut().add_import_option(name, &default.to_variant());
        }
    }

    fn get_option_visibility(&self, _path: GString, _for_animation: bool, _option: GString) -> Variant {
        Variant::nil()
    }

    fn import_scene(&mut self, path: GString, _flags: u32, options: VarDictionary) -> Option<Gd<Object>> {
        let flag = |name: &str| options.get(name).is_some_and(|v| v.booleanize());
        let mut open = sdk_options(flag("cadaclysm/uv_world"));
        open = open.name(path.to_string());
        let scene = match open.open(os_path(&path)) {
            Ok(scene) => scene,
            Err(error) => {
                godot_error!("cadaclysm: {path}: {error}");
                return None;
            }
        };
        scene.realize_all();
        let build = BuildOptions {
            edges: flag("cadaclysm/edges"),
            edge_colour: Color::from_rgb(0.07, 0.07, 0.08),
            material: None,
            tree: flag("cadaclysm/tree"),
            double_sided: flag("cadaclysm/double_sided"),
        };
        let text = path.to_string();
        let name = text.rsplit('/').next().unwrap_or("CadaclysmScene").split('.').next().unwrap_or("CadaclysmScene").to_string();
        let root = meshes::instantiate(&scene, &name, &build);
        Some(root.upcast())
    }
}

fn sdk_options(uv_world: bool) -> cadaclysm_sdk::OpenOptions {
    let convention = cadaclysm_sdk::Convention::YUp as u32 | if uv_world { cadaclysm_sdk::UV_WORLD } else { 0 };
    cadaclysm_sdk::OpenOptions::new().convention(convention)
}
