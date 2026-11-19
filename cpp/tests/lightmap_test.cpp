// Node::lightmap_uvs and OpenOptions::lightmap_resolution over a STEP with faces
// (samples/mechanism.stp has none, and a test on it would pass on nothing).
//
//     cadaclysm_lightmap_test rhino-fillet-mixed-radii.stp      ("-" skips)
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <cadaclysm/cadaclysm.hpp>

using cadaclysm::Result;

static Result<int> run(const std::string& path) {
    CADACLYSM_TRY(plain, cadaclysm::open(path));
    for (const cadaclysm::Node& node : plain.walk()) {
        if (!node.lightmap_uvs().empty()) {
            std::puts("FAIL: a lightmap arrived unasked");
            return 1;
        }
    }
    cadaclysm::OpenOptions asked;
    asked.lightmap_resolution = 256;
    CADACLYSM_TRY(lit, cadaclysm::open(path, asked));
    int count = 0;
    for (const cadaclysm::Node& node : lit.walk()) {
        cadaclysm::Span<const float> uvs = node.lightmap_uvs();
        if (uvs.empty()) continue;
        cadaclysm::Mesh mesh = node.mesh();
        if (uvs.size() != std::size_t(mesh.vertex_count()) * 2) {
            std::puts("FAIL: not two floats a vertex");
            return 1;
        }
        for (std::size_t i = 0; i < uvs.size(); ++i) {
            if (uvs[i] < 0.0f || uvs[i] > 1.0f) {
                std::puts("FAIL: outside the unit square");
                return 1;
            }
        }
        if (!mesh.uvs().empty()) {
            std::puts("FAIL: material uvs came with the lightmap");
            return 1;
        }
        ++count;
    }
    if (count == 0) {
        std::puts("FAIL: a faced STEP came back with no lightmap");
        return 1;
    }
    std::printf("lightmap_uvs: %d lit nodes\n", count);
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2 || std::strcmp(argv[1], "-") == 0) {
        std::puts("skipped: no faced STEP fixture");
        return 0;
    }
    Result<int> outcome = run(argv[1]);
    if (!outcome) {
        std::fprintf(stderr, "FAIL: %s\n", outcome.error().message.c_str());
        return 1;
    }
    return *outcome;
}
