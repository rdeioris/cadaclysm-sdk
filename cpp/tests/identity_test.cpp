// Face and edge identity, history, attributes and edge and vertex references -- at parity with
// the Python reference's TestIdentity tests in test_cadaclysm_blacksmith.py (identity plan C3),
// trimmed to what proves the marshalling: every id, origin and history list read, none for an
// untracked id, attributes in key order and copied out whole, the fifteen-number edge
// reference, the merge step's origins, and every refusal's prefix. The kernel's own correctness
// is the kernel's tests' job. Needs the kernel library; the exit code is the verdict.
//
//     cadaclysm_identity_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::History;
using bs::IdOrigin;
using bs::Solid;

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

// The call must have been refused with exactly `message`.
template <class T>
static void refused_with(const Result<T>& r, const std::string& message, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    check(r.error().message == message, what + ": refused with \"" + r.error().message + "\", wanted \"" + message + "\"");
}

// The call must have been refused with a message starting `prefix`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted it to start \"" + prefix + "\"");
}

static std::string shown(const std::vector<IdOrigin>& o) {
    std::string out = "[";
    for (const IdOrigin& p : o) out += " (" + std::to_string(p.first) + ", " + std::to_string(p.second) + ")";
    return out + " ]";
}

static std::string shown(const std::optional<std::uint64_t>& id) { return id ? std::to_string(*id) : std::string("none"); }

static std::string shown(const History& h) {
    std::string out = "kept";
    for (const std::pair<IdOrigin, std::uint64_t>& k : h.kept) {
        out += " ((" + std::to_string(k.first.first) + ", " + std::to_string(k.first.second) + "), " + std::to_string(k.second) + ")";
    }
    out += "; modified";
    for (const std::pair<IdOrigin, std::vector<std::uint64_t>>& m : h.modified) {
        out += " ((" + std::to_string(m.first.first) + ", " + std::to_string(m.first.second) + ") ->";
        for (std::uint64_t o : m.second) out += " " + std::to_string(o);
        out += ")";
    }
    out += "; generated";
    for (std::uint64_t g : h.generated) out += " " + std::to_string(g);
    out += "; deleted " + shown(h.deleted);
    return out;
}

// A 10-cube centred on the origin and a pin through it (radius 2, along z, z -10..10), both
// tracked -- the kernel's oracle 2 cut.
static std::pair<Solid, Solid> block_and_pin() {
    Solid block = must(must(Solid::cuboid(10, 10, 10), "cuboid").tracked(), "tracked");
    Solid pin = must(must(must(Solid::cylinder(2, 20), "cylinder").translate(0, 0, -10), "translate").tracked(), "tracked");
    return std::pair<Solid, Solid>(std::move(block), std::move(pin));
}

// Face f's outward normal's z, off its reference.
static double nz(const Solid& s, std::uint32_t f) { return must(s.face_ref(f), "face_ref")[6]; }

static std::vector<Solid> split_xy(const Solid& s) {
    return must(s.split_by_plane(must(bs::Frame::xy(), "Frame::xy")), "split_by_plane");
}

static std::uint64_t id(const Solid& s, std::uint32_t f) {
    std::optional<std::uint64_t> got = must(s.face_id(f), "face_id");
    if (!got) {
        std::fprintf(stderr, "FAIL: face %u has no id\n", f);
        std::exit(1);
    }
    return *got;
}

