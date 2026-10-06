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
#include <limits>
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

    // The pose facts, identical in every language (posing plan 2's wrapper brief):
    // mechanism.stp declares no base; pose_state(open) holds the base link fixed and turns
    // the arm by -0.5 about Z (hinge is the arm's joint, reached from its end); a value
    // past the pair's range is used and reported; pose() can hold a different link fixed;
    // pose(state.values) poses like pose_state(state), and pose({}) is the rest pose; a
    // bad row, or a file with no mechanism, is an Error.
    auto apply = [](const std::array<double, 16>& m, std::array<double, 3> p) {
        return std::array<double, 3>{
            m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
            m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
            m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
        };
    };
    expect(!mechanism.base().has_value(), "mechanism.stp declares a base");

    cadaclysm::Link base_link = links[0];
    cadaclysm::Link arm_link = links[1];
    cadaclysm::Node arm_node = arm_link.nodes()[0];
    cadaclysm::Node base_node = base_link.nodes()[0];

    cadaclysm::Result<cadaclysm::Pose> posed = mechanism.pose_state(states[0]);
    expect(posed.ok(), "pose_state(open) failed: " + (posed ? std::string() : posed.error().message));
    if (posed) {
        expect(posed->ground == base_link, "pose_state(open).ground is not the base link");
        expect(posed->unsolved.empty() && posed->out_of_range.empty(), "pose_state(open) has unsolved or out_of_range entries");
        double q = 0.5;  // the arm is the joint's start, reached from its end: it turns by -q
        std::array<double, 3> p1 = apply(posed->raw_transform(arm_node), {10, 0, 0});
        expect(std::abs(p1[0] - 10 * std::cos(q)) < 1e-9 && std::abs(p1[1] - -10 * std::sin(q)) < 1e-9 &&
                   std::abs(p1[2] - 100.0) < 1e-9,
               "pose_state(open): arm_node did not turn by -0.5 about the hinge");
        std::array<double, 3> p2 = apply(posed->raw_transform(arm_node), {0, 0, 0});
        expect(std::abs(p2[0]) < 1e-9 && std::abs(p2[1]) < 1e-9 && std::abs(p2[2] - 100.0) < 1e-9,
               "pose_state(open): the hinge's own point did not stay at (0, 0, 100)");
        std::array<double, 16> base_raw = posed->raw_transform(base_node);
        std::array<double, 16> base_rest = base_node.raw_transform();
        for (int i = 0; i < 16; ++i) expect(base_raw[i] == base_rest[i], "pose_state(open): base_node moved off its rest transform");
    }

    // A value past the range is used and reported.
    cadaclysm::Result<cadaclysm::Pose> over_range = mechanism.pose({cadaclysm::StateValue{hinge, {2.0}}});
    expect(over_range.ok(), "pose([(hinge, [2.0])]) failed");
    if (over_range) {
        expect(over_range->out_of_range.size() == 1, "pose([(hinge, [2.0])]).out_of_range does not have exactly one entry");
        if (over_range->out_of_range.size() == 1) {
            const auto& [row_joint, row_freedom, row_value] = over_range->out_of_range[0];
            expect(row_joint == hinge && row_freedom == 0 && std::abs(row_value - 2.0) < 1e-9,
                   "pose([(hinge, [2.0])]).out_of_range[0] is not (hinge, 0, 2.0)");
        }
        std::array<double, 3> p3 = apply(over_range->raw_transform(arm_node), {10, 0, 0});
        expect(std::abs(p3[0] - 10 * std::cos(2.0)) < 1e-9 && std::abs(p3[1] - -10 * std::sin(2.0)) < 1e-9 &&
                   std::abs(p3[2] - 100.0) < 1e-9,
               "pose([(hinge, [2.0])]): arm_node did not turn by -2.0");
    }

    // The ground can be named.
    cadaclysm::Result<cadaclysm::Pose> grounded = mechanism.pose({cadaclysm::StateValue{hinge, {0.5}}}, arm_link);
    expect(grounded.ok(), "pose([(hinge, [0.5])], ground=arm) failed");
    if (grounded) {
        expect(grounded->ground == arm_link, "pose(..., ground=arm).ground is not the arm link");
        std::array<double, 16> arm_raw = grounded->raw_transform(arm_node);
        std::array<double, 16> arm_rest = arm_node.raw_transform();
        for (int i = 0; i < 16; ++i) expect(arm_raw[i] == arm_rest[i], "pose(..., ground=arm): arm_node moved off its rest transform");
    }

    // State values pose like the state, and an empty pose is the rest pose.
    cadaclysm::Result<cadaclysm::Pose> from_values = mechanism.pose(states[0].values);
    expect(from_values.ok(), "pose(state.values) failed");
    if (from_values && posed) {
        std::array<double, 16> a = from_values->raw_transform(arm_node);
        std::array<double, 16> b = posed->raw_transform(arm_node);
        for (int i = 0; i < 16; ++i) expect(a[i] == b[i], "pose(state.values) does not match pose_state(state)");
    }
    cadaclysm::Result<cadaclysm::Pose> rest = mechanism.pose({});
    expect(rest.ok(), "pose({}) failed");
    if (rest) {
        for (const cadaclysm::Node& node : mechanism.nodes()) {
            std::array<double, 16> raw = rest->raw_transform(node);
            std::array<double, 16> own = node.raw_transform();
            for (int i = 0; i < 16; ++i) expect(raw[i] == own[i], "pose({}) is not the rest pose for node " + std::to_string(node.index()));
        }
    }

    // A bad row, or a file with no mechanism, is an Error.
    cadaclysm::Result<cadaclysm::Pose> bad_row = mechanism.pose({cadaclysm::StateValue{hinge, {1.0, 2.0}}});
    expect(!bad_row.ok() && bad_row.error().message.find("takes 1 value(s)") != std::string::npos,
           "pose([(hinge, [1.0, 2.0])]) did not fail with 'takes 1 value(s)': " +
               (bad_row.ok() ? std::string("ok") : bad_row.error().message));
    cadaclysm::Result<cadaclysm::Pose> no_mechanism = cube.pose({});
    expect(!no_mechanism.ok() && no_mechanism.error().message.find("no mechanism") != std::string::npos,
           "cube.pose({}) did not fail with 'no mechanism': " +
               (no_mechanism.ok() ? std::string("ok") : no_mechanism.error().message));

    // Sequences: mechanism-sequence.stp holds states open, shut, wide and two sequences.
    // swing is closed, one second a unit, shut@0 linear, open@1 synchronous, wide@2 linear;
    // snap is open, has no unit, shut@0 and wide@0.5 both discontinuous. pose() at each of
    // swing's parameters poses its state, and a parameter that is not a number is an Error.
    CADACLYSM_TRY(sequenced, cadaclysm::open(cadaclysm::detail::utf8(
                                 cadaclysm::detail::fs_path(cube_path).parent_path() / "mechanism-sequence.stp")));
    std::vector<cadaclysm::State> seq_states = sequenced.states();
    expect(seq_states.size() == 3 && seq_states[0].name == "open" && seq_states[1].name == "shut" &&
               seq_states[2].name == "wide",
           "mechanism-sequence.stp states are not [open, shut, wide]");
    std::vector<cadaclysm::Sequence> sequences = sequenced.sequences();
    expect(sequences.size() == 2 && sequences[0].name == "swing" && sequences[1].name == "snap",
           "mechanism-sequence.stp sequences are not [swing, snap]");
    expect(cube.sequences().empty(), "the cube scene has sequences");
    if (sequences.size() == 2) {
        const cadaclysm::Sequence& swing = sequences[0];
        expect(swing.index == 0 && swing.closed, "swing is not sequence 0, closed");
        expect(swing.seconds_per_unit.has_value() && *swing.seconds_per_unit == 1.0, "swing's seconds_per_unit is not 1");
        const char* swing_states[3] = {"shut", "open", "wide"};
        const double swing_ts[3] = {0.0, 1.0, 2.0};
        const char* swing_words[3] = {"linear", "synchronous", "linear"};
        expect(swing.segments.size() == 3, "swing does not have 3 segments");
        if (swing.segments.size() == 3) {
            for (int i = 0; i < 3; ++i) {
                expect(swing.segments[i].state.name == swing_states[i] && swing.segments[i].t == swing_ts[i] &&
                           swing.segments[i].interpolation == swing_words[i],
                       "swing segment " + std::to_string(i) + " is " + swing.segments[i].state.name + "@" +
                           std::to_string(swing.segments[i].t) + " " + swing.segments[i].interpolation);
            }
            expect(swing.start() == 0.0 && swing.end() == 2.0, "swing's start/end are not 0 and 2");
            for (const cadaclysm::Segment& segment : swing.segments) {
                cadaclysm::Result<cadaclysm::Pose> at = swing.pose(segment.t);
                cadaclysm::Result<cadaclysm::Pose> want = sequenced.pose_state(segment.state);
                expect(at.ok() && want.ok(), "swing.pose(" + std::to_string(segment.t) + ") failed");
                if (at && want) {
                    for (const cadaclysm::Node& node : sequenced.nodes()) {
                        std::array<double, 16> got = at->raw_transform(node);
                        std::array<double, 16> exact = want->raw_transform(node);
                        for (int i = 0; i < 16; ++i) {
                            expect(std::abs(got[i] - exact[i]) < 1e-9,
                                   "swing.pose(" + std::to_string(segment.t) + ") differs from pose_state(" +
                                       segment.state.name + ")");
                        }
                    }
                }
            }
            cadaclysm::Result<cadaclysm::Pose> grounded_swing = swing.pose(0.5, sequenced.links()[1]);
            expect(grounded_swing.ok(), "swing.pose(0.5, ground) failed");
        }
        cadaclysm::Result<cadaclysm::Pose> nan_pose = swing.pose(std::numeric_limits<double>::quiet_NaN());
        expect(!nan_pose.ok() &&
                   nan_pose.error().message.find("the sequence parameter must be a finite number") != std::string::npos,
               "swing.pose(NaN) did not fail with 'the sequence parameter must be a finite number': " +
                   (nan_pose.ok() ? std::string("ok") : nan_pose.error().message));

        const cadaclysm::Sequence& snap = sequences[1];
        expect(snap.index == 1 && !snap.closed && !snap.seconds_per_unit.has_value(),
               "snap is not sequence 1, open, with no unit");
        expect(snap.segments.size() == 2 && snap.segments[0].state.name == "shut" && snap.segments[0].t == 0.0 &&
                   snap.segments[0].interpolation == "discontinuous" && snap.segments[1].state.name == "wide" &&
                   snap.segments[1].t == 0.5 && snap.segments[1].interpolation == "discontinuous",
               "snap's segments are not shut@0 and wide@0.5, both discontinuous");
    }

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
