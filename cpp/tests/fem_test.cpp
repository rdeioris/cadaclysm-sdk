// The FEM records, over rows built by hand: the branches no fixture in this repo
// reaches, and so the ones the smoke cannot cover.
//
// **Nothing here calls the library.** Every case is a `CadaclysmFemEdge`,
// `CadaclysmFemVertex` or census row filled in this file and pushed through the wrapper's
// own conversion, so the arithmetic and the field-for-field copy are tested as pure
// functions. What the fixtures cannot give us:
//
//   * an edge whose chain **breaks** -- every edge of every fixture body is one run, so
//     `chains()` could ship off by one with every smoke assertion green (LuaJIT's did);
//   * `closed == true` and `seam == true`;
//   * a vertex with `has_position == false`;
//   * a **non-empty** open or folded census row: every fixture is either closed and
//     clean, where both censuses are empty, or an open sheet, where they are deliberately
//     "not asked" -- so the row extraction itself is never exercised.
//
// Both headers are checked, not one: each declares its own copy of these types over its
// own C structs, so a slip in one is invisible from the other.
#include <cadaclysm/cadaclysm.hpp>
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cstdio>
#include <cstdint>
#include <string>
#include <vector>

namespace bs = cadaclysm::blacksmith;

static int failures = 0;

static void check(bool ok, const char* what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++failures;
}

// The two headers' FemEdge/FemVertex are distinct types over distinct C structs, so each
// case is written once as a template and run twice.
template <class Raw, class Edge, class Convert>
static void edge_cases(Convert convert, const char* side) {
    std::string s(side);
    // Three runs: the node chain 10..16 broken at 0, 3 and 5. The last run reaches the
    // end of `nodes` -- the off-by-one every `chains()` gets wrong first.
    const std::uint32_t nodes[] = {10, 11, 12, 13, 14, 15, 16};
    const std::uint32_t runs[] = {0, 3, 5};
    Raw raw{};
    raw.id = 4711;
    raw.nodes = nodes;
    raw.node_count = 7;
    raw.runs = runs;
    raw.run_count = 3;
    raw.face_a = 0;
    raw.face_b = 6;
    raw.end_a = 2;
    raw.end_b = 0;
    raw.closed = false;
    raw.seam = false;
    Edge edge = convert(raw);

    // Every field, by name: a swap of two same-typed neighbours (face_b for end_a, say)
    // is a bug no fixture-driven check would see, both being a uint32 in range.
    check(edge.id == 4711, (s + ": id is not the raw id").c_str());
    check(edge.nodes.size() == 7 && edge.nodes[0] == 10 && edge.nodes[6] == 16, (s + ": nodes is not the raw chain").c_str());
    check(edge.runs.size() == 3 && edge.runs[0] == 0 && edge.runs[1] == 3 && edge.runs[2] == 5,
          (s + ": runs is not the raw run list").c_str());
    check(edge.faces.first == 0 && edge.faces.second == 6, (s + ": faces is not (face_a, face_b)").c_str());
    check(edge.ends.first == 2 && edge.ends.second == 0, (s + ": ends is not (end_a, end_b)").c_str());
    check(!edge.closed && !edge.seam, (s + ": closed or seam is set where the row says false").c_str());

    // The arithmetic: [0, 3), [3, 5), [5, 7). One chain too few, one node too many, or a
    // last run cut at `runs.back()` instead of at the end all fail here.
    std::vector<cadaclysm::Span<const std::uint32_t>> chains = edge.chains();
    check(chains.size() == 3, (s + ": chains() did not give one polyline per run").c_str());
    if (chains.size() == 3) {
        check(chains[0].size() == 3 && chains[0][0] == 10 && chains[0][2] == 12, (s + ": chain 0 is not nodes[0..3)").c_str());
        check(chains[1].size() == 2 && chains[1][0] == 13 && chains[1][1] == 14, (s + ": chain 1 is not nodes[3..5)").c_str());
        check(chains[2].size() == 2 && chains[2][0] == 15 && chains[2][1] == 16, (s + ": chain 2 is not nodes[5..7)").c_str());
        std::size_t covered = 0;
        for (const cadaclysm::Span<const std::uint32_t>& chain : chains) covered += chain.size();
        check(covered == 7, (s + ": the chains do not cover every node exactly once").c_str());
    }

    // Two runs, to catch a walk that only ever reads `runs[i + 1]` correctly for three.
    const std::uint32_t two[] = {0, 4};
    raw.runs = two;
    raw.run_count = 2;
    std::vector<cadaclysm::Span<const std::uint32_t>> pair = convert(raw).chains();
    check(pair.size() == 2 && pair[0].size() == 4 && pair[1].size() == 3, (s + ": two runs did not split 4 + 3").c_str());

    // One run: the ordinary answer, the whole chain.
    const std::uint32_t one[] = {0};
    raw.runs = one;
    raw.run_count = 1;
    std::vector<cadaclysm::Span<const std::uint32_t>> whole = convert(raw).chains();
    check(whole.size() == 1 && whole[0].size() == 7 && whole[0][6] == 16, (s + ": one run is not the whole chain").c_str());

    // A closed seam edge: `closed` and `seam` true, both faces the same, `end_b` the NONE
    // sentinel because both ends are one vertex. The sentinel is the value a wrapper
    // "normalises" to 0 -- and 0 is a real face and a real vertex.
    raw.closed = true;
    raw.seam = true;
    raw.face_a = 3;
    raw.face_b = 3;
    raw.end_a = 0;
    raw.end_b = cadaclysm::NONE;
    Edge closed = convert(raw);
    check(closed.closed && closed.seam, (s + ": closed or seam did not survive the copy").c_str());
    check(closed.faces.first == 3 && closed.faces.second == 3, (s + ": a seam's two faces are not one face").c_str());
    check(closed.ends.first == 0 && closed.ends.second == cadaclysm::NONE,
          (s + ": a closed edge's ends are not (0, NONE) -- 0 is a real vertex and NONE is not 0").c_str());

    // No chain at all, which the library does not produce: nothing is read past the end.
    Raw empty{};
    empty.id = 1;
    Edge none = convert(empty);
    check(none.nodes.empty() && none.runs.empty() && none.chains().empty(),
          (s + ": a row with null arrays did not come back empty").c_str());
}