static void tracking() {
    Solid plain = must(Solid::cuboid(1, 2, 3), "cuboid");
    check(!must(plain.is_tracked(), "is_tracked"), "a cuboid is untracked");
    check(!must(plain.face_id(0), "face_id"), "an untracked face has no id: " + shown(must(plain.face_id(0), "face_id")));
    check(!must(plain.edge_id(0), "edge_id"), "an untracked edge has no id");
    check(must(plain.face_origins(0), "face_origins").empty(), "an untracked face has no origins");
    Solid t = must(plain.tracked(), "tracked");
    check(must(t.is_tracked(), "is_tracked"), "tracked() tracks");
    check(must(must(t.tracked(), "tracked").face_id(5), "face_id") == std::optional<std::uint64_t>(6), "tracked() of a tracked solid keeps its ids");
    for (std::uint32_t f = 0; f < 6; ++f) {
        check(must(t.face_id(f), "face_id") == std::optional<std::uint64_t>(f + 1), "face " + std::to_string(f) + "'s id");
    }
    for (std::uint32_t e = 0; e < 12; ++e) {
        check(must(t.edge_id(e), "edge_id") == std::optional<std::uint64_t>(e + 1), "edge " + std::to_string(e) + "'s id");
    }
    check(must(t.face_with_id(4), "face_with_id") == std::optional<std::uint32_t>(3), "face_with_id(4)");
    check(!must(t.face_with_id(7), "face_with_id"), "face_with_id(7) is none");
    check(!must(t.face_with_id(0), "face_with_id"), "face_with_id(0) is none");
    check(must(t.edge_with_id(12), "edge_with_id") == std::optional<std::uint32_t>(11), "edge_with_id(12)");
    check(!must(t.edge_with_id(13), "edge_with_id"), "edge_with_id(13) is none");
    std::vector<IdOrigin> fo = must(t.face_origins(2), "face_origins");
    check(fo == std::vector<IdOrigin>{IdOrigin(0, 3)}, "face_origins(2): " + shown(fo));
    std::vector<IdOrigin> eo = must(t.edge_origins(11), "edge_origins");
    check(eo == std::vector<IdOrigin>{IdOrigin(0, 12)}, "edge_origins(11): " + shown(eo));
    refused_with(t.face_id(6), "face_id: face 6 of 6", "face_id(6)");
    refused_with(t.face_origins(6), "face_origin_count: face 6 of 6", "face_origins(6)");
    refused_with(t.edge_id(12), "edge_id: edge 12 of 12", "edge_id(12)");
}

static void a_cuts_origins_and_history() {
    std::pair<Solid, Solid> bp = block_and_pin();
    const Solid& block = bp.first;
    const Solid& pin = bp.second;
    std::uint32_t wall = bs::NONE;
    std::vector<IdOrigin> caps;
    for (std::uint32_t f = 0; f < pin.faces(); ++f) {
        if (must(pin.face_kind(f), "face_kind") == "cylinder") {
            wall = f;
        } else {
            caps.push_back(IdOrigin(1, id(pin, f)));
        }
    }
    check(wall != bs::NONE, "the pin has a wall");
    const std::uint64_t wall_id = id(pin, wall);
    Solid cut = must(block.cut(pin), "cut");
    std::uint32_t bore = bs::NONE;
    for (std::uint32_t f = 0; f < cut.faces(); ++f) {
        if (must(cut.face_kind(f), "face_kind") == "cylinder") bore = f;
    }
    check(bore != bs::NONE, "the cut has a bore");
    std::vector<IdOrigin> bo = must(cut.face_origins(bore), "face_origins");
    check(bo == std::vector<IdOrigin>{IdOrigin(1, wall_id)}, "the bore came from the pin's wall: " + shown(bo));
    check(must(cut.face_id(bore), "face_id") == std::optional<std::uint64_t>(7), "renumbered: the wall's id is the box's");
    for (std::uint32_t f = 0; f < cut.faces(); ++f) {
        if (f == bore) continue;
        std::vector<IdOrigin> o = must(cut.face_origins(f), "face_origins");
        check(o == std::vector<IdOrigin>{IdOrigin(0, id(cut, f))}, "face " + std::to_string(f) + " is the box's own: " + shown(o));
    }
    History h = must(cut.history({block, pin}), "history");
    std::vector<std::pair<IdOrigin, std::uint64_t>> six;
    for (std::uint64_t k = 1; k <= 6; ++k) six.push_back({IdOrigin(0, k), k});
    check(h.kept == six, "the box's six kept: " + shown(h));
    std::vector<std::pair<IdOrigin, std::vector<std::uint64_t>>> bored = {{IdOrigin(1, wall_id), {7}}};
    check(h.modified == bored, "the bore modified: " + shown(h));
    check(h.generated.empty(), "nothing generated: " + shown(h));
    check(h.deleted == caps, "the pin's two caps deleted: " + shown(h));
    History again = h;
    check(again == h && !(again != h), "a history equals its copy");
    History e = must(cut.edge_history({block, pin}), "edge_history");
    std::vector<IdOrigin> three = {IdOrigin(1, 1), IdOrigin(1, 2), IdOrigin(1, 3)};
    check(e.kept.size() == 12 && e.deleted == three && e.generated.size() == 3 && e.modified.empty(),
          "edge_history's shape: " + shown(e));
    Solid plain = must(Solid::cuboid(1, 1, 1), "cuboid");
    refused_with(cut.history({block, plain}), "history: input 1 is not tracked", "history of an untracked input");
    Result<History> one = cut.history({block});
    refused(one, "history: face ", "history with one input");
    if (!one) check(one.error().message.find(" names operand 1") != std::string::npos, "one input: " + one.error().message);
    refused_with(plain.edge_history({block}), "edge_history: the result is not tracked", "edge_history of an untracked result");
}

