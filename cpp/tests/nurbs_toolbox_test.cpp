// The NURBS toolbox -- at parity with the other wrappers' smokes and the C-level test
// nurbs_toolbox_abi.rs, every figure worked by hand: knots inserted, refined and removed on a
// rational arc; reparametrised, non-rational, compatible and uniform forms; Greville abscissae
// and a periodic curve; matching directions, the mean of two arcs and the conic kinds; a bicubic
// Hermite surface through a cubic polynomial with its net edits and second derivatives; and a
// cylinder's curvature. Needs the kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_nurbs_toolbox_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec3;
using Range = std::pair<double, double>;
using Domain = std::pair<Range, Range>;
using Counts = std::pair<std::uint32_t, std::uint32_t>;

static int failures = 0;
static const double SQRT_2 = std::sqrt(2.0);

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool near3(const Vec3& a, const Vec3& b, double tolerance) {
    return within(a[0], b[0], tolerance) && within(a[1], b[1], tolerance) && within(a[2], b[2], tolerance);
}

static std::string str3(const Vec3& p) {
    return "(" + std::to_string(p[0]) + ", " + std::to_string(p[1]) + ", " + std::to_string(p[2]) + ")";
}

static bool same_list(const std::vector<double>& a, const std::vector<double>& b, double tolerance) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (!within(a[i], b[i], tolerance)) return false;
    }
    return true;
}