template <class Raw, class Vertex, class Convert>
static void vertex_cases(Convert convert, const char* side) {
    std::string s(side);
    Raw raw{};
    raw.node = 12;
    raw.point[0] = 1.5;
    raw.point[1] = -2.25;
    raw.point[2] = 3.125;
    raw.has_position = true;
    Vertex placed = convert(raw);
    check(placed.node == 12, (s + ": node is not the raw node").c_str());
    check(placed.point[0] == 1.5 && placed.point[1] == -2.25 && placed.point[2] == 3.125,
          (s + ": point is not the raw three doubles, in order").c_str());
    check(placed.has_position, (s + ": has_position did not survive the copy").c_str());

    // The branch no fixture reaches: a vertex every trim meets as a curve with no
    // geometry, reported as the flag rather than as a plausible (0, 0, 0). A wrapper that
    // dropped the flag leaves a solver a node at the origin.
    Raw missing{};
    missing.node = cadaclysm::NONE;
    missing.has_position = false;
    Vertex nowhere = convert(missing);
    check(nowhere.node == cadaclysm::NONE, (s + ": a vertex with no node does not read NONE").c_str());
    check(!nowhere.has_position, (s + ": has_position is true where the row says false").c_str());
    check(nowhere.point[0] == 0.0 && nowhere.point[1] == 0.0 && nowhere.point[2] == 0.0,
          (s + ": a vertex with no position carries a point that is not zeroed").c_str());
}

// The census rows, over a synthetic reader: `census_rows` is shared by `open_edges` and
// `folded_edges`, and no fixture in this repo has a row for either to read.
static void census_cases() {
    const std::array<std::uint32_t, 3> want[] = {{7, 8, 41}, {8, 9, cadaclysm::NONE}, {0, 1, 0}};
    auto row = [&](std::uint32_t i, std::uint32_t* a, std::uint32_t* b, std::uint32_t* brep_edge) {
        *a = want[i][0];
        *b = want[i][1];
        *brep_edge = want[i][2];
        return true;
    };
    auto fail = [](std::uint32_t i) { return cadaclysm::Error{"row " + std::to_string(i)}; };
    cadaclysm::Result<std::vector<std::array<std::uint32_t, 3>>> rows = cadaclysm::detail::census_rows(3, row, fail);
    check(rows.ok(), "census: three good rows came back as a failure");
    if (rows.ok()) {
        const std::vector<std::array<std::uint32_t, 3>>& got = rows.value();
        check(got.size() == 3, "census: not one row per count");
        // In order, and each row (a, b, brep_edge) rather than any other permutation of
        // three uint32s -- including the NONE where the two nodes share no edge, and the
        // `0` that is a real edge and not a sentinel.
        bool same = got.size() == 3;
        for (std::size_t i = 0; same && i < 3; ++i) same = got[i] == want[i];
        check(same, "census: the rows are not (a, b, brep_edge), in order");
    }

    // A refused row is the wrapper's error, not a short list quietly returned.
    auto refuse = [](std::uint32_t i, std::uint32_t*, std::uint32_t*, std::uint32_t*) { return i < 1; };
    cadaclysm::Result<std::vector<std::array<std::uint32_t, 3>>> stopped =
        cadaclysm::detail::census_rows(4, refuse, fail);
    check(!stopped.ok(), "census: a refused row came back as success");
    if (!stopped.ok()) check(stopped.error().message == "row 1", "census: the refusal does not name the row that failed");

    // Zero rows is an empty list, not a failure: the ordinary answer for a clean body.
    cadaclysm::Result<std::vector<std::array<std::uint32_t, 3>>> empty =
        cadaclysm::detail::census_rows(0, row, fail);
    check(empty.ok() && empty.value().empty(), "census: no rows did not come back as an empty list");
}

int main() {
    edge_cases<CadaclysmFemEdge, cadaclysm::FemEdge>(
        [](const CadaclysmFemEdge& raw) { return cadaclysm::detail::fem_edge_of(raw); }, "reader FemEdge");
    edge_cases<CadaclysmBlacksmithFemEdge, bs::FemEdge>(
        [](const CadaclysmBlacksmithFemEdge& raw) { return bs::detail::fem_edge_of(raw); }, "kernel FemEdge");
    vertex_cases<CadaclysmFemVertex, cadaclysm::FemVertex>(
        [](const CadaclysmFemVertex& raw) { return cadaclysm::detail::fem_vertex_of(raw); }, "reader FemVertex");
    vertex_cases<CadaclysmBlacksmithFemVertex, bs::FemVertex>(
        [](const CadaclysmBlacksmithFemVertex& raw) { return bs::detail::fem_vertex_of(raw); }, "kernel FemVertex");
    census_cases();

    // The two ABIs' sentinels are one value, which is what lets a caller move a row
    // between the two sides without translating it.
    check(cadaclysm::NONE == bs::NONE, "the reader's NONE and the kernel's disagree");
    if (failures) {
        std::fprintf(stderr, "%d FEM record check(s) failed\n", failures);
        return 1;
    }
    std::puts("fem records: OK");
    return 0;
}
