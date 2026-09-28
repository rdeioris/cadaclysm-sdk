// Scene::links() / joints() -- the mechanism facts, identical in every language: two
// links "base" and "arm", each naming one node of its own name; one joint "hinge" from
// "arm" (index 1) to "base" (index 0); the cube (no mechanism) has neither. Also the
// joint's pair (revolute, ranged, both contact frames at (0, 0, 100)) and the file's one
// named state ("open": hinge set to 0.5).
//
//     cadaclysm_kinematics_test samples/cube.scad
#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <optional>
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

    // The pair: revolute about Z, ranged -1.5..1.5, both contact frames at (0, 0, 100).
    std::optional<cadaclysm::Pair> pair = hinge.pair();
    expect(pair.has_value(), "hinge has no pair");
    if (pair) {
        expect(pair->kind() == cadaclysm::PairKind::revolute, "hinge's pair is not revolute");
        expect(!pair->type_name().has_value(), "a revolute pair has a type name");
        expect(!pair->pitch().has_value(), "a revolute pair has a pitch");
        for (const std::array<double, 16>& raw : {pair->raw_frame_start(), pair->raw_frame_end()}) {
            expect(std::abs(raw[12] - 0.0) < 1e-9 && std::abs(raw[13] - 0.0) < 1e-9 && std::abs(raw[14] - 100.0) < 1e-9,
                   "a pair frame's origin is not (0, 0, 100)");
            expect(std::abs(raw[8] - 0.0) < 1e-9 && std::abs(raw[9] - 0.0) < 1e-9 && std::abs(raw[10] - 1.0) < 1e-9,
                   "a pair frame's z axis is not (0, 0, 1)");
        }
        std::vector<cadaclysm::Freedom> freedoms = pair->freedoms();
        expect(freedoms.size() == 1, "pair does not have exactly one freedom");
        if (freedoms.size() == 1) {
            expect(freedoms[0].motion == cadaclysm::Motion::rotation && freedoms[0].axis == cadaclysm::FreedomAxis::z,
                   "freedom is not rotation about z");
            expect(freedoms[0].lower.has_value() && std::abs(*freedoms[0].lower - -1.5) < 1e-9 &&
                       freedoms[0].upper.has_value() && std::abs(*freedoms[0].upper - 1.5) < 1e-9,
                   "freedom range is not -1.5..1.5");
        }
    }

    // The state: one named "open", one row (hinge, [0.5]).
    std::vector<cadaclysm::State> states = mechanism.states();
    expect(states.size() == 1 && states[0].index == 0 && states[0].name == "open",
           "mechanism does not carry exactly one state named open");
    if (states.size() == 1) {
        expect(states[0].values.size() == 1, "state open does not have exactly one row");
        if (states[0].values.size() == 1) {
            const cadaclysm::StateValue& row = states[0].values[0];
            expect(row.joint.name() == "hinge" && row.joint.index() == 0, "state row joint is not hinge(0)");
            expect(row.values.size() == 1 && std::abs(row.values[0] - 0.5) < 1e-9, "state row values are not [0.5]");
        }
    }
    expect(cube.states().empty(), "the cube scene has states");

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
