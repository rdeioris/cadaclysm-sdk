// Assembly::pair/state/base and pair_freedom_count, at parity with the Python reference's
// _paired() and its tests in test_cadaclysm_blacksmith.py (spec 2026-09-28) -- see Node's
// blacksmith.test.js and Rust's mod tests for the same facts worked out. Needs the kernel
// library and a license; the exit code is the verdict.
//
//     cadaclysm_pair_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdio>
#include <functional>
#include <optional>
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

static void check_close(double got, double want, const std::string& what, double tolerance = 1e-9) {
    check(std::fabs(got - want) <= tolerance, what + ": got " + std::to_string(got) + ", want " + std::to_string(want));
}

static std::size_t count_of(const std::string& haystack, const std::string& needle) {
    std::size_t n = 0;
    for (std::size_t at = haystack.find(needle); at != std::string::npos; at = haystack.find(needle, at + needle.size())) ++n;
    return n;
}

// The message a refused `step_text()` carries while "back" has no pair -- fact 8.
static Result<std::string> unpaired_message(const bs::Assembly& arm) {
    return arm.step_text();
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
    check(bool(bracket.link("fixed", {"plate"})), "bracket.link(\"fixed\", [\"plate\"]) was refused");
    check(bool(bracket.link("bolts", {"bolt", "bolt 2"})), "bracket.link(\"bolts\", [\"bolt\", \"bolt 2\"]) was refused");
    check(bool(bracket.joint("screw", "fixed", "bolts")), "bracket.joint(\"screw\", \"fixed\", \"bolts\") was refused");

    CADACLYSM_TRY(arm, bs::Assembly::create("arm"));
    CADACLYSM_TRY(upper_at, bs::Frame::xy({0, 0, 10}));
    CADACLYSM_TRY(base_placement, arm.place_solid(plate, xy, "base"));
    (void)base_placement;
    CADACLYSM_TRY(upper_placement, arm.place_assembly(bracket, upper_at, "upper"));
    (void)upper_placement;
    CADACLYSM_TRY(pin_placement, arm.place_solid(bolt, bolt1_at, "pin"));
    (void)pin_placement;
    check(bool(arm.link("ground", {"base"})), "arm.link(\"ground\", [\"base\"]) was refused");
    check(bool(arm.link("upper arm", {"upper", "pin"})), "arm.link(\"upper arm\", [\"upper\", \"pin\"]) was refused");
    check(bool(arm.joint("shoulder", "ground", "upper arm")), "arm.joint(\"shoulder\", \"ground\", \"upper arm\") was refused");

    // _paired(): bracket's "screw" prismatic, arm's "shoulder" revolute ranged, a state, a base.
    CADACLYSM_TRY(screw_frame, bs::Frame::xy({1, 2, 3}));
    CADACLYSM_TRY(screw_end_frame, bs::Frame::xy({4, 2, 3}));
    bs::PairOptions screw_options;
    screw_options.end_frame = screw_end_frame;
    check(bool(bracket.pair("screw", "prismatic", screw_frame, screw_options)), "bracket.pair(\"screw\", \"prismatic\", ...) was refused");

    CADACLYSM_TRY(shoulder_frame, bs::Frame::xy({0, 0, 10}));
    bs::PairOptions shoulder_options;
    shoulder_options.ranges = std::vector<bs::Range>{{-1.5, 1.5}};
    check(bool(arm.pair("shoulder", "revolute", shoulder_frame, shoulder_options)), "arm.pair(\"shoulder\", \"revolute\", ...) was refused");

    check(bool(arm.state("reach", {bs::StateRow{"shoulder", {0.5}}})), "arm.state(\"reach\", ...) was refused");
    check(bool(arm.base("ground")), "arm.base(\"ground\") was refused");

    // Fact 1: the written STEP text carries the pairs and the state.
    CADACLYSM_TRY(step, arm.step_text());
    check(count_of(step, "=MECHANISM_REPRESENTATION(") == 2, "not exactly 2 MECHANISM_REPRESENTATION entities");
    check(count_of(step, "=PAIR_REPRESENTATION_RELATIONSHIP(") == 2, "not exactly 2 PAIR_REPRESENTATION_RELATIONSHIP entities");
    check(count_of(step, "REVOLUTE_PAIR_WITH_RANGE") == 1, "not exactly 1 REVOLUTE_PAIR_WITH_RANGE");
    check(count_of(step, "PRISMATIC_PAIR") == 1, "not exactly 1 PRISMATIC_PAIR");
    check(count_of(step, "=KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION(") == 1, "not exactly 1 KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION");
    check(count_of(step, "=MECHANISM_STATE_REPRESENTATION(") == 1, "not exactly 1 MECHANISM_STATE_REPRESENTATION");

    // Facts 2, 3, 4, 9: read back through to_scene.
    CADACLYSM_TRY(scene, arm.to_scene());
    std::optional<cadaclysm::Joint> shoulder_joint;
    std::optional<cadaclysm::Joint> screw_joint;
    for (const cadaclysm::Joint& j : scene.joints()) {
        if (j.name() == "shoulder") shoulder_joint = j;
        if (j.name() == "screw") screw_joint = j;
    }
    check(shoulder_joint.has_value(), "scene has no joint named 'shoulder'");
    check(screw_joint.has_value(), "scene has no joint named 'screw'");
    if (shoulder_joint) {
        std::optional<cadaclysm::Pair> pair = shoulder_joint->pair();
        check(pair.has_value(), "'shoulder' has no pair");
        if (pair) {
            check(pair->kind() == cadaclysm::PairKind::revolute, "'shoulder''s pair is not revolute");
            for (const cadaclysm::Matrix4& frame : {pair->frame_start(), pair->frame_end()}) {
                check_close(frame[0][3], 0.0, "shoulder frame origin x");
                check_close(frame[1][3], 0.0, "shoulder frame origin y");
                check_close(frame[2][3], 10.0, "shoulder frame origin z");
                check_close(frame[0][2], 0.0, "shoulder frame z-axis x");
                check_close(frame[1][2], 0.0, "shoulder frame z-axis y");
                check_close(frame[2][2], 1.0, "shoulder frame z-axis z");
            }
            std::vector<cadaclysm::Freedom> freedoms = pair->freedoms();
            check(freedoms.size() == 1, "'shoulder' does not have exactly 1 freedom");
            if (freedoms.size() == 1) {
                check(freedoms[0].motion == cadaclysm::Motion::rotation, "'shoulder''s freedom is not a rotation");
                check(freedoms[0].axis == cadaclysm::FreedomAxis::z, "'shoulder''s freedom is not about z");
                check(freedoms[0].lower.has_value(), "'shoulder''s freedom has no lower bound");
                check(freedoms[0].upper.has_value(), "'shoulder''s freedom has no upper bound");
                if (freedoms[0].lower) check_close(*freedoms[0].lower, -1.5, "shoulder lower");
                if (freedoms[0].upper) check_close(*freedoms[0].upper, 1.5, "shoulder upper");
            }
        }
    }
    if (screw_joint) {
        std::optional<cadaclysm::Pair> pair = screw_joint->pair();
        check(pair.has_value(), "'screw' has no pair");
        if (pair) {
            check(pair->kind() == cadaclysm::PairKind::prismatic, "'screw''s pair is not prismatic");
            bool all_unranged = true;
            for (const cadaclysm::Freedom& f : pair->freedoms()) {
                if (f.lower.has_value() || f.upper.has_value()) all_unranged = false;
            }
            check(all_unranged, "'screw''s freedoms are not all unranged");
            cadaclysm::Matrix4 start = pair->frame_start();
            cadaclysm::Matrix4 end = pair->frame_end();
            check_close(start[0][3], 1.0, "screw frame_start x");
            check_close(start[1][3], 2.0, "screw frame_start y");
            check_close(start[2][3], 13.0, "screw frame_start z");
            check_close(end[0][3], 4.0, "screw frame_end x");
            check_close(end[1][3], 2.0, "screw frame_end y");
            check_close(end[2][3], 13.0, "screw frame_end z");
        }
    }

    std::optional<cadaclysm::Link> base = scene.base();
    check(base.has_value() && base->name() == "ground", "scene.base() is not 'ground'");
    std::vector<cadaclysm::State> states = scene.states();
    check(states.size() == 1 && states[0].name == "reach", "scene.states() is not exactly [\"reach\"]");
    if (states.size() == 1) {
        const cadaclysm::State& reach = states[0];
        check(reach.values.size() == 1, "'reach' does not have exactly 1 row");
        if (reach.values.size() == 1) {
            check(reach.values[0].joint.name() == "shoulder", "'reach''s row does not name 'shoulder'");
            check(reach.values[0].values.size() == 1, "'reach''s row does not have exactly 1 value");
            if (reach.values[0].values.size() == 1) check_close(reach.values[0].values[0], 0.5, "reach value");
        }

        // Fact 5: pose_state(reach) carries the pin node's origin (5, 5, 2) to
        // (5cos0.5 - 5sin0.5, 5sin0.5 + 5cos0.5, 2).
        CADACLYSM_TRY(pose, scene.pose_state(reach));
        std::optional<cadaclysm::Link> upper_arm;
        for (const cadaclysm::Link& l : scene.links()) {
            if (l.name() == "upper arm") upper_arm = l;
        }
        check(upper_arm.has_value(), "scene has no link named 'upper arm'");
        if (upper_arm) {
            std::optional<cadaclysm::Node> pin_node;
            for (const cadaclysm::Node& n : upper_arm->nodes()) {
                cadaclysm::Matrix4 t = n.transform();
                if (std::fabs(t[0][3] - 5.0) < 1e-9 && std::fabs(t[1][3] - 5.0) < 1e-9 && std::fabs(t[2][3] - 2.0) < 1e-9) {
                    pin_node = n;
                    break;
                }
            }
            check(pin_node.has_value(), "'upper arm' has no node at (5, 5, 2)");
            if (pin_node) {
                cadaclysm::Matrix4 posed = pose.transform(*pin_node);
                check_close(posed[0][3], 5 * std::cos(0.5) - 5 * std::sin(0.5), "posed pin x");
                check_close(posed[1][3], 5 * std::sin(0.5) + 5 * std::cos(0.5), "posed pin y");
                check_close(posed[2][3], 2.0, "posed pin z");
            }
        }
    }

    // Fact 6: pose([(screw, [3.0])]) leaves every 'bolts' node at rest; [5.0] moves each by
    // (2, 0, 0).
    if (screw_joint) {
        CADACLYSM_TRY(pose3, scene.pose({cadaclysm::StateValue{*screw_joint, {3.0}}}));
        CADACLYSM_TRY(pose5, scene.pose({cadaclysm::StateValue{*screw_joint, {5.0}}}));
        std::optional<cadaclysm::Link> bolts;
        for (const cadaclysm::Link& l : scene.links()) {
            if (l.name() == "bolts") bolts = l;
        }
        check(bolts.has_value(), "scene has no link named 'bolts'");
        if (bolts) {
            for (const cadaclysm::Node& node : bolts->nodes()) {
                cadaclysm::Matrix4 rest = node.transform();
                cadaclysm::Matrix4 at3 = pose3.transform(node);
                cadaclysm::Matrix4 at5 = pose5.transform(node);
                check_close(at3[0][3], rest[0][3], "bolts node at rest(3) x");
                check_close(at3[1][3], rest[1][3], "bolts node at rest(3) y");
                check_close(at3[2][3], rest[2][3], "bolts node at rest(3) z");
                check_close(at5[0][3], rest[0][3] + 2.0, "bolts node at (5) x");
                check_close(at5[1][3], rest[1][3], "bolts node at (5) y");
                check_close(at5[2][3], rest[2][3], "bolts node at (5) z");
            }
        }
    }

    // Fact 9: no diagnostic names kinematics.
    bool has_kinematics_diagnostic = false;
    for (const std::string& d : scene.diagnostics()) {
        if (d.rfind("kinematics:", 0) == 0) has_kinematics_diagnostic = true;
    }
    check(!has_kinematics_diagnostic, "arm.to_scene() has a kinematics: diagnostic");
    scene.close();

    // Fact 7: the eight refusals, each with exactly its message, and the unpaired 'back'
    // trick -- step_text()'s refusal text is identical before and after.
    check(bool(arm.joint("back", "upper arm", "ground")), "arm.joint(\"back\", \"upper arm\", \"ground\") was refused");

    Result<std::string> before_result = unpaired_message(arm);
    check(!before_result, "arm.step_text() was accepted while 'back' has no pair");
    std::string before = before_result ? std::string() : before_result.error().message;

    std::vector<std::pair<std::function<Result<void>()>, std::string>> refusals = {
        {[&] { return arm.pair("shoulder", "revolute", shoulder_frame); }, "pair: joint 'shoulder' already has a pair"},
        {[&]() -> Result<void> {
             CADACLYSM_TRY(f, bs::Frame::xy());
             return arm.pair("back", "orbital", f);
         },
         "pair: 'orbital' is not a pair kind (revolute, prismatic, cylindrical, screw, gear, rack_and_pinion, spherical, "
         "spherical_with_pin, planar, universal, homokinetic, fully_constrained, unconstrained)"},
        {[&]() -> Result<void> {
             CADACLYSM_TRY(f, bs::Frame::xy());
             return arm.pair("back", "screw", f);
         },
         "pair: a screw needs a non-zero pitch"},
        {[&]() -> Result<void> {
             CADACLYSM_TRY(f, bs::Frame::xy());
             bs::PairOptions options;
             options.ranges = std::vector<bs::Range>{{-1.0, 1.0}, {-1.0, 1.0}};
             return arm.pair("back", "revolute", f, options);
         },
         "pair: 'revolute' has 1 freedoms, but 2 ranges were given"},
        {[&]() -> Result<void> {
             CADACLYSM_TRY(f, bs::Frame::xy());
             bs::PairOptions options;
             options.ranges = std::vector<bs::Range>{};
             return arm.pair("back", "revolute", f, options);
         },
         "pair: 'revolute' has 1 freedoms, but 0 ranges were given"},
        {[&]() -> Result<void> {
             CADACLYSM_TRY(f, bs::Frame::xy());
             bs::PairOptions options;
             options.ranges = std::vector<bs::Range>{{1.0, -1.0}};
             return arm.pair("back", "revolute", f, options);
         },
         "pair: range 0 of joint 'back' has lower >= upper"},
        {[&]() -> Result<void> {
             CADACLYSM_TRY(f, bs::Frame::at({0, 0, 0}, {0, 0, 1}, bs::Vec3{0, 1, 0}));
             CADACLYSM_TRY(end, bs::Frame::xy());
             bs::PairOptions options;
             options.end_frame = end;
             return arm.pair("back", "prismatic", f, options);
         },
         "pair: joint 'back' is prismatic, but its end frame is turned 90° about -z, "
         "which prismatic (does not turn) cannot make"},
        {[&] { return arm.state("overreach", {bs::StateRow{"shoulder", {5.0}}}); },
         "state: value 0 of joint 'shoulder' is outside its range"},
        {[&] { return arm.base("upper arm"); }, "base: assembly 'arm' already has base 'ground'"},
    };
    for (const auto& [call, message] : refusals) {
        Result<void> outcome = call();
        check(!outcome, "\"" + message + "\" was accepted");
        if (!outcome) check(outcome.error().message == message, "got \"" + outcome.error().message + "\", expected \"" + message + "\"");
    }
    Result<std::string> after_result = unpaired_message(arm);
    check(!after_result, "arm.step_text() was accepted while 'back' has no pair (after the refusals)");
    std::string after = after_result ? std::string() : after_result.error().message;
    check(after == before, "the unpaired 'back' message changed across the eight refusals");

    // Fact 8: a joint with no pair is refused at write time.
    Result<std::string> write_refused = arm.step_text();
    check(!write_refused, "arm.step_text() was accepted while 'back' has no pair (fact 8)");
    if (!write_refused) {
        check(write_refused.error().message ==
                  "assembly_step: assembly 'arm': joint 'back' has no pair; "
                  "a mechanism with pairs needs one on every joint (AP242)",
              "fact 8's refusal does not have exactly its message: " + write_refused.error().message);
    }

    // Fact 9 (freedom count): pair_freedom_count.
    check(bs::pair_freedom_count("spherical") == 3, "pair_freedom_count(\"spherical\") != 3");
    check(bs::pair_freedom_count("revolute") == 1, "pair_freedom_count(\"revolute\") != 1");
    check(bs::pair_freedom_count("fully_constrained") == 0, "pair_freedom_count(\"fully_constrained\") != 0");
    check(bs::pair_freedom_count("not_a_kind") == 0, "pair_freedom_count(\"not_a_kind\") != 0");

    return {};
}

