// CAM over the release library: Python's test_cadaclysm_blacksmith.py, "machining:
// to_arcs, offset, section, and a CAM job", and the job tests after it, plus Go's and
// Rust's own "the four verbs by hand" fixture (commit 74b9553ec, ported to Rust in
// 0ac0df203 and to Swift in f2e1c18e5) -- machine() is one separate C entry point that
// never calls Job::face/contour/pocket/drill, so one test below drives those four
// wrapper methods' own argument order, side's outside/inside/on mapping and drill's
// point count over the real C ABI directly.
//
//     cadaclysm_blacksmith_cam_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm.hpp>
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <limits>
#include <optional>
#include <string>
#include <system_error>
#include <vector>

using cadaclysm::Error;
using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// `p` extruded by 1 and read back through Solid::bounds: (xMin, xMax, yMin, yMax), as
// Go's and Rust's own smoke/test fixtures measure a profile's footprint.
static Result<std::array<double, 4>> footprint(const bs::Profile& p) {
    CADACLYSM_TRY(frame, bs::Frame::xy());
    CADACLYSM_TRY(solid, bs::Solid::extrude(p, frame, 1.0));
    CADACLYSM_TRY(bounds, solid.bounds());
    return std::array<double, 4>{bounds.first[0], bounds.second[0], bounds.first[1], bounds.second[1]};
}

static Result<void> check_footprint(const bs::Profile& p, const std::array<double, 4>& expected,
                                    double tolerance = 1e-3) {
    CADACLYSM_TRY(got, footprint(p));
    for (int i = 0; i < 4; ++i) {
        check(std::fabs(got[i] - expected[i]) <= tolerance,
              "footprint[" + std::to_string(i) + "] is " + std::to_string(got[i]) + ", expected " +
                  std::to_string(expected[i]));
    }
    return {};
}

// A 40x30x10 block on z=0 with a 20x10 pocket 8 deep: four corners a 6 mm end mill
// misses.
static Result<bs::Solid> pocketed_block() {
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(40, 30, 10));
    CADACLYSM_TRY(block, cuboid.translate(0, 0, 5));
    CADACLYSM_TRY(pocket_cuboid, bs::Solid::cuboid(20, 10, 8));
    CADACLYSM_TRY(pocket, pocket_cuboid.translate(0, 0, 6));
    return block.cut(pocket);
}

// ---- the three geometry verbs --------------------------------------------------------

static Result<void> test_profile_offset_grows_and_shrinks_a_rectangle() {
    CADACLYSM_TRY(rect, bs::Profile::rect(20, 10));
    CADACLYSM_TRY(grown, rect.offset(2, 0.01));
    check(grown.size() == 1, "offset(2) is not one profile");
    if (grown.size() == 1) CADACLYSM_TRY_VOID(check_footprint(grown[0], {-12, 12, -7, 7}));
    CADACLYSM_TRY(shrunk, rect.offset(-2, 0.01));
    check(shrunk.size() == 1, "offset(-2) is not one profile");
    if (shrunk.size() == 1) CADACLYSM_TRY_VOID(check_footprint(shrunk[0], {-8, 8, -3, 3}));
    CADACLYSM_TRY(eaten, rect.offset(-6, 0.01));
    check(eaten.empty(), "offset(-6) is not empty");
    Result<std::vector<bs::Profile>> failed = rect.offset(std::numeric_limits<double>::quiet_NaN(), 0.01);
    check(!failed, "offset(NaN) was accepted");
    if (!failed) check(failed.error().message == "profile_offset: distance must be finite",
                       "offset(NaN) message is '" + failed.error().message + "'");
    return {};
}

static Result<void> test_profile_to_arcs_fits_a_spline_within_tolerance() {
    std::vector<bs::Vec2> points = {{0, 0}, {10, 0}, {10, 10}, {0, 10}};
    CADACLYSM_TRY(spline, bs::Profile::spline(points, 3, std::nullopt, true));
    CADACLYSM_TRY(fitted, spline.to_arcs(0.01));
    CADACLYSM_TRY(expected, footprint(spline));
    CADACLYSM_TRY_VOID(check_footprint(fitted, expected, 0.011));
    Result<bs::Profile> failed = spline.to_arcs(0);
    check(!failed, "to_arcs(0) was accepted");
    if (!failed) check(failed.error().message == "profile_to_arcs: tolerance must be positive and finite",
                       "to_arcs(0) message is '" + failed.error().message + "'");
    return {};
}

