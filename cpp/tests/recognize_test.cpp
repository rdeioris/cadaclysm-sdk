// Canonical recognition -- Solid::recognize on the kernel and Brep::recognize on the reader --
// at parity with the Python reference's test_recognize_* in test_cadaclysm_blacksmith.py and
// test_brep_recognize_* in test_cadaclysm.py, with the same figures, plus their distinct-rows
// decoder test on each header's own decoder. The reader half opens box-union-sphere.3dm (a box
// unioned with a ball, every face stored as NURBS) and is skipped when the path is "-" or
// missing. The exit code is the verdict.
//
//     cadaclysm_recognize_test <box-union-sphere.3dm | -> [cadaclysm.lic]
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <string>

#if defined(_MSC_VER)
#pragma warning(disable : 4611)  // setjmp and C++ destruction: only trivially destructible locals cross it
#endif

// A closed solid is a bad access. The hook below turns it into a longjmp back to `trips`,
// so the test can see it (the default aborts).
namespace trap {
inline std::jmp_buf* where = nullptr;
inline std::string message;
}  // namespace trap
#define CADACLYSM_BAD_ACCESS(text) \
    (::trap::message = (text), ::trap::where ? std::longjmp(*::trap::where, 1) : std::abort())

#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// The value of a call the test cannot go on without; anything else ends the run.
template <class T>
static T must(Result<T> r, const char* what) {
    if (!r) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what, r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// Whether `f` reached CADACLYSM_BAD_ACCESS.
template <class F>
static bool trips(F&& f) {
    std::jmp_buf buffer;
    trap::where = &buffer;
    trap::message.clear();
    if (setjmp(buffer) == 0) {
        f();
        trap::where = nullptr;
        return false;
    }
    trap::where = nullptr;
    return true;
}

// pytest.approx(rel=1e-6).
static bool approx(double a, double b) { return std::fabs(a - b) <= 1e-6 * std::fabs(b); }

static std::string joined(const std::vector<std::string>& parts) {
    std::string out;
    for (const std::string& p : parts) out += (out.empty() ? "" : ", ") + p;
    return "[" + out + "]";
}

// ---- kernel: Solid ----------------------------------------------------------------------

static void a_nurbs_cylinder_comes_back_as_a_cylinder_and_two_planes() {
    bs::Solid cylinder = must(bs::Solid::cylinder(2, 5), "cylinder");
    bs::Solid nurbs = must(cylinder.convert_to_nurbs(bs::NurbsLevel::all), "convert_to_nurbs");
    std::pair<bs::Solid, bs::RecognizeReport> out = must(nurbs.recognize(), "recognize");
    const bs::Solid& back = out.first;
    const bs::RecognizeReport& report = out.second;
    check(back.handle() != nurbs.handle(), "the recognised solid is a new one");
    check(back.faces() == 3, std::to_string(back.faces()) + " faces, not 3");
    std::vector<std::string> kinds;
    std::vector<std::uint32_t> faces;
    for (const bs::RecognizedFace& f : report.faces) {
        kinds.push_back(f.kind);
        faces.push_back(f.face);
    }
    std::sort(kinds.begin(), kinds.end());
    std::sort(faces.begin(), faces.end());
    check(kinds == std::vector<std::string>{"cylinder", "plane", "plane"}, "face kinds " + joined(kinds));
    check(faces == std::vector<std::uint32_t>{0, 1, 2}, "faces 0, 1, 2");
    check(report.refused.empty(), std::to_string(report.refused.size()) + " refused, not 0");
    check(report.edges_left == 0, "edges_left " + std::to_string(report.edges_left));
    std::size_t circles = 0;
    for (const bs::RecognizedEdge& e : report.edges) {
        if (e.kind == "circle") ++circles;
        check(e.kind == "line" || e.kind == "circle", "an edge taken as " + e.kind);
    }
    check(circles >= 2, std::to_string(circles) + " circle edges, not at least 2");
    check(report.tolerance > 0 && report.worst_face <= report.tolerance && report.worst_edge <= report.tolerance,
          "tolerance " + std::to_string(report.tolerance) + ", worst face " + std::to_string(report.worst_face) + ", worst edge " +
              std::to_string(report.worst_edge));
    check(approx(must(back.mass(), "mass").volume, must(cylinder.mass(), "mass").volume), "the cylinder's volume");
    check(must(nurbs.recognize(0.5), "recognize(0.5)").second.tolerance == 0.5, "recognize(0.5) fits to 0.5");
}

static void an_analytic_body_has_nothing_to_take() {
    bs::Solid cylinder = must(bs::Solid::cylinder(2, 5), "cylinder");
    bs::RecognizeReport report = must(cylinder.recognize(), "recognize").second;
    check(report.faces.empty() && report.refused.empty(),
          std::to_string(report.faces.size()) + " taken and " + std::to_string(report.refused.size()) + " refused, not 0 and 0");
}

static void a_closed_solid_is_refused() {
    bs::Solid box = must(bs::Solid::cuboid(1, 1, 1), "cuboid");
    box.close();
    check(trips([&] { (void)box.recognize(); }) && trap::message.find("closed") != std::string::npos,
          "recognize on a closed solid: " + trap::message);
}

// ---- the decoders, over Python's distinct rows ----------------------------------------

static const std::uint32_t COUNTS[10] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 11};
static const double SIZES[3] = {0.5, 0.25, 0.125};

