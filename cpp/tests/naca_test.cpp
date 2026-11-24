// NACA airfoils -- Naca::parse, four, five and the calls points, spline and profile -- at parity
// with the Python reference's tests test_naca_codes, test_naca_figures,
// test_naca_spline_and_profile and test_naca_refusals in test_cadaclysm_blacksmith.py: the
// hand-computed figures A1 and A5 and the refusals in the library's words. Needs the kernel
// library and a license; the exit code is the verdict.
//
//     cadaclysm_naca_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Naca;
using bs::NacaProfile;
using bs::NacaSpline;
using bs::Vec2;

static int failures = 0;

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

static void codes() {
    Naca n = must(Naca::parse("2412"), "parse 2412");
    check(n == Naca::four(0.02, 0.4, 0.12), "2412 is four(0.02, 0.4, 0.12)");
    check(n.series == 4, "2412 series");
    Naca r = must(Naca::parse("23112"), "parse 23112");
    check(r == Naca::five(0.3, 0.15, 0.12, true), "23112 is five(0.3, 0.15, 0.12, reflex)");
    check(must(Naca::parse("23012"), "parse 23012").series == 5, "23012 series");
}

static void figures() {
    // A1: 0012's open-edge ordinate at x = 0.5, the middle station of 201 points.
    std::vector<Vec2> pts = must(Naca::parse("0012").value().points(1, 201, false), "points 0012");
    check(pts.size() == 201, "201 points");
    check(pts[100][0] == 0.0 && pts[100][1] == 0.0, "A1: the leading edge in the middle");
    near(pts[50][0], 0.5, 1e-15, "A1 x");
    near(pts[50][1], 0.052940252, 1e-9, "A1 y");
    // A5: seven points, the leading edge in the middle, the upper surface first.
    std::vector<Vec2> seven = must(Naca::parse("2412").value().points(1, 7), "points 2412");
    check(seven.size() == 7, "A5: seven points");
    check(seven[3][0] == 0.0 && seven[3][1] == 0.0, "A5: the middle point is (0, 0), got (" + num(seven[3][0]) + ", " + num(seven[3][1]) + ")");
    check(seven[1][1] > 0 && seven[5][1] < 0, "A5: upper surface first");
    check(seven[0][0] == 1.0 && seven[0][1] == 0.0 && seven[6] == seven[0], "a closed trailing edge is one point");
}

static void spline_and_profile() {
    Naca n = must(Naca::parse("4412"), "parse 4412");
    NacaSpline s = must(n.spline(50), "spline");
    check(s.controls.size() == 32, "32 controls");
    check(s.controls.front()[0] == 50.0 && s.controls.front()[1] == 0.0 && s.controls.back() == s.controls.front(), "the ends on the trailing edge");
    check(s.error > 0 && s.error < 1e-4 * 50, "spline error " + num(s.error));
    NacaProfile p = must(n.profile(50, false), "profile");
    check(p.error > 0 && p.error <= 5e-4, "profile error " + num(p.error));
    check(must(p.profile.area_properties(), "area_properties").area > 0, "the profile is closed");
}

static void refusals() {
    refused(Naca::parse("12"), "naca_parse: ", "parse 12");
    Result<Naca> six = Naca::parse("26012");
    check(!six.ok() && six.error().message == "naca_parse: 5-digit positions are 1 to 5",
          "parse 26012: " + (six.ok() ? std::string("succeeded") : six.error().message));
    Naca n = Naca::four(0.02, 0.4, 0.12);
    refused(n.points(0), "naca_points: ", "chord 0");
    refused(n.points(1, 8), "naca_points: ", "count 8");
    refused(n.spline(1, 7), "naca_spline: ", "7 controls");
    refused(n.profile(1, true, -1.0), "profile_naca: ", "tolerance -1");
    refused(Naca::four(0.02, 0.4, 0.5).points(1), "naca_points: ", "thickness 0.5");
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    codes();
    figures();
    spline_and_profile();
    refusals();
    if (failures) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    std::printf("naca: ok\n");
    return 0;
}
