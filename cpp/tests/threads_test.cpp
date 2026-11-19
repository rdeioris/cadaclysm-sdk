// Threads -- thread_sizes, thread_size, thread, thread_tool, cosmetic_thread, thread_record(s) and
// the tapped hole (HoleOptions::thread) -- at parity with the Python reference's tests in
// test_cadaclysm_blacksmith.py. A test of its own: each modelled thread is a cut along a coil and
// takes a minute or two, which on top of curve_sheets ran past ctest's ten-minute limit. The
// kernel's own correctness is the kernel's tests' job. Needs the kernel library and a license; the
// exit code is the verdict.
//
//     cadaclysm_threads_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Drilled;
using bs::Solid;

static int failures = 0;
static const double PI = 3.14159265358979323846;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// A value the test cannot go on without: a refusal here is a failure of the test, not of a check.
template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

static std::string num(double v) { return std::to_string(v); }

static double volume_of(const Solid& s) { return must(s.mass(), "mass").volume; }

static bool near(double got, double want, double rel) { return std::abs(got - want) <= rel * std::abs(want); }

// A `w` by `d` by `h` block centred at (x, y, z).
static Solid block(double w, double d, double h, double x, double y, double z) {
    return must(must(Solid::cuboid(w, d, h), "cuboid").translate(x, y, z), "translate");
}