template <class Report>
static void check_recognize_rows(const Report& r, const char* who) {
    std::string w(who);
    check(r.tolerance == 0.5 && r.worst_face == 0.25 && r.worst_edge == 0.125 && r.edges_left == 11,
          w + ": tolerance, worst face, worst edge, edges left (" + std::to_string(r.edges_left) + ")");
    check(r.faces.size() == 2 && r.faces[0].face == 10 && r.faces[0].kind == "torus" && r.faces[0].deviation == 1.5 &&
              r.faces[1].face == 12 && r.faces[1].kind == "plane" && r.faces[1].deviation == 2.5,
          w + ": the faces");
    check(r.refused.size() == 2 && r.refused[0].face == 20 && r.refused[0].why == "no_kind" &&
              r.refused[0].closest == std::optional<double>(7.5) && r.refused[1].face == 21 && r.refused[1].why == "too_few_samples" &&
              !r.refused[1].closest.has_value(),
          w + ": the refusals");
    check(r.edges.size() == 3 && r.edges[0].edge == 30 && r.edges[0].kind == "ellipse" && r.edges[0].deviation == 0.75 &&
              r.edges[1].edge == 31 && r.edges[1].kind == "circle" && r.edges[1].deviation == 0.0625 && r.edges[2].edge == 32 &&
              r.edges[2].kind == "line" && r.edges[2].deviation == 0.03125,
          w + ": the edges");
}

static void the_kernel_decoder_reads_every_column_of_distinct_rows() {
    bs::RecognizeReport r = must(bs::detail::recognize_report(COUNTS, SIZES, {10, 4, 12, 0}, {1.5, 2.5}, {20, 0, 21, 3},
                                                              {7.5, std::nan("")}, {30, 2, 31, 1, 32, 0}, {0.75, 0.0625, 0.03125}),
                                 "recognize_report");
    check_recognize_rows(r, "recognize decoder (kernel)");
    check(!bs::detail::recognize_report(COUNTS, SIZES, {0, 5}, {0.5}, {}, {}, {}, {}).ok(), "recognize decoder (kernel): face kind 5 is refused");
}

static void the_reader_decoder_reads_every_column_of_distinct_rows() {
    cadaclysm::RecognizeReport r =
        must(cadaclysm::detail::recognize_report(COUNTS, SIZES, {10, 4, 12, 0}, {1.5, 2.5}, {20, 0, 21, 3}, {7.5, std::nan("")},
                                                 {30, 2, 31, 1, 32, 0}, {0.75, 0.0625, 0.03125}),
             "recognize_report");
    check_recognize_rows(r, "recognize decoder (reader)");
    check(!cadaclysm::detail::recognize_report(COUNTS, SIZES, {}, {}, {}, {}, {0, 3}, {0.5}).ok(),
          "recognize decoder (reader): edge kind 3 is refused");
}

// ---- reader: Brep, on box-union-sphere.3dm ----------------------------------------------

static std::string ball;
static int ball_ran = 0;