static std::string str_list(const std::vector<double>& a) {
    std::string s = "[";
    for (std::size_t i = 0; i < a.size(); ++i) s += (i ? ", " : "") + std::to_string(a[i]);
    return s + "]";
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
static void refused_as(const Result<T>& r, const std::string& prefix, const std::string& what) {
    check(!r.ok() && r.error().message.rfind(prefix, 0) == 0,
          what + ": not refused as \"" + prefix + "...\"" + (r.ok() ? std::string(" (it succeeded)") : " (got \"" + r.error().message + "\")"));
}

// The quarter circle of radius `r` about the origin in z = 0, from (r, 0, 0) to (0, r, 0).
static bs::NurbsCurve quarter(double r) {
    return must(bs::NurbsCurve::make({Vec3{r, 0, 0}, Vec3{r, r, 0}, Vec3{0, r, 0}}, 2, std::vector<double>{1, SQRT_2 / 2, 1}), "quarter");
}

static bs::NurbsCurve segment(const Vec3& a, const Vec3& b) { return must(bs::NurbsCurve::make({a, b}, 1), "segment"); }

static Vec3 at(const bs::NurbsCurve& c, double t) { return must(c.point(t), "point"); }

// 1. Knots inserted, removed and refined on the quarter circle of radius 2.
static Result<void> knots_on_an_arc() {
    bs::NurbsCurve q = quarter(2);
    bs::NurbsCurve k = must(q.insert_knot(0.5), "insert_knot");
    std::vector<double> kk = must(k.knots(), "knots");
    check(kk == std::vector<double>({0, 0, 0, 0.5, 1, 1, 1}), "inserted knots " + str_list(kk));
    std::vector<Vec3> pts = must(k.control_points(), "control_points");
    std::vector<double> w = must(k.weights(), "weights");
    check(near3(pts[1], Vec3{2, 2 * SQRT_2 - 2, 0}, 1e-14), "inserted point 1 " + str3(pts[1]));
    check(within(w[1], (2 + SQRT_2) / 4, 1e-14), "inserted weight 1 " + std::to_string(w[1]));
    for (int i = 0; i <= 8; ++i) {
        double t = i / 8.0;
        check(near3(at(q, t), at(k, t), 1e-14), "inserted curve at " + std::to_string(t));
    }

    std::pair<bs::NurbsCurve, std::uint32_t> back = must(k.remove_knot(0.5, 1, 1e-9), "remove_knot");
    check(back.second == 1, "removed " + std::to_string(back.second));
    std::vector<Vec3> bp = must(back.first.control_points(), "control_points");
    std::vector<double> bw = must(back.first.weights(), "weights");
    check(bp.size() == 3 && near3(bp[1], Vec3{2, 2, 0}, 1e-12), "removed point 1 " + str3(bp[1]));
    check(within(bw[1], SQRT_2 / 2, 1e-12), "removed weight 1 " + std::to_string(bw[1]));

    bs::NurbsCurve corner = must(bs::NurbsCurve::make({Vec3{0, 0, 0}, Vec3{1, 0, 0}, Vec3{1, 1, 0}}, 1), "corner");
    std::pair<bs::NurbsCurve, std::uint32_t> kept = must(corner.remove_knot(0.5, 1, 1e-6), "corner remove_knot");
    check(kept.second == 0, "a corner removed " + std::to_string(kept.second));
    check(must(kept.first.control_points(), "control_points").size() == 3, "a corner keeps its 3 points");

    bs::NurbsCurve r = must(q.refine_knots({0.25, 0.5, 0.75}), "refine_knots");
    std::vector<double> rk = must(r.knots(), "knots");
    check(rk == std::vector<double>({0, 0, 0, 0.25, 0.5, 0.75, 1, 1, 1}), "refined knots " + str_list(rk));

    refused_as(q.insert_knot(0.5, 3), "nurbs_curve_knot_inserted: ", "a multiplicity past the degree");
    return {};
}

// 2. Reparametrised, non-rational, compatible and uniform.
static Result<void> forms() {
    bs::NurbsCurve q = quarter(2);
    bs::NurbsCurve re = must(q.reparametrize(10, 20), "reparametrize");
    Range d = must(re.domain(), "domain");
    check(d.first == 10 && d.second == 20, "reparametrised domain");
    check(near3(at(re, 15), at(q, 0.5), 1e-12), "reparametrised point(15)");

    bs::NurbsCurve plain = must(q.non_rational(), "non_rational");
    check(!plain.is_rational(), "non_rational is not rational");
    check(near3(at(plain, 0.5), Vec3{1.5, 1.5, 0}, 1e-14), "non_rational point(0.5) " + str3(at(plain, 0.5)));

    bs::NurbsCurve line = must(bs::NurbsCurve::make({Vec3{0, 0, 1}, Vec3{4, 0, 1}}, 1, std::nullopt, std::vector<double>{3, 3, 5, 5}), "line");
    std::vector<bs::NurbsCurve> both = must(bs::NurbsCurve::make_compatible({q, line}), "make_compatible");
    check(both.size() == 2, "two compatible curves");
    for (const bs::NurbsCurve& c : both) {
        check(c.degree() == 2, "compatible degree " + std::to_string(c.degree()));
        Range cd = must(c.domain(), "domain");
        check(cd.first == 0 && cd.second == 1, "compatible domain");
    }
    check(must(both[0].knots(), "knots") == must(both[1].knots(), "knots"), "compatible knots equal");
    check(near3(at(both[1], 0.25), Vec3{1, 0, 1}, 1e-14), "compatible line still the line");

    std::vector<Vec3> zig;
    for (int i = 0; i < 6; ++i) zig.push_back(Vec3{static_cast<double>(i), static_cast<double>(i % 2), 0});
    bs::NurbsCurve cubic = must(bs::NurbsCurve::make(zig, 3, std::nullopt, std::vector<double>{0, 0, 0, 0, 0.1, 0.9, 1, 1, 1, 1}), "cubic");
    std::vector<double> uk = must(must(cubic.make_uniform(), "make_uniform").knots(), "knots");
    check(same_list(uk, {0, 0, 0, 0, 1.0 / 3, 2.0 / 3, 1, 1, 1, 1}, 1e-15), "uniform knots " + str_list(uk));
    return {};
}

// 3. Greville abscissae and a periodic curve.
static Result<void> greville_and_periodic() {
    std::vector<Vec3> zig;
    for (int i = 0; i < 6; ++i) zig.push_back(Vec3{static_cast<double>(i), static_cast<double>(i % 2), 0});
    bs::NurbsCurve cubic = must(bs::NurbsCurve::make(zig, 3, std::nullopt, std::vector<double>{0, 0, 0, 0, 1, 2, 3, 3, 3, 3}), "cubic");
    std::vector<double> g = must(cubic.greville_parameters(), "greville_parameters");
    check(same_list(g, {0, 1.0 / 3, 1, 2, 8.0 / 3, 3}, 1e-14), "greville " + str_list(g));
    std::vector<Vec3> gp = must(cubic.greville_points(), "greville_points");
    check(gp.size() == 6, "six greville points");
    for (std::size_t i = 0; i < gp.size() && i < g.size(); ++i) check(near3(gp[i], at(cubic, g[i]), 1e-14), "greville point " + std::to_string(i));

    bs::NurbsCurve square = must(bs::NurbsCurve::make({Vec3{0, 0, 0}, Vec3{1, 0, 0}, Vec3{1, 1, 0}, Vec3{0, 1, 0}}, 3), "square");
    bs::NurbsCurve p = must(square.periodic(false), "periodic");
    check(must(p.control_points(), "control_points").size() == 7, "periodic has 7 control points");
    Range d = must(p.domain(), "domain");
    check(d.first == 0 && d.second == 4, "periodic domain (" + std::to_string(d.first) + ", " + std::to_string(d.second) + ")");
    check(near3(at(p, 0), Vec3{5.0 / 6, 1.0 / 6, 0}, 1e-14), "periodic point(0) " + str3(at(p, 0)));
    return {};
}

// 4. Directions, the mean of two arcs and the conic kinds.
static Result<void> directions_mean_conics() {
    bs::NurbsCurve a = segment(Vec3{0, 0, 0}, Vec3{10, 0, 0});
    bs::NurbsCurve b = segment(Vec3{0, 1, 0}, Vec3{10, 1, 0});
    bs::NurbsCurve b_back = must(b.reverse(), "reverse");
    check(must(a.directions_match(b), "directions_match") == true, "parallel lines match");
    check(must(a.directions_match(b_back), "directions_match") == false, "a reversed line does not");
    bs::NurbsCurve turned = must(b_back.lined_up_with(a), "lined_up_with");
    check(near3(at(turned, 0), Vec3{0, 1, 0}, 1e-14), "lined up runs with a");
    check(must(a.directions_match(turned), "directions_match") == true, "lined up matches");

    bs::NurbsCurve big_back = must(quarter(4).reverse(), "reverse");
    bs::NurbsCurve m = must(quarter(2).mean(big_back), "mean");
    Range md = must(m.domain(), "domain");
    for (int i = 0; i <= 16; ++i) {
        double t = md.first + (md.second - md.first) * i / 16.0;
        Vec3 p = at(m, t);
        check(within(std::sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]), 3, 1e-12), "mean at distance 3: " + str3(p));
    }

    bs::NurbsCurve q = quarter(2);
    check(must(q.conic_type(1e-6), "conic_type") == bs::ConicType::circle, "q is a circle");
    check(must(must(q.elevate(3), "elevate").conic_type(1e-6), "conic_type") == bs::ConicType::circle, "q elevated is a circle");
    bs::NurbsCurve ell = must(bs::NurbsCurve::make({Vec3{4, 0, 0}, Vec3{4, 2, 0}, Vec3{0, 2, 0}}, 2, std::vector<double>{1, SQRT_2 / 2, 1}), "ellipse");
    check(must(ell.conic_type(1e-6), "conic_type") == bs::ConicType::ellipse, "an ellipse");
    bs::NurbsCurve hyp = must(bs::NurbsCurve::make({Vec3{2, 0, 0}, Vec3{2, 2, 0}, Vec3{0, 2, 0}}, 2, std::vector<double>{1, 2, 1}), "hyperbola");
    check(must(hyp.conic_type(1e-6), "conic_type") == bs::ConicType::hyperbola, "a hyperbola");
    check(must(must(q.non_rational(), "non_rational").conic_type(1e-6), "conic_type") == bs::ConicType::parabola, "a parabola");
    check(must(a.conic_type(1e-6), "conic_type") == bs::ConicType::none, "a line is no conic");
    refused_as(q.conic_type(-1.0), "nurbs_curve_conic_type: ", "a negative tolerance");
    return {};
}

