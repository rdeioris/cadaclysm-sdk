// Node::material, Scene::image_count and Scene::image against samples/textured-quad.glb
// (samples/textured-quad.py writes it): the two materials it names, every field of the
// textured one, its one PNG, and the error past the last image; then samples/cube.scad,
// which names no material and no image.
//
//     cadaclysm_material_test textured-quad.glb cube.scad
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <map>
#include <optional>
#include <string>

#include <cadaclysm/cadaclysm.hpp>

using cadaclysm::Result;

static int failures = 0;

#define CHECK(condition, ...)              \
    do {                                   \
        if (!(condition)) {                \
            std::printf("FAIL: ");         \
            std::printf(__VA_ARGS__);      \
            std::printf("\n");             \
            ++failures;                    \
        }                                  \
    } while (0)

static bool near(float a, float b) { return std::fabs(a - b) < 1e-6f; }

static Result<int> textured(const std::string& path) {
    CADACLYSM_TRY(scene, cadaclysm::open(path));
    std::map<std::string, cadaclysm::Material> materials;
    for (const cadaclysm::Node& node : scene.nodes()) {
        std::optional<cadaclysm::Material> material = node.material();
        if (material) materials.emplace(material->name, *material);
    }
    CHECK(materials.size() == 2 && materials.count("Checker") == 1 && materials.count("Plain") == 1,
          "materials: %zu, not Checker and Plain", materials.size());

    std::map<std::string, cadaclysm::Material>::const_iterator checker = materials.find("Checker");
    if (checker != materials.end()) {
        const cadaclysm::Material& m = checker->second;
        CHECK(near(m.base_color[0], 1.0f) && near(m.base_color[1], 0.5f) && near(m.base_color[2], 0.25f) &&
                  near(m.base_color[3], 1.0f),
              "Checker base_color (%g, %g, %g, %g)", m.base_color[0], m.base_color[1], m.base_color[2],
              m.base_color[3]);
        CHECK(near(m.metallic, 0.0f) && near(m.roughness, 0.5f), "Checker metallic %g roughness %g", m.metallic,
              m.roughness);
        CHECK(m.alpha_mode == CADACLYSM_ALPHA_MASK && m.alpha_mode_name() == "mask", "Checker alpha %s",
              m.alpha_mode_name().c_str());
        CHECK(near(m.alpha_cutoff, 0.25f), "Checker alpha_cutoff %g", m.alpha_cutoff);
        CHECK(m.double_sided, "Checker is not double-sided");
        CHECK(m.base_color_image.has_value() && *m.base_color_image == 0u, "Checker base_color_image");
        CHECK(m.base_color_uv_set == 0u, "Checker uv set %u", m.base_color_uv_set);
        CHECK(near(m.uv_offset[0], 0.5f) && near(m.uv_offset[1], 0.0f), "Checker uv_offset (%g, %g)", m.uv_offset[0],
              m.uv_offset[1]);
        CHECK(near(m.uv_rotation, 0.0f), "Checker uv_rotation %g", m.uv_rotation);
        CHECK(near(m.uv_scale[0], 2.0f) && near(m.uv_scale[1], 2.0f), "Checker uv_scale (%g, %g)", m.uv_scale[0],
              m.uv_scale[1]);
        CHECK(m.wrap_u_name() == "clamp_to_edge" && m.wrap_v_name() == "mirrored_repeat", "Checker wraps %s, %s",
              m.wrap_u_name().c_str(), m.wrap_v_name().c_str());
        CHECK(m.mag_filter_name() == "linear" && m.min_filter_name() == "linear", "Checker filters %s, %s",
              m.mag_filter_name().c_str(), m.min_filter_name().c_str());
    }
    std::map<std::string, cadaclysm::Material>::const_iterator plain = materials.find("Plain");
    if (plain != materials.end()) {
        CHECK(!plain->second.base_color_image.has_value(), "Plain has an image");
        CHECK(plain->second.alpha_mode_name() == "opaque", "Plain alpha %s", plain->second.alpha_mode_name().c_str());
    }

    CHECK(scene.image_count() == 1u, "image_count %u", scene.image_count());
    Result<cadaclysm::Image> image = scene.image(0);
    CHECK(image.ok(), "image 0: %s", image ? "" : image.error().message.c_str());
    if (image) {
        CHECK(image->mime == "image/png", "mime %s", image->mime.c_str());
        CHECK(image->name == "checker", "name %s", image->name.c_str());
        CHECK(image->data.size() == 75u, "%zu bytes, not 75", image->data.size());
        CHECK(image->data.size() >= 4 && image->data[0] == 0x89 && image->data[1] == 'P' && image->data[2] == 'N' &&
                  image->data[3] == 'G',
              "not a PNG");
    }
    Result<cadaclysm::Image> past = scene.image(1);
    CHECK(!past.ok(), "image 1 answered");
    if (!past) CHECK(past.error().message == "image 1: the scene has 1", "%s", past.error().message.c_str());
    return 0;
}

static Result<int> plain(const std::string& path) {
    CADACLYSM_TRY(scene, cadaclysm::open(path));
    CHECK(scene.image_count() == 0u, "cube.scad image_count %u", scene.image_count());
    for (const cadaclysm::Node& node : scene.nodes()) {
        CHECK(!node.material().has_value(), "a cube.scad node has a material");
    }
    CHECK(!scene.image(0).ok(), "cube.scad image 0 answered");
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::puts("usage: cadaclysm_material_test textured-quad.glb cube.scad");
        return 2;
    }
    Result<int> one = textured(argv[1]);
    if (!one) {
        std::printf("FAIL: %s: %s\n", argv[1], one.error().message.c_str());
        return 1;
    }
    Result<int> two = plain(argv[2]);
    if (!two) {
        std::printf("FAIL: %s: %s\n", argv[2], two.error().message.c_str());
        return 1;
    }
    if (failures) return 1;
    std::puts("material: ok");
    return 0;
}
