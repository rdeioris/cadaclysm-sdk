// Assembly, Solid::named and Solid::name, over cadaclysm_blacksmith.py's
// _shared_assembly() shape and the spec section 5 facts it checks -- the same scenario
// Node's blacksmith.test.js and Rust's assembly_facts_hold_as_python_checks_them run.
// Needs the kernel and reader libraries and a license; the exit code is the verdict.
//
//     cadaclysm_assembly_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm.hpp>
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

using cadaclysm::Error;
using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static std::size_t count_of(const std::string& haystack, const std::string& needle) {
    std::size_t n = 0;
    for (std::size_t at = haystack.find(needle); at != std::string::npos; at = haystack.find(needle, at + needle.size())) ++n;
    return n;
}

static Result<void> run() {
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(1, 6));
    CADACLYSM_TRY(bolt, cylinder.named("bolt"));
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(20, 10, 2));
    CADACLYSM_TRY(named_plate, cuboid.named("plate"));
    CADACLYSM_TRY(plate, named_plate.coloured({1, 0.5, 0}));

    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(bracket, bs::Assembly::create("bracket"));
    CADACLYSM_TRY(plate_placement, bracket.place_solid(plate, xy));
    CADACLYSM_TRY(bolt1_at, bs::Frame::xy({5, 5, 2}));
    CADACLYSM_TRY(bolt1_placement, bracket.place_solid(bolt, bolt1_at));
    CADACLYSM_TRY(bolt2_at, bs::Frame::xy({15, 5, 2}));
    CADACLYSM_TRY(bolt2_placement, bracket.place_solid(bolt, bolt2_at));
    check(plate_placement == "plate", "the plate's placement name is '" + plate_placement + "', not 'plate'");
    check(bolt1_placement == "bolt", "the first bolt's placement name is '" + bolt1_placement + "', not 'bolt'");
    check(bolt2_placement == "bolt 2", "the second bolt's placement name is '" + bolt2_placement + "', not 'bolt 2'");  // fact 1

    CADACLYSM_TRY(frame, bs::Assembly::create("frame"));
    CADACLYSM_TRY(right, bs::Frame::make({100, 0, 0}, {0, 1, 0}, {-1, 0, 0}, {0, 0, 1}));
    CADACLYSM_TRY(left_placement, frame.place_assembly(bracket, xy, "left"));
    CADACLYSM_TRY(right_placement, frame.place_assembly(bracket, right, "right"));
    CADACLYSM_TRY(root_bolt_at, bs::Frame::xy({50, 50, 0}));
    CADACLYSM_TRY(root_bolt_placement, frame.place_solid(bolt, root_bolt_at));
    check(left_placement == "left", "left placement name is '" + left_placement + "'");
    check(right_placement == "right", "right placement name is '" + right_placement + "'");
    check(root_bolt_placement == "bolt", "the root bolt's placement name is '" + root_bolt_placement + "'");  // fact 1

    CADACLYSM_TRY(frame_step_text, frame.step_text());
    check(count_of(frame_step_text, "=MANIFOLD_SOLID_BREP(") == 2, "not exactly 2 MANIFOLD_SOLID_BREP entities");
    check(count_of(frame_step_text, "=PRODUCT(") == 4, "not exactly 4 PRODUCT entities");
    check(count_of(frame_step_text, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(") == 6,
          "not exactly 6 NEXT_ASSEMBLY_USAGE_OCCURRENCE entities");  // fact 2
    check(frame_step_text.find("'left'") != std::string::npos && frame_step_text.find("'right'") != std::string::npos &&
              frame_step_text.find("'bolt 2'") != std::string::npos,
          "the STEP text is missing 'left', 'right' or 'bolt 2'");  // fact 3

    // Fact 11: read-back through the reader, structure only. One root "frame" with three
    // children: two "bracket" containers each holding plate/bolt/bolt, and one "bolt".
    {
        cadaclysm::OpenOptions options;
        CADACLYSM_TRY(scene, cadaclysm::open_memory(frame_step_text.data(), frame_step_text.size(), "stp", options));
        std::vector<cadaclysm::Node> roots = scene.roots();
        check(roots.size() == 1, "the read-back scene has " + std::to_string(roots.size()) + " roots, not 1");
        if (roots.size() == 1) {
            check(roots[0].name() == "frame", "the root is named '" + roots[0].name() + "', not 'frame'");
            std::vector<cadaclysm::Node> root_children = roots[0].children();
            check(root_children.size() == 3, "the root has " + std::to_string(root_children.size()) + " children, not 3");  // fact 11
            std::size_t bracket_count = 0, bolt_count = 0;
            for (const cadaclysm::Node& child : root_children) {
                if (child.name() == "bracket") {
                    ++bracket_count;
                    std::vector<std::string> names;
                    for (const cadaclysm::Node& grandchild : child.children()) names.push_back(grandchild.name());
                    std::sort(names.begin(), names.end());
                    check(names == std::vector<std::string>({"bolt", "bolt", "plate"}),
                          "a 'bracket' container's children are not [bolt, bolt, plate]");
                } else if (child.name() == "bolt") {
                    ++bolt_count;
                }
            }
            check(bracket_count == 2, "the root has " + std::to_string(bracket_count) + " 'bracket' children, not 2");
            check(bolt_count == 1, "the root has " + std::to_string(bolt_count) + " 'bolt' children, not 1");
        }
    }

    // Fact 4: a late placement into bracket shows up wherever bracket is placed.
    CADACLYSM_TRY(bolt3_at, bs::Frame::xy({10, 8, 2}));
    CADACLYSM_TRY(bolt3_placement, bracket.place_solid(bolt, bolt3_at));
    (void)bolt3_placement;
    CADACLYSM_TRY(again, frame.step_text());
    check(count_of(again, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(") == 7,
          "after a late placement into bracket, the STEP text has " +
              std::to_string(count_of(again, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE(")) + " NAUOs, not 7");

    // Fact 5: a cycle is refused, naming it.
    Result<std::string> cycle = bracket.place_assembly(frame, xy);
    check(!cycle, "placing frame into bracket (a cycle) was accepted");
    if (!cycle) check(cycle.error().message.find("bracket \xE2\x86\x92 frame \xE2\x86\x92 bracket") != std::string::npos,
                       "the cycle refusal does not name it: " + cycle.error().message);

    // Fact 6: an explicit name already taken is refused.
    Result<std::string> duplicate = frame.place_assembly(bracket, xy, "left");
    check(!duplicate, "placing under the name 'left' twice was accepted");

    // Fact 7: a mirrored raw frame is refused in the library's own words, not
    // Frame::make's -- place_solid_raw is the narrow unchecked route added for this,
    // following Solid::place_raw's own precedent.
    const double mirrored[12] = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1};
    Result<std::string> refused = frame.place_solid_raw(bolt, mirrored);
    check(!refused, "a mirrored raw frame was accepted");
    if (!refused) check(refused.error().message.find("right-handed and orthonormal") != std::string::npos,
                         "the mirrored-frame refusal does not say 'right-handed and orthonormal': " + refused.error().message);

    // Fact 8: an assembly placing nothing is refused at step_text().
    CADACLYSM_TRY(x, bs::Assembly::create("x"));
    check(!x.step_text(), "an empty assembly's step_text() was accepted");

    // Fact 9: an assembly placing an empty sub-assembly is refused, naming it.
    CADACLYSM_TRY(outer, bs::Assembly::create("outer"));
    CADACLYSM_TRY(hollow, bs::Assembly::create("hollow"));
    CADACLYSM_TRY(hollow_placement, outer.place_assembly(hollow, xy));
    (void)hollow_placement;
    Result<std::string> hollow_refused = outer.step_text();
    check(!hollow_refused, "an assembly placing an empty sub-assembly was accepted at step_text()");
    if (!hollow_refused) check(hollow_refused.error().message.find("hollow") != std::string::npos,
                                "the empty-sub-assembly refusal does not mention 'hollow': " + hollow_refused.error().message);

    // Fact 10: Solid::named/Solid::name -- the name rides through a one-source operation
    // (place, coloured) and is dropped by a two-source one (join) or a fresh primitive.
    check(bolt.name() == std::optional<std::string>("bolt"), "bolt.name() is not 'bolt'");
    CADACLYSM_TRY(bolt_at, bs::Frame::xy({1, 2, 3}));
    CADACLYSM_TRY(placed_bolt, bolt.place(bolt_at));
    check(placed_bolt.name() == std::optional<std::string>("bolt"), "a placed bolt's name is not 'bolt'");
    CADACLYSM_TRY(coloured_bolt, bolt.coloured({1, 0, 0}));
    check(coloured_bolt.name() == std::optional<std::string>("bolt"), "a coloured bolt's name is not 'bolt'");
    CADACLYSM_TRY(cube, bs::Solid::cuboid(1, 1, 1));
    CADACLYSM_TRY(joined_bolt, bolt.join(cube));
    check(joined_bolt.name() == std::nullopt, "a joined bolt's name is not null");
    CADACLYSM_TRY(fresh_cube, bs::Solid::cuboid(1, 1, 1));
    check(fresh_cube.name() == std::nullopt, "a fresh cuboid's name is not null");  // fact 10

    check(bolt.named("").ok() == false, "an empty name was accepted");
    return {};
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "FAIL: license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    Result<void> outcome = run();
    if (!outcome) {
        std::fprintf(stderr, "FAIL: %s\n", outcome.error().message.c_str());
        return 1;
    }
    if (failures) {
        std::fprintf(stderr, "%d assembly check(s) failed\n", failures);
        return 1;
    }
    std::puts("assembly: OK");
    return 0;
}