static void a_union_renumbers_the_second_operands_clashing_ids() {
    Solid a = must(must(Solid::cuboid(10, 10, 10), "cuboid").tracked(), "tracked");
    Solid b = must(must(must(Solid::cuboid(10, 10, 10), "cuboid").translate(5, 5, 5), "translate").tracked(), "tracked");
    Solid joined = must(a.join(b), "join");
    check(joined.faces() == 12, "the union has 12 faces");
    std::set<std::uint64_t> firsts;
    std::vector<std::uint64_t> own_seconds;
    std::set<std::uint64_t> named;
    for (std::uint32_t f = 0; f < joined.faces(); ++f) {
        std::vector<IdOrigin> o = must(joined.face_origins(f), "face_origins");
        if (o.empty()) {
            check(false, "face " + std::to_string(f) + " has no origin");
            continue;
        }
        const std::uint64_t own = id(joined, f);
        if (o[0].first == 0) {
            check(own == o[0].second, "operand 0's face keeps its id");
            firsts.insert(o[0].second);
        } else {
            own_seconds.push_back(own);
            named.insert(o[0].second);
        }
    }
    check(firsts == std::set<std::uint64_t>{1, 2, 3, 4, 5, 6}, "operand 0's six");
    check(own_seconds == std::vector<std::uint64_t>{7, 8, 9, 10, 11, 12}, "renumbered 7..12 in face order");
    check(named == std::set<std::uint64_t>{1, 2, 3, 4, 5, 6}, "their origins name operand 1's own ids");
}

static void a_split_halves_the_sides() {
    Solid block = must(must(Solid::cuboid(2, 4, 6), "cuboid").tracked(), "tracked");
    std::vector<Solid> pieces = split_xy(block);
    check(pieces.size() == 2, "two pieces");
    std::map<std::uint64_t, std::vector<std::uint64_t>> halves;
    for (std::uint32_t f = 0; f < 6; ++f) {
        if (std::fabs(nz(block, f)) < 0.5) halves[id(block, f)] = {};
    }
    check(halves.size() == 4, "four sides");
    int cut_faces = 0;
    int caps = 0;
    for (const Solid& p : pieces) {
        for (std::uint32_t f = 0; f < p.faces(); ++f) {
            std::vector<IdOrigin> o = must(p.face_origins(f), "face_origins");
            const std::uint64_t own = id(p, f);
            if (o.empty()) {
                check(own > 6, "a cut face is generated, with a fresh id");
                ++cut_faces;
            } else if (halves.count(o[0].second)) {
                check(o == std::vector<IdOrigin>{IdOrigin(0, o[0].second)}, "a half names its side: " + shown(o));
                halves[o[0].second].push_back(own);
            } else {
                check(o == std::vector<IdOrigin>{IdOrigin(0, own)}, "a cap is kept: " + shown(o));
                ++caps;
            }
        }
    }
    check(cut_faces == 2 && caps == 2, "two cut faces and two caps");
    for (const std::pair<const std::uint64_t, std::vector<std::uint64_t>>& s : halves) {
        check(s.second.size() == 2 && std::count(s.second.begin(), s.second.end(), s.first) == 1,
              "side " + std::to_string(s.first) + " in two, one half keeping its id");
    }
    for (const Solid& p : pieces) {
        History h = must(p.history({block}), "history");
        check(h.generated.size() == 1 && h.deleted.size() == 1, "a piece's history: " + shown(h));
    }
}