static Result<void> test_solid_section_cuts_a_cuboid() {
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(20, 10, 5));
    CADACLYSM_TRY(middle, cuboid.section(0, 0.05));
    check(middle.size() == 1, "section(0) is not one profile");
    if (middle.size() == 1) CADACLYSM_TRY_VOID(check_footprint(middle[0], {-10, 10, -5, 5}));
    CADACLYSM_TRY(miss, cuboid.section(50, 0.05));
    check(miss.empty(), "section(50) is not empty");
    Result<std::vector<bs::Profile>> failed = cuboid.section(2.5, 0.05);
    check(!failed, "section(2.5) (a face lying in the plane) was accepted");
    if (!failed) {
        check(failed.error().message == "solid_section: a face lies in the plane -- section a little above or below it",
              "section(2.5) message is '" + failed.error().message + "'");
    }
    return {};
}

// ---- the pocketed block: machine(), the report and operations() ----------------------

static Result<void> test_pocketed_block_reports_four_corners() {
    CADACLYSM_TRY(block, pocketed_block());
    CADACLYSM_TRY(end_mill, bs::Tool::flat(1, 6, 20, 800, 200, 12000));
    CADACLYSM_TRY(stock, bs::Stock::around(block, 2));
    CADACLYSM_TRY(job, bs::Job::make(stock, 30));
    CADACLYSM_TRY(report, job.machine(block, end_mill, {}, std::nullopt, std::nullopt, 0.3));
    check(report.items.size() == 4, "the report has " + std::to_string(report.items.size()) + " items, not 4");
    std::size_t lines = 1;
    for (char c : report.text) {
        if (c == '\n') ++lines;
    }
    check(lines == 4, "the report text has " + std::to_string(lines) + " lines, not 4");
    for (const bs::ReportItem& item : report.items) {
        check(item.kind == "corner", "a report item's kind is '" + item.kind + "', not 'corner'");
        check(item.size > 0, "a report item's size is not > 0");
        check(!item.region.empty(), "a report item's region is empty");
        check(!item.reason.empty(), "a report item's reason is empty");
    }
    CADACLYSM_TRY(ops, job.operations());
    check(!ops.empty(), "operations() is empty");
    for (const bs::Operation& op : ops) {
        check(!op.kind.empty(), "an operation's kind is empty");
        check(op.tool == 1, "an operation's tool is " + std::to_string(op.tool) + ", not 1");
        check(!op.params.empty(), "an operation's params are empty");
    }

    // A drill as the end mill is refused, and leaves the job as it was.
    CADACLYSM_TRY(drill, bs::Tool::drill(2, 5, 30, 150, 3000));
    CADACLYSM_TRY(fresh_stock, bs::Stock::around(block, 2));
    CADACLYSM_TRY(fresh, bs::Job::make(fresh_stock, 30));
    Result<bs::Report> refused = fresh.machine(block, drill, {}, std::nullopt, std::nullopt, 0.3);
    check(!refused, "a drill as the end mill was accepted");
    if (!refused) {
        check(refused.error().message.find("end mill must not be a drill") != std::string::npos,
              "the refusal does not say 'end mill must not be a drill': " + refused.error().message);
    }
    CADACLYSM_TRY(fresh_ops, fresh.operations());
    check(fresh_ops.empty(), "operations() is not empty after a refused machine()");
    return {};
}

// ---- the plate: an empty report, operations, gcode and write_camotics ----------------

