// The planar contact solver -- contact_settle -- at parity with the Python reference's
// test_contact_settle_figures in test_cadaclysm_blacksmith.py: the hand-computed figures S1, S5
// and S6, the default tolerance, and a refusal in the library's words. Needs the kernel library
// and a license; the exit code is the verdict.
//
//     cadaclysm_settle_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Profile;
using bs::Settle;
using bs::SettleContact;

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

static void figures() {
    // S1: the driver a unit disc at local (3, 0) about (5, 0), turned to pi; the follower a unit
    // disc at local (2, 0) about the origin, clockwise from pi to pi/3.
    const Profile d = must(must(Profile::circle(1), "circle").translate(3, 0), "translate");
    const Profile f = must(must(Profile::circle(1), "circle").translate(2, 0), "translate");
    const double h = std::sqrt(3.0) / 2;
    const Settle s1 = must(bs::contact_settle(d, {5, 0}, PI, f, {0, 0}, PI, -1, std::nullopt, 1e-11), "S1");
    near(s1.value, PI / 3, 1e-9, "S1 value");
    check(!s1.recoiled, "S1 recoiled");
    check(s1.steps > 0, "S1 steps");
    check(s1.contact.has_value(), "S1 contact: nullopt");
    const SettleContact c = s1.contact.value_or(SettleContact());
    near(c.point[0], 1.5, 1e-9, "S1 point x");
    near(c.point[1], h, 1e-9, "S1 point y");
    near(c.normal[0], -0.5, 1e-9, "S1 normal x");
    near(c.normal[1], h, 1e-9, "S1 normal y");
    check(c.driver[0] == 0 && c.follower[0] == 0, "S1 driver and follower loop 0");

    // The default tolerance: 1e-9 of either placed disc's diagonal, 2 sqrt 2.
    const Settle plain = must(bs::contact_settle(d, {5, 0}, PI, f, {0, 0}, PI, -1), "default");
    const Settle given = must(bs::contact_settle(d, {5, 0}, PI, f, {0, 0}, PI, -1, std::nullopt, 2e-9 * std::sqrt(2.0)), "2e-9 sqrt 2");
    check(plain.value == given.value && plain.steps == given.steps && plain.recoiled == given.recoiled &&
              plain.contact.has_value() == given.contact.has_value(),
          "the default tolerance is 2e-9 sqrt 2: " + num(plain.value) + " vs " + num(given.value));

    // S5: counter-clockwise to the limit 3 pi / 2, no contact.
    const Settle s5 = must(bs::contact_settle(d, {5, 0}, PI, f, {0, 0}, PI, 1, 1.5 * PI, 1e-11), "S5");
    check(s5.value == 1.5 * PI, "S5 value " + num(s5.value));
    check(!s5.contact.has_value(), "S5 contact: present at the limit");

    // S6: S1 from pi/6, overlapping: recoiled to pi/3.
    const Settle s6 = must(bs::contact_settle(d, {5, 0}, PI, f, {0, 0}, PI / 6, -1, std::nullopt, 1e-11), "S6");
    near(s6.value, PI / 3, 1e-9, "S6 value");
    check(s6.recoiled, "S6 recoiled");

    // The refusal carries the library's prefix.
    const Result<Settle> refused = bs::contact_settle(d, {5, 0}, PI, f, {0, 0}, PI, 0);
    if (refused.ok()) {
        check(false, "direction 0: expected a refusal, but the call succeeded");
    } else {
        const std::string& got = refused.error().message;
        const std::string prefix = "contact_settle: ";
        check(got.compare(0, prefix.size(), prefix) == 0, "direction 0: refused with \"" + got + "\"");
    }
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    figures();
    if (failures) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    std::printf("settle: ok\n");
    return 0;
}