// Assembly::sequence, read back through to_scene: a paired arm, a state "rest", and a
// two-segment "swing"; one refusal checked exactly.
static Result<void> run_sequence() {
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(1, 6));
    CADACLYSM_TRY(bolt, cylinder.named("bolt"));
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(20, 10, 2));
    CADACLYSM_TRY(plate, cuboid.named("plate"));
    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(pin_at, bs::Frame::xy({5, 5, 2}));
    CADACLYSM_TRY(arm, bs::Assembly::create("arm"));
    CADACLYSM_TRY(base_placement, arm.place_solid(plate, xy, "base"));
    (void)base_placement;
    CADACLYSM_TRY(pin_placement, arm.place_solid(bolt, pin_at, "pin"));
    (void)pin_placement;
    check(bool(arm.link("ground", {"base"})), "arm.link(\"ground\") was refused");
    check(bool(arm.link("upper arm", {"pin"})), "arm.link(\"upper arm\") was refused");
    check(bool(arm.joint("shoulder", "ground", "upper arm")), "arm.joint(\"shoulder\") was refused");
    CADACLYSM_TRY(shoulder_frame, bs::Frame::xy({0, 0, 10}));
    bs::PairOptions shoulder_options;
    shoulder_options.ranges = std::vector<bs::Range>{{-1.5, 1.5}};
    check(bool(arm.pair("shoulder", "revolute", shoulder_frame, shoulder_options)), "arm.pair was refused");
    check(bool(arm.state("reach", {bs::StateRow{"shoulder", {0.5}}})), "arm.state(\"reach\") was refused");
    check(bool(arm.state("rest", {bs::StateRow{"shoulder", {0.0}}})), "arm.state(\"rest\") was refused");
    check(bool(arm.base("ground")), "arm.base(\"ground\") was refused");
    Result<void> written = arm.sequence(
        "swing", {bs::SequenceSegment{"rest", 0.0, "linear"}, bs::SequenceSegment{"reach", 1.0, "linear"}}, true);
    check(written.ok(), "arm.sequence(\"swing\", ...) was refused: " + (written ? std::string() : written.error().message));

    CADACLYSM_TRY(scene, arm.to_scene());
    std::vector<cadaclysm::Sequence> sequences = scene.sequences();
    check(sequences.size() == 1 && sequences[0].name == "swing", "scene.sequences() is not exactly [\"swing\"]");
    if (sequences.size() == 1) {
        const cadaclysm::Sequence& swing = sequences[0];
        check(swing.closed, "swing is not closed");
        check(swing.seconds_per_unit.has_value() && swing.seconds_per_unit.value() == 1.0, "swing's seconds_per_unit is not 1");
        check(swing.segments.size() == 2, "swing does not have 2 segments");
        if (swing.segments.size() == 2) {
            check(swing.segments[0].state.name == "rest" && swing.segments[0].t == 0.0 &&
                      swing.segments[0].interpolation == "linear",
                  "swing's first segment is not rest@0 linear");
            check(swing.segments[1].state.name == "reach" && swing.segments[1].t == 1.0 &&
                      swing.segments[1].interpolation == "linear",
                  "swing's second segment is not reach@1 linear");
        }
    }

    Result<void> refused = arm.sequence(
        "bad", {bs::SequenceSegment{"rest", 0.0, "linear"}, bs::SequenceSegment{"nowhere", 1.0, "linear"}});
    check(!refused.ok(), "a sequence naming 'nowhere' was accepted");
    if (!refused) {
        check(refused.error().message == "sequence: assembly 'arm' has no state named 'nowhere'",
              "got \"" + refused.error().message + "\"");
    }
    scene.close();
    return {};
}

