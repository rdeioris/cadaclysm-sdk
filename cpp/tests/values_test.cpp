// Value geometry -- Interval, the Frame verbs and Frame::fit, CurveFoot / SurfaceFoot, the nine
// value classes and Curve::value -- at parity with the Python reference's TestInterval,
// TestFrameVerbs, TestCurveValues, TestSurfaceValues and TestCuboidValue in
// test_cadaclysm_blacksmith.py, with the same figures and tolerances. The Rhino records are
// crates/cadaclysm/tests/fixtures/rhino/value_vectors.txt, its path a build-time definition:
// in a checkout a missing file fails; in the SDK layout, which does not carry it, the record
// checks are skipped with the reason printed. Needs the kernel library; the exit code is the
// verdict.
//
//     cadaclysm_values_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <type_traits>
#include <unordered_set>
#include <utility>
#include <variant>
#include <vector>

#ifndef CADACLYSM_VALUE_VECTORS
#error "CADACLYSM_VALUE_VECTORS: the path of value_vectors.txt, set by CMakeLists.txt"
#endif
#ifndef CADACLYSM_REPO_MANIFEST
#error "CADACLYSM_REPO_MANIFEST: the path of crates/cadaclysm/Cargo.toml, set by CMakeLists.txt"
#endif

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Arc;
using bs::Circle;
using bs::Cone;
using bs::Cuboid;
using bs::CurveFoot;
using bs::CurveValue;
using bs::Cylinder;
using bs::Ellipse;
using bs::Frame;
using bs::Interval;
using bs::Line;
using bs::Ray;
using bs::Rectangle;
using bs::Solid;
using bs::Sphere;
using bs::SurfaceFoot;
using bs::Torus;
using bs::Transform;
using bs::Triangle;
using bs::Vec2;
using bs::Vec3;

using Frame12 = std::array<double, 12>;

static const double PI = 3.14159265358979323846;
static const double EXACT = 1e-12;
static const double NURBS_FOOT = 1e-7;
static const Frame12 XY = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
// Right-handed and exact: x = world y, y = world z, z = world x, off the origin.
static const Frame12 YZX = {1, 2, 3, 0, 1, 0, 0, 0, 1, 1, 0, 0};

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// The value of a call the test cannot go on without; anything else ends the run.
template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// A refusal whose text is exactly `words`.
template <class T>
static void refused(const Result<T>& r, const std::string& words, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got == words, what + ": refused with \"" + got + "\", wanted \"" + words + "\"");
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }
static bool rel(double a, double b, double r) { return std::fabs(a - b) <= r * std::fabs(b); }
// pytest.approx's default: 1e-6 relative.
static bool approx(double a, double b) { return rel(a, b, 1e-6) || within(a, b, 1e-12); }

static std::string text(const std::vector<double>& v) {
    std::string s = "(";
    for (std::size_t i = 0; i < v.size(); ++i) s += (i ? ", " : "") + std::to_string(v[i]);
    return s + ")";
}

static std::vector<double> vec(const Vec3& v) { return {v[0], v[1], v[2]}; }
static std::vector<double> vec(const Frame12& v) { return std::vector<double>(v.begin(), v.end()); }

// Every number of `got` within `tolerance` of `want`'s, the counts equal.
static void close(const std::vector<double>& got, const std::vector<double>& want, double tolerance, const std::string& what) {
    bool ok = got.size() == want.size();
    for (std::size_t i = 0; ok && i < got.size(); ++i) ok = within(got[i], want[i], tolerance);
    check(ok, what + ": got " + text(got) + ", wanted " + text(want));
}

static double dist(const Vec3& a, const Vec3& b) {
    return std::sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
}

static Interval iv(double t0, double t1) { return must(Interval::make(t0, t1), "Interval::make"); }
static Frame frame_of(const std::vector<double>& v) {
    Frame12 raw{};
    for (std::size_t i = 0; i < 12 && i < v.size(); ++i) raw[i] = v[i];
    return must(Frame::of(raw), "Frame::of");
}
static Frame12 raw12(const std::vector<double>& v) {
    Frame12 raw{};
    for (std::size_t i = 0; i < 12 && i < v.size(); ++i) raw[i] = v[i];
    return raw;
}
static Vec3 v3(const std::vector<double>& v, std::size_t at = 0) { return {v[at], v[at + 1], v[at + 2]}; }
// Python's `a % b` for a positive b: the answer takes b's sign.
static double pymod(double a, double b) {
    double m = std::fmod(a, b);
    return m < 0 ? m + b : m;
}

// ---- the Rhino records ------------------------------------------------------------------

using Records = std::map<std::pair<std::string, std::string>, std::vector<std::string>>;

static bool file_exists(const char* path) {
    std::ifstream f(path);
    return f.good();
}

// The records, or nothing where they cannot be read: a failure in a checkout (the manifest
// beside the fixture exists), a printed skip in the SDK layout.
static const Records* vectors() {
    static bool loaded = false;
    static std::optional<Records> records;
    if (loaded) return records ? &*records : nullptr;
    loaded = true;
    std::ifstream in(CADACLYSM_VALUE_VECTORS);
    if (!in) {
        if (file_exists(CADACLYSM_REPO_MANIFEST)) {
            check(false, std::string("the Rhino records ") + CADACLYSM_VALUE_VECTORS + " are missing from this checkout");
        } else {
            std::printf("skipped: the Rhino records -- value_vectors.txt is not in the SDK layout\n");
        }
        return nullptr;
    }
    Records r;
    std::string line;
    while (std::getline(in, line)) {
        check(line.find("ERROR") == std::string::npos, "an ERROR record: " + line);
        std::istringstream words(line);
        std::string case_name;
        std::string what;
        if (!(words >> case_name) || case_name[0] == '#') continue;
        if (!(words >> what)) continue;
        std::vector<std::string> rest;
        std::string word;
        while (words >> word) rest.push_back(word);
        std::pair<std::string, std::string> key(case_name, what);
        check(r.find(key) == r.end(), "a repeated record: " + case_name + " " + what);
        r[key] = rest;
    }
    records = std::move(r);
    return &*records;
}

static const std::vector<std::string>& words(const Records& r, const std::string& case_name, const std::string& what) {
    Records::const_iterator found = r.find(std::make_pair(case_name, what));
    if (found == r.end()) {
        std::fprintf(stderr, "FAIL: no record %s %s\n", case_name.c_str(), what.c_str());
        std::exit(1);
    }
    return found->second;
}

static std::vector<double> nums(const Records& r, const std::string& case_name, const std::string& what) {
    std::vector<double> out;
    for (const std::string& w : words(r, case_name, what)) out.push_back(std::strtod(w.c_str(), nullptr));
    return out;
}

static std::string two(int k) { return (k < 10 ? "0" : "") + std::to_string(k); }

static std::vector<std::pair<std::string, Vec3>> queries(const Records& r, const std::string& shape) {
    std::vector<std::pair<std::string, Vec3>> out;
    for (int i = 0; i < 12; ++i) {
        std::string case_name = shape + "_" + two(i);
        out.push_back(std::make_pair(case_name, v3(nums(r, case_name, "query"))));
    }
    return out;
}

