// Scene::links() / joints() -- the mechanism facts, identical in every language: two
// links "base" and "arm", each naming one node of its own name; one joint "hinge" from
// "arm" (index 1) to "base" (index 0); the cube (no mechanism) has neither.
//
//     cadaclysm_kinematics_test samples/cube.scad
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include <cadaclysm/cadaclysm.hpp>

using cadaclysm::Result;

static int failures = 0;
static void expect(bool ok, const std::string& what) {
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", what.c_str());
        ++failures;
    }
}

static Result<void> run(const std::string& cube_path) {
    CADACLYSM_TRY(cube, cadaclysm::open(cube_path));
    expect(cube.links().empty() && cube.joints().empty(), "the cube scene has links or joints");

    // mechanism.stp sits beside whatever sample this test was given (the samples/
    // directory is the cube path's directory), the same way every wrapper's smoke finds it.
    std::filesystem::path mechanism_path =
        cadaclysm::detail::fs_path(cube_path).parent_path() / "mechanism.stp";
    CADACLYSM_TRY(mechanism, cadaclysm::open(cadaclysm::detail::utf8(mechanism_path)));

    std::vector<cadaclysm::Link> links = mechanism.links();
    expect(links.size() == 2 && links[0].name() == "base" && links[1].name() == "arm",
           "mechanism links are not [base, arm]");
    expect(links.size() == 2 && links[0].index() == 0 && links[1].index() == 1,
           "the links are not indices 0 and 1");
    for (const cadaclysm::Link& link : links) {
        std::vector<cadaclysm::Node> nodes = link.nodes();
        expect(nodes.size() == 1 && nodes[0].name() == link.name(),
               "link " + link.name() + " does not name exactly one node of its own name");
    }

    std::vector<cadaclysm::Joint> joints = mechanism.joints();
    expect(joints.size() == 1 && joints[0].name() == "hinge", "mechanism does not carry exactly one joint named hinge");
    cadaclysm::Joint hinge = joints[0];
    cadaclysm::Link start = hinge.start();
    cadaclysm::Link end = hinge.end();
    // The file's order, (arm, base): a swap into (parent, child) would fail here.
    expect(start.name() == "arm" && start.index() == 1 && end.name() == "base" && end.index() == 0,
           "joint hinge reads start=" + start.name() + "#" + std::to_string(start.index()) +
               " end=" + end.name() + "#" + std::to_string(end.index()));
    // Link equality holds across two lookups of the same index in the same scene.
    expect(start == mechanism.links()[1] && end == mechanism.links()[0] && start != end,
           "Link equality does not hold across two lookups");

    return {};
}

int main(int argc, char** argv) {
    std::string cube_path = argc > 1 ? argv[1] : "samples/cube.scad";
    Result<void> outcome = run(cube_path);
    if (!outcome) {
        std::fprintf(stderr, "FAIL: %s\n", outcome.error().message.c_str());
        return 1;
    }
    if (failures) return 1;
    std::puts("kinematics: OK");
    return 0;
}