static Result<void> test_the_plate_is_machined_cleanly() {
    CADACLYSM_TRY(plate_rect, bs::Profile::rect(80, 50));
    CADACLYSM_TRY(plate_outline, plate_rect.round(6));
    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(part0, bs::Solid::extrude(plate_outline, xy, 12));

    CADACLYSM_TRY(pocket_rect0, bs::Profile::rect(40, 24));
    CADACLYSM_TRY(pocket_rect, pocket_rect0.round(4));
    CADACLYSM_TRY(hole, bs::Profile::circle(5));
    CADACLYSM_TRY(pocket_outline, pocket_rect.with_hole(hole));
    CADACLYSM_TRY(pocket_frame, bs::Frame::xy({0, 0, 7}));
    CADACLYSM_TRY(pocket_solid, bs::Solid::extrude(pocket_outline, pocket_frame, 5));
    CADACLYSM_TRY(part1, part0.cut(pocket_solid));

    bs::Solid part = std::move(part1);
    const double bore_xy[4][2] = {{-32, -17}, {-32, 17}, {32, -17}, {32, 17}};
    for (const double (&xy_pos)[2] : bore_xy) {
        CADACLYSM_TRY(bore0, bs::Solid::cylinder(3, 12));
        CADACLYSM_TRY(bore, bore0.translate(xy_pos[0], xy_pos[1], 0));
        CADACLYSM_TRY(cut, part.cut(bore));
        part = std::move(cut);
    }

    CADACLYSM_TRY(end_mill, bs::Tool::flat(1, 6, 20, 800, 200, 12000));
    CADACLYSM_TRY(drill, bs::Tool::drill(2, 6, 30, 150, 3000));
    CADACLYSM_TRY(stock, bs::Stock::around(part, 3));
    CADACLYSM_TRY(job, bs::Job::make(stock, 25, 1.0, 0.01, "plate"));
    std::vector<const bs::Tool*> drills = {&drill};
    CADACLYSM_TRY(report, job.machine(part, end_mill, drills, std::nullopt, std::nullopt, 0.3));
    check(report.empty(), "the plate's report is not empty");
    check(report.text == "nothing left uncut", "the plate's report text is '" + report.text + "'");

    CADACLYSM_TRY(ops, job.operations());
    check(!ops.empty(), "the plate's operations() is empty");
    if (!ops.empty()) {
        check(ops.front().kind == "face", "the plate's first operation is '" + ops.front().kind + "', not 'face'");
        bool has_pocket = false;
        for (const bs::Operation& op : ops) has_pocket = has_pocket || op.kind == "pocket";
        check(has_pocket, "the plate's operations() has no 'pocket'");
        const bs::Operation& last = ops.back();
        check(last.kind == "drill", "the plate's last operation is '" + last.kind + "', not 'drill'");
        auto points_it = last.params.find("points");
        check(points_it != last.params.end() && points_it->second.has_value() && *points_it->second == 4.0,
              "the plate's drill 'points' param is not 4");
        auto peck_it = last.params.find("peck");
        check(peck_it != last.params.end(), "the plate's drill operation has no 'peck' param");
        if (peck_it != last.params.end()) check(!peck_it->second.has_value(), "the plate's drill 'peck' is not null");
    }

    CADACLYSM_TRY(programs, job.gcode());
    check(programs.size() == 2, "gcode() has " + std::to_string(programs.size()) + " programs, not 2");
    for (const bs::Program& p : programs) {
        check(p.tool >= 1, "a program's tool is 0");
        check(!p.name.empty(), "a program's name is empty");
        check(!p.text.empty(), "a program's text is empty");
    }

    std::error_code ec;
    std::filesystem::path dir = std::filesystem::temp_directory_path(ec) / "cadaclysm-cam-cpp-test";
    std::filesystem::path camotics = dir / "plate.camotics";
    CADACLYSM_TRY(written, job.write_camotics(camotics.string()));
    check(!written.empty(), "write_camotics returned no files");
    if (!written.empty()) {
        check(written.back().find("plate.camotics") != std::string::npos,
              "the last written file is '" + written.back() + "', not the project");
    }
    for (const std::string& w : written) {
        check(std::filesystem::exists(w), w + " was not written");
    }
    std::filesystem::remove_all(dir, ec);

    // A stem that is all extension (".camotics") stays whole, as Python's Path.stem keeps it.
    std::filesystem::path dot_dir = std::filesystem::temp_directory_path(ec) / "cadaclysm-cam-cpp-dot";
    CADACLYSM_TRY(dot_written, job.write_camotics((dot_dir / ".camotics").string()));
    check(dot_written.size() >= 2, "write_camotics to '.camotics' wrote fewer than two files");
    if (!dot_written.empty()) {
        std::string first = std::filesystem::path(dot_written.front()).filename().string();
        check(first.rfind(".camotics-T1", 0) == 0, "the stem of '.camotics' is not kept: " + first);
    }
    std::filesystem::remove_all(dot_dir, ec);

    // A NUL in a CAMotics stem, or in a name, is refused in the kernel's words before the
    // library is asked, and the stem's refusal makes no folder.
    const std::string nul_name = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |";
    Result<std::vector<std::string>> nul_stem = job.write_camotics(dir.string() + "/" + std::string("a\0b.camotics", 12));
    check(!nul_stem, "a NUL stem was accepted");
    if (!nul_stem) check(nul_stem.error().message == nul_name, "the NUL stem's refusal is '" + nul_stem.error().message + "'");
    check(!std::filesystem::exists(dir), "a refused stem made the folder");
    Result<bs::Job> nul_job = bs::Job::make(stock, 25, 1.0, 0.01, std::string("a\0b", 3));
    check(!nul_job, "a NUL name was accepted");
    if (!nul_job) check(nul_job.error().message == nul_name, "the NUL name's refusal is '" + nul_job.error().message + "'");
    return {};
}