// A foot Rhino found by iteration on a NURBS form: the distance to 1e-12, never beaten by
// Rhino's, the point to 1e-7 -- as B1's nurbs_foot.
static void nurbs_foot(const std::string& label, const Vec3& q, const Vec3& ours, const Vec3& rhino) {
    double d = dist(q, ours);
    double dr = dist(q, rhino);
    check(d <= dr + EXACT && std::fabs(d - dr) <= EXACT,
          label + ": distance " + std::to_string(d) + " against Rhino's " + std::to_string(dr));
    close(vec(ours), vec(rhino), NURBS_FOOT, label);
}

// ---- 1. Interval ----------------------------------------------------------------------

static void interval_measures_keep_the_orientation() {
    Interval up = iv(2, 6);
    Interval down = iv(6, 2);
    check(up.length() == 4.0 && down.length() == -4.0, "length keeps the order");
    check(up.mid() == 4.0 && down.mid() == 4.0, "mid");
    check((up.min)() == 2.0 && (up.max)() == 6.0 && (down.min)() == 2.0 && (down.max)() == 6.0, "min and max");
    check(up.is_increasing() && !down.is_increasing() && !iv(3, 3).is_increasing(), "is_increasing");
    check(iv(3, 3).is_singleton() && !up.is_singleton(), "is_singleton");
    check(up.swapped() == down && down.swapped() == up, "swapped");
    check(down.t0() == 6.0 && down.t1() == 2.0, "t0 and t1 as given");
}

static void interval_set_operations_answer_increasing() {
    Interval up = iv(2, 6);
    Interval down = iv(6, 2);
    check(must(up.grown(9), "grown") == iv(2, 9), "up.grown(9)");
    check(must(down.grown(-1), "grown") == iv(-1, 6), "down.grown(-1)");
    check(must(down.grown(3), "grown") == up, "down.grown(3)");
    check(up.union_with(iv(8, 7)) == iv(2, 8), "up.union_with(8..7)");
    check(down.union_with(iv(1, 3)) == iv(1, 6), "down.union_with(1..3)");
    std::optional<Interval> a = down.intersect(iv(9, 4));
    check(a && *a == iv(4, 6), "down.intersect(9..4)");
    std::optional<Interval> b = up.intersect(iv(3, 5));
    check(b && *b == iv(3, 5), "up.intersect(3..5)");
    check(!up.intersect(iv(7, 9)) && !down.intersect(iv(1, 1.5)), "apart intervals have no intersection");
    std::optional<Interval> touch = iv(0, 1).intersect(iv(1, 2));
    check(touch && *touch == iv(1, 1), "touching intervals intersect in a singleton");
    std::optional<Interval> touch2 = iv(2, 1).intersect(iv(0, 1));
    check(touch2 && *touch2 == iv(1, 1), "a decreasing touch intersects in a singleton");
    for (const Interval& x : {up, down}) {
        check(x.contains(2) && x.contains(6) && x.contains(4.5), "contains the closed range");
        check(!x.contains(1.999) && !x.contains(6.001), "contains nothing outside");
    }
}

static void interval_parameters_round_trip() {
    check(iv(2, 6).parameter_at(0.25) == 3.0 && iv(6, 2).parameter_at(0.25) == 5.0, "parameter_at");
    for (const Interval& x : {iv(2, 6), iv(6, 2), iv(-1.5, 0.7)}) {
        for (double s : {-0.5, 0.0, 0.3, 1.0, 2.0}) {
            std::optional<double> back = x.normalized_parameter_at(x.parameter_at(s));
            check(back && std::fabs(*back - s) <= 1e-15, "normalized_parameter_at(parameter_at(" + std::to_string(s) + "))");
        }
    }
    check(!iv(3, 3).normalized_parameter_at(3), "a singleton has no normalized parameter");
}

static void interval_is_a_hashable_value() {
    Interval a = iv(1, 2);
    check(a == iv(1.0, 2.0), "equal by value");
    check(std::hash<Interval>()(a) == std::hash<Interval>()(iv(1.0, 2.0)), "equal intervals hash alike");
    std::unordered_set<Interval> set = {a, iv(1, 2)};
    check(set.size() == 1, "a set holds one of two equal intervals");
    static_assert(std::is_same<decltype(std::declval<const Interval&>().t0()), double>::value, "t0 is read, not written");
    const double nan = std::numeric_limits<double>::quiet_NaN();
    refused(Interval::make(nan, 1), "Interval: not finite", "a NaN end");
    refused(Interval::of(std::vector<double>{1, 2, 3}), "Interval: an interval is 2 numbers, got 3", "three numbers");
    check(must(Interval::of(std::vector<double>{4, 3}), "of") == iv(4, 3), "of two numbers");
}

static void interval_matches_rhino() {
    const Records* r = vectors();
    if (!r) return;
    for (const char* name : {"apart", "dec_dec", "inc_dec", "inc_inc", "touch"}) {
        std::string c = std::string("interval_") + name;
        std::vector<double> args = nums(*r, c, "args");
        Interval a = iv(args[0], args[1]);
        Interval b = iv(args[2], args[3]);
        Interval u = a.union_with(b);
        close({u.t0(), u.t1()}, nums(*r, c, "union"), 0.0, c + " union");
        std::optional<Interval> got = a.intersect(b);
        if (words(*r, c, "intersection") == std::vector<std::string>{"none"}) {
            check(!got, c + ": no intersection");
        } else {
            check(got.has_value(), c + ": an intersection");
            if (got) close({got->t0(), got->t1()}, nums(*r, c, "intersection"), 0.0, c + " intersection");
        }
    }
    for (const char* name : {"inc_inside", "inc_out", "dec_low", "dec_inside"}) {
        std::string c = std::string("grow_") + name;
        std::vector<double> args = nums(*r, c, "args");
        Interval g = must(iv(args[0], args[1]).grown(args[2]), "grown");
        close({g.t0(), g.t1()}, nums(*r, c, "grown"), 0.0, c);
    }
    for (const char* name : {"inc", "dec"}) {
        for (int k = 0; k < 4; ++k) {
            std::string c = std::string("param_") + name + "_" + std::to_string(k);
            std::vector<double> args = nums(*r, c, "args");
            Interval x = iv(args[0], args[1]);
            double t = args[2];
            close({x.parameter_at(t)}, nums(*r, c, "parameter_at"), EXACT, c);
            std::optional<double> n = x.normalized_parameter_at(2.5 + t);
            close({n ? *n : std::nan("")}, nums(*r, c, "normalized_at"), EXACT, c + " normalized");
        }
    }
}

// ---- 2. Frame verbs ---------------------------------------------------------------------

static void plane_verbs_match_rhino() {
    const Records* r = vectors();
    if (!r) return;
    Frame p = frame_of(nums(*r, "plane", "frame"));
    Frame flip = p.flipped();
    close(vec(flip.raw()), nums(*r, "plane", "flip"), EXACT, "flip");
    close(vec(must(p.rotated(0.6, {1, -1, 0.5}), "rotated").raw()), nums(*r, "plane", "rotate"), EXACT, "rotate");
    for (const std::pair<std::string, Vec3>& q : queries(*r, "plane")) {
        close(vec(p.to_local(q.second)), nums(*r, q.first, "remap"), EXACT, q.first + " to_local");
        close(vec(p.closest_point(q.second)), nums(*r, q.first, "closest"), EXACT, q.first + " closest_point");
        close({p.distance_to(q.second)}, nums(*r, q.first, "distance"), EXACT, q.first + " distance_to");
    }
}

