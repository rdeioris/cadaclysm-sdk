// A user's translation unit calling Solid::from_node, open and open_all, with the
// headers' default hook: an optimised build (the CI's GCC Release leg) must compile it
// under -Werror. GCC -O2 once reported -Wmaybe-uninitialized here that the smoke, with
// its own CADACLYSM_BAD_ACCESS, never showed.
#include <cadaclysm/cadaclysm_blacksmith.hpp>

namespace bs = cadaclysm::blacksmith;

cadaclysm::Result<bs::Solid> first_body(const cadaclysm::Scene& scene) {
    for (const cadaclysm::Placement& placement : scene.placements()) {
        cadaclysm::Node node = placement.geometry();
        if (node.brep()) return bs::Solid::from_node(node);
    }
    return cadaclysm::Error{"no body", cadaclysm::Origin::kernel};
}

std::size_t bodies_in(const std::string& path) {
    auto all = bs::Solid::open_all(path);
    auto one = bs::Solid::open(path, 0);
    return (all ? all->size() : 0) + (one ? 1 : 0);
}

std::uint32_t faces_of(const cadaclysm::Node& node, bool placed) {
    auto made = bs::Solid::from_node(node, placed);
    return made ? made->faces() : 0;
}