// ---- the four verbs driven by hand: face, contour, pocket and drill on their own -----

// Ports Go's "four verbs by hand" fixture (commit 74b9553ec, also ported to Rust in
// 0ac0df203 and Swift in f2e1c18e5): machine() never calls Job::face/contour/pocket/
// drill, so this is the only test that drives their own argument order, side's outside/
// inside/on mapping and drill's point count over the real C ABI.
static Result<void> test_the_four_verbs_by_hand() {
    CADACLYSM_TRY(rect, bs::Profile::rect(60, 40));
    CADACLYSM_TRY(outline, rect.round(5));
    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(part, bs::Solid::extrude(outline, xy, 20));
    CADACLYSM_TRY(end, bs::Tool::flat(1, 6, 20, 800, 200, 12000));
    CADACLYSM_TRY(drill, bs::Tool::drill(2, 5, 30, 150, 3000));
    CADACLYSM_TRY(stock, bs::Stock::around(part, 2));
    CADACLYSM_TRY(job, bs::Job::make(stock, 30));

    CADACLYSM_TRY_VOID(job.face(end, 20, 3, 1));
    CADACLYSM_TRY_VOID(job.contour(end, outline, 20, 0, "outside", 2, true, false));
    CADACLYSM_TRY(levels, part.section(15, 0.05));
    check(!levels.empty(), "job: section(15) is empty");
    if (levels.empty()) return Error{"job: section(15) is empty, cannot continue"};
    CADACLYSM_TRY_VOID(job.pocket(end, levels[0], 20, 10, 2.4, 2));
    std::vector<bs::Vec2> points = {{10, 10}, {40, 10}};
    CADACLYSM_TRY_VOID(job.drill(drill, points, 20, -1, 3.0));

    CADACLYSM_TRY(programs, job.gcode());
    check(programs.size() == 2, "gcode() has " + std::to_string(programs.size()) + " programs, not 2");
    if (programs.size() == 2) {
        check(programs[0].tool == 1, "programs[0].tool is not 1");
        check(programs[0].name == "job-T1", "programs[0].name is '" + programs[0].name + "'");
        check(programs[0].text.rfind("(cadaclysm: job-T1, T1 flat D6)\n", 0) == 0,
              "programs[0].text does not start with the expected header: " + programs[0].text.substr(0, 60));
        check(programs[1].tool == 2, "programs[1].tool is not 2");
        check(programs[1].name == "job-T2", "programs[1].name is '" + programs[1].name + "'");
        check(programs[1].text.rfind("(cadaclysm: job-T2, T2 drill D5)\n", 0) == 0,
              "programs[1].text does not start with the expected header: " + programs[1].text.substr(0, 60));
    }

    CADACLYSM_TRY(ops, job.operations());
    check(ops.size() == 4, "operations() has " + std::to_string(ops.size()) + " entries, not 4");
    if (ops.size() == 4) {
        check(ops[0].kind == "face", "ops[0].kind is '" + ops[0].kind + "'");
        check(ops[1].kind == "contour", "ops[1].kind is '" + ops[1].kind + "'");
        check(ops[2].kind == "pocket", "ops[2].kind is '" + ops[2].kind + "'");
        check(ops[3].kind == "drill", "ops[3].kind is '" + ops[3].kind + "'");
        // job_side's mapping: "outside" is the library's own 0.
        auto side_it = ops[1].params.find("side");
        check(side_it != ops[1].params.end() && side_it->second.has_value() && *side_it->second == 0.0,
              "ops[1] (contour)'s 'side' param is not 0");
        const bs::Operation& drill_op = ops[3];
        auto peck_it = drill_op.params.find("peck");
        check(peck_it != drill_op.params.end() && peck_it->second.has_value() && *peck_it->second == 3.0,
              "the drill operation's 'peck' is not 3");
        auto points_it = drill_op.params.find("points");
        check(points_it != drill_op.params.end() && points_it->second.has_value() && *points_it->second == 2.0,
              "the drill operation's 'points' is not 2");
    }

    // A bad `side` is refused before the library is asked, and leaves the job unchanged.
    CADACLYSM_TRY(before_ops, job.operations());
    std::size_t before = before_ops.size();
    Result<void> bad_side = job.contour(end, outline, 20, 0, "left", 2, true, false);
    check(!bad_side, "a bad side ('left') was accepted");
    if (!bad_side) {
        check(bad_side.error().message == "side must be 'outside', 'inside' or 'on'",
              "the bad-side refusal is not Python's text: " + bad_side.error().message);
    }
    CADACLYSM_TRY(after_ops, job.operations());
    check(after_ops.size() == before, "a bad side changed the job's operation count");

    // A nullopt peck reads back as no peck at all through Job::drill directly, not only
    // through Job::machine (the plate fixture above covers that path).
    CADACLYSM_TRY(no_peck_job, bs::Job::make(stock, 30));
    std::vector<bs::Vec2> one_point = {{0, 0}};
    CADACLYSM_TRY_VOID(no_peck_job.drill(drill, one_point, 20, -1, std::nullopt));
    CADACLYSM_TRY(no_peck_ops, no_peck_job.operations());
    check(!no_peck_ops.empty(), "the no-peck job's operations() is empty");
    if (!no_peck_ops.empty()) {
        auto it = no_peck_ops[0].params.find("peck");
        check(it != no_peck_ops[0].params.end(), "the no-peck job's drill operation has no 'peck' key");
        if (it != no_peck_ops[0].params.end()) check(!it->second.has_value(), "the no-peck job's 'peck' is not null");
    }
    return {};
}