static void a_3dm_ball_comes_back_as_a_sphere_and_leaves_the_original() {
    if (ball.empty()) return;
    cadaclysm::Scene scene = must(cadaclysm::open(ball), "open box-union-sphere.3dm");
    std::optional<cadaclysm::Brep> first;
    for (const cadaclysm::Node& n : scene.nodes()) {
        first = n.brep();
        if (first) break;
    }
    check(first.has_value(), "box-union-sphere.3dm has a body");
    if (!first) return;
    cadaclysm::Brep& body = *first;
    std::pair<cadaclysm::Brep, cadaclysm::RecognizeReport> out = must(body.recognize(), "recognize");
    cadaclysm::Brep& back = out.first;
    const cadaclysm::RecognizeReport& report = out.second;
    check(back.pointer() != body.pointer(), "a new brep");
    std::vector<std::string> kinds;
    std::vector<std::uint32_t> faces;
    for (const cadaclysm::RecognizedFace& f : report.faces) {
        kinds.push_back(f.kind);
        faces.push_back(f.face);
    }
    check(std::find(kinds.begin(), kinds.end(), "sphere") != kinds.end() && std::find(kinds.begin(), kinds.end(), "plane") != kinds.end(),
          "face kinds " + joined(kinds));
    std::sort(faces.begin(), faces.end());
    check(std::adjacent_find(faces.begin(), faces.end()) == faces.end(), "every face once");
    double most = 0.0;
    for (const cadaclysm::RecognizedFace& f : report.faces) {
        check(f.deviation <= report.tolerance, "face " + std::to_string(f.face) + " lies within the tolerance");
        most = std::max(most, f.deviation);
    }
    for (const cadaclysm::RecognizedEdge& e : report.edges) {
        check(e.deviation <= report.tolerance, "edge " + std::to_string(e.edge) + " lies within the tolerance");
        // the edges named as the brep names them
        check(must(back.edge_tolerance(e.edge), "edge_tolerance").has_value(), "edge " + std::to_string(e.edge) + " has a tolerance");
    }
    check(report.worst_face == most, "worst_face " + std::to_string(report.worst_face) + " is the largest face deviation");
    back.release();
    check(must(body.recognize(0.25), "recognize(0.25)").second.tolerance == 0.25, "recognize(0.25) fits to 0.25");

    body.release();
    Result<std::pair<cadaclysm::Brep, cadaclysm::RecognizeReport>> gone = body.recognize();
    check(!gone.ok() && gone.error().message.find("released") != std::string::npos, "recognize on a released brep");
    ++ball_ran;
}

// The first body of `scene`'s recognize report, or none.
static std::optional<cadaclysm::RecognizeReport> first_report(const cadaclysm::Scene& scene) {
    for (const cadaclysm::Node& n : scene.nodes()) {
        std::optional<cadaclysm::Brep> body = n.brep();
        if (body) return must(body->recognize(), "recognize").second;
    }
    return std::nullopt;
}

static void recognize_tolerance_hands_out_analytic_bodies() {
    if (ball.empty()) return;
    // unasked the ball is still NURBS; asked, every body arrives already analytic
    cadaclysm::Scene plain = must(cadaclysm::open(ball), "open box-union-sphere.3dm");
    cadaclysm::OpenOptions asked_options;
    asked_options.recognize_tolerance = 1e-6;
    cadaclysm::Scene asked = must(cadaclysm::open(ball, asked_options), "open box-union-sphere.3dm, recognized");
    std::optional<cadaclysm::RecognizeReport> r0 = first_report(plain);
    std::optional<cadaclysm::RecognizeReport> r1 = first_report(asked);
    check(r0.has_value() && r1.has_value(), "box-union-sphere.3dm has a body");
    if (!r0 || !r1) return;
    bool sphere = false;
    for (const cadaclysm::RecognizedFace& f : r0->faces) sphere = sphere || f.kind == "sphere";
    check(sphere, "unasked: a sphere still to take");
    check(r1->faces.empty(), "asked: " + std::to_string(r1->faces.size()) + " faces still to take, not 0");
    cadaclysm::OpenOptions negative;
    negative.recognize_tolerance = -1.0;
    Result<cadaclysm::Scene> refused = cadaclysm::open(ball, negative);
    check(!refused.ok() && refused.error().message.find("recognize_tolerance") != std::string::npos,
          "a negative tolerance is refused by name");
}

int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) != "-") {
        if (std::filesystem::exists(argv[1])) ball = argv[1];
        else std::printf("recognize: %s not to hand, reader checks SKIPPED\n", argv[1]);
    } else {
        std::printf("recognize: no box-union-sphere.3dm given, reader checks SKIPPED\n");
    }
    if (argc > 2) {
        Result<void> loaded = bs::license(argv[2]);
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
        {"a_nurbs_cylinder_comes_back_as_a_cylinder_and_two_planes", a_nurbs_cylinder_comes_back_as_a_cylinder_and_two_planes},
        {"an_analytic_body_has_nothing_to_take", an_analytic_body_has_nothing_to_take},
        {"a_closed_solid_is_refused", a_closed_solid_is_refused},
        {"the_kernel_decoder_reads_every_column_of_distinct_rows", the_kernel_decoder_reads_every_column_of_distinct_rows},
        {"the_reader_decoder_reads_every_column_of_distinct_rows", the_reader_decoder_reads_every_column_of_distinct_rows},
        {"a_3dm_ball_comes_back_as_a_sphere_and_leaves_the_original", a_3dm_ball_comes_back_as_a_sphere_and_leaves_the_original},
        {"recognize_tolerance_hands_out_analytic_bodies", recognize_tolerance_hands_out_analytic_bodies},
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
    std::printf("recognize: ok (reader %s)\n", ball_ran == 1 ? "ran" : "SKIPPED");
    return 0;
}