// Controller ruling: fact 10 -- a one-sided range survives the round trip. Without this,
// an implementation sending has_lower/has_upper as always-true would pass every other
// fact.
static Result<void> run_one_sided_range() {
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(20, 10, 2));
    CADACLYSM_TRY(plate, cuboid.named("plate2"));
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(1, 6));
    CADACLYSM_TRY(bolt, cylinder.named("bolt2"));

    CADACLYSM_TRY(hinge, bs::Assembly::create("hinge"));
    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(arm_at, bs::Frame::xy({0, 0, 2}));
    CADACLYSM_TRY(base_placement, hinge.place_solid(plate, xy, "base"));
    (void)base_placement;
    CADACLYSM_TRY(arm_placement, hinge.place_solid(bolt, arm_at, "arm"));
    (void)arm_placement;
    check(bool(hinge.link("base", {"base"})), "hinge.link(\"base\", [\"base\"]) was refused");
    check(bool(hinge.link("arm", {"arm"})), "hinge.link(\"arm\", [\"arm\"]) was refused");
    check(bool(hinge.joint("j", "base", "arm")), "hinge.joint(\"j\", \"base\", \"arm\") was refused");

    bs::PairOptions options;
    options.ranges = std::vector<bs::Range>{bs::Range{std::nullopt, 1.0}};
    check(bool(hinge.pair("j", "revolute", xy, options)), "hinge.pair(\"j\", \"revolute\", ..., {nullopt, 1.0}) was refused");

    CADACLYSM_TRY(scene, hinge.to_scene());
    std::optional<cadaclysm::Joint> j_joint;
    for (const cadaclysm::Joint& j : scene.joints()) {
        if (j.name() == "j") j_joint = j;
    }
    check(j_joint.has_value(), "scene has no joint named 'j'");
    if (j_joint) {
        std::optional<cadaclysm::Pair> pair = j_joint->pair();
        check(pair.has_value(), "'j' has no pair");
        if (pair) {
            std::vector<cadaclysm::Freedom> freedoms = pair->freedoms();
            check(freedoms.size() == 1, "'j' does not have exactly 1 freedom");
            if (freedoms.size() == 1) {
                check(!freedoms[0].lower.has_value(), "'j''s freedom has a lower bound");
                check(freedoms[0].upper.has_value() && std::fabs(*freedoms[0].upper - 1.0) <= 1e-9,
                      "'j''s freedom's upper bound is not exactly 1.0");
            }
        }
    }
    scene.close();
    return {};
}