// 6b+: threads -- the size table, a modelled M10 on a rod, a tapped M8, a cosmetic round trip;
// the literals Python's suite pins
static Result<void> threads_the_table_a_rod_a_tapped_hole_and_a_cosmetic_record() {
    std::vector<bs::ThreadSize> sizes = must(bs::thread_sizes(), "thread_sizes");
    check(sizes.size() == 108 && sizes.front().designation == "M1" && sizes.back().designation == "1-1/2-12 UNF" &&
              sizes.back().size == "1-1/2" && sizes.back().family == bs::ThreadFamily::unf && sizes.back().clearance.empty(),
          "thread_sizes: " + std::to_string(sizes.size()) + " rows");
    bs::ThreadSize m10 = must(bs::thread_size("M10"), "thread_size");
    const std::map<std::string, double> clearance = {{"fine", 10.5}, {"medium", 11.0}, {"coarse", 12.0}};
    check(m10.family == bs::ThreadFamily::iso_metric_coarse && m10.designation == "M10" && m10.size == "M10" && m10.major == 10.0 &&
              m10.pitch == 1.5 && m10.tap_drill == 8.5 && std::abs(m10.minor - (10 - 1.25 * std::sqrt(3.0) / 2 * 1.5)) < 1e-12 &&
              m10.clearance == clearance,
          "thread_size M10");
    check(must(bs::thread_size("1/4-20"), "1/4-20").designation == "1/4-20 UNC" &&
              must(bs::thread_size("m10 x 1.25"), "m10 x 1.25").designation == "M10x1.25",
          "thread_size: the forgiving lookup");
    Result<bs::ThreadSize> nothing = bs::thread_size("M7x9");
    check(!nothing.ok() && nothing.error().message == "thread_size_find: \"M7x9\" is not a size in the table", "thread_size M7x9 refusal");

    Solid rod = must(Solid::cylinder(5, 12), "rod");
    std::uint32_t cyl = 0;
    while (must(rod.face_kind(cyl), "face_kind") != "cylinder") ++cyl;
    bs::Threaded threaded = must(rod.thread(cyl, std::string("M10")), "thread");
    const double removed = PI * 25 * 12 - must(threaded.solid.mass(1e-4), "mass").volume;
    check(near(removed, 160.77942917686894, 1e-4), "thread removed " + num(removed));
    const bs::ThreadReport& tr = threaded.report;
    check(!tr.internal && tr.major == 10 && tr.pitch == 1.5 && std::abs(tr.length - 12) < 1e-9 && std::abs(tr.turns - 10) < 1e-9 &&
              std::abs(tr.start[2]) < 1e-9 && std::abs(tr.direction[2] - 1) < 1e-9 && tr.faces_added > 0,
          "thread report");
    Solid coil = must(rod.thread_tool(cyl, m10.designation), "thread_tool");
    check(volume_of(coil) > 0, "thread_tool volume");

    Solid blk = block(40, 30, 20, 20, 15, 10);
    bs::HoleOptions tapped_options;
    tapped_options.thread = "M8";
    Drilled tapped = must(blk.hole({{10, 15, 20}}, 0, tapped_options), "tapped hole");
    const double bored = 24000 - must(tapped.solid.mass(1e-4), "mass").volume;
    check(near(bored, 833.1391195130168, 1e-4), "tapped hole removed " + num(bored));
    check(tapped.report.holes == 1 && tapped.report.thread_depths.size() == 1 && std::abs(tapped.report.thread_depths[0] - 20) < 1e-9,
          "tapped hole report");
    bs::HoleOptions bare_options = tapped_options;
    bare_options.thread_modelled = false;
    Drilled bare = must(blk.hole({{10, 15, 20}}, 0, bare_options), "untapped hole");
    std::vector<std::pair<std::uint32_t, bs::ThreadRecord>> recs = must(bare.solid.thread_records(), "thread_records");
    check(recs.size() == 1 && recs[0].second.designation == "M8" && recs[0].second.major == 8.0 && recs[0].second.pitch == 1.25 &&
              recs[0].second.internal && !recs[0].second.left_handed && std::abs(recs[0].second.length - 20) < 1e-9,
          "tapped hole, not modelled: its record");
    Solid bit = must(blk.hole_tool({{10, 15, 20}}, 0, tapped_options), "tapped hole_tool");
    check(volume_of(bit) > 0, "tapped hole_tool volume");
    Result<Drilled> off = blk.hole({{10, 15, 20}}, 9, tapped_options);
    check(!off.ok() && off.error().message == "hole_threaded: the diameter 9 is not in the thread's band [6.491, 7.188]",
          "tapped hole off the band: " + (off.ok() ? std::string("accepted") : off.error().message));

    bs::ThreadOptions marked_options;
    marked_options.length = 8.0;
    marked_options.offset = 1.0;
    marked_options.reverse = true;
    marked_options.left_handed = true;
    Solid marked = must(rod.cosmetic_thread(cyl, std::string("m10"), marked_options), "cosmetic_thread");
    std::optional<bs::ThreadRecord> rec = must(marked.thread_record(cyl), "thread_record");
    check(rec && rec->designation == "M10" && rec->major == 10.0 && rec->pitch == 1.5 && rec->length == 8.0 && rec->offset == 1.0 &&
              !rec->internal && rec->left_handed && rec->reverse && marked.faces() == rod.faces(),
          "cosmetic_thread round trip");
    check(must(marked.thread_records(), "thread_records").size() == 1, "thread_records of the marked rod");
    check(!must(rod.thread_record(cyl), "bare thread_record"), "a bare rod has a thread record");
    Result<bs::Threaded> unsized = rod.thread(cyl);
    check(!unsized.ok() && unsized.error().message == "thread: neither a size nor a pitch is given", "thread of no size refusal");
    bs::ThreadOptions past;
    past.length = 6.0;
    past.offset = 8.0;
    Result<Solid> beyond = rod.thread_tool(cyl, std::string("M10"), past);
    check(!beyond.ok() && beyond.error().message == "thread_tool: offset 8 and length 6 run past the face's length 12", "thread_tool past the face");
    Result<std::optional<bs::ThreadRecord>> gone = rod.thread_record(3);
    check(!gone.ok() && gone.error().message == "thread_record: face 3 is not one of the solid's 3", "thread_record of face 3");
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
    Result<void> outcome = threads_the_table_a_rod_a_tapped_hole_and_a_cosmetic_record();
    if (!outcome) {
        std::fprintf(stderr, "FAIL: threads_the_table_a_rod_a_tapped_hole_and_a_cosmetic_record: %s\n", outcome.error().message.c_str());
        ++failures;
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("threads: ok\n");
    return 0;
}