static void fit_matches_rhino_and_refuses_in_the_librarys_words() {
    std::vector<Vec3> line = {{0, 0, 0}, {1, 1, 1}, {2, 2, 2}};
    refused(Frame::fit(line), "frame_fit: the points lie on one line", "points on one line");
    refused(Frame::fit({{0, 0, 0}, {1, 0, 0}}), "frame_fit: needs three points", "two points");
    refused(Frame::fit({}), "frame_fit: needs three points", "no points");
    const Records* r = vectors();
    if (!r) return;
    std::vector<double> flat = nums(*r, "fit", "points");
    std::vector<Vec3> pts;
    for (std::size_t k = 0; k + 2 < flat.size(); k += 3) pts.push_back(v3(flat, k));
    std::pair<Frame, double> fitted = must(Frame::fit(pts), "Frame::fit");
    const Frame& got = fitted.first;
    Frame want = frame_of(nums(*r, "fit", "frame"));
    Vec3 gz = got.z();
    Vec3 wz = want.z();
    double sign = gz[0] * wz[0] + gz[1] * wz[1] + gz[2] * wz[2] < 0 ? -1.0 : 1.0;
    close({sign * gz[0], sign * gz[1], sign * gz[2]}, vec(wz), EXACT, "the fitted normal");
    close({want.distance_to(got.origin()), got.distance_to(want.origin())}, {0, 0}, EXACT, "the origins share the plane");
    close({fitted.second}, nums(*r, "fit", "deviation"), EXACT, "the deviation");
    refused(Frame::fit(std::vector<Vec3>(pts.begin(), pts.begin() + 2)), "frame_fit: needs three points", "two of the points");
}

// ---- 3. Curves --------------------------------------------------------------------------

static void a_bad_curve_is_refused_by_value_check() {
    refused(Circle::make(XY, 0), "value_check: the radius must be positive", "a zero radius");
    refused(Line::make({1, 1, 1}, {1, 1, 1}), "value_check: the line has no length", "a point line");
    refused(Arc::make(XY, 1, {0, 7}), "value_check: the angle must increase by at most a full turn", "past a full turn");
    refused(Arc::make(XY, 1, iv(1, 0)), "value_check: the angle must increase by at most a full turn", "a decreasing angle");
    refused(Ellipse::make(XY, 3, -1), "value_check: the second radius must be positive", "a negative radius");
    const Frame12 skew = {0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1};
    refused(Circle::make(skew, 1), "value_check: the frame is not right-handed and orthonormal", "a skew frame");
    refused(Circle::from_array(std::vector<double>(XY.begin(), XY.end())), "value_check: a circle is 13 numbers, got 12",
            "12 numbers for a circle");
    // 1e-7 off square is squared up, not refused.
    const Frame12 near = {0, 0, 0, 1, 1e-7, 0, 0, 1, 0, 0, 0, 1};
    Circle squared = must(Circle::make(near, 1), "a near-square frame");
    Vec3 x = squared.frame().x();
    Vec3 y = squared.frame().y();
    check(std::fabs(x[0] * y[0] + x[1] * y[1] + x[2] * y[2]) < 1e-15 && x[1] != 0, "1e-7 off square is squared up");
}

static void each_curve_call_answers_b1s_figures() {
    Circle unit = must(Circle::make(XY, 1), "unit circle");
    close(vec(must(unit.point_at(PI / 2), "point_at")), {0, 1, 0}, 1e-15, "unit.point_at(pi/2)");
    close(vec(must(unit.tangent_at(0), "tangent_at")), {0, 1, 0}, 1e-15, "unit.tangent_at(0)");
    Line line = must(Line::make({0, 0, 0}, {1, 2, 3}), "line");
    check(must(line.point_at(0.5), "point_at") == Vec3{0.5, 1.0, 1.5}, "line.point_at(0.5)");
    check(must(line.length(), "length") == std::sqrt(14.0), "line.length");
    check(line.start() == Vec3{0, 0, 0} && line.end() == Vec3{1, 2, 3}, "line.start and end");
    double s14 = std::sqrt(14.0);
    close(vec(must(line.tangent_at(0), "tangent_at")), {1 / s14, 2 / s14, 3 / s14}, 1e-15, "line.tangent_at");
    Arc quarter = must(Arc::make(XY, 2, {0, PI / 2}), "quarter");
    check(must(quarter.length(), "length") == PI && quarter.angle() == iv(0, PI / 2), "quarter length and angle");
    close(vec(must(quarter.start(), "start")), {2, 0, 0}, 1e-15, "quarter.start");
    close(vec(must(quarter.end(), "end")), {0, 2, 0}, 1e-15, "quarter.end");
    close(vec(must(quarter.mid(), "mid")), {std::sqrt(2.0), std::sqrt(2.0), 0}, 1e-15, "quarter.mid");
    // On the axis the foot is a pick: t = 0, not unique.
    check(must(unit.closest_point({2, 0, 5}), "closest_point") == CurveFoot{0.0, {1.0, 0.0, 0.0}, true}, "off the axis");
    check(must(unit.closest_point({0, 0, 5}), "closest_point") == CurveFoot{0.0, {1.0, 0.0, 0.0}, false}, "on the axis: a pick");
    check(approx(must(unit.distance_to({2, 0, 5}), "distance_to"), std::sqrt(26.0)), "unit.distance_to");
    std::pair<Vec3, Vec3> box = must(must(Line::make({1, 5, 0}, {0, 2, 3}), "line").bounds(), "bounds");
    check(box.first == Vec3{0, 2, 0} && box.second == Vec3{1, 5, 3}, "a line's bounds");
    check(rel(must(must(Ellipse::make(XY, 3, 1), "ellipse").length(), "length"), 13.364893220555258, 1e-12), "an ellipse's perimeter");
}

static void curve_constructors_and_transforms() {
    Vec3 a = {1, 0, 0};
    Vec3 b = {0, 1, 0};
    Vec3 c = {-1, 0, 0};
    std::vector<double> xy1 = vec(XY);
    xy1.push_back(1);
    std::vector<double> half = xy1;
    half.push_back(0);
    half.push_back(PI);
    close(must(Circle::through(a, b, c), "Circle::through").values(), xy1, 1e-15, "Circle::through");
    close(must(Arc::through(a, b, c), "Arc::through").values(), half, 1e-15, "Arc::through");
    close(must(Arc::from_start_tangent_end(a, {0, 1, 0}, c), "from_start_tangent_end").values(), half, 1e-15,
          "Arc::from_start_tangent_end");
    refused(Circle::through(a, a, c), "circle_through: the points are coincident or collinear", "coincident points");
    refused(Arc::from_start_tangent_end(a, {0, 0, 0}, c),
            "arc_from_start_tangent_end: the tangent is zero or the end lies on the tangent line", "a zero tangent");
    check(must(Ellipse::from_circle(must(Circle::make(XY, 2), "circle")), "from_circle") == must(Ellipse::make(XY, 2, 2), "ellipse"),
          "Ellipse::from_circle");
    Transform twice = must(Transform::scale({0, 0, 0}, 2), "scale");
    Circle unit = must(Circle::make(XY, 1), "circle");
    check(must(unit.transform(twice), "transform") == must(Circle::make(XY, 2), "circle"), "a circle scales");
    Transform stretch = must(Transform::scale_xyz(must(Frame::xy(), "xy"), 1, 3, 1), "scale_xyz");
    refused(unit.transform(stretch), "value_transform: a circle takes only a similarity (use ellipse_from_circle)", "a stretched circle");
    Ellipse e = must(must(Ellipse::from_circle(unit), "from_circle").transform(stretch), "transform");
    close({e.r1(), e.r2()}, {3, 1}, 1e-15, "the stretched circle's radii");
    Line moved = must(must(Line::make({0, 0, 0}, {1, 0, 0}), "line").transform(must(Transform::translation({0, 0, 2}), "t")), "transform");
    check(moved == must(Line::make({0, 0, 2}, {1, 0, 2}), "line"), "a moved line");
}

