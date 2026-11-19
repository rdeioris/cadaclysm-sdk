// Draft -- draft, draft_two_sided, draft_angle_at and draft_analysis, with the DraftPoint and
// FaceDraft records -- at parity with the Python reference's tests of the same names in
// test_cadaclysm_blacksmith.py, every figure a closed form written out here: a 2 x 3 x 4 box's +x
// side drafted 5 degrees about its bottom loses a wedge of h^2 w tan(5)/2. The kernel's own
// correctness is the kernel's tests' job. Needs the kernel library and a license; the exit code is
// the verdict.
//
//     cadaclysm_draft_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Frame;
using bs::Solid;
using bs::Vec3;

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

// The neutral plane z = `z`, its z the pull.
static Frame plane_at(double z) { return must(Frame::xy({0, 0, z}), "Frame::xy"); }

// The face of `s` whose outward normal is `n`.
static std::uint32_t facing(const Solid& s, const Vec3& n) {
    for (std::uint32_t f = 0; f < s.faces(); ++f) {
        Vec3 z = must(s.face_frame(f), "face_frame").z();
        if (std::fabs(z[0] - n[0]) < 1e-9 && std::fabs(z[1] - n[1]) < 1e-9 && std::fabs(z[2] - n[2]) < 1e-9) return f;
    }
    std::fprintf(stderr, "FAIL: no face facing (%g, %g, %g)\n", n[0], n[1], n[2]);
    std::exit(1);
}

// 1: draft_a_box_side_to_the_closed_form
static Result<void> draft_a_box_side_to_the_closed_form() {
    double a = 5.0 * PI / 180.0;
    Solid block = must(Solid::cuboid(2, 3, 4), "cuboid");
    std::uint32_t side = facing(block, {1, 0, 0});
    Solid out = must(block.draft({side}, plane_at(-2), a), "draft");
    check(out.faces() == 6, "the drafted box has 6 faces, not " + std::to_string(out.faces()));
    double want = 24 - 16 * 3 * std::tan(a) / 2;
    double got = must(out.mass(), "mass").volume;
    check(std::fabs(got - want) <= 1e-9 * want, "the drafted box's volume " + num(got) + ", not " + num(want));
    bs::DraftPoint at = must(out.draft_angle_at(side, {5, 0, 0}, {0, 0, 2}), "draft_angle_at");
    check(std::fabs(at.angle - a) <= 1e-12 && at.uv.has_value(), "the drafted side's angle " + num(at.angle) + ", not 5 degrees");
    check(std::fabs(at.normal[0] - std::cos(a)) <= 1e-12 && std::fabs(at.normal[2] - std::sin(a)) <= 1e-12,
          "the drafted side's normal leans 5 degrees towards +z");
    // Two-sided about the middle: two half-height wedges off.
    Solid both = must(block.draft_two_sided({side}, plane_at(0), a, a), "draft_two_sided");
    double want_both = 24 - 2 * (4 * 3 * std::tan(a) / 2);
    double got_both = must(both.mass(), "mass").volume;
    check(std::fabs(got_both - want_both) <= 1e-9 * want_both, "the two-sided volume " + num(got_both) + ", not " + num(want_both));
    return {};
}

// 2: draft_analysis_reads_a_boxs_six_kinds
static Result<void> draft_analysis_reads_a_boxs_six_kinds() {
    Solid block = must(Solid::cuboid(2, 3, 4), "cuboid");
    std::uint32_t top = facing(block, {0, 0, 1});
    std::uint32_t bottom = facing(block, {0, 0, -1});
    std::uint32_t side = facing(block, {1, 0, 0});
    std::vector<bs::FaceDraft> rows = must(block.draft_analysis({0, 0, 1}), "draft_analysis");
    check(rows.size() == 6, "six rows, not " + std::to_string(rows.size()));
    for (std::size_t i = 0; i < rows.size(); ++i) {
        const bs::FaceDraft& r = rows[i];
        std::string want = r.face == top ? "positive" : r.face == bottom ? "negative" : "vertical";
        check(r.face == i && r.kind == want && r.undercut == 0 && r.area > 0, "face " + std::to_string(r.face) + " reads " + r.kind + ", not " + want);
    }
    const bs::FaceDraft& t = rows[top];
    check(std::fabs(t.min - PI / 2) <= 1e-9 && std::fabs(t.area - 6) <= 1e-9 && t.positive == t.area, "the top reads +90 degrees over its 6 of area");
    Solid drafted = must(block.draft({side}, plane_at(-2), 5.0 * PI / 180.0), "draft");
    std::vector<bs::FaceDraft> after = must(drafted.draft_analysis({0, 0, 1}, PI / 180.0, std::nullopt), "draft_analysis of the drafted box");
    check(after[side].kind == "positive" && std::fabs(after[side].min - 5.0 * PI / 180.0) <= 1e-9,
          "the drafted side reads positive at 5 degrees: " + after[side].kind + " " + num(after[side].min));
    return {};
}

// 3: draft_refusals_are_named
static Result<void> draft_refusals_are_named() {
    Solid block = must(Solid::cuboid(2, 3, 4), "cuboid");
    std::uint32_t top = facing(block, {0, 0, 1});
    refused(block.draft({top}, plane_at(0), 0.1), "draft: ", "the top drafted about a plane it lies parallel to");
    refused(block.draft({}, plane_at(0), 0.1), "draft: ", "no faces drafted");
    refused(block.draft_two_sided({0, 0}, plane_at(0), 0.1, 0.1), "draft: ", "a face named twice");
    refused(block.draft_angle_at(9, {0, 0, 0}, {0, 0, 1}), "draft_angle_at: face 9 of 6", "draft_angle_at of face 9");
    refused(block.draft_angle_at(0, {0, 0, 0}, {0, 0, 0}), "draft_angle_at: ", "draft_angle_at with no pull");
    refused(block.draft_analysis({0, 0, 1}, 2.0), "draft_analysis: ", "draft_analysis at a threshold of 2");
    return {};
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    struct Test {
        const char* name;
        Result<void> (*run)();
    };
    const Test tests[] = {
        {"draft_a_box_side_to_the_closed_form", draft_a_box_side_to_the_closed_form},
        {"draft_analysis_reads_a_boxs_six_kinds", draft_analysis_reads_a_boxs_six_kinds},
        {"draft_refusals_are_named", draft_refusals_are_named},
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
    std::printf("draft: ok\n");
    return 0;
}