static void a_fillets_round_is_generated() {
    Solid block = must(must(Solid::cuboid(10, 10, 10), "cuboid").tracked(), "tracked");
    Solid rounded = must(block.fillet({0}, 1.0), "fillet");
    check(rounded.faces() == 7, "seven faces");
    std::uint32_t round = bs::NONE;
    for (std::uint32_t f = 0; f < rounded.faces(); ++f) {
        if (must(rounded.face_kind(f), "face_kind") != "plane") round = f;
    }
    check(round != bs::NONE, "a round");
    check(must(rounded.face_origins(round), "face_origins").empty(), "the round has no origin");
    check(must(rounded.face_id(round), "face_id") == std::optional<std::uint64_t>(7), "the round's id is 7");
    History h = must(rounded.history({block}), "history");
    check(h.generated == std::vector<std::uint64_t>{7} && h.kept.size() == 6, "the round generated: " + shown(h));
    check(!must(rounded.edge_with_id(1), "edge_with_id"), "the rounded edge is gone");
}

static void a_flush_join_merged_names_one_origin_per_input() {
    Solid a = must(must(Solid::cuboid(10, 10, 10), "cuboid").tracked(), "tracked");
    Solid b = must(must(must(Solid::cuboid(4, 10, 10), "cuboid").translate(7, 0, 0), "translate").tracked(), "tracked");
    Solid merged = must(a.join(b, bs::DEFAULT_TOLERANCE, {}, true), "join merged");
    check(merged.faces() == 6, "six faces");
    int two = 0;
    for (std::uint32_t f = 0; f < merged.faces(); ++f) {
        std::vector<IdOrigin> o = must(merged.face_origins(f), "face_origins");
        if (std::fabs(must(merged.face_ref(f), "face_ref")[4]) < 0.5) {
            const bool both = o.size() == 2 && o[0].first == 0 && o[1].first == 1;
            check(both, "face " + std::to_string(f) + " along x: " + shown(o));
            if (both) {
                check(must(a.face_with_id(o[0].second), "face_with_id").has_value() && must(b.face_with_id(o[1].second), "face_with_id").has_value(),
                      "both origins found on their inputs: " + shown(o));
            }
            ++two;
        } else {
            check(o.size() == 1, "an end has one origin: " + shown(o));
        }
    }
    check(two == 4, "four faces along x");
    History h = must(merged.history({a, b}), "history");
    check(h.generated.empty() && h.deleted.size() == 2, "the two flush faces deleted: " + shown(h));
    std::size_t ones = 0;
    for (const std::pair<IdOrigin, std::vector<std::uint64_t>>& m : h.modified) {
        if (m.first.first == 1 && m.second.size() == 1) ++ones;
    }
    check(ones == 4, "operand 1's four sides merged: " + shown(h));
}

static std::pair<std::vector<std::optional<std::uint64_t>>, std::vector<std::optional<std::uint64_t>>> chain() {
    std::pair<Solid, Solid> bp = block_and_pin();
    Solid cut = must(bp.first.cut(bp.second), "cut");
    std::vector<bs::Edge> edges = must(cut.edges(), "edges");
    std::uint32_t line = bs::NONE;
    for (const bs::Edge& e : edges) {
        if (e.is_line()) {
            line = e.index;
            break;
        }
    }
    Solid r = must(cut.fillet({line}, 1.0), "fillet");
    std::vector<std::optional<std::uint64_t>> faces;
    for (std::uint32_t f = 0; f < r.faces(); ++f) faces.push_back(must(r.face_id(f), "face_id"));
    std::vector<std::optional<std::uint64_t>> edge_ids;
    const std::uint32_t n = static_cast<std::uint32_t>(must(r.edges(), "edges").size());
    for (std::uint32_t e = 0; e < n; ++e) edge_ids.push_back(must(r.edge_id(e), "edge_id"));
    return {faces, edge_ids};
}

static void the_same_chain_twice_numbers_the_same() {
    std::pair<std::vector<std::optional<std::uint64_t>>, std::vector<std::optional<std::uint64_t>>> first = chain();
    bool all = true;
    for (const std::optional<std::uint64_t>& i : first.first) all = all && i.has_value();
    for (const std::optional<std::uint64_t>& i : first.second) all = all && i.has_value();
    check(all, "every face and edge has an id");
    check(first == chain(), "the same chain numbers the same");
}

static std::string listed(const std::map<std::string, std::string>& m) {
    std::string out;
    for (const std::pair<const std::string, std::string>& kv : m) out += kv.first + "=" + kv.second + ";";
    return out;
}