static void values_are_hashable_and_hold_their_array() {
    Circle c = must(Circle::make(YZX, 2), "circle");
    std::vector<double> want = vec(YZX);
    want.push_back(2);
    check(c.values() == want && c.radius() == 2.0 && c.frame() == must(Frame::of(YZX), "of"), "the circle's array and fields");
    check(c.kind() == bs::VALUE_CIRCLE, "the circle's kind");
    Circle same = must(Circle::make(must(Frame::of(YZX), "of"), 2.0), "circle");
    check(c == same && std::hash<Circle>()(c) == std::hash<Circle>()(same), "equal circles, equal hashes");
    Sphere sphere = must(Sphere::make(YZX, 2), "sphere");
    check(c.values() == sphere.values(), "a circle and a sphere with the same numbers");
    check(c != sphere && !(c == sphere), "a circle never equals a sphere with the same numbers");
    std::unordered_set<Circle> set = {c, same};
    check(set.size() == 1, "a set holds one of two equal circles");
    static_assert(std::is_same<decltype(std::declval<const Circle&>().values()), const std::vector<double>&>::value,
                  "the array is read only");
    static_assert(!std::is_default_constructible<Circle>::value, "a value comes from a checked maker");
}

static void lines_circles_and_arcs_match_rhino() {
    const Records* r = vectors();
    if (!r) return;
    std::vector<double> ends = nums(*r, "line", "ends");
    Line line = must(Line::make(v3(ends, 0), v3(ends, 3)), "line");
    close({must(line.length(), "length")}, nums(*r, "line", "length"), EXACT, "line length");
    close(vec(must(line.tangent_at(0.5), "tangent_at")), nums(*r, "line", "tangent"), EXACT, "line tangent");
    for (int k = 0; k < 5; ++k) {
        std::vector<double> n = nums(*r, "line_at_" + std::to_string(k), "point");
        close(vec(must(line.point_at(n[0]), "point_at")), {n[1], n[2], n[3]}, EXACT, "line_at_" + std::to_string(k));
    }
    for (const std::pair<std::string, Vec3>& q : queries(*r, "line")) {
        close(vec(must(line.closest_point(q.second), "closest_point").point), nums(*r, q.first, "closest"), EXACT, q.first);
    }

    Circle circle = must(Circle::make(raw12(nums(*r, "circle", "frame")), nums(*r, "circle", "radius")[0]), "circle");
    close({must(circle.length(), "length")}, nums(*r, "circle", "length"), EXACT, "circle length");
    for (int k = 0; k < 5; ++k) {
        std::string c = "circle_at_" + std::to_string(k);
        std::vector<double> n = nums(*r, c, "point");
        close(vec(must(circle.point_at(n[0]), "point_at")), {n[1], n[2], n[3]}, EXACT, c);
        close(vec(must(circle.tangent_at(n[0]), "tangent_at")), {n[4], n[5], n[6]}, EXACT, c + " tangent");
    }
    for (const std::pair<std::string, Vec3>& q : queries(*r, "circle")) {
        std::vector<double> w = nums(*r, q.first, "closest");
        CurveFoot foot = must(circle.closest_point(q.second), "closest_point");
        check(foot.unique, q.first + ": unique");
        close({foot.t}, {pymod(w[0], 2 * PI)}, EXACT, q.first + " t");
        close(vec(foot.point), {w[1], w[2], w[3]}, EXACT, q.first);
    }

    Arc arc = must(Arc::make(raw12(nums(*r, "arc", "frame")), nums(*r, "arc", "radius")[0],
                             {nums(*r, "arc", "angle")[0], nums(*r, "arc", "angle")[1]}),
                   "arc");
    close({must(arc.length(), "length")}, nums(*r, "arc", "length"), EXACT, "arc length");
    for (int k = 0; k < 4; ++k) {
        std::string c = "arc_at_" + std::to_string(k);
        std::vector<double> n = nums(*r, c, "point");
        close(vec(must(arc.point_at(n[0]), "point_at")), {n[1], n[2], n[3]}, EXACT, c);
        close(vec(must(arc.tangent_at(n[0]), "tangent_at")), {n[4], n[5], n[6]}, EXACT, c + " tangent");
    }
    for (const std::pair<std::string, Vec3>& q : queries(*r, "arc")) {
        std::vector<double> w = nums(*r, q.first, "closest");
        CurveFoot foot = must(arc.closest_point(q.second), "closest_point");
        close({foot.t}, {w[0]}, EXACT, q.first + " t");
        close(vec(foot.point), {w[1], w[2], w[3]}, EXACT, q.first);
    }
}

static std::optional<CurveValue> value_of(const bs::Edge& e) {
    if (!e.curve) {
        check(false, "edge " + std::to_string(e.index) + " has no curve");
        return std::nullopt;
    }
    return must(e.curve->value(), "Curve::value");
}

