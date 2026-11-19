// Animation, AnimationTrack and AnimationChannel -- at parity with the Python reference's
// test_animation_* in test_cadaclysm_blacksmith.py, trimmed to what proves the marshalling: the
// turntable placement, every field of a track read back, values_at's order and shapes, the
// nearest hold, each refusal's text, the clone's independence and the handle's lifetime. The
// kernel's own correctness is the kernel's tests' job. Needs the kernel library; the exit code is
// the verdict.
//
//     cadaclysm_animation_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Animation;
using bs::AnimationChannel;
using bs::AnimationKey;
using bs::AnimationTrack;
using bs::InterpolatorMode;
using bs::Vec3;

static int failures = 0;
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();
static const double PI = 3.14159265358979323846;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool close_to(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool close_to_all(const std::vector<double>& a, const std::vector<double>& b, double tolerance) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (!close_to(a[i], b[i], tolerance)) return false;
    }
    return true;
}

// One number out of a dimension-1 answer, checked to be exactly one.
static double scalar(const std::vector<double>& v, const std::string& what) {
    check(v.size() == 1, what + ": " + std::to_string(v.size()) + " numbers, wanted 1");
    return v.empty() ? NAN_VALUE : v[0];
}

// A refusal check that fails when nothing was refused: the call must have returned an error whose
// text starts with `prefix`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted it to start \"" + prefix + "\"");
}

// The same, for a refusal whose whole text is known.
template <class T>
static void refused_with(const Result<T>& r, const std::string& message, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    check(r.error().message == message, what + ": refused with \"" + r.error().message + "\", wanted \"" + message + "\"");
}

// Point `p` through the column-major placement `m` (m[col * 4 + row]).
static Vec3 moved(const std::array<double, 16>& m, const Vec3& p) {
    const double q[4] = {p[0], p[1], p[2], 1.0};
    Vec3 out{0.0, 0.0, 0.0};
    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 4; ++col) out[static_cast<std::size_t>(row)] += m[static_cast<std::size_t>(col * 4 + row)] * q[col];
    }
    return out;
}

static bool close_to_point(const Vec3& a, const Vec3& b, double tolerance) {
    return close_to(a[0], b[0], tolerance) && close_to(a[1], b[1], tolerance) && close_to(a[2], b[2], tolerance);
}

static std::array<double, 16> identity() {
    std::array<double, 16> m{};
    for (std::size_t i = 0; i < 4; ++i) m[i * 4 + i] = 1.0;
    return m;
}

static bool close_to_matrix(const std::array<double, 16>& a, const std::array<double, 16>& b, double tolerance) {
    for (std::size_t i = 0; i < 16; ++i) {
        if (!close_to(a[i], b[i], tolerance)) return false;
    }
    return true;
}

// 1
static Result<void> turntable_through_rotate() {
    CADACLYSM_TRY(a, Animation::make());
    CADACLYSM_TRY(none_duration, a.duration());
    CADACLYSM_TRY(none_targets, a.targets());
    CADACLYSM_TRY(none_values, a.values_at(1.0));
    check(a.size() == 0 && none_duration == 0.0 && none_targets.empty() && none_values.empty(), "an empty animation");

    CADACLYSM_TRY(k, a.rotate("nut", {{0.0, 0.0}, {4.0, 360.0}}, Vec3{1.0, 2.0, 0.0}));
    CADACLYSM_TRY(duration, a.duration());
    CADACLYSM_TRY(targets, a.targets());
    check(k == 0 && a.size() == 1 && targets == std::vector<std::string>{"nut"} && duration == 4.0, "one rotate track");
    CADACLYSM_TRY(m, a.placement_at("nut", 1.0));
    Vec3 p = moved(m, Vec3{2.0, 2.0, 0.0});
    check(close_to_point(p, Vec3{1.0, 3.0, 0.0}, 1e-12), "a quarter turn about (1, 2) takes (2, 2) to (1, 3): " + std::to_string(p[0]) + ", " +
                                                               std::to_string(p[1]) + ", " + std::to_string(p[2]));
    CADACLYSM_TRY(by_index, a.placement_at(static_cast<std::size_t>(0), 1.0));
    check(by_index == m, "by name or by index");
    CADACLYSM_TRY(full_turn, a.placement_at("nut", 4.0));
    check(close_to_matrix(full_turn, identity(), 1e-12), "a full turn is the identity");
    CADACLYSM_TRY(angle, a.value_at(0, 1.0));
    check(close_to(scalar(angle, "angle"), 90.0, 1e-12), "the angle at 1 s");
    CADACLYSM_TRY(tr, a.track(0));
    check(tr.channel == AnimationChannel::rotate && tr.mode == InterpolatorMode::linear && tr.pivot == Vec3{1.0, 2.0, 0.0} &&
              tr.axis == Vec3{0.0, 0.0, 1.0},
          "the rotate track reads back its pivot and axis");

    // a target with no placement track answers the identity
    CADACLYSM_TRY(lamp, a.colour("lamp", {{0.0, {1.0, 0.0, 0.0}}}));
    check(lamp == 1, "the lamp's track");
    CADACLYSM_TRY(lamp_m, a.placement_at("lamp", 2.0));
    check(lamp_m == identity(), "a target with no placement track answers the identity");
    refused_with(a.placement_at("nobody", 0.0), "animation: no target nobody", "an unknown target");
    refused(a.placement_at(static_cast<std::size_t>(9), 0.0), "animation_placement_at: ", "an index past the last");

    // translate and scale, composed T * R * S
    CADACLYSM_TRY(t, a.translate("box", {{0.0, {0.0, 0.0, 0.0}}, {2.0, {10.0, 0.0, 0.0}}}));
    CADACLYSM_TRY(s, a.scale("box", {{0.0, {2.0, 2.0, 2.0}}}, Vec3{1.0, 0.0, 0.0}));
    check(t == 2 && s == 3, "translate and scale tracks");
    CADACLYSM_TRY(box, a.placement_at("box", 1.0));
    Vec3 q = moved(box, Vec3{2.0, 0.0, 0.0});
    check(close_to_point(q, Vec3{8.0, 0.0, 0.0}, 1e-12), "T * S: " + std::to_string(q[0]) + ", " + std::to_string(q[1]) + ", " + std::to_string(q[2]));
    return {};
}