// Drives plan 4's round trip, at parity with Python's _geared(): a pinion turning on
// "drive" meshes, by the gear pair "mesh" (radii 10 and 20, ratio -0.5, bevel 0.25, helical
// 0.125), with a wheel turning on "driven" about (30, 0); the wheel's part sits 5 off its
// axis, at (35, 0, 2).
static Result<bs::Assembly> geared(bool mesh) {
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(40, 10, 2));
    CADACLYSM_TRY(plate, cuboid.named("plate"));
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(1, 6));
    CADACLYSM_TRY(pin, cylinder.named("pin"));
    CADACLYSM_TRY(hub_cylinder, bs::Solid::cylinder(2, 4));
    CADACLYSM_TRY(hub, hub_cylinder.named("hub"));
    CADACLYSM_TRY(gears, bs::Assembly::create("gears"));
    CADACLYSM_TRY(origin, bs::Frame::xy());
    CADACLYSM_TRY(pinion_at, bs::Frame::xy({0, 0, 2}));
    CADACLYSM_TRY(wheel_at, bs::Frame::xy({35, 0, 2}));
    CADACLYSM_TRY(wheel_axis, bs::Frame::xy({30, 0, 2}));
    CADACLYSM_TRY(frame_placement, gears.place_solid(plate, origin, "frame"));
    (void)frame_placement;
    CADACLYSM_TRY(pinion_placement, gears.place_solid(pin, pinion_at, "pinion"));
    (void)pinion_placement;
    CADACLYSM_TRY(wheel_placement, gears.place_solid(hub, wheel_at, "wheel"));
    (void)wheel_placement;
    CADACLYSM_TRY_VOID(gears.link("base", {"frame"}));
    CADACLYSM_TRY_VOID(gears.link("driver", {"pinion"}));
    CADACLYSM_TRY_VOID(gears.link("follower", {"wheel"}));
    CADACLYSM_TRY_VOID(gears.joint("drive", "base", "driver"));
    CADACLYSM_TRY_VOID(gears.joint("driven", "base", "follower"));
    CADACLYSM_TRY_VOID(gears.joint("mesh", "driver", "follower"));
    CADACLYSM_TRY_VOID(gears.pair("drive", "revolute", pinion_at));
    CADACLYSM_TRY_VOID(gears.pair("driven", "revolute", wheel_axis));
    if (mesh) {
        CADACLYSM_TRY_VOID(gears.pair_with("mesh", "gear", pinion_at, {}, {10, 20, -0.5, 0.25, 0.125}));
    }
    return gears;
}

