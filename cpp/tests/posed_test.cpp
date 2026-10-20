// Assembly::posed, at parity with the Python reference's posed tests (spec 2026-10-05):
// the pose moves the posed joints and nothing else, a bare name that two joints carry is
// refused, a path with an escaped "/" finds one, a state and a ground are taken, and every
// refusal is in the kernel's own words. Plus plan 4's gear round trip posed. Needs the
// kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_posed_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cstdio>
#include <sstream>
#include <string>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// `text` with every FILE_NAME( line removed, since only the timestamp line should move.
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

static Result<std::string> stepped(const bs::Assembly& a) {
    CADACLYSM_TRY(text, a.step_text());
    return no_stamp(text);
}

// Python's _paired() arm: bracket's "screw" prismatic, arm's "shoulder" revolute ranged
// to +-1.5, the state "reach" (0.5) and the base "ground".
static Result<bs::Assembly> paired_arm() {
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
    CADACLYSM_TRY_VOID(bracket.link("fixed", {"plate"}));
    CADACLYSM_TRY_VOID(bracket.link("bolts", {"bolt", "bolt 2"}));
    CADACLYSM_TRY_VOID(bracket.joint("screw", "fixed", "bolts"));
    CADACLYSM_TRY(arm, bs::Assembly::create("arm"));
    CADACLYSM_TRY(upper_at, bs::Frame::xy({0, 0, 10}));
    CADACLYSM_TRY(base_placement, arm.place_solid(plate, xy, "base"));
    (void)base_placement;
    CADACLYSM_TRY(upper_placement, arm.place_assembly(bracket, upper_at, "upper"));
    (void)upper_placement;
    CADACLYSM_TRY(pin_placement, arm.place_solid(bolt, bolt1_at, "pin"));
    (void)pin_placement;
    CADACLYSM_TRY_VOID(arm.link("ground", {"base"}));
    CADACLYSM_TRY_VOID(arm.link("upper arm", {"upper", "pin"}));
    CADACLYSM_TRY_VOID(arm.joint("shoulder", "ground", "upper arm"));
    CADACLYSM_TRY(screw_frame, bs::Frame::xy({1, 2, 3}));
    CADACLYSM_TRY(screw_end_frame, bs::Frame::xy({4, 2, 3}));
    bs::PairOptions screw_options;
    screw_options.end_frame = screw_end_frame;
    CADACLYSM_TRY_VOID(bracket.pair("screw", "prismatic", screw_frame, screw_options));
    bs::PairOptions shoulder_options;
    shoulder_options.ranges = std::vector<bs::Range>{{-1.5, 1.5}};
    CADACLYSM_TRY_VOID(arm.pair("shoulder", "revolute", upper_at, shoulder_options));
    CADACLYSM_TRY_VOID(arm.state("reach", {bs::StateRow{"shoulder", {0.5}}}));
    CADACLYSM_TRY_VOID(arm.base("ground"));
    return arm;
}

// Python's _posed_frame(): two copies of a bracket whose bolt turns on "turn", placed as
// "left" and "right/rear".
static Result<bs::Assembly> posed_frame() {
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(1, 1, 6));
    CADACLYSM_TRY(bolt, cuboid.named("bolt"));
    CADACLYSM_TRY(plate_cuboid, bs::Solid::cuboid(20, 10, 2));
    CADACLYSM_TRY(plate, plate_cuboid.named("plate"));
    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(bolt_at, bs::Frame::xy({5, 5, 2}));
    CADACLYSM_TRY(turn_at, bs::Frame::xy({10, 5, 2}));
    CADACLYSM_TRY(right_at, bs::Frame::xy({100, 0, 0}));
    CADACLYSM_TRY(bracket, bs::Assembly::create("bracket"));
    CADACLYSM_TRY(plate_placement, bracket.place_solid(plate, xy));
    (void)plate_placement;
    CADACLYSM_TRY(bolt_placement, bracket.place_solid(bolt, bolt_at));
    (void)bolt_placement;
    CADACLYSM_TRY_VOID(bracket.link("fixed", {"plate"}));
    CADACLYSM_TRY_VOID(bracket.link("bolts", {"bolt"}));
    CADACLYSM_TRY_VOID(bracket.joint("turn", "fixed", "bolts"));
    CADACLYSM_TRY_VOID(bracket.pair("turn", "revolute", turn_at));
    CADACLYSM_TRY(frame, bs::Assembly::create("frame"));
    CADACLYSM_TRY(left_placement, frame.place_assembly(bracket, xy, "left"));
    (void)left_placement;
    CADACLYSM_TRY(right_placement, frame.place_assembly(bracket, right_at, "right/rear"));
    (void)right_placement;
    return frame;
}

// plan 4's gears: "drive" and "driven" revolutes meshed by the gear pair "mesh".
static Result<bs::Assembly> geared() {
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
    CADACLYSM_TRY_VOID(gears.pair_with("mesh", "gear", pinion_at, {}, {10, 20, -0.5, 0.25, 0.125}));
    return gears;
}