static void an_edges_curve_is_its_value() {
    Solid cylinder = must(Solid::cylinder(5, 3), "cylinder");
    for (const bs::Edge& rim : must(cylinder.edges(), "edges")) {
        if (rim.kind != "circle") continue;
        std::optional<CurveValue> v = value_of(rim);
        const Circle* c = v ? std::get_if<Circle>(&*v) : nullptr;
        check(c != nullptr, "a cylinder's rim is a Circle");
        if (!c) continue;
        double z = c->frame().origin()[2];
        check(approx(c->radius(), 5) && (within(z, 0, 1e-12) || within(z, 3, 1e-12)), "the rim's radius and height");
    }
    Solid box = must(Solid::cuboid(2, 4, 6), "cuboid");
    for (const bs::Edge& e : must(box.edges(), "edges")) {
        std::optional<CurveValue> v = value_of(e);
        const Line* l = v ? std::get_if<Line>(&*v) : nullptr;
        check(l != nullptr, "a cuboid's edge is a Line");
        if (!l) continue;
        for (const Vec3& end : {l->start(), l->end()}) {
            bool found = false;
            for (const std::array<Vec3, 2>& seg : e.segments) found = found || dist(seg[0], end) < 1e-9 || dist(seg[1], end) < 1e-9;
            check(found, "a line's end is one of its edge's points");
        }
    }
    Solid cube = must(Solid::cuboid(10, 10, 10), "cube");
    std::vector<std::uint32_t> upright;
    for (const bs::Edge& e : must(cube.edges(), "edges")) {
        std::optional<Vec3> d = e.direction();
        if (d && std::fabs(std::fabs((*d)[2]) - 1) < 1e-9) upright.push_back(e.index);
    }
    check(!upright.empty(), "the cube has upright edges");
    if (upright.empty()) return;
    Solid rounded = must(cube.fillet({upright[0]}, 2.0), "fillet");
    int arcs = 0;
    for (const bs::Edge& e : must(rounded.edges(), "edges")) {
        if (e.kind != "circle") continue;
        ++arcs;
        std::optional<CurveValue> v = value_of(e);
        const Arc* a = v ? std::get_if<Arc>(&*v) : nullptr;
        check(a != nullptr, "a fillet's edge is an Arc");
        if (!a) continue;
        check(approx(a->radius(), 2) && approx(a->angle().length(), PI / 2), "the fillet arc's radius and quarter turn");
        std::vector<Vec3> vertices = {e.segments.front()[0], e.segments.back()[1]};
        Vec3 start = must(a->start(), "start");
        Vec3 end = must(a->end(), "end");
        bool start_on = false;
        bool end_on = false;
        for (const Vec3& p : vertices) {
            start_on = start_on || dist(start, p) < 1e-9;
            end_on = end_on || dist(end, p) < 1e-9;
        }
        check(start_on && end_on, "the arc ends on its edge's vertices");
    }
    check(arcs == 2, "the fillet has two arc edges, got " + std::to_string(arcs));
    bs::Profile spline = must(bs::Profile::spline({{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, std::nullopt, true), "spline");
    Solid sweep = must(Solid::extrude(spline, must(Frame::xy(), "xy"), 2), "extrude");
    int splines = 0;
    for (const bs::Edge& e : must(sweep.edges(), "edges")) {
        if (e.kind != "nurbs") continue;
        ++splines;
        check(!value_of(e).has_value(), "a spline edge has no value");
    }
    check(splines > 0, "the extruded spline has spline edges");
}

// ---- 4. Surfaces ------------------------------------------------------------------------

static void a_bad_surface_is_refused_by_value_check() {
    refused(Cylinder::make(XY, 1, {2, 1}), "value_check: the height must increase", "a decreasing height");
    refused(Torus::make(XY, 1, 1), "value_check: the minor radius must be less than the major", "a fat torus");
    refused(Cone::make(XY, 1, 0), "value_check: the height must be positive", "a flat cone");
    refused(Sphere::make(XY, std::numeric_limits<double>::quiet_NaN()), "value_check: not finite", "a NaN radius");
}

static void each_surface_call_answers_b1s_figures() {
    Sphere sphere = must(Sphere::make(XY, 2), "sphere");
    close(vec(must(sphere.point_at(0, PI / 2), "point_at")), {0, 0, 2}, 1e-15, "the sphere's pole");
    Cylinder cyl = must(Cylinder::make(XY, 1, {-1, 2}), "cylinder");
    check(cyl.height() == iv(-1, 2), "the cylinder's height");
    close(vec(must(cyl.normal_at(PI / 2, 0), "normal_at")), {0, 1, 0}, 1e-15, "the cylinder's normal");
    Torus torus = must(Torus::make(XY, 3, 1), "torus");
    close(vec(must(torus.point_at(0, 0), "point_at")), {4, 0, 0}, 1e-15, "the torus' outer point");
    SurfaceFoot foot = must(sphere.closest_point({0, 0, 5}), "closest_point");
    check(foot.unique, "the pole's foot is unique");
    close({foot.u, foot.v, foot.point[0], foot.point[1], foot.point[2]}, {0, PI / 2, 0, 0, 2}, 1e-15, "the pole's foot");
    check(!must(sphere.closest_point({0, 0, 0}), "closest_point").unique, "the centre is a pick");
    check(approx(must(sphere.distance_to({0, 0, 5}), "distance_to"), 3), "sphere.distance_to");
    std::pair<Interval, Interval> d = must(cyl.domain(), "domain");
    check(d.first == iv(0, 2 * PI) && d.second == iv(-1, 2), "the cylinder's domain");
    std::pair<Interval, Interval> dc = must(must(Cone::make(XY, 1, 2), "cone").domain(), "domain");
    check(dc.first == iv(0, 2 * PI) && dc.second == iv(0, 2), "the cone's domain");
    check(std::fabs(must(sphere.volume(), "volume") - 32 * PI / 3) < 1e-13, "the sphere's volume");
    check(std::fabs(must(sphere.area(), "area") - 16 * PI) < 1e-13, "the sphere's area");
    check(must(torus.contains({3, 0, 0.5}), "contains"), "the torus holds a point in its tube");
    check(!must(sphere.contains({0, 0, 2.5}), "contains"), "the sphere does not hold a point outside");
    check(must(sphere.contains({0, 0, 2.5}, 0.5), "contains"), "within the tolerance counts");
    refused(sphere.contains({0, 0, 0}, -1), "solid_value_contains: the tolerance must be finite and not negative", "a negative tolerance");
    std::pair<Vec3, Vec3> box = must(sphere.bounds(), "bounds");
    check(box.first == Vec3{-2, -2, -2} && box.second == Vec3{2, 2, 2}, "the sphere's bounds");
    refused(sphere.transform(must(Transform::scale_xyz(must(Frame::xy(), "xy"), 1, 3, 1), "scale_xyz")),
            "value_transform: a sphere takes only a similarity", "a stretched sphere");
    Sphere moved = must(sphere.transform(must(Transform::translation({1, 0, 0}), "translation")), "transform");
    check(moved == must(Sphere::make(must(Frame::xy({1, 0, 0}), "xy"), 2), "sphere"), "a moved sphere");
    Solid sheet = must(cyl.to_nurbs_sheet(), "to_nurbs_sheet");
    check(sheet.faces() == 1, "the cylinder's sheet is one face");
}

static void solid_of_its_volume(const bs::SolidValue& shape, double volume, const std::string& what) {
    Solid solid = must(shape.to_solid(), what + " to_solid");
    check(rel(must(solid.mass(1e-9), "mass").volume, volume, 1e-6), what + ": the solid's volume");
    check(rel(must(shape.volume(), "volume"), volume, 1e-12), what + ": the value's volume");
}

static void each_shape_becomes_a_solid_of_its_volume() {
    solid_of_its_volume(must(Sphere::make(XY, 2), "sphere"), 32 * PI / 3, "sphere");
    solid_of_its_volume(must(Cylinder::make(XY, 1, {-1, 2}), "cylinder"), 3 * PI, "cylinder");
    solid_of_its_volume(must(Cone::make(XY, 1, 2), "cone"), 2 * PI / 3, "cone");
    solid_of_its_volume(must(Torus::make(XY, 3, 1), "torus"), 6 * PI * PI, "torus");
    solid_of_its_volume(must(Cuboid::make(YZX, {0, 1}, {0, 2}, {0, 3}), "cuboid"), 6.0, "cuboid");
}

static void spheres_tori_cylinders_and_cones_match_rhino() {
    const Records* r = vectors();
    if (!r) return;
    Sphere sphere = must(Sphere::make(raw12(nums(*r, "sphere", "frame")), nums(*r, "sphere", "radius")[0]), "sphere");
    for (const std::pair<std::string, Vec3>& q : queries(*r, "sphere")) {
        std::vector<double> w = nums(*r, q.first, "closest");
        SurfaceFoot foot = must(sphere.closest_point(q.second), "closest_point");
        close({foot.u, foot.v}, {pymod(w[0], 2 * PI), w[1]}, EXACT, q.first + " u v");
        close(vec(foot.point), {w[2], w[3], w[4]}, EXACT, q.first);
    }
    std::vector<double> radii = nums(*r, "torus", "radii");
    Torus torus = must(Torus::make(raw12(nums(*r, "torus", "frame")), radii[0], radii[1]), "torus");
    for (const std::pair<std::string, Vec3>& q : queries(*r, "torus")) {
        SurfaceFoot foot = must(torus.closest_point(q.second), "closest_point");
        check(foot.unique, q.first + ": unique");
        nurbs_foot(q.first, q.second, foot.point, v3(nums(*r, q.first, "closest")));
    }
    std::vector<double> h = nums(*r, "cylinder", "height");
    Cylinder cyl = must(Cylinder::make(raw12(nums(*r, "cylinder", "frame")), nums(*r, "cylinder", "radius")[0], {h[0], h[1]}), "cylinder");
    for (const std::pair<std::string, Vec3>& q : queries(*r, "cylinder")) {
        nurbs_foot(q.first, q.second, must(cyl.closest_point(q.second), "closest_point").point, v3(nums(*r, q.first, "closest")));
    }
    std::vector<double> size = nums(*r, "cone", "size");
    Cone cone = must(Cone::make(raw12(nums(*r, "cone", "frame")), size[0], size[1]), "cone");
    for (const std::pair<std::string, Vec3>& q : queries(*r, "cone")) {
        nurbs_foot(q.first, q.second, must(cone.closest_point(q.second), "closest_point").point, v3(nums(*r, q.first, "closest")));
    }
}

// ---- 5. Cuboid --------------------------------------------------------------------------

static void cuboid_construction_bounds_and_around() {
    Cuboid box = must(Cuboid::make(YZX, {0, 1}, {0, 2}, iv(0, 3)), "cuboid");
    check(box.x() == iv(0, 1) && box.y() == iv(0, 2) && box.z() == iv(0, 3), "the box's ranges");
    // x along world y (0..1), y along world z (0..2), z along world x (0..3), from (1, 2, 3).
    std::pair<Vec3, Vec3> b = must(box.bounds(), "bounds");
    check(b.first == Vec3{1, 2, 3} && b.second == Vec3{4, 3, 5}, "the turned box's bounds");
    check(must(Cuboid::from_bounds({0, 0, 0}, {1, 2, 3}), "from_bounds") == must(Cuboid::make(XY, {0, 1}, {0, 2}, {0, 3}), "cuboid"),
          "from_bounds");
    refused(Cuboid::from_bounds({0, 0, 0}, {1, 0, 3}), "cuboid_from_bounds: the bounds must increase along every axis", "flat bounds");
    refused(Cuboid::make(XY, {0, 1}, {2, 2}, {0, 1}), "value_check: the y range must increase", "an empty y range");
    std::vector<Vec3> pts = {{0, 0, 0}, {1, 2, 3}, {0.5, -1, 0.25}};
    check(must(Cuboid::around(must(Frame::xy(), "xy"), pts), "around") == must(Cuboid::make(XY, {0, 1}, {-1, 2}, {0, 3}), "cuboid"),
          "around");
    refused(Cuboid::around(XY, {{0, 0, 0}, {1, 1, 0}}), "cuboid_around: the points are flat along an axis of the frame", "flat points");
    refused(Cuboid::around(XY, {}), "cuboid_around: no points", "no points");
}

static void each_cuboid_call_answers_b1s_figures() {
    Cuboid box = must(Cuboid::make(XY, {0, 1}, {0, 2}, {0, 3}), "cuboid");
    check(must(box.area(), "area") == 22.0 && must(box.volume(), "volume") == 6.0, "area and volume");
    check(must(box.contains({0.5, 0.5, 0.5}), "contains"), "holds a point inside");
    check(!must(box.contains({1.5, 0.5, 0.5}, 0.4), "contains"), "not a point 0.5 out at 0.4");
    check(must(box.contains({1.5, 0.5, 0.5}, 0.5), "contains"), "a point 0.5 out at 0.5");
    Cuboid tilted = must(Cuboid::make(YZX, {0, 1}, {0, 2}, {0, 3}), "cuboid");
    check(must(tilted.closest_point({9, 9, 9}), "closest_point") == Vec3{4, 3, 5}, "the closest corner");
    close(vec(must(tilted.point_at(0.5, 0.5, 0.5), "point_at")), {2.5, 2.5, 4}, 1e-15, "the centre");
    std::array<Vec3, 8> corners = must(box.corners(), "corners");
    check(corners[0] == Vec3{0, 0, 0} && corners[2] == Vec3{1, 2, 0} && corners[6] == Vec3{1, 2, 3}, "corners 0, 2 and 6");
    Cuboid moved = must(box.transform(must(Transform::translation({0, 0, 1}), "translation")), "transform");
    std::pair<Vec3, Vec3> b = must(moved.bounds(), "bounds");
    check(b.first == Vec3{0, 0, 1} && b.second == Vec3{1, 2, 4}, "a moved box");
}

static void boxes_match_rhino() {
    const Records* r = vectors();
    if (!r) return;
    std::vector<double> ranges = nums(*r, "box", "ranges");
    Cuboid box = must(Cuboid::make(raw12(nums(*r, "box", "frame")), {ranges[0], ranges[1]}, {ranges[2], ranges[3]}, {ranges[4], ranges[5]}),
                      "box");
    std::vector<double> corners = nums(*r, "box", "corners");
    std::array<Vec3, 8> got = must(box.corners(), "corners");
    for (std::size_t k = 0; k < 8; ++k) close(vec(got[k]), {corners[3 * k], corners[3 * k + 1], corners[3 * k + 2]}, EXACT, "corner " + std::to_string(k));
    for (int k = 0; k < 4; ++k) {
        std::string c = "box_at_" + std::to_string(k);
        std::vector<double> n = nums(*r, c, "point");
        close(vec(must(box.point_at(n[0], n[1], n[2]), "point_at")), {n[3], n[4], n[5]}, EXACT, c);
    }
    for (const std::pair<std::string, Vec3>& q : queries(*r, "box")) {
        close(vec(must(box.closest_point(q.second), "closest_point")), nums(*r, q.first, "closest"), EXACT, q.first);
    }
}

// ---- 6. The rectangle, the triangle and the ray (plan B4, TestPlanarValues) --------------

static const std::array<double, 16> SHEAR = {1, 0.5, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};

static void a_rectangle_is_a_curve_with_calls_of_its_own() {
    Rectangle r = must(Rectangle::make(XY, {1, 4}, iv(0, 4)), "rectangle");
    check(r.x() == iv(1, 4) && r.y() == iv(0, 4) && r.frame() == must(Frame::of(XY), "xy"), "the rectangle's fields");
    const bs::CurveValueBase& curve = r;
    check(must(curve.point_at(2.25), "point_at") == Vec3{3.25, 4, 0} && must(r.point_at(9), "point_at") == Vec3{1, 0, 0},
          "point_at, clamped past 4");
    check(must(r.tangent_at(1.5), "tangent_at") == Vec3{0, 1, 0} && must(r.length(), "length") == 14.0, "tangent_at and length");
    check(must(r.closest_point({2, -1, 7}), "closest_point") == CurveFoot{1.0 / 3, {2, 0, 0}, true}, "the boundary's closest point");
    Rectangle square = must(Rectangle::make(XY, {0, 2}, {0, 2}), "rectangle");
    check(!must(square.closest_point({1, 1, 0}), "closest_point").unique, "the centre is a pick");
    std::array<Vec3, 4> corners = must(r.corners(), "corners");
    check(corners[0] == Vec3{1, 0, 0} && corners[1] == Vec3{4, 0, 0} && corners[2] == Vec3{4, 4, 0} && corners[3] == Vec3{1, 4, 0},
          "the corners");
    check(must(r.area(), "area") == 12.0, "the area");
    check(must(r.closest_point_in({2, 1, 5}), "closest_point_in") == Vec3{2, 1, 0}, "closest_point_in, filled");
    check(must(r.closest_point_in({2, 1, 5}, false), "closest_point_in") == Vec3{1, 1, 0}, "closest_point_in, the boundary");
    std::pair<Vec3, Vec3> b = must(r.bounds(), "bounds");
    check(b.first == Vec3{1, 0, 0} && b.second == Vec3{4, 4, 0}, "the bounds");
    refused(Rectangle::make(XY, {1, 1}, {0, 4}), "value_check: the x range must increase", "an empty x range");
    std::vector<double> fifteen = vec(XY);
    fifteen.insert(fifteen.end(), {1, 4, 0});
    refused(Rectangle::from_array(fifteen), "value_check: a rectangle is 16 numbers, got 15", "15 numbers");
    refused(r.transform(must(Transform::from_rows(SHEAR), "shear")),
            "value_transform: a rectangle takes only a map that keeps its sides square (no shear in its plane)", "a shear");
    Rectangle scaled = must(r.transform(must(Transform::scale_xyz(XY, 2, 3, 1), "scale_xyz")), "transform");
    check(scaled == must(Rectangle::make(XY, {2, 8}, {0, 12}), "rectangle"), "the scaled rectangle");
    Solid sheet = must(r.to_sheet(), "to_sheet");
    check(sheet.faces() == 1 && rel(must(sheet.mass(1e-9), "mass").area, 12.0, 1e-9), "the sheet");
    bs::NurbsCurve ring = must(r.to_nurbs(), "to_nurbs");
    std::pair<double, double> rd = must(ring.domain(), "domain");
    check(ring.degree() == 1 && ring.is_closed() && !ring.is_rational() && rd.first == 0 && rd.second == 4, "the boundary's curve");
    Vec3 rp = must(ring.point(2.25), "point");
    check(std::fabs(rp[0] - 3.25) + std::fabs(rp[1] - 4) + std::fabs(rp[2]) <= 1e-12, "its parameter is t");
}

static void rectangle_contains_takes_none_as_its_effective_tolerance_and_zero_as_exact() {
    Rectangle r = must(Rectangle::make(XY, {1, 4}, {0, 4}), "rectangle");  // diagonal 5: effective 5e-4
    check(must(r.contains({2, 2, 9}, 0.0), "contains") == "inside", "inside, exact");
    check(must(r.contains({0, 2, 0}, 0.0), "contains") == "outside", "outside, exact");
    check(must(r.contains({1, 2, 0}, 0.0), "contains") == "on", "on, exact");
    Vec3 near = {1 - 4e-4, 2, 0};
    check(must(r.contains(near, 0.0), "contains") == "outside" && must(r.contains(near, 1e-3), "contains") == "on", "named tolerances");
    check(must(r.contains(near), "contains") == "on" && must(r.contains(near, std::numeric_limits<double>::quiet_NaN()), "contains") == "on",
          "unset");
    check(must(r.contains({1 - 6e-4, 2, 0}), "contains") == "outside", "unset, past the effective tolerance");
    refused(r.contains({0, 0, 0}, -1.0), "rectangle_contains: the tolerance must be finite and not negative", "a negative tolerance");
    double eff = 1e-4 * 4 * std::sqrt(3.0);
    double nan = std::numeric_limits<double>::quiet_NaN();
    Sphere ball = must(Sphere::make(XY, 2), "sphere");
    check(must(ball.contains({2 + 0.9 * eff, 0, 0}, nan), "contains") && !must(ball.contains({2 + 0.9 * eff, 0, 0}), "contains") &&
              !must(ball.contains({2 + 1.1 * eff, 0, 0}, nan), "contains"),
          "a sphere's contains takes NaN as unset");
}

static void a_triangle_answers_its_closed_forms() {
    Triangle t = must(Triangle::make({0, 0, 0}, {4, 0, 0}, {0, 3, 0}), "triangle");
    check(t.a() == Vec3{0, 0, 0} && t.b() == Vec3{4, 0, 0} && t.c() == Vec3{0, 3, 0}, "the vertices");
    check(must(t.area(), "area") == 6.0 && must(t.perimeter(), "perimeter") == 12.0, "area and perimeter");
    close(vec(must(t.centroid(), "centroid")), {4.0 / 3, 1, 0}, 1e-15, "centroid");
    Circle cc = must(t.circumcircle(), "circumcircle");
    close(vec(cc.frame().origin()), {2, 1.5, 0}, 1e-15, "the circumcircle's centre");
    check(within(cc.radius(), 2.5, 1e-15), "the circumcircle's radius");
    check(must(t.point_at(0.5, 0.25, 0.25), "point_at") == Vec3{1, 0.75, 0}, "point_at");
    close(vec(must(t.barycentric({1, 0.75, 5}), "barycentric")), {0.5, 0.25, 0.25}, 1e-15, "barycentric");
    check(must(t.closest_point({2, -1, 0}), "closest_point") == Vec3{2, 0, 0} && must(t.closest_point({1, 1, 3}), "closest_point") == Vec3{1, 1, 0},
          "closest_point");
    check(must(t.distance_to({1, 1, 3}), "distance_to") == 3.0, "distance_to");
    check(must(t.edge(1), "edge") == must(Line::make({4, 0, 0}, {0, 3, 0}), "line"), "edge 1");
    refused(t.edge(3), "triangle_edge: edge 3 is not 0, 1 or 2", "edge 3");
    refused(Triangle::make({0, 0, 0}, {1, 1, 1}, {2, 2, 2}), "value_check: the triangle is degenerate (its points are collinear or coincident)",
            "a degenerate triangle");
    refused(Triangle::from_array({0, 0, 0, 4, 0, 0, 0, 3}), "value_check: a triangle is 9 numbers, got 8", "8 numbers");
    Triangle sheared = must(t.transform(must(Transform::from_rows(SHEAR), "shear")), "transform");
    check(sheared == must(Triangle::make({0, 0, 0}, {4, 0, 0}, {1.5, 3, 0}), "triangle"), "any affine map");
    Solid sheet = must(t.to_sheet(), "to_sheet");
    check(rel(must(sheet.mass(1e-9), "mass").area, 6.0, 1e-9), "the sheet's area");
    Triangle reordered = must(Triangle::make({0, 0, 0}, {0, 3, 0}, {4, 0, 0}), "triangle");
    Triangle again = must(Triangle::make(t.a(), t.b(), t.c()), "triangle");
    check(t != reordered && std::hash<Triangle>()(t) == std::hash<Triangle>()(again), "equality and hashing");
}

static void a_ray_holds_to_its_half_line_only_in_closest_point() {
    Ray ray = must(Ray::make({1, 2, 3}, {0, 0, 2}), "ray");
    check(ray.values() == std::vector<double>{1, 2, 3, 0, 0, 2} && ray.position() == Vec3{1, 2, 3} && ray.direction() == Vec3{0, 0, 2},
          "kept as given");
    check(must(ray.point_at(1.5), "point_at") == Vec3{1, 2, 6} && must(ray.point_at(-1), "point_at") == Vec3{1, 2, 1}, "point_at");
    check(must(ray.closest_point({5, 2, 7}), "closest_point") == CurveFoot{2, {1, 2, 7}, true}, "the closest point");
    check(must(ray.closest_point({5, 2, -7}), "closest_point") == CurveFoot{0, {1, 2, 3}, true}, "behind: the start");
    check(within(must(ray.distance_to({5, 2, -7}), "distance_to"), std::sqrt(116.0), 1e-12), "distance_to");
    refused(ray.bounds(), "value_bounds: a ray has no box (it is unbounded)", "a ray's bounds");
    refused(Ray::make({0, 0, 0}, {0, 0, 0}), "value_check: the ray's direction is zero", "a zero direction");
    refused(Ray::from_array({0, 0, 0, 1, 0, 0, 0}), "value_check: a ray is 6 numbers, got 7", "7 numbers");
    Ray scaled = must(ray.transform(must(Transform::scale_xyz(XY, 1, 1, 3), "scale_xyz")), "transform");
    check(scaled == must(Ray::make({1, 2, 9}, {0, 0, 6}), "ray"), "the scaled ray");
}

static void rectangles_triangles_and_rays_match_rhino() {
    const Records* r = vectors();
    if (!r) return;
    std::vector<double> ranges = nums(*r, "rectangle", "ranges");
    Rectangle rect = must(Rectangle::make(raw12(nums(*r, "rectangle", "frame")), {ranges[0], ranges[1]}, {ranges[2], ranges[3]}), "rectangle");
    std::vector<double> corners = nums(*r, "rectangle", "corners");
    std::array<Vec3, 4> got = must(rect.corners(), "corners");
    for (std::size_t k = 0; k < 4; ++k) close(vec(got[k]), {corners[3 * k], corners[3 * k + 1], corners[3 * k + 2]}, EXACT, "corner " + std::to_string(k));
    close({must(rect.area(), "area"), must(rect.length(), "length")}, {nums(*r, "rectangle", "area")[0], nums(*r, "rectangle", "circumference")[0]},
          EXACT, "area and circumference");
    for (int k = 0; k < 9; ++k) {
        std::string c = "rectangle_at_" + std::to_string(k);
        std::vector<double> n = nums(*r, c, "point");
        close(vec(must(rect.point_at(n[0]), "point_at")), {n[1], n[2], n[3]}, EXACT, c);
    }
    std::map<std::string, std::string> said = {{"Inside", "inside"}, {"Outside", "outside"}, {"Coincident", "on"}};
    for (const char* shape : {"rectangle", "rectangle_in"}) {
        for (const std::pair<std::string, Vec3>& q : queries(*r, shape)) {
            close(vec(must(rect.closest_point(q.second), "closest_point").point), nums(*r, q.first, "boundary"), EXACT, q.first + " boundary");
            close(vec(must(rect.closest_point_in(q.second, true), "closest_point_in")), nums(*r, q.first, "filled"), EXACT, q.first + " filled");
            check(must(rect.contains(q.second, 0.0), "contains") == said[words(*r, q.first, "contains")[0]], q.first + " contains");
        }
    }
    std::vector<double> p = nums(*r, "triangle", "points");
    Triangle tri = must(Triangle::make(v3(p, 0), v3(p, 3), v3(p, 6)), "triangle");
    close({must(tri.area(), "area"), must(tri.perimeter(), "perimeter")}, {nums(*r, "triangle", "area")[0], nums(*r, "triangle", "perimeter")[0]},
          EXACT, "area and perimeter");
    close(vec(must(tri.centroid(), "centroid")), nums(*r, "triangle", "centroid"), EXACT, "centroid");
    close(must(tri.circumcircle(), "circumcircle").values(), nums(*r, "triangle", "circumcircle"), EXACT, "circumcircle");
    for (const char* shape : {"triangle", "triangle_in"}) {
        for (const std::pair<std::string, Vec3>& q : queries(*r, shape)) {
            Vec3 w = must(tri.barycentric(q.second), "barycentric");
            std::vector<double> rw = nums(*r, q.first, "barycentric");
            close({w[1], w[2]}, {rw[0], rw[1]}, EXACT, q.first + " barycentric");
            close(vec(must(tri.point_at(w[0], w[1], w[2]), "point_at")), nums(*r, q.first, "projected"), EXACT, q.first + " projected");
            if (std::min(w[0], std::min(w[1], w[2])) < 0) {
                close(vec(must(tri.closest_point(q.second), "closest_point")), nums(*r, q.first, "boundary"), EXACT, q.first + " closest");
            }
        }
    }
    std::vector<double> rn = nums(*r, "ray", "ray");
    Ray ray = must(Ray::make(v3(rn, 0), v3(rn, 3)), "ray");
    for (int k = 0; k < 4; ++k) {
        std::string c = "ray_at_" + std::to_string(k);
        std::vector<double> n = nums(*r, c, "point");
        close(vec(must(ray.point_at(n[0]), "point_at")), {n[1], n[2], n[3]}, EXACT, c);
    }
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
        void (*run)();
    };
    const Test tests[] = {
        {"interval_measures_keep_the_orientation", interval_measures_keep_the_orientation},
        {"interval_set_operations_answer_increasing", interval_set_operations_answer_increasing},
        {"interval_parameters_round_trip", interval_parameters_round_trip},
        {"interval_is_a_hashable_value", interval_is_a_hashable_value},
        {"interval_matches_rhino", interval_matches_rhino},
        {"plane_verbs_match_rhino", plane_verbs_match_rhino},
        {"fit_matches_rhino_and_refuses_in_the_librarys_words", fit_matches_rhino_and_refuses_in_the_librarys_words},
        {"a_bad_curve_is_refused_by_value_check", a_bad_curve_is_refused_by_value_check},
        {"each_curve_call_answers_b1s_figures", each_curve_call_answers_b1s_figures},
        {"curve_constructors_and_transforms", curve_constructors_and_transforms},
        {"values_are_hashable_and_hold_their_array", values_are_hashable_and_hold_their_array},
        {"lines_circles_and_arcs_match_rhino", lines_circles_and_arcs_match_rhino},
        {"an_edges_curve_is_its_value", an_edges_curve_is_its_value},
        {"a_bad_surface_is_refused_by_value_check", a_bad_surface_is_refused_by_value_check},
        {"each_surface_call_answers_b1s_figures", each_surface_call_answers_b1s_figures},
        {"each_shape_becomes_a_solid_of_its_volume", each_shape_becomes_a_solid_of_its_volume},
        {"spheres_tori_cylinders_and_cones_match_rhino", spheres_tori_cylinders_and_cones_match_rhino},
        {"cuboid_construction_bounds_and_around", cuboid_construction_bounds_and_around},
        {"each_cuboid_call_answers_b1s_figures", each_cuboid_call_answers_b1s_figures},
        {"boxes_match_rhino", boxes_match_rhino},
        {"a_rectangle_is_a_curve_with_calls_of_its_own", a_rectangle_is_a_curve_with_calls_of_its_own},
        {"rectangle_contains_takes_none_as_its_effective_tolerance_and_zero_as_exact",
         rectangle_contains_takes_none_as_its_effective_tolerance_and_zero_as_exact},
        {"a_triangle_answers_its_closed_forms", a_triangle_answers_its_closed_forms},
        {"a_ray_holds_to_its_half_line_only_in_closest_point", a_ray_holds_to_its_half_line_only_in_closest_point},
        {"rectangles_triangles_and_rays_match_rhino", rectangles_triangles_and_rays_match_rhino},
    };
    for (const Test& t : tests) {
        int before = failures;
        t.run();
        std::printf("%s %s\n", failures == before ? "ok  " : "FAIL", t.name);
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("values: ok\n");
    return 0;
}