static void attributes() {
    Solid s = must(must(Solid::cuboid(1, 2, 3), "cuboid").with_attribute("material", "steel"), "with_attribute");
    check(must(s.is_tracked(), "is_tracked"), "an attribute rides with the ids");
    check(must(s.attribute("material"), "attribute") == std::optional<std::string>("steel"), "attribute(material)");
    check(!must(s.attribute("absent"), "attribute"), "an absent attribute is none");
    check(listed(must(s.attributes(), "attributes")) == "material=steel;", "attributes: " + listed(must(s.attributes(), "attributes")));
    Solid both = must(s.with_attributes({{"zeta", "1"}, {"alpha", "2"}}), "with_attributes");
    const std::string order = listed(must(both.attributes(), "attributes"));
    check(order == "alpha=2;material=steel;zeta=1;", "listed in key order: " + order);
    const std::string text = "acciaio inossidabile \xc3\xa8 \xe2\x98\x83 \xf0\x9f\x94\xa7";
    check(must(must(s.with_attribute("m", text), "with_attribute").attribute("m"), "attribute") == std::optional<std::string>(text),
          "non-ASCII round-trips");
    check(must(must(s.with_attribute("empty", ""), "with_attribute").attribute("empty"), "attribute") == std::optional<std::string>(""),
          "an empty value round-trips");
    refused_with(s.with_attribute("", "x"), "with_attribute: the key is empty", "an empty key");
    check(listed(must(must(s.without_attribute("absent"), "without_attribute").attributes(), "attributes")) == "material=steel;",
          "without an absent key");
    check(must(must(s.without_attribute("material"), "without_attribute").attributes(), "attributes").empty(), "without a present key");
    check(must(must(Solid::cuboid(1, 1, 1), "cuboid").attributes(), "attributes").empty(), "a plain solid has none");
    check(listed(must(must(s.with_attributes({}), "with_attributes").attributes(), "attributes")) == "material=steel;",
          "with no attributes: equal to this one");
}

static void face_attributes() {
    Solid block = must(Solid::cuboid(10, 10, 10), "cuboid");
    std::uint32_t side = bs::NONE;
    for (std::uint32_t f = 0; f < 6 && side == bs::NONE; ++f) {
        if (std::fabs(nz(block, f)) < 0.5) side = f;
    }
    Solid s = must(block.with_face_attribute(side, "finish", "ground"), "with_face_attribute");
    check(must(s.face_attribute(side, "finish"), "face_attribute") == std::optional<std::string>("ground"), "face_attribute");
    const std::uint32_t other = (side + 1) % 6;
    check(!must(s.face_attribute(other, "finish"), "face_attribute"), "another face has none");
    check(must(s.face_attributes(other), "face_attributes").empty(), "another face lists none");
    check(listed(must(s.face_attributes(side), "face_attributes")) == "finish=ground;", "face_attributes");
    Solid two = must(s.with_face_attributes(side, {{"b", "1"}, {"a", "2"}}), "with_face_attributes");
    const std::string order = listed(must(two.face_attributes(side), "face_attributes"));
    check(order == "a=2;b=1;finish=ground;", "listed in key order: " + order);
    check(must(must(s.without_face_attribute(side, "finish"), "without_face_attribute").face_attributes(side), "face_attributes").empty(),
          "without_face_attribute");
    check(must(must(s.translate(5, 0, 0), "translate").face_attribute(side, "finish"), "face_attribute") == std::optional<std::string>("ground"),
          "survives a translate");
    refused_with(s.face_attribute(6, "finish"), "face_attribute: face 6 is not one of the solid's 6", "face 6");
    refused_with(s.with_face_attribute(side, "", "x"), "with_face_attribute: the key is empty", "an empty key");
    const std::uint64_t side_id = id(s, side);
    std::vector<std::optional<std::string>> found;
    for (const Solid& p : split_xy(s)) {
        for (std::uint32_t f = 0; f < p.faces(); ++f) {
            std::vector<IdOrigin> o = must(p.face_origins(f), "face_origins");
            if (std::find(o.begin(), o.end(), IdOrigin(0, side_id)) != o.end()) found.push_back(must(p.face_attribute(f, "finish"), "face_attribute"));
        }
    }
    check(found == std::vector<std::optional<std::string>>{std::string("ground"), std::string("ground")}, "both pieces of the side read ground");
}