// f(u, v) = (u, v, u^2 v + u v^3) and its derivatives.
static Vec3 f_of(double u, double v) { return Vec3{u, v, u * u * v + u * v * v * v}; }

// 5. The bicubic Hermite surface through f, and its net edits.
static Result<void> hermite_surface() {
    std::vector<double> us = {0, 0.5, 2}, vs = {0, 1, 1.5};
    std::vector<Vec3> points, du, dv, twists;
    for (double u : us) {
        for (double v : vs) {
            points.push_back(f_of(u, v));
            du.push_back(Vec3{1, 0, 2 * u * v + v * v * v});
            dv.push_back(Vec3{0, 1, u * u + 3 * u * v * v});
            twists.push_back(Vec3{0, 0, 2 * u + 3 * v * v});
        }
    }
    bs::NurbsSurface s = must(bs::NurbsSurface::hermite(us, vs, points, du, dv, twists), "hermite");
    check(must(s.counts(), "counts") == Counts(6, 6), "hermite counts");
    std::vector<double> ku = must(s.knots(bs::SurfaceDirection::u), "knots u");
    check(ku == std::vector<double>({0, 0, 0, 0, 0.5, 0.5, 2, 2, 2, 2}), "hermite knots u " + str_list(ku));
    std::vector<double> kv = must(s.knots(bs::SurfaceDirection::v), "knots v");
    check(kv == std::vector<double>({0, 0, 0, 0, 1, 1, 1.5, 1.5, 1.5, 1.5}), "hermite knots v " + str_list(kv));
    check(must(s.control_points(), "control_points").size() == 36, "36 control points");
    std::vector<double> w = must(s.weights(), "weights");
    check(w.size() == 36 && w[0] == 1 && w[35] == 1, "plain weights");

    const double U = 1.3, V = 0.7;
    Vec3 p = must(s.point_at(U, V), "point_at");
    check(near3(p, f_of(U, V), 1e-13), "hermite point_at " + str3(p));
    bs::SurfaceDerivatives d = must(s.second_derivatives(U, V), "second_derivatives");
    check(near3(d.point, f_of(U, V), 1e-13), "second_derivatives S");
    check(near3(d.du, Vec3{1, 0, 2 * U * V + V * V * V}, 1e-12), "Su " + str3(d.du));
    check(near3(d.dv, Vec3{0, 1, U * U + 3 * U * V * V}, 1e-12), "Sv " + str3(d.dv));
    check(near3(d.duu, Vec3{0, 0, 2 * V}, 1e-12), "Suu " + str3(d.duu));
    check(near3(d.duv, Vec3{0, 0, 2 * U + 3 * V * V}, 1e-12), "Suv " + str3(d.duv));
    check(near3(d.dvv, Vec3{0, 0, 6 * U * V}, 1e-12), "Svv " + str3(d.dvv));

    bs::NurbsSurface e = must(s.elevate(bs::SurfaceDirection::u), "elevate");
    check(must(e.degree_u(), "degree_u") == 4 && must(e.degree_v(), "degree_v") == 3, "elevated degrees (4, 3)");
    check(near3(must(e.point_at(U, V), "point_at"), f_of(U, V), 1e-13), "elevated point");

    bs::NurbsSurface i = must(s.insert_knot(bs::SurfaceDirection::u, 1.0), "insert_knot");
    check(must(i.counts(), "counts") == Counts(7, 6), "inserted counts (7, 6)");
    bs::NurbsSurface r = must(s.refine_knots(bs::SurfaceDirection::v, {0.25, 1.25}), "refine_knots");
    check(must(r.counts(), "counts") == Counts(6, 8), "refined counts (6, 8)");
    std::pair<bs::NurbsSurface, std::uint32_t> back = must(i.remove_knot(bs::SurfaceDirection::u, 1.0, 1, 1e-9), "remove_knot");
    check(back.second == 1, "surface removed " + std::to_string(back.second));
    check(must(back.first.counts(), "counts") == Counts(6, 6), "removed counts (6, 6)");

    bs::NurbsSurface x = must(s.extend(bs::SurfaceSide::u_end, 0.5), "extend");
    Domain xd = must(x.domain(), "domain");
    check(xd.first.second > 2, "extended u end " + std::to_string(xd.first.second));
    check(near3(must(x.point_at(U, V), "point_at"), p, 1e-12), "extended point unchanged");
    refused_as(s.extend(bs::SurfaceSide::u_end, -1.0), "nurbs_surface_extended: ", "a negative length");
    return {};
}