// 2
static Result<void> track_reads_back_every_field() {
    CADACLYSM_TRY(a, Animation::make());
    CADACLYSM_TRY(dial, a.value("dial", {{0.0, {1.0, 2.0}}, {1.0, {3.0, 5.0}}, {3.0, {8.0, 13.0}}}, InterpolatorMode::cubic));
    CADACLYSM_TRY(lamp, a.colour("lamp", {{0.5, {1.0, 0.0, 0.0}}, {2.0, {0.0, 0.5, 1.0}}}));
    check(dial == 0 && lamp == 1, "track indexes");
    CADACLYSM_TRY(tr, a.track(0));
    check(tr.target == "dial" && tr.channel == AnimationChannel::value && tr.mode == InterpolatorMode::cubic && tr.dimension == 2,
          "the dial's header");
    check(tr.times == std::vector<double>({0.0, 1.0, 3.0}), "the dial's times");
    check(tr.values == std::vector<std::vector<double>>({{1.0, 2.0}, {3.0, 5.0}, {8.0, 13.0}}), "the dial's values");
    check(tr.pivot == Vec3{0.0, 0.0, 0.0} && tr.axis == Vec3{0.0, 0.0, 1.0}, "the dial's pivot and axis");
    CADACLYSM_TRY(again, a.track(0));
    check(tr == again && !(tr != again), "a track equals itself read again");
    CADACLYSM_TRY(other, a.track(1));
    check(tr != other, "two tracks differ");
    check(other.target == "lamp" && other.channel == AnimationChannel::colour && other.dimension == 3 &&
              other.values == std::vector<std::vector<double>>({{1.0, 0.0, 0.0}, {0.0, 0.5, 1.0}}),
          "the lamp's colours");
    CADACLYSM_TRY(vis_index, a.visible("lamp", {{0.0, 1.0}, {2.0, 0.0}}));
    CADACLYSM_TRY(vis, a.track(vis_index));
    check(vis.dimension == 1 && vis.values == std::vector<std::vector<double>>({{1.0}, {0.0}}) && vis.mode == InterpolatorMode::nearest,
          "the visible track holds");
    CADACLYSM_TRY(targets, a.targets());
    CADACLYSM_TRY(duration, a.duration());
    check(targets == std::vector<std::string>({"dial", "lamp"}) && duration == 3.0, "targets and duration");
    refused_with(a.track(9), "animation_track_target: track 9 is not below 3", "a track past the last");
    return {};
}

// 3
static Result<void> values_at_shapes() {
    CADACLYSM_TRY(a, Animation::make());
    CADACLYSM_TRY(speed, a.value("speed", {{0.0, 0.0}, {2.0, 4.0}}));
    CADACLYSM_TRY(box, a.translate("box", {{0.0, {0.0, 0.0, 0.0}}, {2.0, {2.0, 4.0, 6.0}}}));
    CADACLYSM_TRY(ghost, a.ghost("box", {{0.0, 0.0}, {1.0, 1.0}}));
    check(speed == 0 && box == 1 && ghost == 2, "track indexes");
    CADACLYSM_TRY(v, a.values_at(1.0));
    check(v.size() == 3, "one answer a track");
    if (v.size() == 3) {
        check(v[0].size() == 1 && close_to(v[0][0], 2.0, 1e-12), "the speed, a vector of one");
        check(close_to_all(v[1], {1.0, 2.0, 3.0}, 1e-12), "the offset, three numbers");
        check(v[2].size() == 1 && v[2][0] == 1.0, "the ghost holds its key");
        for (std::size_t k = 0; k < 3; ++k) {
            CADACLYSM_TRY(one, a.value_at(k, 1.0));
            check(v[k] == one, "values_at is value_at, track " + std::to_string(k));
        }
    }
    return {};
}