static Result<void> run_geared() {
    CADACLYSM_TRY(gears, geared(true));
    CADACLYSM_TRY(scene, gears.to_scene());
    std::vector<cadaclysm::Joint> joints = scene.joints();
    std::optional<cadaclysm::Joint> drive, driven, mesh;
    for (const cadaclysm::Joint& j : joints) {
        if (j.name() == "drive") drive = j;
        if (j.name() == "driven") driven = j;
        if (j.name() == "mesh") mesh = j;
    }
    check(drive && driven && mesh, "the geared scene lacks drive, driven or mesh");
    if (!(drive && driven && mesh)) return {};

    std::optional<cadaclysm::Pair> mesh_pair = mesh->pair();
    check(mesh_pair.has_value(), "'mesh' has no pair");
    if (mesh_pair) {
        check(mesh_pair->kind() == cadaclysm::PairKind::other, "'mesh''s kind is not other");
        check(mesh_pair->kind_name() == "gear", "'mesh''s kind_name is " + mesh_pair->kind_name());
        std::vector<double> parameters = mesh_pair->parameters();
        check(parameters.size() == 5, "'mesh' does not have 5 parameters");
        if (parameters.size() == 5) {
            const double want[5] = {10, 20, -0.5, 0.25, 0.125};
            for (int i = 0; i < 5; ++i) check_close(parameters[i], want[i], "mesh parameter " + std::to_string(i));
        }
    }
    std::optional<cadaclysm::Pair> drive_pair = drive->pair();
    check(drive_pair.has_value(), "'drive' has no pair");
    if (drive_pair) {
        check(drive_pair->kind_name() == "revolute", "'drive''s kind_name is not revolute");
        check(drive_pair->parameters().empty(), "'drive' has parameters");
    }

    // The driver alone turns the wheel by ratio x 0.4 about (30, 0): nothing to report.
    CADACLYSM_TRY(alone, scene.pose({cadaclysm::StateValue{*drive, {0.4}}}));
    check(alone.diagnostics.empty() && alone.unsolved.empty(), "driver alone: diagnostics or unsolved are not empty");
    std::vector<cadaclysm::Node> wheel_nodes = scene.links()[2].nodes();
    check(!wheel_nodes.empty(), "the follower link has no node");
    if (!wheel_nodes.empty()) {
        std::array<double, 16> raw = alone.raw_transform(wheel_nodes[0]);
        check_close(raw[12], 30 + 5 * std::cos(-0.2), "wheel x");
        check_close(raw[13], 5 * std::sin(-0.2), "wheel y");
        check_close(raw[14], 2.0, "wheel z");
    }

    // Both sides given, against the law: one diagnostic, in the kernel's words.
    CADACLYSM_TRY(both, scene.pose({cadaclysm::StateValue{*drive, {0.4}}, cadaclysm::StateValue{*driven, {0.4}}}));
    check(both.diagnostics.size() == 1, "both sides given: not exactly one diagnostic");
    const std::string prefix = "coupling 'mesh': both 'drive' and 'driven' are given and disagree by";
    if (!both.diagnostics.empty()) {
        check(both.diagnostics[0].compare(0, prefix.size(), prefix) == 0, "diagnostic reads: " + both.diagnostics[0]);
    }
    scene.close();

    // A wrong parameter count is refused in the kernel's words; the right one is then taken.
    CADACLYSM_TRY(bare, geared(false));
    CADACLYSM_TRY(xy, bs::Frame::xy());
    Result<void> refused = bare.pair_with("mesh", "gear", xy, {}, {10, 20});
    check(!refused.ok(), "pair_with with 2 gear parameters was accepted");
    if (!refused) {
        check(refused.error().message == "pair: a gear takes 3 or 5 parameters, not 2",
              "pair_with refusal reads: " + refused.error().message);
    }
    check(bool(bare.pair_with("mesh", "gear", xy, {}, {10, 20, -0.5})), "pair_with with 3 gear parameters was refused");
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
    Result<void> range_outcome = run_one_sided_range();
    if (!range_outcome) {
        std::fprintf(stderr, "FAIL: %s\n", range_outcome.error().message.c_str());
        return 1;
    }
    Result<void> sequence_outcome = run_sequence();
    if (!sequence_outcome) {
        std::fprintf(stderr, "FAIL: %s\n", sequence_outcome.error().message.c_str());
        return 1;
    }
    Result<void> geared_outcome = run_geared();
    if (!geared_outcome) {
        std::fprintf(stderr, "FAIL: %s\n", geared_outcome.error().message.c_str());
        return 1;
    }
    if (failures) {
        std::fprintf(stderr, "%d pair check(s) failed\n", failures);
        return 1;
    }
    std::puts("pair: OK");
    return 0;
}
