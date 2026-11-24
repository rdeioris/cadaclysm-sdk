// Gear profiles -- Profile::gear_involute, gear_wheel_cycloidal, gear_pinion_cycloidal and
// gear_centre_distance_involute -- at parity with the Python reference's tests
// test_gear_involute_figures, test_gear_cycloidal_figures, test_gear_centre_distance and
// test_gear_refusals in test_cadaclysm_blacksmith.py: the hand-computed figures I1, I5 and C2
// and the refusals in the library's words. Needs the kernel library and a license; the exit code
// is the verdict.
//
//     cadaclysm_gears_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::GearInvoluteOptions;
using bs::GearPinionCycloidalOptions;
using bs::GearProfile;
using bs::GearTip;
using bs::Profile;

static int failures = 0;
static const double PI = 3.14159265358979323846;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static std::string num(double v) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    return buf;
}

static void near(double got, double want, double tol, const std::string& what) {
    check(std::fabs(got - want) <= tol, what + ": got " + num(got) + ", want " + num(want));
}

template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// The call must have been refused with a message starting `prefix`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted \"" + prefix + "...\"");
}

// I1: m = 1, z = 20, defaults; the explicit defaults are the defaults; I4's undercut.
static void involute_figures() {
    GearProfile g = must(Profile::gear_involute(1, 20), "gear_involute");
    near(g.pitch_radius, 10, 1e-9, "I1 pitch_radius");
    check(g.base_radius.has_value(), "I1 base_radius: nullopt for an involute gear");
    near(g.base_radius.value_or(0.0), 9.396926208, 1e-9, "I1 base_radius");
    near(g.tip_radius, 11, 1e-9, "I1 tip_radius");
    near(g.root_radius, 8.75, 1e-9, "I1 root_radius");
    near(g.thickness, 1.570796327, 1e-6, "I1 thickness");
    check(!g.undercut, "I1 undercut");
    check(must(g.profile.area_properties(), "area_properties").area > PI * 8.75 * 8.75, "I1: the profile is the gear's, closed");

    GearInvoluteOptions explicit_defaults;
    explicit_defaults.pressure_angle = 20 * PI / 180;
    explicit_defaults.shift = 0.0;
    explicit_defaults.addendum = 1.0;
    explicit_defaults.dedendum = 1.25;
    explicit_defaults.root_fillet = 0.38;
    explicit_defaults.backlash = 0.0;
    explicit_defaults.tolerance = 1e-4;
    GearProfile e = must(Profile::gear_involute(1, 20, explicit_defaults), "gear_involute explicit");
    check(e.pitch_radius == g.pitch_radius && e.base_radius == g.base_radius && e.tip_radius == g.tip_radius &&
              e.root_radius == g.root_radius && e.thickness == g.thickness && e.undercut == g.undercut,
          "the explicit defaults are the defaults");
    check(must(Profile::gear_involute(1, 12), "gear_involute 12").undercut, "I4: 12 teeth undercut");
}

// I5: the centre distance, plain and with shifts 0.25 and 0.25.
static void centre_distance() {
    near(must(bs::gear_centre_distance_involute(1, 20, 40), "centre distance"), 30, 1e-12, "I5 centre distance");
    double a = must(bs::gear_centre_distance_involute(1, 20, 40, 0.25, 0.25), "centre distance shifted");
    check(a > 30.4 && a < 30.5, "I5 shifted centre distance " + num(a));
}

// C1 and C2: the wheel of 60 for a pinion of 8, and the pinion's leaf, either tip.
static void cycloidal_figures() {
    GearProfile w = must(Profile::gear_wheel_cycloidal(1, 60, 8), "gear_wheel_cycloidal");
    near(w.pitch_radius, 30, 1e-12, "C1 pitch_radius");
    near(w.root_radius, 28.43, 1e-9, "C1 root_radius");
    check(!w.base_radius.has_value() && !w.undercut, "C1: no base circle, no undercut");
    const GearTip tips[2] = {GearTip::round, GearTip::ogive};
    for (const GearTip tip : tips) {
        GearPinionCycloidalOptions options;
        options.tip = tip;
        GearProfile p = must(Profile::gear_pinion_cycloidal(1, 8, 60, options), "gear_pinion_cycloidal");
        const std::string which = tip == GearTip::round ? "round" : "ogive";
        near(p.pitch_radius, 4, 1e-12, "C2 pitch_radius, " + which);
        near(p.thickness, 1.05, 1e-12, "C2 thickness, " + which);
        check(!p.base_radius.has_value(), "C2: no base circle, " + which);
    }
}

static void refusals() {
    refused(Profile::gear_involute(1, 3), "profile_gear_involute: ", "involute z = 3");
    refused(Profile::gear_involute(0, 20), "profile_gear_involute: ", "involute m = 0");
    refused(Profile::gear_wheel_cycloidal(1, 60, 5), "profile_gear_wheel_cycloidal: ", "wheel for 5 leaves");
    refused(Profile::gear_pinion_cycloidal(1, 8, 8), "profile_gear_pinion_cycloidal: ", "pinion for a wheel of 8");
    GearPinionCycloidalOptions negative;
    negative.clearance = -1.0;
    refused(Profile::gear_pinion_cycloidal(1, 8, 60, negative), "profile_gear_pinion_cycloidal: ", "pinion clearance -1");
    refused(bs::gear_centre_distance_involute(1, 3, 40), "gear_centre_distance_involute: ", "centre distance z = 3");
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    involute_figures();
    centre_distance();
    cycloidal_figures();
    refusals();
    if (failures) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    std::printf("gears: ok\n");
    return 0;
}