// ---- a closed job refuses every call --------------------------------------------------

static Result<void> test_a_closed_job_refuses_a_later_call() {
    CADACLYSM_TRY(stock, bs::Stock::box({-10, -10, -10}, {10, 10, 10}));
    CADACLYSM_TRY(job, bs::Job::make(stock, 20));
    check(!job.closed(), "a fresh job reports closed()");
    job.close();
    check(job.closed(), "close() did not mark the job closed");
    CADACLYSM_TRY(tool, bs::Tool::flat(1, 6, 20, 800, 200, 12000));
    Result<void> refused = job.face(tool, 0, 3, 1);
    check(!refused, "a closed job accepted face()");
    if (!refused) check(refused.error().message == "job: closed",
                        "the closed-job refusal is '" + refused.error().message + "', not 'job: closed'");
    // Idempotent: closing again does not crash.
    job.close();
    check(job.closed(), "a second close() left the job open");
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

    Result<void> outcome = test_profile_offset_grows_and_shrinks_a_rectangle();
    if (outcome) outcome = test_profile_to_arcs_fits_a_spline_within_tolerance();
    if (outcome) outcome = test_solid_section_cuts_a_cuboid();
    if (outcome) outcome = test_pocketed_block_reports_four_corners();
    if (outcome) outcome = test_the_plate_is_machined_cleanly();
    if (outcome) outcome = test_the_four_verbs_by_hand();
    if (outcome) outcome = test_a_closed_job_refuses_a_later_call();

    if (!outcome) {
        std::fprintf(stderr, "FAIL: %s\n", outcome.error().message.c_str());
        return 1;
    }
    if (failures) {
        std::fprintf(stderr, "%d CAM check(s) failed\n", failures);
        return 1;
    }
    std::puts("blacksmith_cam: OK");
    return 0;
}