// 6. The curvature of a quarter cylinder of radius 2 along z.
static Result<void> cylinder_curvature() {
    std::vector<Vec3> net = {Vec3{2, 0, 0}, Vec3{2, 0, 5}, Vec3{2, 2, 0}, Vec3{2, 2, 5}, Vec3{0, 2, 0}, Vec3{0, 2, 5}};
    std::vector<double> w = {1, 1, SQRT_2 / 2, SQRT_2 / 2, 1, 1};
    bs::NurbsSurface s = must(bs::NurbsSurface::make(net, Counts{3, 2}, 2, 1, w), "cylinder");
    bs::SurfaceCurvature c = must(s.curvature(0.5, 0.3), "curvature");
    check(within(c.k1, 0, 1e-12), "k1 " + std::to_string(c.k1));
    check(within(c.k2, -0.5, 1e-12), "k2 " + std::to_string(c.k2));
    check(within(c.gaussian, 0, 1e-12), "gaussian " + std::to_string(c.gaussian));
    check(within(c.mean, -0.25, 1e-12), "mean " + std::to_string(c.mean));
    check(near3(c.normal, Vec3{SQRT_2 / 2, SQRT_2 / 2, 0}, 1e-12), "normal " + str3(c.normal));
    // k1's direction runs along the axis, k2's around it.
    check(near3(c.dir1, Vec3{0, 0, 1}, 1e-12) || near3(c.dir1, Vec3{0, 0, -1}, 1e-12), "dir1 " + str3(c.dir1));
    check(within(std::fabs(c.dir2[2]), 0, 1e-12), "dir2 " + str3(c.dir2));
    refused_as(s.curvature(2.0, 0.3), "nurbs_surface_curvature: ", "a parameter outside the domain");
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
        {"knots_on_an_arc", knots_on_an_arc},
        {"forms", forms},
        {"greville_and_periodic", greville_and_periodic},
        {"directions_mean_conics", directions_mean_conics},
        {"hermite_surface", hermite_surface},
        {"cylinder_curvature", cylinder_curvature},
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
    std::printf("nurbs toolbox: ok\n");
    return 0;
}