static Result<void> run() {
    // Posing the shoulder, or sliding the screw, moves things; 0 and no rows do not.
    CADACLYSM_TRY(arm, paired_arm());
    CADACLYSM_TRY(arm_rest, stepped(arm));
    CADACLYSM_TRY(shoulder_posed, arm.posed({bs::StateRow{"shoulder", {0.5}}}));
    CADACLYSM_TRY(shoulder_text, stepped(shoulder_posed));
    check(shoulder_posed.name() == "arm", "posed shoulder is named " + shoulder_posed.name());
    check(shoulder_text != arm_rest, "posing the shoulder left the step text unchanged");
    CADACLYSM_TRY(screw_posed, arm.posed({bs::StateRow{"upper/screw", {5.0}}}));
    CADACLYSM_TRY(screw_text, stepped(screw_posed));
    check(screw_text != arm_rest, "sliding the screw left the step text unchanged");
    CADACLYSM_TRY(zero_posed, arm.posed({bs::StateRow{"shoulder", {0.0}}}));
    CADACLYSM_TRY(zero_text, stepped(zero_posed));
    check(zero_text == arm_rest, "posing the shoulder at 0 changed the step text");
    CADACLYSM_TRY(nothing_posed, arm.posed({}));
    CADACLYSM_TRY(nothing_text, stepped(nothing_posed));
    check(nothing_text == arm_rest, "posing no rows changed the step text");

    // An ambiguous bare name, and a path escaping the "/" inside "right/rear".
    CADACLYSM_TRY(frame, posed_frame());
    CADACLYSM_TRY(frame_rest, stepped(frame));
    Result<bs::Assembly> ambiguous = frame.posed({bs::StateRow{"turn", {0.3}}});
    check(!ambiguous.ok(), "posing the bare 'turn' was accepted");
    if (!ambiguous) {
        check(ambiguous.error().message ==
                  "posed: 'turn' names 2 joints: left/turn, right\\/rear/turn; give one by its path",
              "ambiguous refusal reads: " + ambiguous.error().message);
    }
    CADACLYSM_TRY(turned, frame.posed({bs::StateRow{"right\\/rear/turn", {0.3}}}));
    check(turned.name() == "frame", "posed frame is named " + turned.name());
    CADACLYSM_TRY(turned_text, stepped(turned));
    check(turned_text != frame_rest, "posing right\\/rear/turn left the step text unchanged");
    CADACLYSM_TRY(still, frame.posed({bs::StateRow{"right\\/rear/turn", {0.0}}}));
    CADACLYSM_TRY(still_text, stepped(still));
    check(still_text == frame_rest, "posing right\\/rear/turn at 0 changed the step text");
    CADACLYSM_TRY(frame_after, stepped(frame));
    check(frame_after == frame_rest, "the frame changed after being posed");

    // A state, a ground, and the kernel's own refusals.
    CADACLYSM_TRY(from_state, arm.posed({}, "reach"));
    CADACLYSM_TRY(from_state_text, stepped(from_state));
    check(from_state_text == shoulder_text, "state 'reach' differs from shoulder = 0.5");
    CADACLYSM_TRY(held, arm.posed({bs::StateRow{"shoulder", {0.5}}}, std::nullopt, "upper arm"));
    CADACLYSM_TRY(held_text, stepped(held));
    check(held_text != shoulder_text, "ground 'upper arm' left the posed step text unchanged");
    Result<bs::Assembly> out_of_range = arm.posed({bs::StateRow{"shoulder", {2.0}}});
    check(!out_of_range.ok(), "shoulder = 2.0 was accepted");
    if (!out_of_range) {
        check(out_of_range.error().message == "posed: value 0 of joint 'shoulder' is 2, outside its range",
              "range refusal reads: " + out_of_range.error().message);
    }
    Result<bs::Assembly> no_state = arm.posed({}, "fold");
    check(!no_state.ok(), "state 'fold' was accepted");
    if (!no_state) {
        check(no_state.error().message == "posed: assembly 'arm' has no state named 'fold'",
              "state refusal reads: " + no_state.error().message);
    }
    CADACLYSM_TRY(arm_after, stepped(arm));
    check(arm_after == arm_rest, "the arm changed after being posed");

    // The gears: both sides of the mesh given against the law is refused; one side is fine.
    CADACLYSM_TRY(gears, geared());
    CADACLYSM_TRY(gears_rest, stepped(gears));
    Result<bs::Assembly> both = gears.posed({bs::StateRow{"drive", {0.4}}, bs::StateRow{"driven", {0.4}}});
    check(!both.ok(), "drive = 0.4 with driven = 0.4 was accepted");
    if (!both) {
        const std::string prefix =
            "posed: assembly 'gears': coupling 'mesh': both 'drive' and 'driven' are given and disagree by";
        check(both.error().message.compare(0, prefix.size(), prefix) == 0,
              "gears refusal reads: " + both.error().message);
    }
    CADACLYSM_TRY(alone, gears.posed({bs::StateRow{"drive", {0.4}}}));
    check(alone.name() == "gears", "posed gears is named " + alone.name());
    CADACLYSM_TRY(gears_after, stepped(gears));
    check(gears_after == gears_rest, "the gears changed after being posed");
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
        std::fprintf(stderr, "%d posed check(s) failed\n", failures);
        return 1;
    }
    std::puts("posed: OK");
    return 0;
}