// 4
static Result<void> nearest_holds_and_modes_differ() {
    CADACLYSM_TRY(a, Animation::make());
    CADACLYSM_TRY(step, a.value("step", {{0.0, 0.0}, {2.0, 10.0}, {3.0, 20.0}}, InterpolatorMode::nearest));
    const double ts[7] = {-1.0, 0.0, 1.99, 2.0, 2.5, 3.0, 9.0};
    const double want[7] = {0.0, 0.0, 0.0, 10.0, 10.0, 20.0, 20.0};
    for (std::size_t i = 0; i < 7; ++i) {
        CADACLYSM_TRY(v, a.value_at(step, ts[i]));
        check(scalar(v, "step") == want[i], "nearest hold at " + std::to_string(ts[i]));
    }
    // visible and ghost hold whatever mode was asked, and read the mode back as given
    CADACLYSM_TRY(flag, a.add_track("flag", AnimationChannel::visible, {{0.0, 0.0}, {1.0, 1.0}}, InterpolatorMode::linear));
    CADACLYSM_TRY(held, a.value_at(flag, 0.9));
    CADACLYSM_TRY(flag_track, a.track(flag));
    check(scalar(held, "flag") == 0.0 && flag_track.mode == InterpolatorMode::linear, "visible holds, and reads its mode as given");
    const std::vector<AnimationKey> keys = {{0.0, 0.0}, {1.0, 1.0}, {3.0, 0.0}};
    CADACLYSM_TRY(cubic, a.value("c", keys, InterpolatorMode::cubic));
    CADACLYSM_TRY(catmull, a.value("r", keys, InterpolatorMode::catmull_rom));
    CADACLYSM_TRY(cosine, a.value("o", {{0.0, 0.0}, {2.0, 10.0}}, InterpolatorMode::cosine));
    CADACLYSM_TRY(vc, a.value_at(cubic, 2.0));
    CADACLYSM_TRY(vr, a.value_at(catmull, 2.0));
    CADACLYSM_TRY(vo, a.value_at(cosine, 0.5));
    check(close_to(scalar(vc, "cubic"), 0.625, 1e-12), "cubic on uneven keys");
    check(close_to(scalar(vr, "catmull_rom"), 0.5625, 1e-12), "catmull_rom on uneven keys");
    check(close_to(scalar(vo, "cosine"), 10.0 * (1.0 - std::cos(PI / 4.0)) / 2.0, 1e-12), "cosine");
    const std::size_t made[3] = {cubic, catmull, cosine};
    const InterpolatorMode modes[3] = {InterpolatorMode::cubic, InterpolatorMode::catmull_rom, InterpolatorMode::cosine};
    for (std::size_t i = 0; i < 3; ++i) {
        CADACLYSM_TRY(tr, a.track(made[i]));
        check(tr.mode == modes[i], "the mode reads back, track " + std::to_string(made[i]));
    }
    return {};
}