static std::size_t occurrences(const std::string& text, const std::string& what) {
    std::size_t n = 0;
    for (std::size_t at = text.find(what); at != std::string::npos; at = text.find(what, at + what.size())) ++n;
    return n;
}

static void a_solids_attributes_reach_step() {
    std::string text = must(must(must(Solid::cuboid(1, 2, 3), "cuboid").with_attribute("material", "steel"), "with_attribute").step_text(), "step_text");
    check(occurrences(text, "PROPERTY_DEFINITION('material','user defined attribute',") == 1, "one user-defined attribute");
    check(text.find("DESCRIPTIVE_REPRESENTATION_ITEM('material','steel')") != std::string::npos, "its value");
    check(text.substr(0, text.find("ENDSEC;")).find("AP242") != std::string::npos, "the header names the AP242 schema");
}

static void edge_and_vertex_references() {
    Solid cube = must(Solid::cuboid(10, 10, 10), "cuboid");
    Solid longer = must(Solid::cuboid(11, 10, 10), "cuboid");
    const std::uint32_t n = static_cast<std::uint32_t>(must(cube.edges(), "edges").size());
    std::vector<std::array<double, 15>> refs;
    std::vector<std::uint32_t> found;
    for (std::uint32_t e = 0; e < n; ++e) {
        refs.push_back(must(cube.edge_ref(e), "edge_ref"));
        std::optional<std::uint32_t> g = must(longer.find_edge(refs.back()), "find_edge");
        check(g.has_value(), "edge " + std::to_string(e) + " found again");
        found.push_back(g.value_or(bs::NONE));
    }
    std::vector<std::uint32_t> sorted = found;
    std::sort(sorted.begin(), sorted.end());
    std::vector<std::uint32_t> all;
    for (std::uint32_t e = 0; e < n; ++e) all.push_back(e);
    check(n == 12 && sorted == all, "a permutation of all twelve");
    for (std::uint32_t e = 0; e < n && found[e] != bs::NONE; ++e) {
        std::array<double, 15> t = must(longer.edge_ref(found[e]), "edge_ref");
        const double dot = refs[e][4] * t[4] + refs[e][5] * t[5] + refs[e][6] * t[6];
        check(std::fabs(dot) > 0.99, "edge " + std::to_string(e) + ": tangents parallel");
    }
    // A 14-number reference cannot be passed: the reference is a std::array<double, 15>.
    std::array<double, 15> bad = refs[0];
    bad[1] = std::numeric_limits<double>::quiet_NaN();
    refused_with(cube.find_edge(bad), "find_edge: an edge reference is fifteen finite numbers", "a NaN edge reference");
    refused_with(cube.edge_ref(12), "edge_ref: edge 12 of 12", "edge_ref(12)");
    check(must(cube.vertex_count(), "vertex_count") == 8, "eight vertices");
    Solid moved = must(cube.translate(1e-4, 0, 0), "translate");
    for (std::uint32_t v = 0; v < 8; ++v) {
        bs::Vec3 p = must(cube.vertex_ref(v), "vertex_ref");
        check(must(moved.find_vertex(p), "find_vertex") == std::optional<std::uint32_t>(v), "vertex " + std::to_string(v) + " found again");
    }
    check(!must(cube.find_vertex({100, 0, 0}), "find_vertex"), "a far point finds none");
    refused(cube.find_vertex({0, 0, std::numeric_limits<double>::quiet_NaN()}), "find_vertex: ", "a NaN point");
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
        {"tracking", tracking},
        {"a_cuts_origins_and_history", a_cuts_origins_and_history},
        {"a_union_renumbers_the_second_operands_clashing_ids", a_union_renumbers_the_second_operands_clashing_ids},
        {"a_split_halves_the_sides", a_split_halves_the_sides},
        {"a_fillets_round_is_generated", a_fillets_round_is_generated},
        {"a_flush_join_merged_names_one_origin_per_input", a_flush_join_merged_names_one_origin_per_input},
        {"the_same_chain_twice_numbers_the_same", the_same_chain_twice_numbers_the_same},
        {"attributes", attributes},
        {"face_attributes", face_attributes},
        {"a_solids_attributes_reach_step", a_solids_attributes_reach_step},
        {"edge_and_vertex_references", edge_and_vertex_references},
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
    std::printf("identity: ok\n");
    return 0;
}
