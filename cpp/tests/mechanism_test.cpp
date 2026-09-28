// Assembly::link/Assembly::joint, at parity with the Python reference's _mechanism() and
// its two mechanism tests in test_cadaclysm_blacksmith.py -- see Node's
// blacksmith.test.js and Rust's mod tests for the same facts worked out. Needs the
// kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_mechanism_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cstdio>
#include <functional>
#include <sstream>
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

// `text` with every FILE_NAME( line removed -- what fact 3 compares before and after the
// eleven refusals, since only the timestamp line should ever move.
static std::string no_stamp(const std::string& text) {
    std::ostringstream out;
    std::size_t start = 0;
    bool first = true;
    while (start <= text.size()) {
        std::size_t nl = text.find('\n', start);
        std::string line = text.substr(start, nl == std::string::npos ? std::string::npos : nl - start);
        if (line.rfind("FILE_NAME(", 0) != 0) {
            if (!first) out << '\n';
            out << line;
            first = false;
        }
        if (nl == std::string::npos) break;
        start = nl + 1;
    }
    return out.str();
}

static Result<void> run() {
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(1, 6));
    CADACLYSM_TRY(bolt, cylinder.named("bolt"));
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(20, 10, 2));
    CADACLYSM_TRY(plate, cuboid.named("plate"));

    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(bracket, bs::Assembly::create("bracket"));
    CADACLYSM_TRY(bolt1_at, bs::Frame::xy({5, 5, 2}));
    CADACLYSM_TRY(bolt2_at, bs::Frame::xy({15, 5, 2}));
    CADACLYSM_TRY(plate_placement, bracket.place_solid(plate, xy));
    (void)plate_placement;
    CADACLYSM_TRY(bolt1_placement, bracket.place_solid(bolt, bolt1_at));
    (void)bolt1_placement;
    CADACLYSM_TRY(bolt2_placement, bracket.place_solid(bolt, bolt2_at));
    (void)bolt2_placement;
    Result<void> bracket_fixed = bracket.link("fixed", {"plate"});
    check(bool(bracket_fixed), "bracket.link(\"fixed\", [\"plate\"]) was refused");
    Result<void> bracket_bolts = bracket.link("bolts", {"bolt", "bolt 2"});
    check(bool(bracket_bolts), "bracket.link(\"bolts\", [\"bolt\", \"bolt 2\"]) was refused");
    Result<void> bracket_screw = bracket.joint("screw", "fixed", "bolts");
    check(bool(bracket_screw), "bracket.joint(\"screw\", \"fixed\", \"bolts\") was refused");

    CADACLYSM_TRY(arm, bs::Assembly::create("arm"));
    CADACLYSM_TRY(upper_at, bs::Frame::xy({0, 0, 10}));
    CADACLYSM_TRY(base_placement, arm.place_solid(plate, xy, "base"));
    (void)base_placement;
    CADACLYSM_TRY(upper_placement, arm.place_assembly(bracket, upper_at, "upper"));
    (void)upper_placement;
    CADACLYSM_TRY(pin_placement, arm.place_solid(bolt, bolt1_at, "pin"));
    (void)pin_placement;
    Result<void> arm_ground = arm.link("ground", {"base"});
    check(bool(arm_ground), "arm.link(\"ground\", [\"base\"]) was refused");
    Result<void> arm_upper_arm = arm.link("upper arm", {"upper", "pin"});
    check(bool(arm_upper_arm), "arm.link(\"upper arm\", [\"upper\", \"pin\"]) was refused");
    Result<void> arm_shoulder = arm.joint("shoulder", "ground", "upper arm");
    check(bool(arm_shoulder), "arm.joint(\"shoulder\", \"ground\", \"upper arm\") was refused");

    // Fact 1: the default schema (no explicit schema) carries the kinematic entities.
    CADACLYSM_TRY(step, arm.step_text());
    check(step.find("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF") != std::string::npos,
          "step_text() does not carry AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF");
    check(count_of(step, "=KINEMATIC_LINK(") == 4, "not exactly 4 KINEMATIC_LINK entities");
    check(count_of(step, "=RIGID_LINK_REPRESENTATION(") == 6, "not exactly 6 RIGID_LINK_REPRESENTATION entities");
    check(count_of(step, "=CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION(") == 6,
          "not exactly 6 CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION entities");
    check(count_of(step, "=KINEMATIC_JOINT(") == 2, "not exactly 2 KINEMATIC_JOINT entities");
    check(count_of(step, "=KINEMATIC_TOPOLOGY_STRUCTURE(") == 2, "not exactly 2 KINEMATIC_TOPOLOGY_STRUCTURE entities");

    // Fact 2: an explicit schema without kinematic entities is refused.
    Result<std::string> schema_refused = arm.step_text("config_control_design");
    check(!schema_refused, "step_text(\"config_control_design\") was accepted");
    if (!schema_refused) {
        check(schema_refused.error().message.find("no kinematic entities") != std::string::npos,
              "the schema refusal does not say 'no kinematic entities': " + schema_refused.error().message);
    }

    // Fact 3: each of the eleven refusals raises with exactly its message, and afterwards
    // the STEP text (with FILE_NAME( lines stripped) is unchanged.
    CADACLYSM_TRY(before_raw, arm.step_text());
    std::string before = no_stamp(before_raw);
    std::vector<std::pair<std::function<Result<void>()>, std::string>> refusals = {
        {[&] { return arm.link("", {"base"}); }, "link: a name cannot be empty"},
        {[&] { return arm.link("ground", {"base"}); }, "link: assembly 'arm' already has a link named 'ground'"},
        {[&] { return arm.link("free", {}); }, "link: link 'free' names no placements"},
        {[&] { return arm.link("free", {"base", "base"}); }, "link: link 'free' names placement 'base' twice"},
        {[&] { return arm.link("free", {"bolt"}); }, "link: assembly 'arm' has no placement named 'bolt'"},
        {[&] { return arm.link("free", {"pin"}); }, "link: placement 'pin' of assembly 'arm' is already in link 'upper arm'"},
        {[&] { return arm.joint("", "ground", "upper arm"); }, "joint: a name cannot be empty"},
        {[&] { return arm.joint("shoulder", "upper arm", "ground"); },
         "joint: assembly 'arm' already has a joint named 'shoulder'"},
        {[&] { return arm.joint("wrist", "ground", "hand"); }, "joint: assembly 'arm' has no link named 'hand'"},
        {[&] { return arm.joint("wrist", "ground", "ground"); }, "joint: joint 'wrist' joins link 'ground' to itself"},
        {[&] { return arm.joint("wrist", "ground", "upper arm"); },
         "joint: assembly 'arm' already joins 'ground' to 'upper arm'"},
    };
    for (const auto& [call, message] : refusals) {
        Result<void> outcome = call();
        check(!outcome, "\"" + message + "\" was accepted");
        if (!outcome) check(outcome.error().message == message, "got \"" + outcome.error().message + "\", expected \"" + message + "\"");
    }
    CADACLYSM_TRY(after_raw, arm.step_text());
    check(no_stamp(after_raw) == before, "step_text() (minus FILE_NAME( lines) changed after the eleven refusals");

    // Fact 5: read-back through to_scene. Checked ahead of fact 4's reverse "back"
    // joint, so the joint list below is exactly the two joints the fixture built.
    CADACLYSM_TRY(scene, arm.to_scene());
    std::vector<cadaclysm::Link> links = scene.links();
    check(links.size() == 4, "arm.to_scene() does not have exactly 4 links");
    std::vector<std::string> link_names;
    std::vector<std::size_t> node_counts;
    for (const cadaclysm::Link& link : links) {
        link_names.push_back(link.name());
        node_counts.push_back(link.nodes().size());
    }
    check(link_names == std::vector<std::string>({"fixed", "bolts", "ground", "upper arm"}),
          "arm.to_scene()'s link names are wrong");
    check(node_counts == std::vector<std::size_t>({1, 2, 1, 2}), "arm.to_scene()'s link node counts are not 1/2/1/2");
    std::vector<cadaclysm::Joint> joints = scene.joints();
    check(joints.size() == 2, "arm.to_scene() does not have exactly 2 joints");
    if (joints.size() == 2) {
        check(joints[0].name() == "screw" && joints[0].start().index() == 0 && joints[0].end().index() == 1,
              "arm.to_scene()'s first joint is not (screw, 0, 1)");
        check(joints[1].name() == "shoulder" && joints[1].start().index() == 2 && joints[1].end().index() == 3,
              "arm.to_scene()'s second joint is not (shoulder, 2, 3)");
    }
    bool has_kinematics_diagnostic = false;
    for (const std::string& d : scene.diagnostics()) {
        if (d.rfind("kinematics:", 0) == 0) has_kinematics_diagnostic = true;
    }
    check(!has_kinematics_diagnostic, "arm.to_scene() has a kinematics: diagnostic");

    // Fact 4: the reverse pair is a new joint.
    Result<void> back = arm.joint("back", "upper arm", "ground");
    check(bool(back), "arm.joint(\"back\", \"upper arm\", \"ground\") (the reverse pair) was refused");

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
        std::fprintf(stderr, "%d mechanism check(s) failed\n", failures);
        return 1;
    }
    std::puts("mechanism: OK");
    return 0;
}