// 5
static Result<void> refusals() {
    CADACLYSM_TRY(a, Animation::make());
    // an argument refused before the call
    refused_with(a.value("x", {{0.0, {1.0, 2.0}}, {1.0, {1.0, 2.0, 3.0}}}), "animation: key values differ in length", "unequal key values");
    // the library's refusals, under their call's name
    refused(a.value("x", {{0.0, 0.0}, {1.5, 1.0}, {1.0, 2.0}}), "animation_add_track: times must increase: key 2 at 1 after 1.5", "times");
    refused(a.translate("x", {{0.0, 1.0}}), "animation_add_track: ", "a translate key is three numbers");
    refused(a.value("x", {}), "animation_add_track: ", "no keys");
    refused(a.value("", {{0.0, 1.0}}), "animation_add_track: ", "an empty target");
    refused_with(a.rotate("x", {{0.0, 0.0}}, Vec3{0.0, 0.0, 0.0}, Vec3{0.0, 0.0, 0.0}), "animation_set_pivot: the axis is too short", "a zero axis");
    refused_with(a.rotate("x", {{0.0, 0.0}}, Vec3{NAN_VALUE, 0.0, 0.0}), "animation_set_pivot: the pivot and axis must be finite", "a NaN pivot");
    refused_with(a.scale("x", {{0.0, {1.0, 1.0, 1.0}}}, Vec3{0.0, NAN_VALUE, 0.0}), "animation_set_pivot: the pivot and axis must be finite",
                 "a NaN scale pivot");
    check(a.size() == 0, "every refusal leaves the animation as it was");
    CADACLYSM_TRY(k, a.value("x", {{0.0, 0.0}}));
    refused(a.set_pivot(k, Vec3{0.0, 0.0, 0.0}), "animation_set_pivot: track 0 is value: only rotate and scale have a pivot", "set_pivot on a value track");
    refused(a.value_at(k, NAN_VALUE), "animation_track_value_at: t NaN is not finite", "a NaN t");
    refused(a.values_at(NAN_VALUE), "animation_values_at: ", "a NaN t for every track");
    refused(a.placement_at(static_cast<std::size_t>(0), NAN_VALUE), "animation_placement_at: ", "a NaN t for a placement");
    CADACLYSM_TRY(y, a.value("y", {{0.0, 1.0}}));
    check(y == 1, "the second track");
    refused_with(a.value_at(9, 0.0), "animation_track_value_at: track 9 is not below 2", "value_at past the last track");
    refused_with(a.track(2), "animation_track_target: track 2 is not below 2", "track past the last track");
    refused(a.set_pivot(9, Vec3{0.0, 0.0, 0.0}), "animation_set_pivot: ", "set_pivot past the last track");
    CADACLYSM_TRY(targets, a.targets());
    check(a.size() == 2 && targets == std::vector<std::string>({"x", "y"}), "the refused calls left no stray track");
    return {};
}

// 6
static Result<void> clone_is_independent_and_close_twice_refuses() {
    CADACLYSM_TRY(a, Animation::make());
    CADACLYSM_TRY(first, a.translate("box", {{0.0, {0.0, 0.0, 0.0}}, {1.0, {1.0, 0.0, 0.0}}}));
    check(first == 0, "the first track");
    CADACLYSM_TRY(b, a.clone());
    CADACLYSM_TRY(second, b.value("dial", {{0.0, 5.0}, {7.0, 6.0}}));
    check(second == 1, "the clone's second track");
    CADACLYSM_TRY(a_duration, a.duration());
    CADACLYSM_TRY(b_duration, b.duration());
    CADACLYSM_TRY(a_targets, a.targets());
    CADACLYSM_TRY(b_targets, b.targets());
    check(a.size() == 1 && b.size() == 2 && a_duration == 1.0 && b_duration == 7.0, "tracks added to the clone never reach the source");
    check(a_targets == std::vector<std::string>({"box"}) && b_targets == std::vector<std::string>({"box", "dial"}), "targets are independent");
    a.close();
    check(a.closed(), "closed");
    CADACLYSM_TRY(still, b.track(0));
    check(still.target == "box", "the clone outlives its source");
    a.close();
    refused_with(a.values_at(0.0), "animation: closed", "values_at on a closed animation");
    refused_with(a.duration(), "animation: closed", "duration on a closed animation");
    refused_with(a.targets(), "animation: closed", "targets on a closed animation");
    refused_with(a.track(0), "animation: closed", "track on a closed animation");
    refused_with(a.value_at(0, 0.0), "animation: closed", "value_at on a closed animation");
    refused_with(a.placement_at("box", 0.0), "animation: closed", "placement_at on a closed animation");
    refused_with(a.value("z", {{0.0, 0.0}}), "animation: closed", "add_track on a closed animation");
    refused_with(a.rotate("z", {{0.0, 0.0}}), "animation: closed", "rotate on a closed animation");
    refused_with(a.set_pivot(0, Vec3{0.0, 0.0, 0.0}), "animation: closed", "set_pivot on a closed animation");
    refused_with(a.clone(), "animation: closed", "clone of a closed animation");
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
    struct Test {
        const char* name;
        Result<void> (*run)();
    };
    const Test tests[] = {
        {"turntable_through_rotate", turntable_through_rotate},
        {"track_reads_back_every_field", track_reads_back_every_field},
        {"values_at_shapes", values_at_shapes},
        {"nearest_holds_and_modes_differ", nearest_holds_and_modes_differ},
        {"refusals", refusals},
        {"clone_is_independent_and_close_twice_refuses", clone_is_independent_and_close_twice_refuses},
    };
    for (const Test& t : tests) {
        int before = failures;
        Result<void> outcome = t.run();
        if (!outcome) {
            std::fprintf(stderr, "FAIL: %s: %s\n", t.name, outcome.error().message.c_str());
            ++failures;
        }
        std::printf("%s %s\n", failures == before ? "ok  " : "FAIL", t.name);
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("animation: ok\n");
    return 0;
}
